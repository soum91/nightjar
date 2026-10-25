import WidgetKit
import SwiftUI

@main
struct NightjarWidgets: WidgetBundle {
    var body: some Widget {
        CameraStatusWidget()
        if #available(iOS 18.0, *) { CameraActionControl() }

        LastEventWidget()
    }
}

// MARK: - Timeline

struct NightjarEntry: TimelineEntry {
    let date: Date
    let event: CamEvent?
    let cameras: [Camera]
    let recent: [CamEvent]
    let thumb: UIImage?
    let signedIn: Bool
    let todayCount: Int

    var camera: Camera? {
        guard let e = event else { return cameras.first }
        return cameras.first { $0.id == e.serial } ?? cameras.first
    }

    static func make() -> NightjarEntry {
        let snap = Snapshot.load()
        let events = snap?.events ?? []
        let today = events.filter { Calendar.current.isDateInToday($0.date) }.count
        var img: UIImage?
        if let data = AppGroup.readData("thumb.jpg"), let full = UIImage(data: data) {
            img = full.preparingThumbnail(of: CGSize(width: 700, height: 700 * full.size.height / max(full.size.width, 1))) ?? full
        }
        return NightjarEntry(date: .now, event: events.first, cameras: snap?.cameras ?? [], recent: Array(events.prefix(3)),
                             thumb: img, signedIn: SessionStore.load() != nil, todayCount: today)
    }

    static let preview = NightjarEntry(
        date: .now,
        event: CamEvent(id: "p", serial: "s", cameraName: "Front door", date: .now.addingTimeInterval(-420), duration: 12,
                        imageURL: nil, videoURL: nil, tags: ["Person"], isRead: nil),
        cameras: [Camera(id: "s", name: "Front door", model: nil, battery: 82, charging: false, signal: -58, online: true,
                         ip: nil, network: nil, location: nil, mac: nil, firmware: nil, streamProtocol: nil, updatedAt: .now)],
        recent: [], thumb: nil, signedIn: true, todayCount: 6)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NightjarEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (NightjarEntry) -> Void) {
        let e = NightjarEntry.make()
        completion(context.isPreview && e.event == nil ? .preview : e)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NightjarEntry>) -> Void) {
        Task {
            if SessionStore.load() != nil { _ = try? await Refresher.refresh() }
            completion(Timeline(entries: [.make()], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Widget

struct LastEventWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightjarLastEvent", provider: Provider()) { entry in
            WidgetRoot(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        Color(red: 0.03, green: 0.04, blue: 0.08)
                        if let img = entry.thumb {
                            Image(uiImage: img).resizable().scaledToFill()
                        }
                    }
                }
                .widgetURL(URL(string: "nightjar://home"))
        }
        .configurationDisplayName("Last motion")
        .description("Latest event snapshot and camera battery.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

struct WidgetRoot: View {
    @Environment(\.widgetFamily) var family
    let entry: NightjarEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let e = entry.event { Text("\(e.headline) \(e.date, style: .relative) ago") } else { Text("Nightjar") }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "eye")
                    Text("\(entry.todayCount)").font(.headline)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.event?.cameraName ?? "Nightjar", systemImage: "eye").font(.headline).widgetAccentable()
                if let e = entry.event {
                    Text("\(e.headline) · \(e.date, style: .relative) ago").font(.caption)
                } else {
                    Text(entry.signedIn ? "No recent events" : "Open Nightjar to sign in").font(.caption)
                }
                if let b = entry.camera?.battery { Text("Battery \(b)% · \(entry.todayCount) today").font(.caption2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            MediumView(entry: entry)
        default:
            SmallView(entry: entry)
        }
    }
}

private let amber = Color(red: 0.91, green: 0.64, blue: 0.24)

struct SmallView: View {
    let entry: NightjarEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: entry.event?.symbol ?? "eye").foregroundStyle(amber)
                    Spacer()
                    if let cam = entry.camera { BatteryBadge(camera: cam) }
                }
                Spacer()
                if let e = entry.event {
                    Text(e.headline).font(.headline)
                    Text(e.cameraName).font(.caption).lineLimit(1)
                    Text(e.date, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(entry.signedIn ? "No recent events" : "Sign in to Nightjar").font(.caption)
                }
            }
            .padding(12)
        }
        .foregroundStyle(.white)
    }
}

struct MediumView: View {
    let entry: NightjarEntry
    var body: some View {
        HStack(spacing: 0) {
            SmallView(entry: entry)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(entry.todayCount)").font(.caption.weight(.bold)).foregroundStyle(amber)
                }
                ForEach(entry.recent.dropFirst().prefix(2)) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.symbol).font(.caption2).foregroundStyle(amber).frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.headline).font(.caption.weight(.semibold))
                            Text(e.date, style: .time).font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                Spacer(minLength: 0)
                ForEach(entry.cameras.prefix(2)) { c in
                    HStack(spacing: 5) {
                        Circle().fill(c.online == false ? .red : .green).frame(width: 6, height: 6)
                        Text(c.name).font(.caption2).lineLimit(1)
                        Spacer(minLength: 2)
                        BatteryBadge(camera: c)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.04, green: 0.05, blue: 0.10).opacity(0.92))
        }
        .foregroundStyle(.white)
    }
}

struct BatteryBadge: View {
    let camera: Camera
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: camera.batterySymbol)
            if let b = camera.battery { Text("\(b)%") }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle((camera.battery ?? 100) <= 15 && !camera.charging ? .red : .white.opacity(0.9))
    }
}
