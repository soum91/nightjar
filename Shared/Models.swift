import Foundation

// MARK: - Region and session

enum Region: String, Codable, CaseIterable, Identifiable {
    case us, eu, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .us: return "Americas (US)"
        case .eu: return "Europe"
        case .custom: return "Custom"
        }
    }

    var defaultBase: String {
        switch self {
        case .us, .custom: return "https://api-us.vicohome.io"
        case .eu: return "https://api-eu.vicoo.tech"
        }
    }

    var country: String { self == .eu ? "EU" : "US" }
}

struct Session: Codable, Equatable {
    var email: String
    var token: String
    var base: String
    var country: String
    var region: Region
    var signedInAt: Date
}

enum SessionStore {
    static func load() -> Session? { AppGroup.read(Session.self, "session.json") }
    static func save(_ s: Session) { AppGroup.write(s, "session.json") }
    static func clear() { AppGroup.remove("session.json") }
}

// MARK: - Loose JSON helpers (the API is inconsistent about field names and types)

typealias JSONDict = [String: Any]

enum J {
    static func str(_ d: JSONDict, _ keys: String...) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
            if let n = d[k] as? NSNumber { return n.stringValue }
        }
        return nil
    }

    static func num(_ d: JSONDict, _ keys: String...) -> Double? {
        for k in keys {
            if let n = d[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
            if let s = d[k] as? String, let v = Double(s) { return v }
        }
        return nil
    }

    static func bool(_ d: JSONDict, _ keys: String...) -> Bool? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.boolValue }
            if let s = (d[k] as? String)?.lowercased() {
                if ["true", "1", "online", "yes"].contains(s) { return true }
                if ["false", "0", "offline", "no"].contains(s) { return false }
            }
        }
        return nil
    }

    static func date(_ d: JSONDict, _ keys: String...) -> Date? {
        for k in keys {
            if let v = d[k] as? NSNumber {
                let x = v.doubleValue
                return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
            }
            if let s = d[k] as? String {
                if let x = Double(s) { return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x) }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
                    f.dateFormat = fmt
                    if let date = f.date(from: s) { return date }
                }
            }
        }
        return nil
    }

    static func pretty(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(any)" }
        return s
    }
}

// MARK: - Camera

struct Camera: Codable, Identifiable, Hashable {
    var id: String              // serial number
    var name: String
    var model: String?
    var battery: Int?
    var charging: Bool
    var signal: Int?
    var online: Bool?
    var ip: String?
    var network: String?
    var location: String?
    var mac: String?
    var firmware: String?
    var streamProtocol: String?
    var updatedAt: Date

    static func from(_ d: JSONDict) -> Camera? {
        guard let sn = J.str(d, "serialNumber", "sn", "deviceSn") else { return nil }
        var battery = J.num(d, "batteryLevel", "battery_percent", "batteryPercent", "battery").map { Int($0) }
        if let b = battery, b < 0 || b > 100 { battery = nil }
        let ip = J.str(d, "ip")
        var online = J.bool(d, "online", "isOnline", "deviceOnline")
        if online == nil, let ip { online = !ip.isEmpty && ip != "0.0.0.0" }
        return Camera(
            id: sn,
            name: J.str(d, "deviceName", "name") ?? "Camera",
            model: J.str(d, "modelNo", "displayModelNo", "model"),
            battery: battery,
            charging: (J.num(d, "isCharging") ?? 0) > 0,
            signal: J.num(d, "signalStrength", "signalDbm", "wifiStrength", "rssi").map { Int($0) },
            online: online,
            ip: ip,
            network: J.str(d, "networkName", "wifiName", "ssid"),
            location: J.str(d, "locationName"),
            mac: J.str(d, "macAddress", "mac"),
            firmware: J.str(d, "firmwareId", "firmwareVersion", "newestFirmwareId"),
            streamProtocol: J.str(d, "streamProtocol"),
            updatedAt: .now
        )
    }

