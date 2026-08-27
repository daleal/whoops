import AppKit
import Foundation

enum PacketFilterError: LocalizedError {
    case authorization(String)
    case stopFile(String)

    var errorDescription: String? {
        switch self {
        case .authorization(let message): message
        case .stopFile(let message): message
        }
    }
}

struct PacketFilter {
    static let anchor = "com.apple/whoops"

    let appPID: Int32
    let userID: uid_t

    var stopFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whoops", isDirectory: true)
            .appendingPathComponent("filter-\(appPID).stop")
    }

    var watcherFilePath: String {
        "/var/run/whoops-\(userID)-\(appPID).sh"
    }

    var stateFilePath: String {
        "/var/run/whoops-\(userID)-\(appPID).state"
    }

    func enable() throws {
        let directory = stopFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stopFileURL)

        let escapedStopPath = shellQuote(stopFileURL.path)
        let watcherPath = watcherFilePath
        let statePath = stateFilePath
        // Reply packets from the proxy to a client's ephemeral port must match no
        // translation rule at all: any rdr/no-rdr match on a reply suppresses pf's
        // state-based reverse translation and wedges the connection. The redirected
        // port range therefore stops below the ephemeral floor, and the proxy's own
        // upstream connections are excluded by source (127.0.0.2 / fe80::1).
        let redirectUpperBound = Self.ephemeralPortFloor() - 1
        let rules = """
        rdr pass on lo0 inet proto tcp from ! 127.0.0.2 to 127.0.0.1 port 1:\(redirectUpperBound) -> 127.0.0.1 port \(ProxyServer.port)
        rdr pass on lo0 inet6 proto tcp from ! fe80::1 to ::1 port 1:\(redirectUpperBound) -> ::1 port \(ProxyServer.port)
        """ + "\n"
        let watcher = """
        while /bin/kill -0 \(appPID) 2>/dev/null && [ ! -e \(escapedStopPath) ]; do
          /bin/sleep 0.25
        done
        until /sbin/pfctl -a \(Self.anchor) -f /dev/null >/dev/null 2>&1; do
          /bin/sleep 0.25
        done
        if [ "$2" = "1" ]; then /sbin/ifconfig lo0 -alias 127.0.0.2 >/dev/null 2>&1 || true; fi
        if [ -n "$1" ]; then
          refs=$(/sbin/pfctl -s References 2>/dev/null) || exit 1
          if /bin/echo "$refs" | /usr/bin/grep -F -q "$1"; then
            /sbin/pfctl -X "$1" >/dev/null 2>&1 || exit 1
          fi
        fi
        /bin/rm -f \(shellQuote(statePath))
        /bin/rm -f \(shellQuote(watcherPath))
        """
        let watcherBase64 = Data(watcher.utf8).base64EncodedString()
        let rulesBase64 = Data(rules.utf8).base64EncodedString()

        let script = """
        set -e
        token=""
        added4=0
        /bin/echo \(shellQuote(watcherBase64)) | /usr/bin/base64 -D > \(shellQuote(watcherPath))
        /bin/chmod 700 \(shellQuote(watcherPath))
        /usr/bin/printf '%s\n%s\n' "$token" "$added4" > \(shellQuote(statePath))
        /bin/chmod 600 \(shellQuote(statePath))
        cleanup_setup() {
          trap - EXIT
          set +e
          cleanup_ok=1
          attempts=0
          until /sbin/pfctl -a \(Self.anchor) -f /dev/null >/dev/null 2>&1; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 20 ]; then cleanup_ok=0; break; fi
            /bin/sleep 0.25
          done
          if [ "$added4" = "1" ]; then /sbin/ifconfig lo0 -alias 127.0.0.2 >/dev/null 2>&1 || true; fi
          if [ -n "$token" ]; then
            refs=$(/sbin/pfctl -s References 2>/dev/null)
            if [ "$?" -ne 0 ]; then
              cleanup_ok=0
            elif /bin/echo "$refs" | /usr/bin/grep -F -q "$token"; then
              /sbin/pfctl -X "$token" >/dev/null 2>&1 || cleanup_ok=0
            fi
          fi
          if [ "$cleanup_ok" = "1" ]; then
            /bin/rm -f \(shellQuote(statePath)) \(shellQuote(watcherPath))
          else
            /usr/bin/printf '%s\n%s\n' "$token" "$added4" > \(shellQuote(statePath))
            /usr/bin/touch \(escapedStopPath)
            /usr/bin/nohup /bin/sh \(shellQuote(watcherPath)) "$token" "$added4" </dev/null >/dev/null 2>&1 &
          fi
        }
        trap cleanup_setup EXIT
        if ! /sbin/ifconfig lo0 | /usr/bin/grep -F -q 'inet 127.0.0.2 '; then
          /sbin/ifconfig lo0 inet 127.0.0.2 netmask 255.255.255.255 alias
          added4=1
          /usr/bin/printf '%s\n%s\n' "$token" "$added4" > \(shellQuote(statePath))
        fi
        /bin/echo \(shellQuote(rulesBase64)) | /usr/bin/base64 -D | /sbin/pfctl -a \(Self.anchor) -f -
        if ! /sbin/pfctl -s info 2>/dev/null | /usr/bin/grep -q '^Status: Enabled'; then
          output=$(/sbin/pfctl -E 2>&1)
          token=$(/bin/echo "$output" | /usr/bin/awk '/Token/ { print $NF; exit }')
          [ -n "$token" ]
        fi
        /usr/bin/printf '%s\n%s\n' "$token" "$added4" > \(shellQuote(statePath))
        /usr/bin/nohup /bin/sh \(shellQuote(watcherPath)) "$token" "$added4" </dev/null >/dev/null 2>&1 &
        trap - EXIT
        """

        try runWithAdministratorPrivileges(script)
    }

    static func ephemeralPortFloor() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("net.inet.ip.portrange.first", &value, &size, nil, 0)
        guard result == 0, value > 1024, value <= 65535 else { return 49152 }
        return Int(value)
    }

    func signalDisable() throws {
        do {
            try Data().write(to: stopFileURL, options: .atomic)
        } catch {
            throw PacketFilterError.stopFile(error.localizedDescription)
        }
    }

    func waitForDisable(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: watcherFilePath) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !FileManager.default.fileExists(atPath: watcherFilePath)
    }

    func forceDisable() throws {
        let script = """
        set -e
        token=""
        added4=0
        if [ -f \(shellQuote(stateFilePath)) ]; then
          token=$(/usr/bin/sed -n '1p' \(shellQuote(stateFilePath)))
          added4=$(/usr/bin/sed -n '2p' \(shellQuote(stateFilePath)))
        fi
        /sbin/pfctl -a \(Self.anchor) -f /dev/null >/dev/null 2>&1
        if [ "$added4" = "1" ]; then /sbin/ifconfig lo0 -alias 127.0.0.2 >/dev/null 2>&1 || true; fi
        if [ -n "$token" ]; then
          refs=$(/sbin/pfctl -s References 2>/dev/null)
          if /bin/echo "$refs" | /usr/bin/grep -F -q "$token"; then
            /sbin/pfctl -X "$token" >/dev/null 2>&1
          fi
        fi
        /bin/rm -f \(shellQuote(stateFilePath)) \(shellQuote(watcherFilePath))
        """
        try runWithAdministratorPrivileges(script)
    }

    private func runWithAdministratorPrivileges(_ script: String) throws {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Administrator authorization was cancelled"
            throw PacketFilterError.authorization(message)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
