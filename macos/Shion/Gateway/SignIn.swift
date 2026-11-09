import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Observation

/// What the socket and the REST checks are signed with.
nonisolated enum Credential: Sendable {
    /// The server's HERMES_DASHBOARD_SESSION_TOKEN; REST carries it as X-Hermes-Session-Token.
    case sessionToken(String)
    /// A browser sign-in's access token; REST carries it as a bearer.
    case bearer(String)

    /// Either one rides `/api/ws` as `?token=`.
    var token: String {
        switch self {
        case .sessionToken(let token), .bearer(let token): return token
        }
    }

    func sign(_ request: inout URLRequest) {
        switch self {
        case .sessionToken(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// A browser sign-in's tokens, from `/auth/native/token` or `/auth/native/refresh`. The access
/// token works on its own (a bearer, the socket's `?token=`); the refresh token buys the next
/// pair. Tied to the server that issued them, and sent nowhere else.
nonisolated struct SignInTokens: Codable, Equatable, Sendable {
    var server: String
    var accessToken: String
    var refreshToken: String
    /// Unix seconds; 0 when the server did not say.
    var expiresAt: Double
    var provider: String
    var userId: String

    init(server: String, accessToken: String, refreshToken: String, expiresAt: Double, provider: String, userId: String) {
        self.server = server
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userId = userId
    }

    /// `{access_token, refresh_token, token_type, expires_at, provider, user_id}`
    init?(reply: JSONValue, server: String) {
        guard let access = reply["access_token"]?.string, !access.isEmpty else { return nil }
        self.init(
            server: server,
            accessToken: access,
            refreshToken: reply["refresh_token"]?.string ?? "",
            expiresAt: reply["expires_at"]?.number ?? 0,
            provider: reply["provider"]?.string ?? "",
            userId: reply["user_id"]?.string ?? ""
        )
    }

    /// A minute early, so a token does not lapse between this check and the dial.
    func needsRefresh(at now: Date = Date()) -> Bool {
        expiresAt <= 0 || now.timeIntervalSince1970 >= expiresAt - 60
    }
}

/// RFC 7636 S256, with the random values the sign-in needs.
nonisolated enum PKCE {
    /// `count` random bytes, base64url without padding: 32 make a 43-character verifier.
    static func random(_ count: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Hermes's endpoints for a native app's tokens. Both are public on the server and answer JSON.
enum SignInAPI {
    /// `POST /auth/native/token`: the one-time code and the PKCE verifier buy the tokens.
    static func redeem(code: String, verifier: String, settings: ServerSettings) async throws -> SignInTokens {
        let (reply, status) = try await post("/auth/native/token", ["code": .string(code), "code_verifier": .string(verifier)], settings)
        guard status == 200, let reply, let tokens = SignInTokens(reply: reply, server: settings.signInServer) else {
            throw GatewayError.signInFailed(status == 400 ? "登录码过期了，再登录一次" : "换登录凭证时服务器返回 HTTP \(status)")
        }
        return tokens
    }

    /// `POST /auth/native/refresh`: the refresh token buys the next pair, which replaces it.
    static func refresh(_ tokens: SignInTokens, settings: ServerSettings) async throws -> SignInTokens {
        let (reply, status) = try await post("/auth/native/refresh", ["refresh_token": .string(tokens.refreshToken), "provider": .string(tokens.provider)], settings)
        switch status {
        case 200:
            guard let reply, var fresh = SignInTokens(reply: reply, server: tokens.server) else {
                throw GatewayError.signInFailed("续登录时服务器的回复不对")
            }
            if fresh.refreshToken.isEmpty { fresh.refreshToken = tokens.refreshToken }
            if fresh.userId.isEmpty { fresh.userId = tokens.userId }
            if fresh.provider.isEmpty { fresh.provider = tokens.provider }
            return fresh
        case 400, 401:
            // `session_expired`: every provider turned the refresh token down
            throw GatewayError.signInExpired
        default:
            throw GatewayError.http(status)
        }
    }

    private static func post(_ path: String, _ body: JSONValue, _ settings: ServerSettings) async throws -> (JSONValue?, Int) {
        guard let url = settings.httpURL(path) else { throw GatewayError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        settings.applyAccessHeaders(to: &request)
        request.httpBody = Data(try body.serialized().utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ServerSettings.checkAccess(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (try? JSONValue.parse(String(decoding: data, as: UTF8.self)), status)
    }
}

/// Hermes's sign-in for native apps (RFC 8252, brokered by the gateway): its login page opens in
/// a browser sheet, the gateway sends the browser back to a one-shot listener on 127.0.0.1 with a
/// code, and the code plus the PKCE verifier buys the tokens. Shion never sees the password.
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Where the listener sends the browser once it has the code; the sheet closes on it.
    nonisolated static let callbackScheme = "dev.shion.signin"

    private var session: ASWebAuthenticationSession?
    private var waiting: CheckedContinuation<String, Error>?
    private var expectedState = ""
    private var deadline: Task<Void, Never>?

    func run(_ settings: ServerSettings) async throws -> SignInTokens {
        guard let authorize = settings.httpURL("/auth/native/authorize") else { throw GatewayError.notConfigured }
        let verifier = PKCE.random()
        let state = PKCE.random(24)
        expectedState = state
        let listener = try await LoopbackListener.start { [weak self] query in
            guard let self else { return }
            Task { @MainActor in
                self.received(query)
            }
        }
        defer { listener.stop() }
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(listener.port)/callback"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw GatewayError.notConfigured }
        let code = try await waitForCode(url, headers: settings.accessHeaders)
        return try await SignInAPI.redeem(code: code, verifier: verifier, settings: settings)
    }

    /// Closes the sheet; `run` then throws `CancellationError`.
    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func waitForCode(_ url: URL, headers: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(Self.callbackScheme)) { @Sendable [weak self] _, error in
                guard let self else { return }
                Task { @MainActor in
                    self.sheetClosed(error)
                }
            }
            session.presentationContextProvider = self
            // nothing to keep: the gateway sets no cookies on this path, and an ephemeral sheet
            // does not first ask whether Shion may use the site to sign in
            session.prefersEphemeralWebBrowserSession = true
            // Cloudflare Access checks the service token on the first request and answers with
            // its own cookie, which carries the rest of the login page through
            if !headers.isEmpty {
                session.additionalHeaderFields = headers
            }
            self.session = session
            // the gateway keeps a pending sign-in for ten minutes
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(GatewayError.timeout("浏览器里登录")))
            }
            if !session.start() {
                finish(.failure(GatewayError.signInFailed("打不开登录窗口")))
            }
        }
    }

    /// The listener's query: the code, or the reason there is none.
    private func received(_ query: [String: String]) {
        if let error = query["error"], !error.isEmpty {
            let detail = query["error_description"].map { "\(error)（\($0)）" } ?? error
            finish(.failure(GatewayError.signInFailed(detail)))
        } else if let code = query["code"], !code.isEmpty {
            // a forged redirect cannot know the state, so its code is never redeemed (RFC 6749 §10.12)
            guard query["state"] == expectedState else {
                finish(.failure(GatewayError.signInFailed("回来的 state 对不上，没用这个登录码")))
                return
            }
            finish(.success(code))
        }
    }

    private func sheetClosed(_ error: Error?) {
        session = nil
        guard waiting != nil else { return }
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
            finish(.failure(CancellationError()))
        } else if let error {
            finish(.failure(GatewayError.signInFailed(error.localizedDescription)))
        } else {
            // closed by the listener's redirect: the code reaches `received` a hop behind
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(.failure(GatewayError.signInFailed("登录页关了，但没收到登录码")))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        deadline?.cancel()
        deadline = nil
        if let session {
            // closes the sheet if the browser did not follow the redirect itself
            self.session = nil
            session.cancel()
        }
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(with: result)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? ASPresentationAnchor()
        }
    }
}

/// The browser sign-in Shion holds: its tokens (in the keychain, tied to the server that issued
/// them), renewed before they lapse, and the sign-in itself.
@Observable
final class Account {
    enum State: Equatable {
        case idle
        case signingIn
        case failed(String)
    }

    private(set) var tokens: SignInTokens?
    private(set) var state = State.idle
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var browser: BrowserSignIn?
    @ObservationIgnored private var renewal: Task<SignInTokens, Error>?

    /// `persist: false` keeps the tokens in memory only (screenshot and test runs).
    init(persist: Bool, tokens: SignInTokens? = nil) {
        self.persist = persist
        self.tokens = persist ? Self.load() : tokens
    }

    /// The sign-in for this address, if there is one.
    func tokens(for settings: ServerSettings) -> SignInTokens? {
        guard let tokens, !tokens.server.isEmpty, tokens.server == settings.signInServer else { return nil }
        return tokens
    }

    /// Opens the server's login page in a browser sheet and keeps the tokens it hands back.
    func signIn(_ settings: ServerSettings) async -> Bool {
        guard state != .signingIn else { return false }
        state = .signingIn
        let browser = BrowserSignIn()
        self.browser = browser
        defer { self.browser = nil }
        do {
            guard let status = try await settings.status() else { throw GatewayError.notHermes }
            guard status.authRequired else { throw GatewayError.noSignInNeeded }
            guard status.takesBrowserSignIn else { throw GatewayError.noBrowserSignIn(status.providers) }
            keep(try await browser.run(settings))
            state = .idle
            return true
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        return false
    }

    func cancelSignIn() {
        browser?.cancel()
    }

    /// Forgets the tokens. They are signed, not stored, on the server, so there is nothing to revoke
    /// there; the access token lapses on its own.
    func signOut() {
        keep(nil)
        state = .idle
    }

    /// An access token for this server: renewed first when it is about to lapse, or when `renew`
    /// says the server just refused it. Renewals in flight are shared, so a refresh token is spent once.
    func accessToken(for settings: ServerSettings, renew: Bool) async throws -> String {
        guard let current = tokens(for: settings) else { throw GatewayError.notSignedIn }
        guard renew || current.needsRefresh() else { return current.accessToken }
        if let renewal {
            return try await renewal.value.accessToken
        }
        let task = Task { try await SignInAPI.refresh(current, settings: settings) }
        renewal = task
        defer { renewal = nil }
        do {
            let fresh = try await task.value
            keep(fresh)
            return fresh.accessToken
        } catch GatewayError.signInExpired {
            keep(nil)
            throw GatewayError.signInExpired
        }
    }

    private func keep(_ tokens: SignInTokens?) {
        self.tokens = tokens
        guard persist else { return }
        if let tokens, let data = try? JSONEncoder().encode(tokens) {
            Keychain.write(String(decoding: data, as: UTF8.self), for: "hermes-sign-in")
        } else {
            Keychain.write("", for: "hermes-sign-in")
        }
    }

    private static func load() -> SignInTokens? {
        let text = Keychain.read("hermes-sign-in")
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(SignInTokens.self, from: Data(text.utf8))
    }
}