    /// Wi-Fi bars 0...3 from dBm (or a 0-100 percentage on some firmwares).
    var bars: Int? {
        guard let s = signal else { return nil }
        if s < 0 { return s >= -55 ? 3 : s >= -67 ? 2 : s >= -78 ? 1 : 0 }
        return s >= 70 ? 3 : s >= 45 ? 2 : s >= 20 ? 1 : 0
    }

    var signalText: String? {
        guard let s = signal else { return nil }
        return s < 0 ? "\(s) dBm" : "\(s)%"
    }

    var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        guard let b = battery else { return "powerplug" }
        switch b {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

// MARK: - Event

struct CamEvent: Codable, Identifiable, Hashable {
    var id: String              // traceId
    var serial: String
    var cameraName: String
    var date: Date
    var duration: Double?
    var imageURL: String?
    var videoURL: String?
    var tags: [String]
    var isRead: Bool?

    static func from(_ d: JSONDict) -> CamEvent? {
        guard let trace = J.str(d, "traceId", "traceID", "id") else { return nil }
        var tags: [String] = []
        func add(_ s: String?) {
            guard let s, !s.isEmpty else { return }
            let pretty = Self.prettyTag(s)
            if !tags.contains(pretty) { tags.append(pretty) }
        }
        for info in (d["subcategoryInfoList"] as? [JSONDict]) ?? [] {
            add(J.str(info, "objectName") ?? J.str(info, "objectType"))
        }
        var firstShot: String?
        for shot in (d["keyshots"] as? [JSONDict]) ?? [] {
            add(J.str(shot, "objectCategory"))
            add(J.str(shot, "subCategoryName"))
            if firstShot == nil { firstShot = J.str(shot, "imageUrl") }
        }
        if let list = d["tags"] as? [String] { list.forEach { add($0) } }
        else if let t = d["tags"] as? String { t.split(separator: ",").forEach { add(String($0)) } }
        add(J.str(d, "eventType", "type", "event_type"))
        tags.removeAll { $0.isEmpty || $0 == "Unknown" }

        return CamEvent(
            id: trace,
            serial: J.str(d, "serialNumber") ?? "",
            cameraName: J.str(d, "deviceName") ?? "Camera",
            date: J.date(d, "timestamp", "startTimestamp", "time") ?? .now,
            duration: J.num(d, "period", "duration"),
            imageURL: J.str(d, "imageUrl", "imageURL", "coverUrl") ?? firstShot,
            videoURL: J.str(d, "videoUrl", "videoURL", "m3u8Url"),
            tags: tags,
            isRead: J.bool(d, "marked", "isRead", "read")
        )
    }

    static func prettyTag(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        switch s.lowercased() {
        case "person", "human", "people": return "Person"
        case "vehicle", "car": return "Vehicle"
        case "pet", "dog", "cat", "animal": return s.lowercased() == "pet" ? "Pet" : s.capitalized
        case "package", "parcel": return "Package"
        case "bird": return "Bird"
        case "motion", "pir": return "Motion"
        case "unknown", "null", "none", "0": return ""
        default: return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    var headline: String { tags.first ?? "Motion" }

    var symbol: String {
        switch headline {
        case "Person": return "figure.walk"
        case "Vehicle": return "car.fill"
        case "Pet", "Dog", "Cat": return "pawprint.fill"
        case "Package": return "shippingbox.fill"
        case "Bird": return "bird.fill"
        default: return "waveform.path.ecg"
        }
    }

    var durationText: String? {
        guard let d = duration, d > 0 else { return nil }
        let s = Int(d.rounded())
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }
}

// MARK: - Cache shared with the widget

struct Snapshot: Codable {
    var cameras: [Camera]
    var events: [CamEvent]
    var updatedAt: Date

    static func load() -> Snapshot? { AppGroup.read(Snapshot.self, "snapshot.json") }
    func save() { AppGroup.write(self, "snapshot.json") }

    func lastEvent(for serial: String?) -> CamEvent? {
        guard let serial else { return events.first }
        return events.first { $0.serial == serial }
    }
}
