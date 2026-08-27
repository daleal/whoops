import AppKit
import Foundation
import OSLog

private let appLog = Logger(subsystem: "dev.whoops.app", category: "app")

@MainActor
final class AppModel: ObservableObject {
    enum FilterState: Equatable {
        case off
        case enabling
        case on
        case disabling

        var isBusy: Bool { self == .enabling || self == .disabling }
    }

    @Published private(set) var filterState: FilterState = .off
    @Published private(set) var pending: [InterceptedRequest] = []
    @Published var targets: [RedirectTarget] {
        didSet { saveTargets() }
    }
    @Published var errorMessage: String?
    var onUserResolvedAll: (() -> Void)?

    private let proxy = ProxyServer()
    private let packetFilter = PacketFilter(appPID: ProcessInfo.processInfo.processIdentifier, userID: getuid())
    private var proxyFailureDuringEnable: String?
    private static let targetsKey = "redirectTargets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.targetsKey),
           let decoded = try? JSONDecoder().decode([RedirectTarget].self, from: data) {
            targets = decoded
        } else {
            targets = [RedirectTarget(url: "http://remote.dev.fin")]
        }

        proxy.onIntercept = { [weak self] request in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.append(request)
                appLog.info("Added intercept \(request.id, privacy: .public); pending=\(self.pending.count)")
                NSSound(named: "Pop")?.play()
            }
        }
        proxy.onRequestClosed = { [weak self] id in
            DispatchQueue.main.async {
                self?.pending.removeAll { $0.id == id }
            }
        }
        proxy.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.errorMessage = message
                if self.filterState == .on {
                    self.disable(afterProxyFailure: true)
                } else if self.filterState == .enabling {
                    self.proxyFailureDuringEnable = message
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func addTarget() {
        targets.append(RedirectTarget(url: "https://"))
    }

    func removeTarget(id: UUID) {
        targets.removeAll { $0.id == id }
    }

    func passthrough(_ request: InterceptedRequest) {
        pending.removeAll { $0.id == request.id }
        if pending.isEmpty { onUserResolvedAll?() }
        proxy.route(requestID: request.id, choice: .passthrough)
    }

    func redirect(_ request: InterceptedRequest, to target: RedirectTarget, samePort: Bool) {
        guard let url = target.parsedURL else { return }
        pending.removeAll { $0.id == request.id }
        if pending.isEmpty { onUserResolvedAll?() }
        proxy.route(requestID: request.id, choice: .redirect(url, useOriginalPort: samePort))
    }

    func quit() {
        if filterState == .on {
            disable(quitAfter: true)
        } else if filterState == .disabling {
            return
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func enable() {
        guard filterState == .off else { return }
        filterState = .enabling
        errorMessage = nil
        proxyFailureDuringEnable = nil

        proxy.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.filterState = .off
                    self.errorMessage = error.localizedDescription
                case .success:
                    Task {
                        do {
                            try await Task.detached { [packetFilter = self.packetFilter] in
                                try packetFilter.enable()
                            }.value
                            self.filterState = .on
                            appLog.info("Packet filter enabled")
                            if self.proxyFailureDuringEnable != nil {
                                self.disable(afterProxyFailure: true)
                            }
                        } catch {
                            let setupError = error
                            let cleaned = await Task.detached { [packetFilter = self.packetFilter] in
                                if packetFilter.waitForDisable() { return true }
                                do {
                                    try packetFilter.forceDisable()
                                    return true
                                } catch {
                                    return false
                                }
                            }.value
                            if cleaned {
                                self.proxy.stop()
                                self.filterState = .off
                                self.errorMessage = setupError.localizedDescription
                            } else {
                                self.filterState = .on
                                self.errorMessage = "Setup failed and PF cleanup could not be confirmed. The proxy remains running."
                            }
                        }
                    }
                }
            }
        }
    }

    private func disable(afterProxyFailure: Bool = false, quitAfter: Bool = false) {
        guard filterState == .on else { return }
        filterState = .disabling
        if !afterProxyFailure { errorMessage = nil }

        do {
            try packetFilter.signalDisable()
            Task {
                let disabled = await Task.detached { [packetFilter = self.packetFilter] in
                    packetFilter.waitForDisable()
                }.value
                if disabled {
                    self.completeDisable(quitAfter: quitAfter)
                } else {
                    do {
                        try await Task.detached { [packetFilter = self.packetFilter] in
                            try packetFilter.forceDisable()
                        }.value
                        self.completeDisable(quitAfter: quitAfter)
                    } catch {
                        self.filterState = .on
                        self.errorMessage = "Packet-filter cleanup failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            if afterProxyFailure {
                let cleanupError = error
                Task {
                    do {
                        try await Task.detached { [packetFilter = self.packetFilter] in
                            try packetFilter.forceDisable()
                        }.value
                        self.completeDisable(quitAfter: quitAfter)
                    } catch {
                        self.errorMessage = "Proxy failed and cleanup could not be confirmed: \(cleanupError.localizedDescription)"
                        NSApplication.shared.terminate(nil)
                    }
                }
            } else {
                filterState = .on
                errorMessage = error.localizedDescription
            }
        }
    }

    private func completeDisable(quitAfter: Bool) {
        appLog.info("Packet filter disabled")
        proxy.stop()
        pending.removeAll()
        onUserResolvedAll?()
        filterState = .off
        if quitAfter {
            NSApplication.shared.terminate(nil)
        }
    }

    private func saveTargets() {
        guard let data = try? JSONEncoder().encode(targets) else { return }
        UserDefaults.standard.set(data, forKey: Self.targetsKey)
    }
}
