import SwiftUI
import AVKit
import Photos

struct EventView: View {
    @EnvironmentObject var model: AppModel
    let event: CamEvent
    @State private var fresh: CamEvent?
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var note: String?
    @State private var saving = false

    private var e: CamEvent { fresh ?? event }

    var body: some View {
        ZStack {
            Theme.background()
            ScrollView {
                VStack(spacing: 18) {
                    media
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if let note {
                        Text(note).font(.footnote).foregroundStyle(Theme.dim)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: e.symbol).foregroundStyle(Theme.accent)
                            Text(e.tags.isEmpty ? "Motion" : e.tags.joined(separator: ", ")).font(.headline)
                        }
                        info("Camera", e.cameraName)
                        info("When", e.date.formatted(date: .abbreviated, time: .standard))
                        if let d = e.durationText { info("Length", d) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    HStack(spacing: 12) {
                        if let v = e.videoURL, let url = URL(string: v) {
                            Button { Task { await saveVideo(url) } } label: {
                                Label(saving ? "Saving" : "Save clip", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(saving)
                            ShareLink(item: url) {
                                Label("Share link", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                        }
                        if e.videoURL == nil, let i = e.imageURL, let url = URL(string: i) {
                            Button { Task { await saveImage(url) } } label: {
                                Label("Save snapshot", systemImage: "photo").frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)

                    NavigationLink(value: Route.raw(title: "Event data", serial: nil, traceId: event.id)) {
                        Label("Diagnostics: raw event data", systemImage: "curlybraces")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .card(padding: 14)
                }
                .padding(16)
            }
        }
        .navigationTitle(e.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private var media: some View {
        if let player {
            VideoPlayer(player: player)
        } else {
            ZStack {
                RemoteImage(url: e.imageURL, key: e.id, contentMode: .fit)
                if loading { ProgressView() }
            }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.dim)
            Spacer()
            Text(v)
        }
        .font(.subheadline)
    }

    private func load() async {
        defer { loading = false }
        // List URLs are signed and may have expired; ask for the event again for fresh links.
        if let result = try? await Vico.event(event.id), let ev = result.0 { fresh = ev }
        if let s = e.videoURL, let url = URL(string: s) {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        } else {
            note = "No clip for this event (cloud recording may be off for this camera, or it's past your plan's history)."
        }
    }

    private func saveVideo(_ url: URL) async {
        saving = true
        defer { saving = false }
        do {
            let local = try await downloadClip(url)
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: local)
            }
            note = "Saved to Photos."
        } catch {
            note = "Couldn't save the clip: \(error.localizedDescription)"
        }
    }

    /// Plain MP4 links download directly; HLS (.m3u8) gets exported through AVFoundation.
    private func downloadClip(_ url: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nightjar-\(event.id).mp4")
        try? FileManager.default.removeItem(at: out)
        if url.pathExtension.lowercased() == "m3u8" || url.absoluteString.contains(".m3u8") {
            let asset = AVURLAsset(url: url)
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw VicoError(message: "This clip format can't be exported.")
            }
            try await export.export(to: out, as: .mp4)
            return out
        }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    private func saveImage(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            note = "Saved to Photos."
        } catch {
            note = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Pretty-printed API responses, for figuring out fields and the live view protocol.
struct RawView: View {
    let title: String
    let serial: String?
    let traceId: String?
    @State private var text = "Loading…"

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .background(Theme.bgBottom.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .task {
            do {
                if let serial {
                    text = J.pretty(try await Vico.cameraRaw(serial))
                } else if let traceId {
                    text = J.pretty(try await Vico.event(traceId).1)
                }
            } catch {
                text = "Error: \(error.localizedDescription)"
            }
        }
    }
}
