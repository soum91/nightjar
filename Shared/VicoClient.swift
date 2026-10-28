import Foundation
import Security

struct VicoError: LocalizedError {
    var message: String
    var code: Int?
    var isAuth = false
    var kicked = false
    var errorDescription: String? { message }
}

/// Password for automatic re-login. App-only keychain item; the widget just uses the cached token.
enum Keychain {
    private static let service = "com.soum91.nightjar.account"

    static func save(_ password: String, for email: String) {
        clear()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func password(for email: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
    }
}

/// Vicohome cloud API (reverse engineered; see dydx/vico-cli). Every call is a JSON POST with the
/// account token in `Authorization`, and responses carry `result` (or `code`) = 0 on success.
enum Vico {
    static let authCodes: Set<Int> = [-1024, -1025, -1026, -1027]

    private static let urlSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    // MARK: Auth

    static func login(email: String, password: String, region: Region, customBase: String? = nil) async throws -> Session {
        var base = region == .custom ? (customBase ?? region.defaultBase) : region.defaultBase
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http") { base = "https://" + base }

        let body: JSONDict = ["email": email, "password": password, "loginType": 0]
        let json = try await send(base: base, path: "/account/login", token: nil, body: body)
        guard let data = json["data"] as? JSONDict,
              let tok = data["token"] as? JSONDict,
              let token = tok["token"] as? String, !token.isEmpty else {
            throw VicoError(message: "Login worked but no token came back. The API may have changed.")
        }
        let session = Session(email: email, token: token, base: base, country: region.country, region: region, signedInAt: .now)
        SessionStore.save(session)
        Keychain.save(password, for: email)
        return session
    }

    static func signOut() {
        SessionStore.clear()
        Keychain.clear()
        AppGroup.remove("snapshot.json")
        AppGroup.remove("thumb.jpg")
    }

    // MARK: Endpoints

    static func cameras() async throws -> [Camera] {
        let json = try await call("/device/listuserdevices", [:])
        let list = ((json["data"] as? JSONDict)?["list"] as? [JSONDict]) ?? (json["data"] as? [JSONDict]) ?? []
        return list.compactMap(Camera.from)
    }

    static func cameraRaw(_ serial: String) async throws -> JSONDict {
        let json = try await call("/device/selectsingledevice", ["serialNumber": serial])
        return (json["data"] as? JSONDict) ?? json
    }

    /// Events between two dates, newest first.
    static func events(from start: Date, to end: Date) async throws -> [CamEvent] {
        let body: JSONDict = [
            "startTimestamp": String(Int(start.timeIntervalSince1970)),
            "endTimestamp": String(Int(end.timeIntervalSince1970)),
        ]
        let json = try await call("/library/newselectlibrary", body)
        let list = ((json["data"] as? JSONDict)?["list"] as? [JSONDict]) ?? []
        return list.compactMap(CamEvent.from).sorted { $0.date > $1.date }
    }

    /// One event with fresh media URLs (the signed links in the list can expire).
    static func event(_ traceId: String) async throws -> (CamEvent?, JSONDict) {
        let json = try await call("/library/newselectsinglelibrary", ["traceId": traceId])
        var data = (json["data"] as? JSONDict) ?? [:]
        if data["traceId"] == nil, let inner = data["event"] as? JSONDict { data = inner }
        return (CamEvent.from(data), data)
    }

    /// Any endpoint, for the diagnostics screen.
    static func raw(_ path: String, _ body: JSONDict) async throws -> JSONDict {
        try await call(path, body)
    }

    // MARK: Live view

