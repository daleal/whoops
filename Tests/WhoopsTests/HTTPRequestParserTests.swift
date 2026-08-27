import Foundation
import Network
import Testing
@testable import Whoops

@Suite(.serialized)
struct HTTPRequestParserTests {
    @Test func parsesLocalhostWithPort() throws {
        let data = Data("GET /hello?q=1 HTTP/1.1\r\nHost: localhost:3000\r\nAccept: */*\r\n\r\n".utf8)
        let head = try #require(HTTPRequestParser.parseHead(from: data))

        #expect(head.method == "GET")
        #expect(head.target == "/hello?q=1")
        #expect(HTTPRequestParser.hostAndPort(from: try #require(head.hostHeader))?.0 == "localhost")
        #expect(HTTPRequestParser.hostAndPort(from: try #require(head.hostHeader))?.1 == 3000)
    }

    @Test func parsesIPv6Host() {
        let parsed = HTTPRequestParser.hostAndPort(from: "[::1]:8080")
        #expect(parsed?.0 == "::1")
        #expect(parsed?.1 == 8080)
    }

    @Test func rewritesRedirectAndPreservesBody() throws {
        let original = Data("POST /api/items HTTP/1.1\r\nHost: localhost:4000\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\ntest".utf8)
        let head = try #require(HTTPRequestParser.parseHead(from: original))
        let destination = try #require(URL(string: "https://remote.dev/base"))
        let rewritten = HTTPRequestParser.rewrite(
            original,
            head: head,
            destinationURL: destination,
            destinationPort: nil
        )
        let text = try #require(String(data: rewritten, encoding: .utf8))

        #expect(text.hasPrefix("POST /base/api/items HTTP/1.1\r\n"))
        #expect(text.contains("Host: remote.dev\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\ntest"))
    }

    @Test func samePortAppearsInRedirectHost() throws {
        let original = Data("GET / HTTP/1.1\r\nHost: 127.0.0.1:8123\r\n\r\n".utf8)
        let head = try #require(HTTPRequestParser.parseHead(from: original))
        let destination = try #require(URL(string: "http://remote.dev"))
        let rewritten = HTTPRequestParser.rewrite(
            original,
            head: head,
            destinationURL: destination,
            destinationPort: 8123
        )
        let text = try #require(String(data: rewritten, encoding: .utf8))

        #expect(text.contains("Host: remote.dev:8123\r\n"))
    }

    @Test func preservesPercentEncodedPath() throws {
        let original = Data("GET /files/a%2Fb%20c HTTP/1.1\r\nHost: localhost:3000\r\n\r\n".utf8)
        let head = try #require(HTTPRequestParser.parseHead(from: original))
        let destination = try #require(URL(string: "https://remote.dev/root%20dir"))
        let rewritten = HTTPRequestParser.rewrite(
            original,
            head: head,
            destinationURL: destination,
            destinationPort: nil
        )
        let text = try #require(String(data: rewritten, encoding: .utf8))

        #expect(text.hasPrefix("GET /root%20dir/files/a%2Fb%20c HTTP/1.1\r\n"))
    }

    @Test func ephemeralPortFloorIsSaneAndAboveProxyRedirectRange() {
        let floor = PacketFilter.ephemeralPortFloor()
        #expect(floor > 1024)
        #expect(floor <= 65535)
        #expect(Int(ProxyServer.port) >= floor, "Proxy port must sit outside the redirected range to avoid self-capture")
    }

    @Test func recognizesTLSHandshakeWithoutMistakingHTTPForTLS() {
        #expect(HTTPRequestParser.isTLSHandshake(Data([0x16, 0x03, 0x01, 0x00, 0x10])))
        #expect(HTTPRequestParser.isTLSHandshake(Data("GET / HTTP/1.1\r\n".utf8)) == false)
    }

