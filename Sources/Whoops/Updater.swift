import AppKit
import CryptoKit
import Foundation
import OSLog

private let updateLog = Logger(subsystem: "dev.whoops.app", category: "updater")

@MainActor
final class UpdaterModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case available(String)
        case updating
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    static let repository = "daleal/whoops"

    private let restart: () -> Void
    private var release: Release?

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    init(restart: @escaping () -> Void) {
        self.restart = restart
        Task { await check() }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func check() async {
        guard status == .idle || isFailed, let current = Self.parseVersion(currentVersion) else { return }
        status = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                status = .idle
                return
            }
            let latest = try JSONDecoder().decode(Release.self, from: data)
            let latestVersion = latest.tagName.hasPrefix("v") ? String(latest.tagName.dropFirst()) : latest.tagName
            guard let parsedLatest = Self.parseVersion(latestVersion), parsedLatest.lexicographicallyPrecedes(current) == false, parsedLatest != current else {
                status = .idle
                return
            }
            release = latest
            status = .available(latestVersion)
            updateLog.info("Update available: v\(latestVersion, privacy: .public)")
        } catch {
            updateLog.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = .idle
        }
    }

    func update() {
        switch status {
        case .available, .failed:
            break
        default:
            return
        }
        guard let release else { return }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        status = .updating
        Task {
            do {
                try await install(version: version, release: release)
                restart()
            } catch {
                updateLog.error("Update failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func install(version: String, release: Release) async throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError("Not running from an app bundle")
        }

        let zipName = "Whoops-v\(version).zip"
        guard let zipAsset = release.assets.first(where: { $0.name == zipName }) else {
            throw UpdateError("Release is missing \(zipName)")
        }
        let shaAsset = release.assets.first { $0.name == "\(zipName).sha256" }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whoops-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let (downloaded, zipResponse) = try await URLSession.shared.download(from: zipAsset.browserDownloadURL)
        guard let zipHTTP = zipResponse as? HTTPURLResponse, zipHTTP.statusCode == 200 else {
            throw UpdateError("Download failed for \(zipName)")
        }
        let zipURL = staging.appendingPathComponent(zipName)
        try FileManager.default.moveItem(at: downloaded, to: zipURL)

        if let shaAsset {
            let (shaData, shaResponse) = try await URLSession.shared.data(from: shaAsset.browserDownloadURL)
            guard let shaHTTP = shaResponse as? HTTPURLResponse, shaHTTP.statusCode == 200,
                  let expected = String(data: shaData, encoding: .utf8)?
                      .split(separator: " ", omittingEmptySubsequences: true).first
            else {
                throw UpdateError("Checksum download failed")
            }
            let digest = SHA256.hash(data: try Data(contentsOf: zipURL))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else {
                throw UpdateError("Checksum mismatch")
            }
        }

        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw UpdateError("Could not extract the update")
        }

        let newApp = extracted.appendingPathComponent("Whoops.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Whoops").path) else {
            throw UpdateError("Update archive did not contain Whoops.app")
        }

        let retired = staging.appendingPathComponent("Whoops-old.app", isDirectory: true)
        try FileManager.default.moveItem(at: bundleURL, to: retired)
        do {
            try FileManager.default.moveItem(at: newApp, to: bundleURL)
        } catch {
            try? FileManager.default.moveItem(at: retired, to: bundleURL)
            throw error
        }

        try spawnRelauncher(appPath: bundleURL.path)
        updateLog.info("Installed v\(version, privacy: .public); restarting")
    }

    private func spawnRelauncher(appPath: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let escaped = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open '\(escaped)'"
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", script]
        try relauncher.run()
    }

    private static func parseVersion(_ raw: String) -> [Int]? {
        let parts = raw.split(separator: ".").map { Int($0) }
        guard parts.count == 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
