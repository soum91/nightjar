import SwiftUI

struct CameraView: View {
    @EnvironmentObject var model: AppModel
    let serial: String
    @State private var filter = "All"
    @State private var detail: JSONDict?

    private var camera: Camera? { model.camera(serial) }
    private var events: [CamEvent] { model.events(for: serial) }

    /// selectsingledevice is richer than the list; prefer it when it's loaded.
    private var live: Camera? {
        guard let detail, var c = Camera.from(detail) else { return camera }
        if let base = camera {
            c.name = base.name
            c.battery = c.battery ?? base.battery
            c.signal = c.signal ?? base.signal
            c.online = c.online ?? base.online
        }
        return c
    }

    var body: some View {
        ZStack {
            Theme.background()
            ScrollView {
                VStack(spacing: 18) {
                    if let cam = live {
                        CameraCard(camera: cam, last: events.first)
                        LiveViewCard(camera: cam)
                        StatusGrid(camera: cam)
                    }
                    EventTimeline(events: events, filter: $filter, showCamera: false)

                    NavigationLink(value: Route.raw(title: "Camera data", serial: serial, traceId: nil)) {
                        Label("Diagnostics: raw camera data", systemImage: "curlybraces")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .card(padding: 14)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .refreshable {
                await model.refresh()
                detail = try? await Vico.cameraRaw(serial)
            }
        }
        .navigationTitle(camera?.name ?? "Camera")
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = try? await Vico.cameraRaw(serial) }
    }
}

struct LiveViewCard: View {
    let camera: Camera
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Live view").font(.subheadline.weight(.semibold))
                Text(liveText).font(.footnote).foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }

    private var liveText: String {
        switch camera.streamProtocol?.lowercased() {
        case "webrtc"?:
            return "This camera streams over WebRTC, so live view can be added. It's waiting on a one time capture of the Vicohome app's signaling handshake."
        case let p?:
            return "This camera reports stream protocol \"\(p)\". Live view needs that protocol worked out first."
        case nil:
            return "Live view isn't in this build yet. Clips from motion events play below."
        }
    }
}

struct StatusGrid: View {
    let camera: Camera
    private var rows: [(String, String, String)] {
        var r: [(String, String, String)] = []
        r.append(("Status", camera.online == false ? "Offline" : "Online", "circle.fill"))
        if let b = camera.battery { r.append(("Battery", "\(b)%\(camera.charging ? " · charging" : "")", camera.batterySymbol)) }
        else if camera.charging { r.append(("Power", "Charging", "bolt.fill")) }
        if let s = camera.signalText { r.append(("Wi-Fi", s, "wifi")) }
        if let n = camera.network { r.append(("Network", n, "network")) }
        if let ip = camera.ip, !ip.isEmpty { r.append(("IP", ip, "number")) }
        if let m = camera.model { r.append(("Model", m, "video")) }
        if let f = camera.firmware { r.append(("Firmware", f, "cpu")) }
        if let l = camera.location { r.append(("Location", l, "house")) }
        if let p = camera.streamProtocol { r.append(("Stream", p, "play.rectangle")) }
        r.append(("Serial", camera.id, "barcode"))
        return r
    }

    var body: some View {
        VStack(spacing: 10) {
            SectionTitle(text: "Camera")
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Image(systemName: row.2)
                            .frame(width: 22)
                            .foregroundStyle(row.0 == "Status" ? (camera.online == false ? Theme.danger : Theme.good) : Theme.accent)
                            .font(.footnote)
                        Text(row.0).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(row.1).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 10)
                    if row.0 != rows.last?.0 { Divider().overlay(Theme.stroke) }
                }
            }
            .card(padding: 14)
        }
    }
}
