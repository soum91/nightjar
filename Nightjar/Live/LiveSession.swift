import Foundation
import AVFoundation
import WebRTC

/// One live view of one camera.
///
/// Flow (from bbielsa/vicostream, which mirrors the official app):
/// 1. `getWebrtcTicket` → signaling server, access token, group/trace ids, TURN servers.
/// 2. WebSocket: AUTH → AUTH_RESPONSE(code 0) → JOIN_LIVE → PEER_IN (camera joined).
/// 3. SDP offer / answer and ICE candidates go through `TRANSMIT` with base64 JSON payloads.
/// 4. Once the data channel opens, `{"action":"startLive"}` makes the camera start sending H.264 + PCMU.
@MainActor
final class LiveSession: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case ticket
        case signaling
        case waiting      // joined, waiting for the camera to wake and join
        case connecting   // offer/answer done, ICE + DTLS
        case live
        case ended(String)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .ticket: return "Requesting stream"
            case .signaling: return "Connecting to Vicohome"
            case .waiting: return "Waking the camera"
            case .connecting: return "Connecting to the camera"
            case .live: return "Live"
            case .ended(let s), .failed(let s): return s
            }
        }

        var isActive: Bool {
            switch self {
            case .ticket, .signaling, .waiting, .connecting, .live: return true
            default: return false
            }
        }
    }

    let serial: String
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var liveSince: Date?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var relayed = false
    @Published var log: [String] = []
    @Published var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "live.muted")
            audioTrack?.isEnabled = !muted
        }
    }

    private var pc: RTCPeerConnection?
    private var dc: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var ws: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var pingTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    private var clientID = ""
    private var groupID = ""
    private var traceID = ""
    private var sessionID = ""
    private var offerSent = false
    private var localSent = 0
    private var offerReceiptLogged = false
    private var remoteSet = false
    private var pendingLocal: [RTCIceCandidate] = []
    private var pendingRemote: [RTCIceCandidate] = []
    private var startLiveSent = false
    /// Bumped on every start/stop so callbacks from an older attempt are ignored.
    private var generation = 0

    init(serial: String) {
        self.serial = serial
        self.muted = UserDefaults.standard.object(forKey: "live.muted") as? Bool ?? true
        super.init()
    }

    // MARK: - Factory

    private static let factory: RTCPeerConnectionFactory = {
        _ = RTCInitializeSSL()
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.default.rawValue
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        RTCAudioSessionConfiguration.setWebRTC(audio)
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: CameraDecoderFactory())
    }()

    // MARK: - Control

    func start() {
        stop(silently: true)
        generation += 1
        let gen = generation
        log = []
        liveSince = nil
        videoSize = .zero
        relayed = false
        phase = .ticket
        note("Requesting WebRTC ticket")
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard let self, self.generation == gen, self.phase != .live, self.phase.isActive else { return }
            self.fail("Timed out while \(self.phase.label.lowercased()). The camera may be asleep, offline or busy with another viewer.")
        }
        Task { await connect(gen) }
    }

    func stop(silently: Bool = false) {
        generation += 1
        watchdog?.cancel(); watchdog = nil
        pingTask?.cancel(); pingTask = nil
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        wsSession?.invalidateAndCancel(); wsSession = nil
        dc?.delegate = nil; dc?.close(); dc = nil
        pc?.delegate = nil; pc?.close(); pc = nil
        audioTrack = nil
        videoTrack = nil
        offerSent = false
        localSent = 0
        offerReceiptLogged = false
        remoteSet = false
        startLiveSent = false
        pendingLocal = []
        pendingRemote = []
        liveSince = nil
        if !silently, phase.isActive { phase = .ended("Stopped") }
        if silently { phase = .idle }
    }

    /// Called by the video view when the first frame (or a new size) arrives.
    func didRender(size: CGSize) {
        videoSize = size
        guard phase != .live, phase.isActive else { return }
        phase = .live
        liveSince = .now
        watchdog?.cancel()
        note("First frame \(Int(size.width))x\(Int(size.height))")
    }

    // MARK: - Steps

    private func connect(_ gen: Int) async {
        let ticket: JSONDict
        do {
            ticket = try await Vico.webrtcTicket(serial: serial)
        } catch {
            guard gen == generation else { return }
            return fail("Couldn't start live view: \(error.localizedDescription)")
        }
        guard gen == generation else { return }

        clientID = J.str(ticket, "id") ?? ""
        groupID = J.str(ticket, "groupId") ?? ""
        traceID = J.str(ticket, "traceId") ?? ""
        sessionID = "Android-\(clientID)-\(Int64(Date().timeIntervalSince1970 * 1000))"
        let accessToken = J.str(ticket, "accessToken") ?? ""
        let server = J.str(ticket, "signalServer") ?? ""
        let path = J.str(ticket, "websocketPath") ?? ""
        let ping = max(J.num(ticket, "signalPingInterval") ?? 10, 2)
        let ice = (ticket["iceServer"] as? [JSONDict]) ?? []
        note("Ticket ok: \(ice.count) ICE server(s), signal \(URL(string: server)?.host ?? server)")

        guard !server.isEmpty, !clientID.isEmpty else {
            return fail("Vicohome's ticket was missing the signaling details.")
        }

        do {
            try makePeer(iceServers: ice)
        } catch {
            return fail("WebRTC setup failed: \(error.localizedDescription)")
        }

        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        let full = path.isEmpty ? base : base + (path.hasPrefix("/") ? path : "/" + path)
        guard let url = URL(string: full) else { return fail("Bad signaling URL.") }

        phase = .signaling
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        wsSession = session
        ws = task
        task.resume()
        receiveLoop(gen)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ping))
                guard let self, self.generation == gen, let ws = self.ws else { return }
                ws.sendPing { _ in }
            }
        }

        send(["method": "AUTH", "clientType": "app", "status": "normal", "accessToken": accessToken, "id": clientID])
    }

    private func makePeer(iceServers: [JSONDict]) throws {
        let config = RTCConfiguration()
        config.iceServers = iceServers.compactMap { s in
            guard let url = J.str(s, "url", "urls") else { return nil }
            return RTCIceServer(urlStrings: [url], username: J.str(s, "username"), credential: J.str(s, "credential"))
        }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let made: RTCPeerConnection? = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        guard let pc = made else {
            throw VicoError(message: "Couldn't create a peer connection.")
        }
        self.pc = pc

        // Same shape as the official viewer: audio sendrecv (talk-back channel), video recvonly.
        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .sendRecv
        let audio: RTCRtpTransceiver? = pc.addTransceiver(of: .audio, init: audioInit)
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        let video: RTCRtpTransceiver? = pc.addTransceiver(of: .video, init: videoInit)

        restrictCodecs(audio: audio, video: video)

        audioTrack = audio?.receiver.track as? RTCAudioTrack
        audioTrack?.isEnabled = !muted
        videoTrack = video?.receiver.track as? RTCVideoTrack

        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        let channel: RTCDataChannel? = pc.dataChannel(forLabel: serial, configuration: dcConfig)
        dc = channel
        dc?.delegate = self
    }

    /// Offer only what the camera speaks: H.264 video, G.711 audio. Google's default offer carries
    /// VP8/VP9/AV1/H.264 variants plus RTX, RED and FEC, several times the size of the official
    /// app's, and the camera's KVS-based stack drops oversized signaling messages.
    private func restrictCodecs(audio: RTCRtpTransceiver?, video: RTCRtpTransceiver?) {
        let f = Self.factory
        let videoCaps = f.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            .filter { $0.name.uppercased() == "H264" }
        var seen = Set<String>()
        let h264 = videoCaps.filter { c in
            let key = (c.parameters["profile-level-id"] ?? "") + "/" + (c.parameters["packetization-mode"] ?? "")
            return seen.insert(key).inserted
        }
        let allAudio = f.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindAudio).codecs
        let audioCaps = allAudio.filter { $0.name.uppercased() == "PCMU" } + allAudio.filter { $0.name.uppercased() == "PCMA" }
        apply(Array(h264.prefix(4)), to: video, label: "video")
        apply(audioCaps, to: audio, label: "audio")
    }

    private func apply(_ codecs: [RTCRtpCodecCapability], to tx: RTCRtpTransceiver?, label: String) {
        guard let tx, !codecs.isEmpty else { return note("No \(label) codecs to prefer") }
        // Called by selector: the SDK also has a deprecated overload with the same Swift name.
        let sel = NSSelectorFromString("setCodecPreferences:error:")
        guard tx.responds(to: sel) else { return note("Codec preferences unsupported") }
        let ok = tx.perform(sel, with: codecs as NSArray, with: nil) != nil
        let names = codecs.map { c in
            c.name + (c.parameters["profile-level-id"].map { " " + $0 } ?? "")
        }
        note("\(label) codecs \(ok ? "" : "NOT ")set: \(names.joined(separator: ", "))")
    }

    private func createOffer() {
        guard let pc, !offerSent else { return }
        let gen = generation
        phase = .connecting
        note("Camera joined, sending offer")
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                guard let sdp else { return self.fail("Couldn't create an offer: \(error?.localizedDescription ?? "unknown")") }
                self.pc?.setLocalDescription(sdp) { error in
                    Task { @MainActor in
                        guard self.generation == gen else { return }
                        if let error { return self.fail("Couldn't set the offer: \(error.localizedDescription)") }
                        self.note("Offer \(sdp.sdp.utf8.count) bytes, \(sdp.sdp.components(separatedBy: "a=rtpmap:").count - 1) codecs")
                        self.transmit(type: "SDP_OFFER", payload: [("type", "offer"), ("sdp", sdp.sdp)], extra: [
                            "mode": "vicoo",
                            "viewerType": "a4x_sdk",
                            "resolution": "1280x720",
                        ])
                        self.offerSent = true
                        let queued = self.pendingLocal
                        self.pendingLocal = []
                        queued.forEach { self.sendCandidate($0) }
                    }
                }
            }
        }
    }

    private func handleAnswer(_ sdp: String) {
        guard let pc, !remoteSet else { return }
        let gen = generation
        let maps = sdp.components(separatedBy: "\n")
            .filter { $0.hasPrefix("a=rtpmap:") }
            .compactMap { $0.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
        let fmtp = sdp.components(separatedBy: "\n").first { $0.contains("profile-level-id") }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        note("Got answer: \(maps.joined(separator: ", ")) \(fmtp)")
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let error { return self.fail("The camera's answer was rejected: \(error.localizedDescription)") }
                self.remoteSet = true
                let queued = self.pendingRemote
                self.pendingRemote = []
                queued.forEach { self.addRemote($0) }
            }
        }
    }

    private func addRemote(_ c: RTCIceCandidate) {
        guard remoteSet else { pendingRemote.append(c); return }
        pc?.add(c) { _ in }
    }

    private func sendCandidate(_ c: RTCIceCandidate) {
        if c.sdp.contains(" 127.0.0.1 ") || c.sdp.contains(" ::1 ") { return }
        guard offerSent else { pendingLocal.append(c); return }
        transmit(type: "ICE_CANDIDATE", payload: [
            ("sdpMid", c.sdpMid ?? "0"),
            ("sdpMLineIndex", Int(c.sdpMLineIndex)),
            ("candidate", c.sdp),
        ], extra: [:])
    }

    private func sendStartLive() {
        guard let dc, !startLiveSent else { return }
        startLiveSent = true
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let cmd: JSONDict = [
            "action": "startLive",
            "requestID": ts,
            "connectionID": "",
            "timeStamp": ts,
            "size": "medium",
            "resolution": "1280x720",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cmd, options: [.withoutEscapingSlashes]) else { return }
        dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        note("Sent startLive")
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.generation == gen, self.phase != .live, self.phase.isActive, let dc = self.dc else { return }
            self.note("No video after 8s, sending startLive again")
            dc.sendData(RTCDataBuffer(data: data, isBinary: false))
        }
    }

    // MARK: - Signaling

    /// Field order as vicostream's Go structs marshal them. JSON objects are unordered in theory, but the
    /// payload is parsed by the camera's firmware, so match the known-working client byte for byte.
    private static let fieldOrder = ["method", "code", "message", "clientType", "clientId", "status", "accessToken", "id",
                                     "role", "name", "group", "traceId", "recipientClientId", "senderClientId", "sessionId",
                                     "messageType", "messagePayload", "mode", "viewerType", "resolution", "version",
                                     "timestamp", "reason"]

    static func orderedJSON(_ pairs: [(String, Any)]) -> String {
        let parts = pairs.compactMap { k, v -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return "\"\(k)\":\(s)"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func transmit(type: String, payload: [(String, Any)], extra: JSONDict) {
        let json = Self.orderedJSON(payload)
        var msg: JSONDict = [
            "method": "TRANSMIT",
            "messageType": type,
            "messagePayload": Data(json.utf8).base64EncodedString(),
            "recipientClientId": serial,
            "senderClientId": clientID,
            "sessionId": sessionID,
            "version": "0.0.1",
        ]
        extra.forEach { msg[$0.key] = $0.value }
        send(msg)
    }

    private func send(_ msg: JSONDict) {
        guard let ws else { return }
        let pairs = Self.fieldOrder.compactMap { k in msg[k].map { (k, $0) } }
            + msg.keys.filter { !Self.fieldOrder.contains($0) }.sorted().map { ($0, msg[$0]!) }
        let text = Self.orderedJSON(pairs)
        let label = (msg["method"] as? String ?? "?") + ((msg["messageType"] as? String).map { " " + $0 } ?? "")
        if label == "TRANSMIT ICE_CANDIDATE" { localSent += 1 } else { note("→ \(label) (\(text.utf8.count) B)") }
        ws.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.note("send failed: \(error.localizedDescription)") }
        }
    }

    /// Server text for the log, with secrets blanked.
    private static func redacted(_ raw: String, limit: Int = 600) -> String {
        var t = raw
        for key in ["credential", "accessToken", "sign", "password", "token", "username"] {
            t = t.replacingOccurrences(of: "(\"\(key)\"\\s*:\\s*\")[^\"]*\"", with: "$1…\"", options: .regularExpression)
        }
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }

    private func receiveLoop(_ gen: Int) {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch result {
                case .failure(let error):
                    if self.phase.isActive && self.phase != .live {
                        self.fail("Signaling connection dropped: \(error.localizedDescription)")
                    }
                case .success(let message):
                    var text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let text, let data = text.data(using: .utf8),
                       let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict {
                        self.handle(json, raw: text)
                    }
                    self.receiveLoop(gen)
                }
            }
        }
    }

    private func handle(_ msg: JSONDict, raw: String) {
        let method = J.str(msg, "method") ?? ""
        let code = (msg["code"] as? NSNumber)?.intValue
        let text = J.str(msg, "message", "msg") ?? ""
        switch method {
        case "AUTH_RESPONSE":
            note("← AUTH_RESPONSE \(code.map(String.init) ?? "?")")
            guard code == 0 else { return fail("Vicohome refused the live session (\(code ?? -1)\(text.isEmpty ? "" : ": \(text)")).") }
            phase = .waiting
            send([
                "method": "JOIN_LIVE",
                "role": "viewer",
                "name": clientID,
                "group": groupID,
                "traceId": traceID,
                "recipientClientId": serial,
            ])
        case "JOIN_LIVE_RESPONSE":
            note("← JOIN_LIVE_RESPONSE \(code.map(String.init) ?? "?") \(text)")
            if let code, code != 0 { fail("The camera couldn't be joined (\(code)\(text.isEmpty ? "" : ": \(text)")).") }
        case "PEER_IN":
            note("← PEER_IN")
            createOffer()
        case "PEER_OUT":
            note("← PEER_OUT")
            stopMedia()
            phase = .ended("The camera ended the stream")
        case "TRANSMIT":
            let type = J.str(msg, "messageType") ?? ""
            guard let b64 = J.str(msg, "messagePayload"),
                  let raw = Data(base64Encoded: b64),
                  let payload = (try? JSONSerialization.jsonObject(with: raw)) as? JSONDict else { return }
            switch type {
            case "SDP_ANSWER":
                if let sdp = J.str(payload, "sdp") { handleAnswer(sdp) }
            case "ICE_CANDIDATE":
                guard let cand = J.str(payload, "candidate"), !cand.isEmpty else { return }
                let idx = Int32(J.num(payload, "sdpMLineIndex") ?? 0)
                addRemote(RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: J.str(payload, "sdpMid")))
            default:
                note("← TRANSMIT \(type)")
            }
        case "PONG":
            break
        case "TRANSMIT_RESPONSE", "RESPONSE":
            // The server's receipt for each thing we sent. Quiet when it's fine, loud when it isn't.
            if let code, code != 0 { note("← \(method) \(code): \(Self.redacted(raw, limit: 300))") }
            else if !offerReceiptLogged, offerSent { offerReceiptLogged = true; note("← \(method) ok") }
        case "WEBRTC_CONFIG":
            note("← WEBRTC_CONFIG \(Self.redacted(raw))")
        default:
            note("← \(Self.redacted(raw, limit: 300))")
        }
    }

    // MARK: - Helpers

    private func stopMedia() {
        watchdog?.cancel()
        pingTask?.cancel()
        dc?.close()
        pc?.close()
        ws?.cancel(with: .normalClosure, reason: nil)
        liveSince = nil
    }

    private func fail(_ message: String) {
        note("✕ \(message)")
        let keepLog = log
        stop(silently: true)
        log = keepLog
        phase = .failed(message)
    }

    private func note(_ s: String) {
        let t = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        log.append("\(t)  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - Peer connection delegate (called on WebRTC's signaling thread)

extension LiveSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.note("Sent \(self.localSent) local ICE candidate(s)")
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let name: String
        switch newState {
        case .new: name = "new"
        case .checking: name = "checking"
        case .connected: name = "connected"
        case .completed: name = "completed"
        case .failed: name = "failed"
        case .disconnected: name = "disconnected"
        case .closed: name = "closed"
        default: name = "other"
        }
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.note("ICE \(name)")
            switch newState {
            case .connected, .completed:
                peerConnection.statistics { report in
                    let relay = report.statistics.values.contains { s in
                        s.type == "local-candidate" && (s.values["candidateType"] as? String) == "relay"
                            && report.statistics.values.contains { p in
                                p.type == "candidate-pair" && (p.values["state"] as? String) == "succeeded"
                                    && (p.values["localCandidateId"] as? String) == s.id
                            }
                    }
                    Task { @MainActor in self.relayed = relay }
                }
            case .failed:
                self.fail("Couldn't reach the camera (ICE failed). Check that it's online.")
            case .disconnected:
                if self.phase == .live { self.note("Connection unstable") }
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard peerConnection === self.pc else { return }
            self.sendCandidate(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Data channel delegate

extension LiveSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let open = dataChannel.readyState == .open
        Task { @MainActor in
            guard dataChannel === self.dc else { return }
            if open {
                self.note("Data channel open")
                self.sendStartLive()
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let text = String(data: buffer.data, encoding: .utf8) ?? "\(buffer.data.count) bytes"
        Task { @MainActor in
            guard dataChannel === self.dc else { return }
            self.note("← camera: \(text.prefix(160))")
        }
    }
}

// MARK: - Decoder factory

/// The camera answers with H.264 High profile (64001f), packetization-mode 0 in vicostream's capture.
/// Google's default iOS factory only advertises Constrained High/Baseline, so list High first too.
/// VideoToolbox decodes all of them.
final class CameraDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        if info.name == kRTCVideoCodecH264Name { return RTCVideoDecoderH264() }
        return base.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var out: [RTCVideoCodecInfo] = []
        for mode in ["1", "0"] {
            out.append(RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
                "profile-level-id": "64001f",
                "level-asymmetry-allowed": "1",
                "packetization-mode": mode,
            ]))
        }
        out.append(contentsOf: base.supportedCodecs())
        return out
    }
}
