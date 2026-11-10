import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a picture or a file could not be sent or fetched.
nonisolated enum MediaError: LocalizedError {
    /// 404: the server no longer has it (Hermes clears its caches after about a day).
    case gone
    case tooLarge(String)
    case refused(Int, String)
    case badReply
    /// `file.attach` needs the chat attached on this connection.
    case chatClosed
    case notPicture
    /// The web's pictures only: never this Mac or its network.
    case localAddress

    var errorDescription: String? {
        switch self {
        case .gone: return "服务器上已经没有这个文件了"
        case .tooLarge(let limit): return "超过 \(limit)"
        case .refused(let status, let detail):
            return detail.isEmpty ? "服务器返回 HTTP \(status)" : "\(detail)（HTTP \(status)）"
        case .badReply: return "服务器的回复看不懂"
        case .chatClosed: return "对话还没打开"
        case .notPicture: return "这不是一张能显示的图片"
        case .localAddress: return "不取本机和局域网里的图片"
        }
    }
}

/// A file the server has: how big, from `Content-Length`.
nonisolated struct RemoteFile: Sendable, Equatable {
    var size: Int?
}

/// The chat's file routes on the Hermes server, signed as every `/api/*` request is (the session
/// token as X-Hermes-Session-Token, a sign-in as a bearer, plus the Cloudflare Access headers);
/// Hermes's gated mode reads credentials from headers only, so nothing goes in the address. From
/// `hermes_cli/web_routers/files.py` and `uploads.py`, which the official desktop uses too (not in
/// Hermes's user docs):
/// - `POST /api/chat/image-upload?profile=` `{data_url, filename}` → `{ok, path, name, bytes,
///   mime_type}`: a picture into that profile's `cache/images/`, the one folder `prompt.submit`'s
///   `attachments` take; 25 MiB; served on every listener.
/// - `POST /api/chat/file-upload?profile=` multipart `file` → `{ok, path, size, staged_upload}`:
///   16 MiB, the Webapp only (404 elsewhere); `file.attach {staged_upload}` takes the receipt.
/// - `GET /api/fs/read-data-url?path=&profile=&session_id=` → `{dataUrl}`, 16 MiB, else 413.
/// - `GET`/`HEAD /api/fs/download?path=&profile=&session_id=`: the file, any size.
/// With `session_id`, a relative path is read from that session's directory.
final class MediaClient {
    typealias Signer = (_ settings: ServerSettings, _ renew: Bool) async throws -> Credential

    nonisolated static let pictureLimit = 25 * 1024 * 1024
    nonisolated static let fileLimit = 16 * 1024 * 1024

    let settings: ServerSettings
    private let credential: Signer

    init(settings: ServerSettings, credential: @escaping Signer) {
        self.settings = settings
        self.credential = credential
    }

