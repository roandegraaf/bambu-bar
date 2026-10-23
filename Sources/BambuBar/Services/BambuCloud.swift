import Foundation
import Observation

/// The Bambu Lab account, used only to open the printer's camera through Bambu's cloud.
///
/// Sign-in is the REST flow Bambu Studio's login page uses: email with a password or an emailed code,
/// then a 2FA code if the account has one. The session lives in the keychain and is refreshed in its
/// last two weeks.
@MainActor
@Observable
final class BambuCloud {
    static let shared = BambuCloud()

    struct Session: Codable, Equatable {
        var email: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        /// Numeric user id, without the "u_" prefix MQTT uses.
        var uid: String
        var name: String
    }

    struct Device: Equatable {
        var id: String
        var name: String
        var online: Bool
    }

    enum Step: Equatable {
        case signedOut
        case code(email: String)
        case tfa(email: String, key: String)
        case signedIn
    }

    struct Failure: LocalizedError {
        var message: String
        var code: Int?
        var status = 0
        var errorDescription: String? { message }
    }

    private(set) var session: Session? {
        didSet {
            if oldValue?.accessToken != session?.accessToken {
                PrinterStore.shared.syncCamera(restart: true)
            }
        }
    }
    private(set) var step: Step = .signedOut
    private(set) var devices: [Device] = []
    private(set) var busy = false
    private(set) var error: String?

    var isSignedIn: Bool { session != nil }
    var needsSignIn: Bool { session.map { $0.expiresAt <= Date() } ?? true }

    private static let api = URL(string: "https://api.bambulab.com")!
    private static let web = URL(string: "https://bambulab.com")!
    private static let refreshWindow: TimeInterval = 14 * 86_400
    private static let fallbackLifetime: TimeInterval = 90 * 86_400

    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {
        if let data = Keychain.cloudSession(), let saved = try? JSONDecoder().decode(Session.self, from: data) {
            session = saved
            step = .signedIn
        }
    }

    // MARK: - Sign-in

    /// Starts signing in; without a password Bambu emails a code.
    func start(email: String, password: String) async {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty else { return }
        await run {
            if password.isEmpty {
                try await self.sendCode(to: email)
            } else {
                try await self.handleLogin(email: email, body: self.call("v1/user-service/user/login", json: ["account": email, "password": password, "apiError": ""]))
            }
        }
    }

    func submitCode(_ code: String) async {
        guard case .code(let email) = step else { return }
        let code = code.trimmingCharacters(in: .whitespaces)
        await run {
            do {
                try await self.handleLogin(email: email, body: self.call("v1/user-service/user/login", json: ["account": email, "code": code, "apiError": ""]))
            } catch let failure as Failure where failure.code == 1 {
                try await self.sendCode(to: email)
                throw Failure(message: "That code had expired; Bambu sent a new one.")
            } catch let failure as Failure where failure.code == 2 {
                throw Failure(message: "That code isn't right.")
            }
        }
    }

    func submitTfa(_ code: String) async {
        guard case .tfa(let email, let key) = step else { return }
        let code = code.trimmingCharacters(in: .whitespaces)
        await run {
            let token = try await self.verifyTfa(key: key, code: code)
            try await self.finish(email: email, accessToken: token.value, refreshToken: token.value, expiresIn: token.maxAge)
        }
    }

    func cancelSignIn() {
        step = session == nil ? .signedOut : .signedIn
        error = nil
    }

    func signOut() {
        session = nil
        devices = []
        step = .signedOut
        error = nil
        Keychain.setCloudSession(nil)
    }

