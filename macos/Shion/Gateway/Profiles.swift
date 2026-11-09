import Foundation

/// What a Hermes REST route refused, with FastAPI's `detail`: a sentence, or the reasons a body
/// did not validate.
nonisolated enum HermesAPIError: LocalizedError {
    case refused(Int, String)

    var status: Int {
        switch self {
        case .refused(let status, _): return status
        }
    }

    var errorDescription: String? {
        switch self {
        case .refused(let status, let detail):
            return detail.isEmpty ? "服务器返回 HTTP \(status)" : "\(detail)（HTTP \(status)）"
        }
    }
}

/// Hermes's own REST routes under `/api`: profiles and their SOUL, MCP servers, skills, toolsets,
/// config and the model list. Signed as the socket is (the session token as X-Hermes-Session-Token,
/// a sign-in as a bearer) plus the Cloudflare Access headers. Every call that is about one
/// assistant names its profile, in the path (`/api/profiles/{name}/…`) or as `?profile=`: without
/// one, a route acts on the gateway's own profile, whichever that is.
final class HermesAPI {
    typealias Signer = (_ settings: ServerSettings, _ renew: Bool) async throws -> Credential

    let settings: ServerSettings
    private let credential: Signer

    init(settings: ServerSettings, credential: @escaping Signer) {
        self.settings = settings
        self.credential = credential
    }

    func get(_ path: String, _ query: [(String, String)] = [], timeout: Double = 30) async throws -> JSONValue {
        try await request("GET", path, query, timeout: timeout)
    }

    /// One call; a 401 renews the credential once and tries again.
    @discardableResult
    func request(_ method: String, _ path: String, _ query: [(String, String)] = [], body: JSONValue = .null,
                 timeout: Double = 30) async throws -> JSONValue {
        var renew = false
        while true {
            guard let url = url(path, query) else { throw GatewayError.notConfigured }
            let signed = try await credential(settings, renew)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            settings.applyAccessHeaders(to: &request)
            signed.sign(&request)
            if !body.isNull {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(try body.serialized().utf8)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            try ServerSettings.checkAccess(response)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data, as: UTF8.self)
            if status == 401 && !renew {
                renew = true
                continue
            }
            guard (200..<300).contains(status) else {
                throw HermesAPIError.refused(status, Self.detail(text))
            }
            return text.isEmpty ? .null : try JSONValue.parse(text)
        }
    }

    /// `/api/profiles/{name}` and what is under it.
    static func profilePath(_ name: String, _ rest: String = "") -> String {
        "/api/profiles/" + KanbanClient.encode(name) + rest
    }

    /// `/api/mcp/servers/{name}` and what is under it.
    static func serverPath(_ name: String, _ rest: String = "") -> String {
        "/api/mcp/servers/" + KanbanClient.encode(name) + rest
    }

    /// `?profile=`, for the routes that take the profile as a parameter.
    static func scope(_ profile: String) -> [(String, String)] {
        [("profile", profile)]
    }

    /// FastAPI's `detail`: a sentence, a list of validation errors, or an object with a message.
    static func detail(_ text: String) -> String {
        guard let body = try? JSONValue.parse(text), let detail = body["detail"] else { return "" }
        if let line = detail.string { return line }
        if case .array(let items) = detail {
            return items.compactMap { $0["msg"]?.string }.joined(separator: "；")
        }
        return detail["message"]?.string ?? detail["error"]?.string ?? ""
    }

    private func url(_ path: String, _ query: [(String, String)]) -> URL? {
        let encoded = query.map { "\($0.0)=\(KanbanClient.encode($0.1))" }.joined(separator: "&")
        return settings.httpURL(path + (encoded.isEmpty ? "" : "?" + encoded))
    }
}

/// One Hermes profile, which is one assistant, as the socket's `profiles.list` gives it.
struct ProfileRow: Identifiable, Equatable {
    let name: String
    let isDefault: Bool
    let displayName: String
    let description: String
    /// ui_meta's `hermes-bots` section, where Bot Mode keeps an assistant's title (and its colour,
    /// groups and more). It is kept whole: a new title is written back into it, so the rest stays.
    let botsMeta: [String: JSONValue]
    /// That section's revision: `profiles.configure` writes it only while it is still this one.
    let botsRevision: Int

    var id: String { name }

    init?(_ row: JSONValue) {
        guard let name = row["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        isDefault = row["is_default"]?.bool == true
        displayName = row["display_name"]?.string ?? ""
        description = row["description"]?.string ?? ""
        if case .object(let section)? = row["ui_meta"]?["hermes-bots"] {
            botsMeta = section
        } else {
            botsMeta = [:]
        }
        botsRevision = row["ui_meta_revisions"]?["hermes-bots"]?.int ?? 0
    }

    /// Bot Mode's title, if it has one.
    var title: String { botsMeta["title"]?.string ?? "" }

    /// The name Shion shows: Bot Mode's title, then the profile's display name, then its id.
    var shownName: String {
        [title, displayName].first { !$0.isEmpty } ?? name
    }
}

/// Profile ids as Hermes takes them (hermes_cli/profiles.py): lowercase letters, digits, `-` and
/// `_`, starting with a letter or digit, at most 64 characters, and not one of its reserved names.
enum ProfileName {
    static let reserved: Set<String> = ["hermes", "default", "test", "tmp", "root", "sudo"]

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ name: String) -> Bool {
        !reserved.contains(name) && name.wholeMatch(of: #/[a-z0-9][a-z0-9_-]{0,63}/#) != nil
    }
}
