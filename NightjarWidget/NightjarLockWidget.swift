import SwiftUI
import WidgetKit

// Read-only Lock Screen status, built exactly like DewPoint's 1x1 temperature widget,
// the one Lock Screen widget that renders on iOS 27 beta 4 with sideloaded builds:
// static configuration, cached data only (no network in the timeline), no buttons,
// no accessory background. Tapping it opens the app.
struct NightjarLockEntry: TimelineEntry {
    var date: Date
    var last: CamEvent?
    var today: Int
    var camera: Camera?
    var icon: String { "video.fill" }
    var short: String { "\(today)" }
    var title: String { last?.cameraName ?? camera?.name ?? "Nightjar" }
    var headline: String { last.map { "Motion \($0.date.formatted(date: .omitted, time: .shortened))" } ?? "No events" }
    var detail: String { "\(today) today" + (camera?.battery.map { " · \($0)%" } ?? "") }
    static func make() -> NightjarLockEntry {
        let snap = Snapshot.load()
        let events = snap?.events ?? []
        let last = events.first
        let cam = snap?.cameras.first { $0.id == last?.serial } ?? snap?.cameras.first
        return .init(date: .now, last: last, today: events.filter { Calendar.current.isDateInToday($0.date) }.count, camera: cam)
    }
}

struct NightjarLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> NightjarLockEntry { NightjarLockEntry.make() }
    func getSnapshot(in context: Context, completion: @escaping (NightjarLockEntry) -> Void) { completion(NightjarLockEntry.make()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NightjarLockEntry>) -> Void) {
        completion(Timeline(entries: [NightjarLockEntry.make()], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct NightjarLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NightjarLockStatusV1", provider: NightjarLockProvider()) { entry in
            NightjarLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Camera status")
        .description("Last motion event and today count. Tap to open Nightjar.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct NightjarLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NightjarLockEntry

    var body: some View {
        Group {
            if family == .accessoryCircular {
                VStack(spacing: 1) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .semibold))
                    Text(entry.short)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: entry.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption2).lineLimit(1)
                        Text(entry.headline).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
