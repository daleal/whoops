import Foundation
import Network
import OSLog

private let proxyLog = Logger(subsystem: "dev.whoops.app", category: "proxy")

final class ProxyServer {
    static let port: UInt16 = 61_337

    var onIntercept: ((InterceptedRequest) -> Void)?
    var onRequestClosed: ((UUID) -> Void)?
    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dev.whoops.proxy", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [UUID: ProxySession] = [:]
    private let maximumSessions = 256

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.listener == nil else {
                completion(.success(()))
                return
            }

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = false
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
                var didComplete = false

                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        proxyLog.info("Proxy listener ready on port \(Self.port)")
                        if !didComplete {
                            didComplete = true
                            completion(.success(()))
                        }
                    case .failed(let error):
                        proxyLog.error("Proxy listener failed: \(error.localizedDescription, privacy: .public)")
                        self.listener = nil
                        listener?.cancel()
                        if !didComplete {
                            didComplete = true
                            completion(.failure(error))
                        } else {
                            self.onFailure?(error.localizedDescription)
                        }
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener = listener
                listener.start(queue: self.queue)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async {
            let listener = self.listener
            self.listener = nil
            self.sessions.values.forEach { $0.cancel() }
            self.sessions.removeAll()
            guard let listener else {
                completion?()
                return
            }
            listener.stateUpdateHandler = { state in
                if case .cancelled = state {
                    completion?()
                }
            }
            listener.cancel()
        }
    }

    func route(requestID: UUID, choice: RouteChoice) {
        queue.async {
            self.sessions[requestID]?.route(choice)
        }
    }

    private func accept(_ connection: NWConnection) {
        let endpoint = String(describing: connection.endpoint)
        guard sessions.count < maximumSessions else {
            proxyLog.error("Rejected connection: session limit reached")
            connection.cancel()
            return
        }
        guard isLoopback(connection.endpoint) else {
            proxyLog.error("Rejected non-loopback connection from \(endpoint, privacy: .public)")
            connection.cancel()
            return
        }

        let session = ProxySession(client: connection, queue: queue)
        proxyLog.info("Accepted session \(session.id, privacy: .public) from \(endpoint, privacy: .public)")
        sessions[session.id] = session
        session.onIntercept = { [weak self] request in
            self?.onIntercept?(request)
        }
        session.onFinish = { [weak self] id in
            guard let self else { return }
            proxyLog.info("Finished session \(id, privacy: .public)")
            self.sessions.removeValue(forKey: id)
            self.onRequestClosed?(id)
        }
        session.start()
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let value = "\(host)".lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }
}

private final class ProxySession {
    let id = UUID()
    var onIntercept: ((InterceptedRequest) -> Void)?
    var onFinish: ((UUID) -> Void)?

    private enum State {
        case readingHead
        case awaitingChoice(HTTPRequestHead, host: String, port: Int)
        case connecting
        case relaying
        case closed
    }

    private let client: NWConnection
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var state: State = .readingHead
    private var bufferedClientData = Data()
    private var pendingUpstreamWrites: [Data] = []
    private var clientInputComplete = false
    private var interceptedIPv6 = false
    private let maximumHeaderSize = 1_048_576

    init(client: NWConnection, queue: DispatchQueue) {
        self.client = client
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                proxyLog.info("Session \(self.id, privacy: .public) client ready")
                self.interceptedIPv6 = self.localEndpointIsIPv6()
                self.receiveFromClient()
            case .failed(let error):
                proxyLog.error("Session \(self.id, privacy: .public) client failed: \(error.localizedDescription, privacy: .public)")
                self.finish()
            case .cancelled:
                proxyLog.info("Session \(self.id, privacy: .public) client cancelled")
                self.finish()
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    func cancel() {
        guard !isClosed else { return }
        state = .closed
        client.cancel()
        upstream?.cancel()
        onFinish?(id)
    }

    func route(_ choice: RouteChoice) {
        guard case let .awaitingChoice(head, originalHost, originalPort) = state else { return }

        let endpoint: NWEndpoint
        let parameters: NWParameters
        let rewrittenData: Data

        switch choice {
        case .passthrough:
            let loopback = passthroughHost(originalHost: originalHost)
            endpoint = .hostPort(
                host: NWEndpoint.Host(loopback),
                port: NWEndpoint.Port(rawValue: UInt16(originalPort))!
            )
            parameters = tcpParameters(localHost: interceptedIPv6 ? "fe80::1%lo0" : "127.0.0.2")
            rewrittenData = HTTPRequestParser.rewrite(
                bufferedClientData,
                head: head,
                destinationURL: nil,
                destinationPort: nil
            )

        case let .redirect(url, useOriginalPort):
            guard let host = url.host else {
                sendBadGateway("Invalid redirect URL")
                return
            }
            let usesTLS = url.scheme?.lowercased() == "https"
            let port = useOriginalPort ? originalPort : (usesTLS ? 443 : 80)
            endpoint = .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!
            )
            parameters = usesTLS ? NWParameters.tls : NWParameters.tcp
            rewrittenData = HTTPRequestParser.rewrite(
                bufferedClientData,
                head: head,
                destinationURL: url,
                destinationPort: useOriginalPort ? port : nil
            )
        }

        state = .connecting
        bufferedClientData.removeAll(keepingCapacity: false)
        pendingUpstreamWrites.append(rewrittenData)

        let upstream = NWConnection(to: endpoint, using: parameters)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self, weak upstream] newState in
            guard let self, let upstream else { return }
            switch newState {
            case .ready:
                self.state = .relaying
                self.flushPendingWrites(to: upstream)
                self.receiveFromUpstream(upstream)
            case .failed(let error):
                self.sendBadGateway(error.localizedDescription)
            case .cancelled:
                if !self.isClosed { self.closeClient() }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private func receiveFromClient() {
        guard !isClosed else { return }
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }

            var shouldContinueImmediately = true
            if let data, !data.isEmpty {
                shouldContinueImmediately = self.handleClientData(data)
            }
            if isComplete {
                self.clientInputComplete = true
                if case .readingHead = self.state {
                    self.finish()
                    return
                } else if case .relaying = self.state {
                    self.upstream?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
            }
            if error != nil {
                self.finish()
                return
            }
            if !isComplete && shouldContinueImmediately {
                self.receiveFromClient()
            }
        }
    }

