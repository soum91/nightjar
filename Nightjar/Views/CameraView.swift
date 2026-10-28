import SwiftUI

struct CameraView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let serial: String
    var autoStart: Bool? = nil
    @State private var filter = "All"
    @State private var detail: JSONDict?
    @StateObject private var live: LiveSession
    @State private var fullscreen = false
    @AppStorage("live.autoStart") private var autoLive = true

    init(serial: String, autoStart: Bool? = nil) {
        self.serial = serial
        self.autoStart = autoStart
        _live = StateObject(wrappedValue: LiveSession(serial: serial))
    }

    private var camera: Camera? { model.camera(serial) }
    private var events: [CamEvent] { model.events(for: serial) }

    /// selectsingledevice is richer than the list; prefer it when it's loaded.
    private var merged: Camera? {
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
                    LivePlayer(session: live, poster: events.first, onFullscreen: { fullscreen = true })
                    if let cam = merged {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(cam.online == false ? Theme.danger : Theme.good)
                                .frame(width: 8, height: 8)
                            Text(cam.name).font(.headline)
                            Spacer()
                            StatusPills(camera: cam)
                        }
                        .card(padding: 14)
                    }
                    EventTimeline(events: events, filter: $filter, showCamera: false)
                    if let cam = merged {
                        StatusGrid(camera: cam)
                    }

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
        .task {
            if autoStart ?? autoLive, live.phase == .idle { live.start() }
            detail = try? await Vico.cameraRaw(serial)
        }
        .fullScreenCover(isPresented: $fullscreen) {
            FullscreenLive(session: live, poster: events.first)
        }
        .onDisappear { if !fullscreen { live.stop(silently: true) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, live.phase.isActive { live.stop() }
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