    /// WebRTC ticket for one live session: signaling server + path, access token, group/trace ids and
    /// TURN servers (protocol from bbielsa/vicostream). The official app calls this on the vicoo.tech host
    /// with a Bearer token; the vicohome.io host and a bare token are tried too.
    static func webrtcTicket(serial: String) async throws -> JSONDict {
        func attempt() async throws -> JSONDict {
            guard let session = SessionStore.load() else { throw VicoError(message: "Not signed in.", isAuth: true) }
            let requestId = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
            let body: JSONDict = [
                "serialNumber": serial,
                "countryNo": session.country,
                "requestId": requestId,
                "language": "en",
                "supportUnlimitedWebsocket": true,
                "list": [Any](),
                "app": [
                    "versionName": "3.50.0(2f68e2)",
                    "bundle": "addx.ai.vicoo",
                    "timeZone": TimeZone.current.identifier,
                    "appName": "VicoHome",
                    "tenantId": "vicoo",
                    "env": "prod-k8s",
                    "version": 14148,
                    "appType": "iOS",
                ] as JSONDict,
            ]
            let vicoo = session.base.replacingOccurrences(of: "vicohome.io", with: "vicoo.tech")
            let bearer = session.token.hasPrefix("Bearer ") ? session.token : "Bearer " + session.token
            var tries: [(String, String)] = [(vicoo, bearer)]
            if vicoo != session.base { tries.append((session.base, bearer)) }
            tries.append((session.base, session.token))

            var lastError: Error = VicoError(message: "No live ticket.")
            var sawAuth = false
            for (base, auth) in tries {
                do {
                    let json = try await send(base: base, path: "/device/getWebrtcTicket", token: auth, body: body)
                    if let data = json["data"] as? JSONDict, data["signalServer"] != nil { return data }
                    lastError = VicoError(message: "Vicohome returned a ticket without a signaling server.")
                } catch let e as VicoError {
                    if e.isAuth { sawAuth = true }
                    lastError = e
                } catch {
                    lastError = error
                }
            }
            if sawAuth { throw VicoError(message: (lastError as? VicoError)?.message ?? "Session expired.", isAuth: true) }
            throw lastError
        }

        do {
            return try await attempt()
        } catch let e as VicoError where e.isAuth {
            _ = try await call("/device/listuserdevices", [:]) // forces a re-login through the stored password
            return try await attempt()
        }
    }

    // MARK: Plumbing

    /// Signed-in call with one automatic re-login when the token is rejected.
    private static func call(_ path: String, _ extra: JSONDict) async throws -> JSONDict {
        guard var session = SessionStore.load() else { throw VicoError(message: "Not signed in.", isAuth: true) }
        var body = extra
        body["language"] = "en"
        body["countryNo"] = session.country
        do {
            return try await send(base: session.base, path: path, token: session.token, body: body)
        } catch let e as VicoError where e.isAuth {
            guard let pw = Keychain.password(for: session.email) else { throw e }
            session = try await login(email: session.email, password: pw, region: session.region, customBase: session.base)
            body["countryNo"] = session.country
            do {
                return try await send(base: session.base, path: path, token: session.token, body: body)
            } catch let again as VicoError where again.isAuth {
                var err = again
                err.message = e.kicked
                    ? "Vicohome signed this account out because it logged in somewhere else. Use a separate account with the cameras shared to it."
                    : again.message
                throw err
            }
        }
    }

    private static func send(base: String, path: String, token: String?, body: JSONDict) async throws -> JSONDict {
        guard let url = URL(string: base + path) else { throw VicoError(message: "Bad URL \(base + path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await urlSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict else {
            if status == 401 || status == 403 { throw VicoError(message: "Session expired.", code: status, isAuth: true) }
            throw VicoError(message: "Unexpected reply from Vicohome (HTTP \(status)).", code: status, isAuth: token != nil && status >= 400)
        }
        let code = (json["result"] as? NSNumber)?.intValue ?? (json["code"] as? NSNumber)?.intValue ?? 0
        if code != 0 {
            let msg = (json["msg"] as? String) ?? "Error \(code)"
            let lower = msg.lowercased()
            let auth = authCodes.contains(code) || lower.contains("token") || msg.contains("踢下线")
            if token == nil {
                throw VicoError(message: "Sign in failed: \(msg)", code: code)
            }
            throw VicoError(message: msg, code: code, isAuth: auth, kicked: code == -1024 || msg.contains("踢下线"))
        }
        return json
    }
}

// MARK: - Refresh used by both the app and the widget

enum Refresher {
    /// Pulls cameras and the last day of events, caches them and the newest thumbnail for the widget.
    @discardableResult
    static func refresh(days: Double = 1) async throws -> Snapshot {
        async let cams = Vico.cameras()
        async let evts = Vico.events(from: Date().addingTimeInterval(-days * 86_400), to: .now)
        var snap = Snapshot(cameras: try await cams, events: try await evts, updatedAt: .now)
        if snap.events.isEmpty, let old = Snapshot.load() {
            snap.events = Array(old.events.prefix(30)) // keep the last known event around for the widget
        }
        snap.save()
        await cacheThumb(snap.events.first)
        return snap
    }

    static func cacheThumb(_ event: CamEvent?) async {
        guard let s = event?.imageURL, let url = URL(string: s) else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty {
            AppGroup.writeData(data, "thumb.jpg")
            AppGroup.write(event!.id, "thumb-id.json")
        }
    }
}