    @discardableResult
    private func handleClientData(_ data: Data) -> Bool {
        switch state {
        case .readingHead:
            bufferedClientData.append(data)
            let prefix = data.prefix(12).map { String(format: "%02x", $0) }.joined()
            proxyLog.info("Session \(self.id, privacy: .public) received \(data.count) bytes; prefix=\(prefix, privacy: .public)")
            // HTTPS-first browsers must see their speculative TLS probe fail before
            // they will send the explicitly requested plaintext HTTP connection.
            if HTTPRequestParser.isTLSHandshake(bufferedClientData) {
                proxyLog.info("Session \(self.id, privacy: .public) rejected TLS handshake")
                finish()
                return false
            }
            guard bufferedClientData.count <= maximumHeaderSize else {
                sendHTTPError(status: "431 Request Header Fields Too Large", message: "Request headers are too large")
                return false
            }
            guard let head = HTTPRequestParser.parseHead(from: bufferedClientData),
                  let hostHeader = head.hostHeader,
                  let (host, port) = HTTPRequestParser.hostAndPort(from: hostHeader) else {
                if HTTPRequestParser.headerRange(in: bufferedClientData) != nil {
                    proxyLog.error("Session \(self.id, privacy: .public) received invalid HTTP headers")
                    sendHTTPError(status: "400 Bad Request", message: "A valid Host header is required")
                    return false
                }
                return true
            }
            state = .awaitingChoice(head, host: host, port: port)
            proxyLog.info("Session \(self.id, privacy: .public) intercepted \(head.method, privacy: .public) for \(host, privacy: .public):\(port)")
            onIntercept?(InterceptedRequest(
                id: id,
                method: head.method,
                path: HTTPRequestParser.displayPath(from: head.target),
                host: host,
                port: port,
                receivedAt: Date()
            ))
            return false

        case .awaitingChoice:
            bufferedClientData.append(data)
            return false

        case .connecting:
            pendingUpstreamWrites.append(data)
            return false

        case .relaying:
            upstream?.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.finish()
                } else if !self.clientInputComplete {
                    self.receiveFromClient()
                }
            })
            return false

        case .closed:
            return false
        }
    }

    private func flushPendingWrites(to upstream: NWConnection) {
        let writes = pendingUpstreamWrites
        pendingUpstreamWrites.removeAll()
        sendPendingWrites(writes, index: 0, to: upstream)
    }

    private func sendPendingWrites(_ writes: [Data], index: Int, to upstream: NWConnection) {
        guard index < writes.count else {
            if !clientInputComplete { receiveFromClient() }
            return
        }
        let isLast = clientInputComplete && index == writes.count - 1
        upstream.send(
            content: writes[index],
            contentContext: isLast ? .finalMessage : .defaultMessage,
            isComplete: isLast,
            completion: .contentProcessed { [weak self, weak upstream] error in
                guard let self, let upstream else { return }
                if error != nil {
                    self.finish()
                } else {
                    self.sendPendingWrites(writes, index: index + 1, to: upstream)
                }
            }
        )
    }

    private func receiveFromUpstream(_ upstream: NWConnection) {
        guard !isClosed else { return }
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak upstream] data, _, isComplete, error in
            guard let self, let upstream, !self.isClosed else { return }

            if let data, !data.isEmpty {
                self.client.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil {
                        self.finish()
                    } else if isComplete {
                        self.closeClient()
                    } else {
                        self.receiveFromUpstream(upstream)
                    }
                })
            } else if error != nil {
                self.closeClient()
            } else if isComplete {
                self.closeClient()
            } else {
                self.receiveFromUpstream(upstream)
            }
        }
    }

    private func passthroughHost(originalHost: String) -> String {
        if originalHost == "127.0.0.1" { return "127.0.0.1" }
        if originalHost == "::1" { return "::1" }
        return interceptedIPv6 ? "::1" : "127.0.0.1"
    }

    private func tcpParameters(localHost: String) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localHost), port: .any)
        return parameters
    }

    private func localEndpointIsIPv6() -> Bool {
        guard case let .hostPort(host, _) = client.currentPath?.localEndpoint else { return false }
        return "\(host)".contains(":")
    }

    private func sendBadGateway(_ message: String) {
        sendHTTPError(status: "502 Bad Gateway", message: message)
    }

    private func sendHTTPError(status: String, message: String) {
        guard !isClosed else { return }
        let body = "Whoops: \(message)\n"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        state = .closed
        upstream?.cancel()
        client.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.client.cancel()
            self?.onFinish?(self?.id ?? UUID())
        })
    }

    private func closeClient() {
        guard !isClosed else { return }
        state = .closed
        upstream?.cancel()
        client.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.client.cancel()
            self.onFinish?(self.id)
        })
    }

    private func finish() {
        guard !isClosed else { return }
        state = .closed
        client.cancel()
        upstream?.cancel()
        onFinish?(id)
    }
}
