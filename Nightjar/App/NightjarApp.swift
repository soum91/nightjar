import SwiftUI
import AppIntents

@main
struct NightjarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() { AppModel.registerBackground() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { url in
                    Task {
                        // nightjar://event/<traceId> from an ntfy alert: open that event.
                        if url.host == "event", let ev = try? await Vico.event(url.lastPathComponent).0 {
                            NightjarQuickRoute.shared.route = .event(ev)
                        }
                        await model.refresh()
                    }
                }
        }
        .onChange(of: phase) { _, new in
            if new == .active { Task { await model.refresh() } }
            if new == .background { AppModel.scheduleBackground() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.signedIn {
            HomeView()
        } else {
            LoginView()
        }
    }
}


/// Visible Apple Shortcuts control for opening the selected camera.
struct NightjarShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .purple

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenCameraIntent(), phrases: [
            "Open my camera in \(.applicationName)",
        ], shortTitle: "Open Camera", systemImageName: "video.fill")
        AppShortcut(intent: OpenCameraIntent(nil, .live), phrases: [
            "Show my camera live in \(.applicationName)",
            "Go live in \(.applicationName)",
        ], shortTitle: "Go Live", systemImageName: "dot.radiowaves.left.and.right")
    }
}