    /// Stores a picture in the profile's `cache/images/`; its path goes in `prompt.submit`.
    func uploadPicture(_ data: Data, name: String, mime: String, profile: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.pictureBody(data, name: name, mime: mime)
        }.value
        let (reply, status) = try await send("POST", "/api/chat/image-upload", ["profile": profile],
                                             body: body, type: "application/json", progress: progress)
        guard status == 200 else { throw Self.refusal(status, reply, limit: "25 MB") }
        guard let path = (try? JSONValue.parse(String(decoding: reply, as: UTF8.self)))?["path"]?.string, !path.isEmpty
        else { throw MediaError.badReply }
        return path
    }

    /// Stages a file on the Webapp; nil where the route is not served (another listener), when
    /// the bytes have to go to `file.attach` themselves. The receipt is what `file.attach` takes.
    func uploadFile(_ data: Data, name: String, mime: String, profile: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> JSONValue? {
        let boundary = "shion-" + UUID().uuidString
        let body = Self.multipart(data, name: name, mime: mime, boundary: boundary)
        let (reply, status) = try await send("POST", "/api/chat/file-upload", ["profile": profile], body: body,
                                             type: "multipart/form-data; boundary=\(boundary)", progress: progress)
        if status == 404 || status == 405 { return nil }
        guard status == 200 else { throw Self.refusal(status, reply, limit: "16 MB") }
        let parsed = try? JSONValue.parse(String(decoding: reply, as: UTF8.self))
        // without an install identity Hermes gives no receipt: send the bytes instead
        guard let receipt = parsed?["staged_upload"], case .object = receipt else { return nil }
        return receipt
    }

    /// A picture's bytes; past `read-data-url`'s 16 MiB, the whole file.
    func picture(at path: String, profile: String, session: String?) async throws -> Data {
        let (reply, status) = try await send("GET", "/api/fs/read-data-url", query(path, profile, session))
        if status == 413 {
            let file = try await download(path, profile: profile, session: session)
            defer { try? FileManager.default.removeItem(at: file) }
            return try Data(contentsOf: file)
        }
        guard status == 200 else { throw Self.refusal(status, reply, limit: "16 MB") }
        guard let bytes = await Task.detached(priority: .userInitiated, operation: { Self.dataURLBytes(reply) }).value
        else { throw MediaError.badReply }
        return bytes
    }

    /// A file into a temporary place of its own; the caller moves it.
    func download(_ path: String, profile: String, session: String?) async throws -> URL {
        var renew = false
        while true {
            let request = try await signed("GET", "/api/fs/download", query(path, profile, session), renew: renew)
            let (file, response) = try await URLSession.shared.download(for: request)
            try ServerSettings.checkAccess(response)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return file }
            let reply = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            if status == 401 && !renew {
                renew = true
                continue
            }
            throw Self.refusal(status, reply, limit: "")
        }
    }

    /// Whether the server has the file, and how big it is.
    func check(_ path: String, profile: String, session: String?) async throws -> RemoteFile {
        let (reply, status, response) = try await exchange("HEAD", "/api/fs/download", query(path, profile, session))
        guard status == 200 else { throw Self.refusal(status, reply, limit: "") }
        let length = response?.expectedContentLength ?? -1
        return RemoteFile(size: length >= 0 ? Int(length) : nil)
    }

    // MARK: requests

    private func query(_ path: String, _ profile: String, _ session: String?) -> [String: String] {
        var items = ["path": path, "profile": profile]
        if let session {
            items["session_id"] = session
        }
        return items
    }

    private func send(_ method: String, _ route: String, _ query: [String: String], body: Data? = nil, type: String? = nil,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> (Data, Int) {
        let (data, status, _) = try await exchange(method, route, query, body: body, type: type, progress: progress)
        return (data, status)
    }

    /// One request; a 401 renews the credential once and tries again.
    private func exchange(_ method: String, _ route: String, _ query: [String: String], body: Data? = nil,
                          type: String? = nil, progress: (@Sendable (Double) -> Void)? = nil)
        async throws -> (Data, Int, HTTPURLResponse?) {
        var renew = false
        while true {
            var request = try await signed(method, route, query, renew: renew)
            let data: Data
            let response: URLResponse
            if let body {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300
                let delegate = progress.map { UploadProgress($0) }
                (data, response) = try await URLSession.shared.upload(for: request, from: body, delegate: delegate)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            try ServerSettings.checkAccess(response)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 && !renew {
                renew = true
                continue
            }
            return (data, status, http)
        }
    }

    private func signed(_ method: String, _ route: String, _ query: [String: String], renew: Bool) async throws -> URLRequest {
        let items = query.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.encode($0.value))" }.joined(separator: "&")
        guard let url = settings.httpURL(route + (items.isEmpty ? "" : "?" + items)) else { throw GatewayError.notConfigured }
        let signed = try await credential(settings, renew)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        settings.applyAccessHeaders(to: &request)
        signed.sign(&request)
        return request
    }

    /// ASCII letters, digits and `-._~` stay; everything else, a path's slashes and Chinese names
    /// among it, is percent-encoded.
    nonisolated static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: bodies

    nonisolated static func pictureBody(_ data: Data, name: String, mime: String) throws -> Data {
        struct Body: Encodable {
            let data_url: String
            let filename: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(Body(data_url: "data:\(mime);base64," + data.base64EncodedString(), filename: name))
    }

    nonisolated static func multipart(_ data: Data, name: String, mime: String, boundary: String) -> Data {
        // as a browser sends it: the name as UTF-8, its quotes and line breaks taken out
        let safe = name.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\n".utf8)
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// `{"dataUrl": "data:<mime>;base64,<bytes>"}` → the bytes.
    nonisolated static func dataURLBytes(_ reply: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let url = object["dataUrl"] as? String ?? object["data_url"] as? String
        else { return nil }
        return decodeDataURL(url)
    }

    nonisolated static func decodeDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    private static func refusal(_ status: Int, _ reply: Data, limit: String) -> Error {
        switch status {
        case 404: return MediaError.gone
        case 413: return MediaError.tooLarge(limit.isEmpty ? "服务器的上限" : limit)
        default:
            let detail = (try? JSONValue.parse(String(decoding: reply, as: UTF8.self)))?["detail"]?.string ?? ""
            return MediaError.refused(status, detail)
        }
    }
}

/// Reports how much of an upload has gone out, from URLSession's delegate queue.
nonisolated final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