    @Test func proxyHoldsThenRoutesARequest() throws {
        let queue = DispatchQueue(label: "dev.whoops.integration-test")
        let upstreamReady = DispatchSemaphore(value: 0)
        let proxyReady = DispatchSemaphore(value: 0)
        let intercepted = DispatchSemaphore(value: 0)
        let responseReceived = DispatchSemaphore(value: 0)
        let upstream = try NWListener(using: .tcp, on: .any)

        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let body = "routed"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(response.utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        upstream.stateUpdateHandler = { state in
            if case .ready = state { upstreamReady.signal() }
        }
        upstream.start(queue: queue)
        #expect(upstreamReady.wait(timeout: .now() + 3) == .success)
        let upstreamPort = try #require(upstream.port?.rawValue)

        let proxy = ProxyServer()
        proxy.start { result in
            if case .success = result { proxyReady.signal() }
        }
        #expect(proxyReady.wait(timeout: .now() + 3) == .success)

        proxy.onIntercept = { request in
            intercepted.signal()
            queue.asyncAfter(deadline: .now() + 0.15) {
                proxy.route(
                    requestID: request.id,
                    choice: .redirect(URL(string: "http://127.0.0.1")!, useOriginalPort: true)
                )
            }
        }

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: ProxyServer.port)!,
            using: .tcp
        )
        let response = ResponseBox()
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let request = "GET /probe HTTP/1.1\r\nHost: localhost:\(upstreamPort)\r\n\r\n"
            client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            receiveAll(from: client, into: response) { _ = responseReceived.signal() }
        }
        client.start(queue: queue)

        #expect(intercepted.wait(timeout: .now() + 3) == .success)
        #expect(responseReceived.wait(timeout: .now() + 3) == .success)
        #expect(String(data: response.data, encoding: .utf8)?.hasSuffix("routed") == true)

        client.cancel()
        stopAndWait(proxy)
        upstream.cancel()
    }

    @Test func proxyRejectsTLSProbeWithoutCreatingAnIntercept() {
        let queue = DispatchQueue(label: "dev.whoops.tls-probe-test")
        let proxyReady = DispatchSemaphore(value: 0)
        let connectionClosed = DispatchSemaphore(value: 0)
        let intercepted = DispatchSemaphore(value: 0)
        let proxy = ProxyServer()
        proxy.onIntercept = { _ in intercepted.signal() }
        proxy.start { result in
            if case .success = result { proxyReady.signal() }
        }
        #expect(proxyReady.wait(timeout: .now() + 3) == .success)

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: ProxyServer.port)!,
            using: .tcp
        )
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data([0x16, 0x03, 0x01, 0x00, 0x10]), completion: .contentProcessed { _ in
                client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                    connectionClosed.signal()
                }
            })
        }
        client.start(queue: queue)

        #expect(connectionClosed.wait(timeout: .now() + 3) == .success)
        #expect(intercepted.wait(timeout: .now() + 0.1) == .timedOut)

        client.cancel()
        stopAndWait(proxy)
    }

    @Test func proxyReleasesAnIncompleteEOF() {
        let queue = DispatchQueue(label: "dev.whoops.eof-test")
        let proxyReady = DispatchSemaphore(value: 0)
        let sessionClosed = DispatchSemaphore(value: 0)
        let proxy = ProxyServer()
        proxy.onRequestClosed = { _ in sessionClosed.signal() }
        proxy.start { result in
            if case .success = result { proxyReady.signal() }
        }
        #expect(proxyReady.wait(timeout: .now() + 3) == .success)

        let client = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: ProxyServer.port)!,
            using: .tcp
        )
        client.stateUpdateHandler = { state in
            if case .ready = state {
                client.send(
                    content: Data("GET /incomplete".utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .idempotent
                )
            }
        }
        client.start(queue: queue)

        #expect(sessionClosed.wait(timeout: .now() + 3) == .success)
        client.cancel()
        stopAndWait(proxy)
    }

    @Test func ipv6PassthroughUsesExistingLoopbackAddress() throws {
        let queue = DispatchQueue(label: "dev.whoops.ipv6-test")
        let upstreamReady = DispatchSemaphore(value: 0)
        let proxyReady = DispatchSemaphore(value: 0)
        let responseReceived = DispatchSemaphore(value: 0)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        let upstream = try NWListener(using: parameters)

        upstream.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                let response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(response.utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        upstream.stateUpdateHandler = { state in
            if case .ready = state { upstreamReady.signal() }
        }
        upstream.start(queue: queue)
        #expect(upstreamReady.wait(timeout: .now() + 3) == .success)
        let upstreamPort = try #require(upstream.port?.rawValue)

        let proxy = ProxyServer()
        proxy.onIntercept = { request in proxy.route(requestID: request.id, choice: .passthrough) }
        proxy.start { result in
            if case .success = result { proxyReady.signal() }
        }
        #expect(proxyReady.wait(timeout: .now() + 3) == .success)

        let client = NWConnection(
            host: "::1",
            port: NWEndpoint.Port(rawValue: ProxyServer.port)!,
            using: .tcp
        )
        let response = ResponseBox()
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let request = "GET /ipv6 HTTP/1.1\r\nHost: localhost:\(upstreamPort)\r\n\r\n"
            client.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            receiveAll(from: client, into: response) { _ = responseReceived.signal() }
        }
        client.start(queue: queue)

        #expect(responseReceived.wait(timeout: .now() + 3) == .success)
        #expect(String(data: response.data, encoding: .utf8)?.contains("204 No Content") == true)

        client.cancel()
        stopAndWait(proxy)
        upstream.cancel()
    }
}

private final class ResponseBox {
    var data = Data()
}

private func stopAndWait(_ proxy: ProxyServer) {
    let stopped = DispatchSemaphore(value: 0)
    proxy.stop { stopped.signal() }
    _ = stopped.wait(timeout: .now() + 3)
}

private func receiveAll(from connection: NWConnection, into response: ResponseBox, completion: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, error in
        if let chunk { response.data.append(chunk) }
        if isComplete || error != nil {
            completion()
        } else {
            receiveAll(from: connection, into: response, completion: completion)
        }
    }
}
