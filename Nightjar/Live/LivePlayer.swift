import SwiftUI
import WebRTC

/// Metal renderer for the camera's video track.
struct LiveVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    let session: LiveSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = .scaleAspectFit
        v.backgroundColor = .black
        v.delegate = context.coordinator
        context.coordinator.attach(track, to: v)
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: v)
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: v)
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        private weak var session: LiveSession?
        private var current: RTCVideoTrack?

        init(session: LiveSession) { self.session = session }

        func attach(_ track: RTCVideoTrack?, to view: RTCMTLVideoView) {
            guard track !== current else { return }
            current?.remove(view)
            current = track
            track?.add(view)
        }

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak session] in session?.didRender(size: size) }
        }
    }
}

/// Live view card: last snapshot until you go live, then the stream with mute, fullscreen and stop.
struct LivePlayer: View {
    @ObservedObject var session: LiveSession
    var poster: CamEvent?
    var fullscreen = false
    var onFullscreen: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var showLog = false
    @State private var controlsVisible = true

    private var aspect: CGFloat {
        let s = session.videoSize
        return s.width > 0 && s.height > 0 ? s.width / s.height : 16 / 9
    }

    var body: some View {
        ZStack {
            Color.black
            if session.phase == .idle {
                RemoteImage(url: poster?.imageURL, key: poster?.id, contentMode: .fill)
                    .opacity(0.55)
                    .clipped()
            } else {
                LiveVideoView(track: session.videoTrack, session: session)
            }
            overlay
        }
        .aspectRatio(fullscreen ? nil : aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: fullscreen ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if session.phase == .live { withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() } }
        }
        .sheet(isPresented: $showLog) { LiveLogView(session: session) }
    }

    @ViewBuilder private var overlay: some View {
        switch session.phase {
        case .idle:
            Button { session.start() } label: {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle.fill").font(.system(size: 54))
                    Text("Go live").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
            }
        case .failed(let message), .ended(let message):
            VStack(spacing: 10) {
                Image(systemName: session.phase == .ended(message) ? "stop.circle" : "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(session.phase == .ended(message) ? .white : Theme.danger)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 24)
                HStack(spacing: 10) {
                    Button("Retry") { session.start() }
                        .buttonStyle(.borderedProminent)
                    Button("Log") { showLog = true }
                        .buttonStyle(.bordered)
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.vertical, 12)
        case .live:
            if controlsVisible { liveControls.transition(.opacity) }
        default:
            VStack(spacing: 10) {
                ProgressView().tint(.white).controlSize(.large)
                Text(session.phase.label).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            }
            closeButtonOverlay
        }
    }

    private var closeButtonOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button { session.stop() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold))
                        .padding(9)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(10)
    }

    private var liveControls: some View {
        VStack {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("LIVE").font(.caption2.weight(.heavy))
                    if let since = session.liveSince {
                        Text(since, style: .timer).font(.caption2.monospacedDigit())
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.black.opacity(0.5), in: Capsule())
                if session.relayed {
                    Text("RELAY").font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                Spacer()
                if let onClose {
                    roundButton("xmark", action: onClose)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                roundButton(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") { session.muted.toggle() }
                Spacer()
                roundButton("list.bullet.rectangle") { showLog = true }
                if let onFullscreen {
                    roundButton(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: onFullscreen)
                }
                roundButton("stop.fill") { session.stop() }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.5), in: Circle())
        }
    }
}

struct LiveLogView: View {
    @ObservedObject var session: LiveSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(session.log.isEmpty ? "Nothing yet." : session.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Theme.bgBottom.ignoresSafeArea())
            .navigationTitle("Live log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UIPasteboard.general.string = session.log.joined(separator: "\n") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Edge-to-edge player; rotate the phone for landscape.
struct FullscreenLive: View {
    @ObservedObject var session: LiveSession
    var poster: CamEvent?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LivePlayer(session: session, poster: poster, fullscreen: true,
                   onFullscreen: { dismiss() }, onClose: { dismiss() })
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
    }
}
