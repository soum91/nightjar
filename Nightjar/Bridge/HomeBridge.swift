import Foundation
import Network

/// The Keystone bridge (ESP32 running the Afterglow/Keystone firmware, 1.8+). Nightjar pairs with it as
/// its own app ("nightjar") and sends it the camera, so the bridge can show the camera in Apple Home
/// (motion, person, battery) and run the person-turns-on-lights rule without a home hub.
struct BridgeLink: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
}

struct BridgeCamConfig: Codable, Equatable {
    var serial = ""
    var name = ""
    var sendPassword = true
    var ruleOn = false
    var lights: [String] = []
    var window = true
    var from = 18 * 60
    var to = 7 * 60
    var offAfter = 10
    // Alerts (sent by the bridge)
    var alertOn = false
    var alertAll = false
    var cooldown = 60
    var topic = ""
    var aiKey = ""
    var aiOnly = false
    var sent = false
    var sentToken = ""
}

extension BridgeCamConfig {
    /// Settings saved by an older build lack newer fields; keep what's there instead of resetting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var x = BridgeCamConfig()
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) { if let v = try? c.decodeIfPresent(T.self, forKey: k) { into = v } }
        get(.serial, &x.serial); get(.name, &x.name); get(.sendPassword, &x.sendPassword)
        get(.ruleOn, &x.ruleOn); get(.lights, &x.lights); get(.window, &x.window)
        get(.from, &x.from); get(.to, &x.to); get(.offAfter, &x.offAfter)
        get(.alertOn, &x.alertOn); get(.alertAll, &x.alertAll); get(.cooldown, &x.cooldown)
        get(.topic, &x.topic)
        get(.aiKey, &x.aiKey); get(.aiOnly, &x.aiOnly)
        get(.sent, &x.sent); get(.sentToken, &x.sentToken)
        self = x
    }
}

struct BridgeLight: Identifiable, Hashable { var id: String; var name: String }

enum HomeBridge {
    private static let linkKey = "bridge.link", cfgKey = "bridge.camera"

