import SwiftUI
import WidgetKit
import BackgroundTasks

@MainActor
final class AppModel: ObservableObject {
    @Published var session: Session? = SessionStore.load()
    @Published var cameras: [Camera] = []
    @Published var events: [CamEvent] = []
    @Published var loading = false
    @Published var loadingMore = false
    @Published var error: String?
    @Published var lastUpdated: Date?
    /// How far back the timeline currently reaches.
    @Published private(set) var historyStart = Date().addingTimeInterval(-86_400)

    init() {
        if let snap = Snapshot.load() {
            cameras = snap.cameras
            events = snap.events
            lastUpdated = snap.updatedAt
        }
    }

    var signedIn: Bool { session != nil }

    func camera(_ serial: String) -> Camera? { cameras.first { $0.id == serial } }

    func events(for serial: String?) -> [CamEvent] {
        guard let serial else { return events }
        return events.filter { $0.serial == serial }
    }

    // MARK: Auth

    func signIn(email: String, password: String, region: Region, customBase: String) async throws {
        session = try await Vico.login(email: email, password: password, region: region, customBase: customBase)
        historyStart = Date().addingTimeInterval(-86_400)
        await refresh()
    }

    func signOut() {
        Vico.signOut()
        session = nil
        cameras = []
        events = []
        lastUpdated = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Data

    func refresh() async {
        guard signedIn, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let cams = Vico.cameras()
            async let evts = Vico.events(from: historyStart, to: .now)
            let (c, e) = try await (cams, evts)
            cameras = c
            events = e
            lastUpdated = .now
            error = nil
            let snap = Snapshot(cameras: c, events: Array(e.prefix(60)), updatedAt: .now)
            snap.save()
            await Refresher.cacheThumb(e.first)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = error.localizedDescription
            if let v = error as? VicoError, v.isAuth, Keychain.password(for: session?.email ?? "") == nil {
                signOut()
            }
        }
        session = SessionStore.load()
    }

    /// Extends the timeline back one more day (or a week once you're past a few days).
    func loadEarlier() async {
        guard signedIn, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let span: TimeInterval = historyStart < Date().addingTimeInterval(-4 * 86_400) ? 7 * 86_400 : 86_400
        let newStart = historyStart.addingTimeInterval(-span)
        do {
            let older = try await Vico.events(from: newStart, to: historyStart)
            let known = Set(events.map(\.id))
            events.append(contentsOf: older.filter { !known.contains($0.id) })
            events.sort { $0.date > $1.date }
            historyStart = newStart
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Background refresh (keeps the widget fresh)

    static let bgID = "com.soum91.nightjar.refresh"

    nonisolated static func registerBackground() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            scheduleBackground()
            let work = Task {
                _ = try? await Refresher.refresh()
                WidgetCenter.shared.reloadAllTimelines()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    nonisolated static func scheduleBackground() {
        let req = BGAppRefreshTaskRequest(identifier: bgID)
        req.earliestBeginDate = Date().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
