import SwiftUI

struct BridgeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var finder = BridgeFinder()
    @State private var link = HomeBridge.link
    @State private var cfg = HomeBridge.config
    @State private var lights: [BridgeLight] = []
    @State private var camera: JSONDict?
    @State private var manualHost = ""
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        ZStack {
            Theme.background()
            List {
                if link == nil { pairSections } else { configSections }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Apple Home bridge")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if link == nil { finder.start() } else { await load() }
            if cfg.serial.isEmpty, let first = model.cameras.first {
                cfg.serial = first.id
                cfg.name = first.name
            }
        }
        .onDisappear { finder.stop() }
        .refreshable { await load() }
    }

    // MARK: - Pairing

    @ViewBuilder private var pairSections: some View {
        Section {
            if finder.found.isEmpty {
                HStack {
                    if finder.searching { ProgressView().padding(.trailing, 6) }
                    Text(finder.searching ? "Looking on your Wi-Fi…" : "No bridge found.").foregroundStyle(Theme.dim)
                }
            }
            ForEach(finder.found, id: \.self) { f in
                Button { Task { await pair(f.host, f.port) } } label: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(f.name)
                            Text(f.host).font(.caption).foregroundStyle(Theme.dim)
                        }
                        Spacer()
                        if busy { ProgressView() } else { Text("Pair").foregroundStyle(Theme.accent) }
                    }
                }
                .disabled(busy)
            }
            if !finder.searching { Button("Search again") { finder.start() } }
        } header: {
            Text("Keystone Bridge")
        } footer: {
            Text("Puts this camera in Apple Home as a motion sensor, a person sensor and a battery, and lets the bridge switch lights on when the camera sees someone. Needs bridge firmware 1.8 or newer and your home Wi-Fi.")
        }

        Section("Or by address") {
            HStack {
                TextField("192.168.1.50", text: $manualHost)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair") { Task { await pair(manualHost.trimmingCharacters(in: .whitespaces), 8080) } }
                    .disabled(manualHost.isEmpty || busy)
            }
        }
    }

    // MARK: - Camera config

    @ViewBuilder private var configSections: some View {
        Section {
            if let link {
                row("Bridge", link.host)
            }
            statusRows
            Button("Forget this bridge", role: .destructive) {
                HomeBridge.forget()
                link = nil
                cfg = HomeBridge.config
                camera = nil
                finder.start()
            }
        } header: {
            Text("Bridge")
        }

        Section {
            Picker("Camera", selection: $cfg.serial) {
                ForEach(model.cameras) { Text($0.name).tag($0.id) }
            }
            .onChange(of: cfg.serial) { _, new in
                if let c = model.camera(new) { cfg.name = c.name }
            }
            HStack {
                Text("Name in Home")
                TextField("Camera", text: $cfg.name).multilineTextAlignment(.trailing).foregroundStyle(Theme.dim)
            }
            Toggle("Let the bridge sign in itself", isOn: $cfg.sendPassword)
        } header: {
            Text("Camera")
        } footer: {
            Text(cfg.sendPassword
                 ? "The bridge uses Nightjar's session and only signs in with your password if that session runs out. It's stored on the bridge."
                 : "The bridge only uses Nightjar's session. When it runs out, open Nightjar at home and it hands the bridge a new one.")
        }

        Section {
            Toggle("Person turns lights on", isOn: $cfg.ruleOn)
            if cfg.ruleOn {
                if lights.isEmpty {
                    Text("The bridge has no lights. Add them from Afterglow.").font(.footnote).foregroundStyle(Theme.dim)
                }
                ForEach(lights) { l in
                    Button {
                        if let i = cfg.lights.firstIndex(of: l.id) { cfg.lights.remove(at: i) } else { cfg.lights.append(l.id) }
                    } label: {
                        HStack {
                            Text(l.name).foregroundStyle(.white)
                            Spacer()
                            if cfg.lights.contains(l.id) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
                Toggle("Only between", isOn: $cfg.window)
                if cfg.window {
                    DatePicker("From", selection: minutes($cfg.from), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutes($cfg.to), displayedComponents: .hourAndMinute)
                }
                Stepper(value: $cfg.offAfter, in: 0...120, step: 5) {
                    Text(cfg.offAfter == 0 ? "Leave them on" : "Off after \(cfg.offAfter) quiet min")
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("Runs on the bridge, so it works without a HomePod or Apple TV. Lights that were already on are left alone, and only the ones it switched on go off again. Expect 10 to 30 seconds of lag: the bridge reads the camera's events from Vicohome's cloud.")
        }

        alertSections

        Section {
            Button {
                Task { await send() }
            } label: {
                HStack {
                    Text(cfg.sent ? "Update bridge" : "Add to Apple Home").fontWeight(.semibold)
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || cfg.serial.isEmpty)
            if cfg.sent {
                Button("Remove camera from the bridge", role: .destructive) { Task { await remove() } }
                    .disabled(busy)
            }
        } footer: {
            if let message { Text(message) }
        }
    }

    @ViewBuilder private var alertSections: some View {
        Section {
            Toggle("Push alerts (ntfy)", isOn: $cfg.alertOn)
                .onChange(of: cfg.alertOn) { _, on in if on && cfg.topic.isEmpty { cfg.topic = Ntfy.newTopic() } }
            if cfg.alertOn {
                HStack {
                    Text(cfg.topic).font(.system(.footnote, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { UIPasteboard.general.string = cfg.topic; message = "Topic copied. In ntfy tap +, paste it, Subscribe." } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                if let u = URL(string: "https://apps.apple.com/app/ntfy/id1625396347") {
                    Link("Get ntfy from the App Store", destination: u)
                }
                Button("Send a test push") { Task { await testPush() } }.disabled(busy)
                Toggle("Any motion, not just people", isOn: $cfg.alertAll)
                Stepper(value: $cfg.cooldown, in: 0...600, step: 30) {
                    Text(cfg.cooldown == 0 ? "Every event" : "At most one per \(cfg.cooldown < 60 ? "\(cfg.cooldown) s" : "\(cfg.cooldown / 60) min")")
                }
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("The bridge pushes each person event with its snapshot through ntfy, so it works with the phone asleep or away; tap the alert to open the event in Nightjar. In the ntfy app tap +, paste this topic and subscribe. Keep the topic private: anyone who has it can read the alerts.")
        }

        if cfg.alertOn {
            Section {
                SecureField("Anthropic API key (optional)", text: $cfg.aiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !cfg.aiKey.isEmpty {
                    Toggle("Only alert when something's flagged", isOn: $cfg.aiOnly)
                }
                if let a = camera?["alerts"] as? JSONDict, let last = J.str(a, "lastAi") {
                    row("Last check", last)
                }
            } header: {
                Text("AI check")
            } footer: {
                Text("Claude Haiku looks at each snapshot and flags someone right at the lens, touching or covering the camera, or at the food or fridge. Flagged alerts skip the cooldown. The snapshot link goes to Anthropic; roughly a fraction of a cent per check.")
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        if let c = camera, (c["configured"] as? Bool) == true {
            let ok = (c["ok"] as? Bool) == true
            row("Camera on bridge", ok ? "Working" : (J.str(c, "error") ?? "Starting"))
            if let b = J.num(c, "battery") { row("Battery", "\(Int(b))%") }
            if let a = c["alerts"] as? JSONDict, (a["enabled"] as? Bool) == true {
                row("Alerts sent", J.str(a, "error").map { "⚠︎ \($0)" } ?? "\(Int(J.num(a, "sent") ?? 0))")
            }
            if let ago = J.num(c, "lastEventAgo") {
                let s = Int(ago)
                row("Last \(J.str(c, "lastType") ?? "event")", s < 60 ? "\(s)s ago" : s < 3600 ? "\(s / 60)m ago" : "\(s / 3600)h ago")
            }
        } else if camera != nil {
            row("Camera on bridge", "Not added yet")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(Theme.dim).lineLimit(2).multilineTextAlignment(.trailing)
        }
    }

    private func minutes(_ b: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: b.wrappedValue / 60, minute: b.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    // MARK: - Actions

    private func load() async {
        guard link != nil else { return }
        do {
            let r = try await HomeBridge.info()
            lights = r.lights
            camera = r.camera
            error = nil
        } catch {
            self.error = "Couldn't reach the bridge: \(error.localizedDescription). Are you on your home Wi-Fi?"
        }
    }

    private func pair(_ host: String, _ port: Int) async {
        guard !host.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            link = try await HomeBridge.claim(host: host, port: port)
            finder.stop()
            error = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() async {
        busy = true
        defer { busy = false }
        if cfg.name.trimmingCharacters(in: .whitespaces).isEmpty { cfg.name = model.camera(cfg.serial)?.name ?? "Camera" }
        do {
            let restart = try await HomeBridge.send(cfg)
            cfg = HomeBridge.config
            error = nil
            message = restart
                ? "Sent. The bridge is restarting to add \(cfg.name) to Apple Home; it shows up in the Home app within a minute."
                : "Sent. The bridge picked up the changes."
            try? await Task.sleep(for: .seconds(restart ? 20 : 2))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func testPush() async {
        busy = true
        defer { busy = false }
        do {
            try await Ntfy.test(cfg.topic)
            message = "Test sent. If it didn't arrive, subscribe to the topic in ntfy. Tap Update bridge to save the alert settings on the bridge."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do {
            try await HomeBridge.send(cfg, remove: true)
            cfg = HomeBridge.config
            message = "Removed. The bridge restarts and the camera leaves Apple Home."
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
