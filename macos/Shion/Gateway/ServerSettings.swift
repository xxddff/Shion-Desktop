import Foundation

/// Where the Hermes server is and how to get in: the address in preferences, the Hermes session
/// token (the server's HERMES_DASHBOARD_SESSION_TOKEN) and the Cloudflare Access service token in
/// the keychain.
struct ServerSettings: Equatable {
    var address = ""
    var token = ""
    var accessClientId = ""
    var accessClientSecret = ""

    static func load() -> ServerSettings {
        ServerSettings(
            address: UserDefaults.standard.string(forKey: "ServerAddress") ?? "",
            token: Keychain.read("hermes-session-token"),
            accessClientId: Keychain.read("cf-access-client-id"),
            accessClientSecret: Keychain.read("cf-access-client-secret")
        )
    }

    func save() {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ServerAddress")
        Keychain.write(token, for: "hermes-session-token")
        Keychain.write(accessClientId, for: "cf-access-client-id")
        Keychain.write(accessClientSecret, for: "cf-access-client-secret")
    }

    /// Pasted values often carry a trailing newline or space; Hermes compares the token exactly.
    var trimmed: ServerSettings {
        ServerSettings(
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            accessClientId: accessClientId.trimmingCharacters(in: .whitespacesAndNewlines),
            accessClientSecret: accessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Enough of the token to compare with the server's without showing it: the first and last
    /// four characters and the length.
    var tokenHint: String {
        guard token.count > 8 else { return "\(token.count) 个字符" }
        return "\(token.prefix(4))…\(token.suffix(4))，\(token.count) 个字符"
    }

    var isConfigured: Bool { base != nil }

    /// `https://host[/prefix]`, without a trailing slash; a bare host means https.
    var base: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    var host: String { base?.host ?? "" }

    func httpURL(_ path: String) -> URL? {
        guard let base else { return nil }
        return URL(string: base.absoluteString + path)
    }

    /// `wss://host[/prefix]/api/ws?token=…`, as the official Desktop dials a remote gateway:
    /// no subprotocol, the token in the query.
    var socketURL: URL? {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += "/api/ws"
        if !token.isEmpty {
            // URLQueryItem leaves "+" alone, which a server reads as a space
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            components.percentEncodedQuery = "token=" + (token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token)
        }
        return components.url
    }

    /// The Cloudflare Access service token goes on every HTTP and WebSocket request.
    func applyAccessHeaders(to request: inout URLRequest) {
        if !accessClientId.isEmpty {
            request.setValue(accessClientId, forHTTPHeaderField: "CF-Access-Client-Id")
        }
        if !accessClientSecret.isEmpty {
            request.setValue(accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }
}