    /// Refreshes the session when it's close to expiring, and the list of printers on the account.
    func refreshIfNeeded() async {
        guard var current = session else { return }
        if current.expiresAt.timeIntervalSinceNow < Self.refreshWindow, current.expiresAt > Date() {
            do {
                let body = try await call("v1/user-service/user/refreshtoken", json: ["refreshToken": current.refreshToken], token: current.accessToken)
                if let token = body["accessToken"] as? String, !token.isEmpty {
                    current.accessToken = token
                    current.refreshToken = (body["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? token
                    current.expiresAt = Date().addingTimeInterval(Self.lifetime(body["expiresIn"]))
                    save(current)
                }
            } catch let failure as Failure where failure.status == 401 {
                error = "Bambu signed this Mac out. Sign in again to see the camera."
            } catch {}
        }
        await loadDevices()
    }

    /// The account in the shape Bambu Studio hands its network plugin after signing in.
    func pluginUserInfo() -> String? {
        guard let s = session, s.expiresAt > Date() else { return nil }
        let expiresIn = String(max(0, Int(s.expiresAt.timeIntervalSinceNow)))
        let envelope: [String: Any] = [
            "data": [
                "token": s.accessToken,
                "refresh_token": s.refreshToken,
                "expires_in": expiresIn,
                "refresh_expires_in": expiresIn,
                "user": ["uid": s.uid, "name": s.name, "account": s.email, "avatar": "", "nickname": s.name],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func device(serial: String) -> Device? {
        devices.first { $0.id.caseInsensitiveCompare(serial) == .orderedSame }
    }

    // MARK: - Steps

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await work()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendCode(to email: String) async throws {
        _ = try await call("v1/user-service/user/sendemail/code", json: ["email": email, "type": "codeLogin"])
        step = .code(email: email)
    }

    private func handleLogin(email: String, body: [String: Any]) async throws {
        if let token = body["accessToken"] as? String, !token.isEmpty {
            let refresh = (body["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? token
            try await finish(email: email, accessToken: token, refreshToken: refresh, expiresIn: Self.lifetime(body["expiresIn"]))
            return
        }
        switch body["loginType"] as? String {
        case "verifyCode":
            try await sendCode(to: email)
        case "tfa":
            guard let key = body["tfaKey"] as? String, !key.isEmpty else { throw Failure(message: "Bambu asked for a 2FA code but sent no key.") }
            step = .tfa(email: email, key: key)
        default:
            throw Failure(message: (body["message"] as? String) ?? "Bambu sent an unexpected answer.")
        }
    }

    private func finish(email: String, accessToken: String, refreshToken: String, expiresIn: TimeInterval) async throws {
        let profile = try await call("v1/design-user-service/my/preference", token: accessToken)
        var uid = Self.text(profile["uidStr"]) ?? Self.text(profile["uid"]) ?? Self.jwtUsername(accessToken) ?? ""
        if uid.hasPrefix("u_") { uid.removeFirst(2) }
        guard !uid.isEmpty else { throw Failure(message: "Bambu didn't say which account this is. Try again.") }
        let name = Self.text(profile["name"]) ?? Self.text(profile["handle"]) ?? email
        save(Session(email: email, accessToken: accessToken, refreshToken: refreshToken,
                     expiresAt: Date().addingTimeInterval(expiresIn), uid: uid, name: name))
        step = .signedIn
        await loadDevices()
    }

    private func save(_ new: Session) {
        session = new
        if let data = try? JSONEncoder().encode(new) { Keychain.setCloudSession(data) }
    }

    private func loadDevices() async {
        guard let token = session?.accessToken else { return }
        guard let body = try? await call("v1/iot-service/api/user/bind", token: token),
              let list = body["devices"] as? [[String: Any]] else { return }
        devices = list.compactMap { d in
            guard let id = Self.text(d["dev_id"]) else { return nil }
            return Device(id: id, name: Self.text(d["name"]) ?? id, online: d["online"] as? Bool ?? false)
        }
    }

    // MARK: - HTTP

    private static let clientHeaders = [
        "User-Agent": "bambu_network_agent/02.08.04.57",
        "X-BBL-Client-Name": "BambuStudio",
        "X-BBL-Client-Type": "slicer",
        "X-BBL-Client-Version": "02.08.04.57",
        "X-BBL-Agent-Version": "02.08.04.57",
        "X-BBL-OS-Type": "macos",
        "X-BBL-Language": "en",
        "Accept": "application/json",
    ]

    private func request(_ url: URL, json: [String: Any]?, token: String?, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in Self.clientHeaders.merging(headers, uniquingKeysWith: { $1 }) { request.setValue(value, forHTTPHeaderField: key) }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func call(_ path: String, json: [String: Any]? = nil, token: String? = nil) async throws -> [String: Any] {
        let (data, response) = try await send(request(Self.api.appendingPathComponent(path), json: json, token: token))
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            if body == nil { throw Failure(message: "Bambu's server refused the request (\(response.statusCode)).", status: response.statusCode) }
            let message = (body?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Bambu answered \(response.statusCode)."
            throw Failure(message: message, code: (body?["code"] as? NSNumber)?.intValue, status: response.statusCode)
        }
        return body ?? [:]
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await http.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "Bambu's server sent no answer.") }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "Couldn't reach Bambu: \(error.localizedDescription)")
        }
    }

    /// The 2FA step runs on the website, which answers with the token as a cookie.
    private func verifyTfa(key: String, code: String) async throws -> (value: String, maxAge: TimeInterval) {
        let csrfURL = Self.web.appendingPathComponent("api/csrf")
        let (_, csrfResponse) = try await send(request(csrfURL, json: nil, token: nil))
        guard let csrf = Self.cookie("bbl_csrf_token", in: csrfResponse, url: csrfURL) else {
            throw Failure(message: "Bambu's website didn't start the 2FA check (\(csrfResponse.statusCode)).")
        }
        let url = Self.web.appendingPathComponent("api/sign-in/tfa")
        let (_, response) = try await send(request(url, json: ["tfaKey": key, "tfaCode": code], token: nil,
                                                   headers: ["x-bbl-csrf-token": csrf.value, "Cookie": "bbl_csrf_token=\(csrf.value)"]))
        guard (200..<300).contains(response.statusCode), let token = Self.cookie("token", in: response, url: url) else {
            throw Failure(message: "That 2FA code wasn't accepted.")
        }
        let maxAge = token.expiresDate.map { $0.timeIntervalSinceNow } ?? Self.fallbackLifetime
        return (token.value, maxAge > 0 ? maxAge : Self.fallbackLifetime)
    }

    private static func cookie(_ name: String, in response: HTTPURLResponse, url: URL) -> HTTPCookie? {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first { $0.name == name && !$0.value.isEmpty }
    }

    private static func lifetime(_ value: Any?) -> TimeInterval {
        let seconds = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
        return seconds > 0 ? seconds : fallbackLifetime
    }

    private static func text(_ value: Any?) -> String? {
        if let s = value as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func jwtUsername(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return text(json["username"])
    }
}
