import Foundation

struct RedirectTarget: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: String

    var parsedURL: URL? {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = value.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              value.host != nil else {
            return nil
        }
        return value
    }

    var defaultPort: Int {
        parsedURL?.scheme?.lowercased() == "https" ? 443 : 80
    }
}

struct InterceptedRequest: Identifiable, Equatable {
    let id: UUID
    let method: String
    let path: String
    let host: String
    let port: Int
    let receivedAt: Date
}

enum RouteChoice {
    case passthrough
    case redirect(URL, useOriginalPort: Bool)
}

struct HTTPRequestHead: Equatable {
    let method: String
    let target: String
    let version: String
    let headers: [(name: String, value: String)]

    static func == (lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        lhs.method == rhs.method &&
            lhs.target == rhs.target &&
            lhs.version == rhs.version &&
            lhs.headers.elementsEqual(rhs.headers, by: ==)
    }

    var hostHeader: String? {
        headers.first { $0.name.caseInsensitiveCompare("Host") == .orderedSame }?.value
    }

    var isUpgrade: Bool {
        headers.contains {
            $0.name.caseInsensitiveCompare("Upgrade") == .orderedSame
        }
    }
}

enum HTTPRequestParser {
    static let headerTerminator = Data("\r\n\r\n".utf8)

    static func isTLSHandshake(_ data: Data) -> Bool {
        let prefix = data.prefix(3)
        guard prefix.count == 3 else { return false }
        return prefix[prefix.startIndex] == 0x16 &&
            prefix[prefix.index(after: prefix.startIndex)] == 0x03 &&
            prefix[prefix.index(prefix.startIndex, offsetBy: 2)] <= 0x04
    }

    static func headerRange(in data: Data) -> Range<Data.Index>? {
        data.range(of: headerTerminator)
    }

    static func parseHead(from data: Data) -> HTTPRequestHead? {
        guard let range = headerRange(in: data),
              let text = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            return nil
        }

        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers.append((name, value))
        }

        return HTTPRequestHead(
            method: parts[0],
            target: parts[1],
            version: parts[2],
            headers: headers
        )
    }

    static func hostAndPort(from hostHeader: String, defaultPort: Int = 80) -> (String, Int)? {
        let value = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            let suffix = value[value.index(after: closingBracket)...]
            if suffix.isEmpty { return (host, defaultPort) }
            guard suffix.first == ":", let port = Int(suffix.dropFirst()), (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        let colonCount = value.filter { $0 == ":" }.count
        if colonCount == 1, let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            guard let port = Int(value[value.index(after: colon)...]), (1...65535).contains(port) else {
                return nil
            }
            return (host, port)
        }

        return (value, defaultPort)
    }

    static func displayPath(from target: String) -> String {
        guard !target.hasPrefix("/"),
              let components = URLComponents(string: target),
              components.scheme != nil else {
            return target
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?\(query)" }
        return path
    }

    static func rewrite(
        _ data: Data,
        head: HTTPRequestHead,
        destinationURL: URL?,
        destinationPort: Int?
    ) -> Data {
        guard let headerRange = headerRange(in: data) else { return data }

        var target = displayPath(from: head.target)
        var hostHeader = head.hostHeader ?? ""

        if let destinationURL, let host = destinationURL.host {
            target = joinedPath(baseURL: destinationURL, requestTarget: target)
            hostHeader = formattedHost(host, port: destinationPort)
        }

        var lines = ["\(head.method) \(target) \(head.version)"]
        var replacedHost = false
        var replacedConnection = false

        for header in head.headers {
            if header.name.caseInsensitiveCompare("Host") == .orderedSame {
                lines.append("Host: \(hostHeader)")
                replacedHost = true
            } else if header.name.caseInsensitiveCompare("Connection") == .orderedSame, !head.isUpgrade {
                lines.append("Connection: close")
                replacedConnection = true
            } else if header.name.caseInsensitiveCompare("Proxy-Connection") != .orderedSame {
                lines.append("\(header.name): \(header.value)")
            }
        }

        if !replacedHost { lines.append("Host: \(hostHeader)") }
        if !replacedConnection && !head.isUpgrade { lines.append("Connection: close") }

        let headerText = lines.joined(separator: "\r\n") + "\r\n\r\n"
        var result = headerText.data(using: .isoLatin1) ?? Data(headerText.utf8)
        result.append(data[headerRange.upperBound...])
        return result
    }

    private static func joinedPath(baseURL: URL, requestTarget: String) -> String {
        let encodedBasePath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? baseURL.path
        let basePath = encodedBasePath == "/" ? "" : encodedBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let request = requestTarget.hasPrefix("/") ? String(requestTarget.dropFirst()) : requestTarget
        let joined = [basePath, request].filter { !$0.isEmpty }.joined(separator: "/")
        var result = "/" + joined
        if result.isEmpty { result = "/" }
        if let query = baseURL.query, !query.isEmpty, !result.contains("?") {
            result += "?\(query)"
        }
        return result
    }

    private static func formattedHost(_ host: String, port: Int?) -> String {
        let formatted = host.contains(":") ? "[\(host)]" : host
        guard let port else { return formatted }
        return "\(formatted):\(port)"
    }
}
