import Foundation

/// Where the Hermes server is and how to get in: the address and the login method in
/// preferences; the Hermes session token (the server's HERMES_DASHBOARD_SESSION_TOKEN) and the
/// Cloudflare Access service token in the keychain. A browser sign-in's tokens are kept apart,
/// by `Account`.
struct ServerSettings: Equatable {
    enum Login: String {
        /// Hermes's own login page, in a browser sheet (RFC 8252 sign-in for native apps).
        case browser
        /// The deployment session token pasted in.
        case sessionToken
    }

    var address = ""
    var login = Login.browser
    var token = ""
    var accessClientId = ""
    var accessClientSecret = ""

    static func load() -> ServerSettings {
        let defaults = UserDefaults.standard
        return ServerSettings(
            address: defaults.string(forKey: "ServerAddress") ?? "",
            login: Login(rawValue: defaults.string(forKey: "ServerLogin") ?? "") ?? .browser,
            token: Keychain.read("hermes-session-token"),
            accessClientId: Keychain.read("cf-access-client-id"),
            accessClientSecret: Keychain.read("cf-access-client-secret")
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ServerAddress")
        defaults.set(login.rawValue, forKey: "ServerLogin")
        Keychain.write(token, for: "hermes-session-token")
        Keychain.write(accessClientId, for: "cf-access-client-id")
        Keychain.write(accessClientSecret, for: "cf-access-client-secret")
    }

    /// Pasted values often carry a trailing newline or space; Hermes compares the token exactly.
    var trimmed: ServerSettings {
        ServerSettings(
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            login: login,
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

    /// The server a sign-in belongs to: its tokens go to this address and nowhere else.
    var signInServer: String { base?.absoluteString ?? "" }

    var host: String { base?.host ?? "" }

    func httpURL(_ path: String) -> URL? {
        guard let base else { return nil }
        return URL(string: base.absoluteString + path)
    }

    /// `wss://host[/prefix]/api/ws?token=…`, as the official Desktop dials a remote gateway:
    /// no subprotocol, the token in the query. Either credential rides there: the session token,
    /// or a browser sign-in's access token.
    func socketURL(token: String) -> URL? {
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
        for (name, value) in accessHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Shion's own requests only: the sign-in window goes through Access as a browser does.
    var accessHeaders: [String: String] {
        var headers: [String: String] = [:]
        if !accessClientId.isEmpty {
            headers["CF-Access-Client-Id"] = accessClientId
        }
        if !accessClientSecret.isEmpty {
            headers["CF-Access-Client-Secret"] = accessClientSecret
        }
        return headers
    }

    /// `GET /api/status`, which Hermes answers without a login: says whether Cloudflare Access
    /// lets Shion through, and how the server takes logins. Nil when the reply is not Hermes's.
    func status() async throws -> ServerStatus? {
        guard let url = httpURL("/api/status") else { throw GatewayError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        applyAccessHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        // the route is public on Hermes: any refusal comes from in front of it
        try Self.checkAccess(response, publicRoute: true)
        guard let body = try? JSONValue.parse(String(decoding: data, as: UTF8.self)), body["auth_required"] != nil else { return nil }
        return ServerStatus(
            authRequired: body["auth_required"]?.bool ?? false,
            providers: (body["auth_providers"]?.array ?? []).compactMap { $0.string },
            flows: (body["auth_flows"]?.array ?? []).compactMap { $0.string },
            memoryMB: body["memory"]?["system_total_mb"]?.int
        )
    }

    /// Cloudflare Access turns a refused request into its login page or a 401/403. Hermes's own
    /// refusals are JSON, so on its other routes only a refusal that is not counts.
    static func checkAccess(_ response: URLResponse, publicRoute: Bool = false) throws {
        if let host = response.url?.host, host.hasSuffix("cloudflareaccess.com") {
            throw GatewayError.accessDenied
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 else { return }
        if publicRoute || http.mimeType != "application/json" {
            throw GatewayError.accessDenied
        }
    }
}

/// What `/api/status` says about logins.
nonisolated struct ServerStatus: Sendable {
    var authRequired: Bool
    var providers: [String]
    var flows: [String]
    /// The server's memory; nil where it cannot read it (it reads /proc/meminfo, so Linux only).
    var memoryMB: Int?

    /// The gateway brokers RFC 8252 sign-in when a provider has a login page (password or OAuth).
    var takesBrowserSignIn: Bool { flows.contains("native_pkce") }
}
