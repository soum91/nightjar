import SwiftUI
import WidgetKit
import AppIntents
@available(iOS 18.0, *) struct CameraActionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.soum91.nightjar.camera", intent: CameraControlConfig.self) { config in
            ControlWidgetButton(action: OpenCameraIntent(config.camera, config.action)) { Label(config.camera?.name ?? "Nightjar", systemImage: "video.fill") }
        }.displayName("Camera / latest event").description("Open a chosen camera, its latest recorded event or the event timeline.")
    }
}
struct CameraStatusEntry: TimelineEntry { var date: Date; var camera: Camera?; var last: CamEvent? }
struct CameraStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CameraStatusEntry { .init(date: .now, camera: nil, last: nil) }
    func snapshot(for configuration: CameraWidgetConfig, in context: Context) async -> CameraStatusEntry { entry(configuration) }
    func timeline(for configuration: CameraWidgetConfig, in context: Context) async -> Timeline<CameraStatusEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(.now.addingTimeInterval(900)))
    }
    func entry(_ config: CameraWidgetConfig) -> CameraStatusEntry {
        let snap = Snapshot.load()
        let cam = config.camera == nil ? snap?.cameras.first : snap?.cameras.first { $0.id == config.camera?.id }
        return .init(date: .now, camera: cam, last: snap?.events.first { $0.serial == cam?.id })
    }
}
struct CameraStatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NightjarCameraStatus", intent: CameraWidgetConfig.self, provider: CameraStatusProvider()) { entry in
            CameraStatusView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }.configurationDisplayName("Chosen camera").description("Battery, last-reported online status and latest motion time.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct CameraStatusView: View {
    @Environment(\.widgetFamily) var family
    var entry: CameraStatusEntry
    var body: some View {
        if let c = entry.camera {
            Button(intent: OpenCameraIntent(CameraEntity(id: c.id, name: c.name), .camera)) {
                if family == .accessoryInline { Text("\(c.name) · \(c.battery.map { "\($0)%" } ?? "Battery unknown")") }
                else if family == .accessoryCircular {
                    ZStack { AccessoryWidgetBackground(); VStack { Image(systemName: "video.fill"); Text(c.battery.map { "\($0)%" } ?? "--").font(.caption) } }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.headline)
                        Text("\(c.online.map { $0 ? "Online" : "Offline" } ?? "Unknown") · \(c.battery.map { "\($0)%" } ?? "--")").font(.caption)
                        if let e = entry.last { Text("Motion \(e.date, style: .relative) ago").font(.caption2) }
                    }
                }
            }.buttonStyle(.plain).privacySensitive()
        } else { Label("Choose a camera", systemImage: "video").font(.caption) }
    }
}
