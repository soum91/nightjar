import SwiftUI

enum Route: Hashable {
    case camera(String)
    case live(String)
    case event(CamEvent)
    case settings
    case raw(title: String, serial: String?, traceId: String?)
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var path = NavigationPath()
    @ObservedObject private var quickRoute = NightjarQuickRoute.shared
    @State private var filter: String = "All"

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background()
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if let error = model.error {
                            ErrorBanner(text: error) { Task { await model.refresh() } }
                        }

                        if model.cameras.isEmpty && !model.loading {
                            EmptyState()
                        }

                        ForEach(model.cameras) { cam in
                            NavigationLink(value: Route.camera(cam.id)) {
                                CameraCard(camera: cam, last: model.events(for: cam.id).first)
                            }
                            .buttonStyle(.plain)
                        }

                        EventTimeline(events: model.events, filter: $filter, showCamera: model.cameras.count > 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable { await model.refresh() }
            }
            .navigationTitle("Nightjar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.loading { ProgressView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .camera(let id): CameraView(serial: id)
                case .live(let id): CameraView(serial: id, autoStart: true)
                case .event(let e): EventView(event: e)
                case .settings: SettingsView()
                case .raw(let title, let serial, let trace): RawView(title: title, serial: serial, traceId: trace)
                }
            }
        }
        .onReceive(quickRoute.$route) { route in
            if let route { path = NavigationPath(); path.append(route); quickRoute.route = nil }
        }
        .onReceive(quickRoute.$showTimeline) { request in
            if request != nil { path = NavigationPath(); filter = "All"; quickRoute.showTimeline = nil }
        }
        .task { if model.lastUpdated == nil || model.lastUpdated! < Date().addingTimeInterval(-60) { await model.refresh() } }
    }
}

// MARK: - Camera card

struct CameraCard: View {
    let camera: Camera
    let last: CamEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: last?.imageURL, key: last?.id)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                if let last {
                    HStack(spacing: 6) {
                        Image(systemName: last.symbol)
                        Text("\(last.headline) · \(last.date.relative)")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(12)
                } else {
                    Text("No recent events").font(.footnote).foregroundStyle(Theme.dim).padding(12)
                }
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(camera.online == false ? Theme.danger : Theme.good)
                    .frame(width: 8, height: 8)
                Text(camera.name).font(.headline)
                Spacer()
                StatusPills(camera: camera)
            }
            .padding(14)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }
}

struct StatusPills: View {
    let camera: Camera
    var body: some View {
        HStack(spacing: 10) {
            if let bars = camera.bars {
                Image(systemName: "wifi", variableValue: Double(bars) / 3)
            }
            HStack(spacing: 3) {
                Image(systemName: camera.batterySymbol)
                if let b = camera.battery { Text("\(b)%") }
            }
            .foregroundStyle((camera.battery ?? 100) <= 15 && !camera.charging ? Theme.danger : .white.opacity(0.8))
        }
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.8))
    }
}

// MARK: - Timeline

struct EventTimeline: View {
    @EnvironmentObject var model: AppModel
    let events: [CamEvent]
    @Binding var filter: String
    var showCamera = true
    var title = "Events"

    private var tags: [String] {
        var out = ["All"]
        for e in events { for t in e.tags where !out.contains(t) { out.append(t) } }
        return out
    }

    private var filtered: [CamEvent] {
        filter == "All" ? events : events.filter { $0.tags.contains(filter) }
    }

    private var days: [(Date, [CamEvent])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                SectionTitle(text: title)
                Text("\(filtered.count)").font(.caption).foregroundStyle(Theme.dim)
            }
            .padding(.top, 6)

            if tags.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { t in
                            Button(t) { filter = t }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(filter == t ? Theme.accent : Theme.card, in: Capsule())
                                .foregroundStyle(filter == t ? .black : .white)
                        }
                    }
                }
            }

            if filtered.isEmpty {
                Text(events.isEmpty ? "Nothing in this window yet." : "No \(filter.lowercased()) events.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }

            ForEach(days, id: \.0) { day, items in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    VStack(spacing: 0) {
                        ForEach(items) { e in
                            NavigationLink(value: Route.event(e)) {
                                EventRow(event: e, showCamera: showCamera)
                            }
                            .buttonStyle(.plain)
                            if e.id != items.last?.id { Divider().overlay(Theme.stroke).padding(.leading, 112) }
                        }
                    }
                    .card(padding: 8)
                }
            }

            Button {
                Task { await model.loadEarlier() }
            } label: {
                HStack {
                    if model.loadingMore { ProgressView() }
                    Text(model.loadingMore ? "Loading" : "Load earlier events")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .card(padding: 4)
            .disabled(model.loadingMore)
        }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month().day())
    }
}

struct EventRow: View {
    let event: CamEvent
    var showCamera = true

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: event.imageURL, key: event.id)
                .frame(width: 96, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let d = event.durationText {
                        Text(d).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: event.symbol).foregroundStyle(Theme.accent)
                    Text(event.tags.isEmpty ? "Motion" : event.tags.joined(separator: ", "))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(showCamera ? "\(event.cameraName) · \(event.date.formatted(date: .omitted, time: .shortened))"
                                : event.date.formatted(date: .omitted, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.25))
        }
        .padding(6)
        .contentShape(Rectangle())
    }
}

// MARK: - Bits

struct ErrorBanner: View {
    let text: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(text).font(.footnote)
            Spacer()
            Button("Retry", action: retry).font(.footnote.weight(.semibold))
        }
        .card(padding: 12)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(Theme.dim)
            Text("No cameras on this account").font(.headline)
            Text("If you signed in with a second account, share the cameras to it from your main Vicohome account first.")
                .font(.footnote)
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .card()
    }
}