    static var link: BridgeLink? {
        get { UserDefaults.standard.data(forKey: linkKey).flatMap { try? JSONDecoder().decode(BridgeLink.self, from: $0) } }
        set {
            if let newValue, let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: linkKey) }
            else { UserDefaults.standard.removeObject(forKey: linkKey) }
        }
    }

    static var config: BridgeCamConfig {
        get { UserDefaults.standard.data(forKey: cfgKey).flatMap { try? JSONDecoder().decode(BridgeCamConfig.self, from: $0) } ?? BridgeCamConfig() }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: cfgKey) } }
    }

    private static func url(_ host: String, _ port: Int, _ path: String) throws -> URL {
        guard let u = URL(string: "http://\(host):\(port)\(path)") else { throw VicoError(message: "Bad bridge address.") }
        return u
    }

    static func claim(host: String, port: Int) async throws -> BridgeLink {
        var req = URLRequest(url: try url(host, port, "/api/dev/claim?app=nightjar"))
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 409: throw VicoError(message: "The bridge already has a Nightjar pairing (from an older install?). In Keystone › Bridge › Apps paired with the bridge, reset Nightjar, then pair again.")
        case 400: throw VicoError(message: "This bridge's firmware doesn't know Nightjar yet. Update it to 1.8 or newer from Keystone, then pair.")
        case let c: throw VicoError(message: "The bridge said HTTP \(c).")
        }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict, let t = o["token"] as? String else {
            throw VicoError(message: "The bridge didn't hand out a token.")
        }
        let l = BridgeLink(host: host, port: port, token: t)
        link = l
        return l
    }

    static func forget() {
        link = nil
        var c = config
        c.sent = false
        c.sentToken = ""
        config = c
    }

    /// /api/info: the bridge's lights (for the rule) and its view of the camera.
    static func info() async throws -> (lights: [BridgeLight], camera: JSONDict?) {
        guard let l = link else { throw VicoError(message: "No bridge paired.") }
        var req = URLRequest(url: try url(l.host, l.port, "/api/info?lite=1"))
        req.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict, o["app"] as? String == "afterglow-bridge" else {
            throw VicoError(message: "That address isn't a Keystone bridge.")
        }
        let lights = ((o["lights"] as? [JSONDict]) ?? []).compactMap { d -> BridgeLight? in
            guard let id = J.str(d, "id") else { return nil }
            return BridgeLight(id: id, name: J.str(d, "name") ?? id)
        }
        return (lights, o["camera"] as? JSONDict)
    }

    /// Sends the camera (or removes it with `remove`). Returns true if the bridge restarts to update Home.
    @discardableResult
    static func send(_ c: BridgeCamConfig, remove: Bool = false) async throws -> Bool {
        guard let l = link else { throw VicoError(message: "No bridge paired.") }
        var camera: JSONDict = [:]
        if !remove {
            guard let s = SessionStore.load() else { throw VicoError(message: "Sign in to Vicohome first.") }
            camera = [
                "serial": c.serial,
                "name": c.name,
                "token": s.token,
                "base": s.base,
                "country": s.country,
                "person": [
                    "enabled": c.ruleOn,
                    "lights": c.lights,
                    "window": c.window,
                    "from": c.from,
                    "to": c.to,
                    "offAfter": c.offAfter,
                ] as JSONDict,
                "alerts": [
                    "enabled": c.alertOn,
                    "all": c.alertAll,
                    "cooldown": c.cooldown,
                    "topic": c.topic,
                    "aiKey": c.aiKey,
                    "aiOnly": c.aiOnly,
                ] as JSONDict,
            ]
            if c.sendPassword, let pw = Keychain.password(for: s.email) {
                camera["email"] = s.email
                camera["pass"] = pw
            }
        }
        var req = URLRequest(url: try url(l.host, l.port, "/api/dev/config?app=nightjar"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(l.token, forHTTPHeaderField: "X-Device-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["camera": camera])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw VicoError(message: "The bridge doesn't recognise Nightjar anymore. Forget the bridge here and pair again.") }
        let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict ?? [:]
        guard code == 200 else { throw VicoError(message: (o["error"] as? String) ?? "The bridge said HTTP \(code).") }
        var saved = c
        saved.sent = !remove
        saved.sentToken = remove ? "" : (SessionStore.load()?.token ?? "")
        config = saved
        return o["restart"] as? Bool ?? false
    }

    /// After Nightjar signs in again, hand the bridge the new token (quietly; only works at home).
    static func syncToken() async {
        let c = config
        guard link != nil, c.sent, let s = SessionStore.load(), s.token != c.sentToken else { return }
        _ = try? await send(c)
    }
}

/// ntfy.sh: the bridge publishes, the ntfy iOS app (1.7+) shows the push with the snapshot.
enum Ntfy {
    /// Long and random: on ntfy.sh anyone who knows a topic name can read it.
    static func newTopic() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return "nightjar-" + String((0..<22).map { _ in chars.randomElement()! })
    }

    static func test(_ topic: String) async throws {
        guard let u = URL(string: "https://ntfy.sh") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "topic": topic,
            "title": "Nightjar alerts are set up",
            "message": "The bridge will push camera alerts here.",
            "tags": ["white_check_mark"],
            "click": "nightjar://home",
        ] as JSONDict)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw VicoError(message: "ntfy.sh didn't take the test message.") }
    }
}

/// Finds bridges by Bonjour (_afterglow._tcp), same as Keystone.
@MainActor
final class BridgeFinder: ObservableObject {
    struct Found: Hashable { var name: String; var host: String; var port: Int }
    @Published var found: [Found] = []
    @Published var searching = false
    private var browser: NWBrowser?

    func start() {
        stop()
        searching = true
        found = []
        let b = NWBrowser(for: .bonjour(type: "_afterglow._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                Task { await self?.resolve(r.endpoint, name: name) }
            }
        }
        b.start(queue: .main)
        browser = b
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            searching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) async {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        let result: (String, Int)? = await withCheckedContinuation { cont in
            let once = OnceFlag()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let h, let p)? = c.currentPath?.remoteEndpoint, once.fire() {
                        var host = "\(h)"
                        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                        cont.resume(returning: (host, Int(p.rawValue)))
                    } else if once.fire() { cont.resume(returning: nil) }
                    c.cancel()
                case .failed, .cancelled:
                    if once.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if once.fire() { cont.resume(returning: nil); c.cancel() }
            }
        }
        guard let r = result, !found.contains(where: { $0.host == r.0 }) else { return }
        found.append(Found(name: name, host: r.0, port: r.1))
    }
}

final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
