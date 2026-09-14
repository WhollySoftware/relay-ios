import AVFoundation

private let maxRecordingSec = 120

/// State + controls for one in-progress voice-message recording — tap to start, tap to stop, an
/// elapsed-seconds counter capped at `maxRecordingSec`, and a `cancel()` that discards the clip
/// instead of finalizing it. Mirrors Android's `VoiceRecorderState` (`VoiceRecorder.kt`) and Web's
/// `MediaRecorder`-based recording in `MessageComposer.tsx` — same 120s cap, same "just a data:
/// URL, no upload step" attachment convention as images/files.
@MainActor
@Observable
public final class VoiceRecorderState {
    public private(set) var isRecording = false
    public private(set) var elapsedSeconds = 0

    private var recorder: AVAudioRecorder?
    private var outputURL: URL?
    private var tickTask: Task<Void, Never>?

    public init() {}

    /// Requests mic permission if needed, then starts recording. No-ops if already recording or
    /// permission is denied.
    public func start() async {
        guard !isRecording, await Self.isAuthorized() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else { return }
        self.recorder = recorder
        outputURL = url
        isRecording = true
        elapsedSeconds = 0
        tickTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRecording else { return }
                self.elapsedSeconds += 1
                if self.elapsedSeconds >= maxRecordingSec { self.finish(); return }
            }
        }
    }

    /// Stops recording and returns the clip as a data URL + duration, or `nil` if nothing usable
    /// was captured (e.g. stopped within the first instant).
    @discardableResult
    public func finish() -> (dataUrl: String, durationSec: Int)? {
        guard isRecording else { return nil }
        let seconds = elapsedSeconds
        stopInternal()
        guard let url = outputURL else { return nil }
        outputURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return ("data:audio/mp4;base64,\(data.base64EncodedString())", seconds)
    }

    /// Stops recording and discards the clip.
    public func cancel() {
        guard isRecording else { return }
        stopInternal()
        if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        outputURL = nil
    }

    private func stopInternal() {
        isRecording = false
        tickTask?.cancel()
        tickTask = nil
        recorder?.stop()
        recorder = nil
    }

    /// `AVCaptureDevice`'s permission API (not `AVAudioSession`, which doesn't exist on macOS) —
    /// same cross-platform pattern `RelayCall/CallCenter.swift`'s `isAuthorized` already uses for
    /// mic/camera before a call.
    private static func isAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { granted in c.resume(returning: granted) }
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }
}

/// Shared playback for voice-message bubbles — one `AVAudioPlayer` at a time (not one per
/// bubble), so tapping play on one bubble stops whatever else was playing. `audioUrl` is always a
/// data: URL (the SDK's attachment convention), decoded to a temp file since `AVAudioPlayer` has
/// no simple in-memory playback path from raw bytes. Mirrors Android's `ChatAudioPlayer` object.
@MainActor
@Observable
public final class ChatAudioPlayer {
    public static let shared = ChatAudioPlayer()

    public private(set) var playingMessageId: String?
    public private(set) var elapsedSeconds = 0

    private var player: AVAudioPlayer?
    private var delegate: PlaybackFinishedDelegate?
    private var tempURL: URL?
    private var tickTask: Task<Void, Never>?

    private init() {}

    public func isPlaying(_ messageId: String) -> Bool { playingMessageId == messageId }

    public func toggle(messageId: String, audioUrl: String) {
        if playingMessageId == messageId { stop(); return }
        stop()
        guard let range = audioUrl.range(of: "base64,"),
              let data = Data(base64Encoded: String(audioUrl[range.upperBound...])) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-play-\(UUID().uuidString).m4a")
        guard (try? data.write(to: url)) != nil, let player = try? AVAudioPlayer(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let delegate = PlaybackFinishedDelegate { [weak self] in self?.stop() }
        player.delegate = delegate
        guard player.play() else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        self.player = player
        self.delegate = delegate
        tempURL = url
        playingMessageId = messageId
        elapsedSeconds = 0
        tickTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.playingMessageId == messageId, let player = self.player else { return }
                self.elapsedSeconds = Int(player.currentTime)
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        player?.stop()
        player = nil
        delegate = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
        playingMessageId = nil
        elapsedSeconds = 0
    }
}

/// `AVAudioPlayerDelegate` requires an `NSObject` conformer; wraps a completion closure so
/// `ChatAudioPlayer` itself doesn't need to inherit from `NSObject`.
private final class PlaybackFinishedDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: @MainActor @Sendable () -> Void
    init(onFinish: @escaping @MainActor @Sendable () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let onFinish = onFinish // avoid capturing non-Sendable `self` in the Task below
        Task { @MainActor in onFinish() }
    }
}
