import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmSignOut = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (build \(b))"
    }

    var body: some View {
        ZStack {
            Theme.background()
            List {
                Section("Account") {
                    row("Email", model.session?.email ?? "–")
                    row("Region", model.session?.region.title ?? "–")
                    row("Server", model.session?.base.replacingOccurrences(of: "https://", with: "") ?? "–")
                    if let d = model.lastUpdated { row("Last refresh", d.relative) }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }

                Section {
                    row("Cameras", "\(model.cameras.count)")
                    row("Events loaded", "\(model.events.count)")
                    row("Widget data", AppGroup.isShared ? "Shared" : "Not shared")
                } header: {
                    Text("Data")
                } footer: {
                    if !AppGroup.isShared {
                        Text("The sideloader stripped the App Group, so the widget can't see the app's data. Re-sign with app extensions and App Groups kept.")
                    }
                }

                Section {
                    Text("Vicohome live view is WebRTC with its own signaling. Once the handshake is captured from the Vicohome app, live view gets added here. Everything else (cameras, events, clips) uses the cloud API and works now.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                } header: {
                    Text("Live view")
                }

                Section("About") {
                    row("Version", version)
                    Link("Source on GitHub", destination: URL(string: "https://github.com/soum91/nightjar")!)
                    Text("Unofficial client. Not affiliated with Vicohome.")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out of Nightjar?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOut() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
        }
    }
}
