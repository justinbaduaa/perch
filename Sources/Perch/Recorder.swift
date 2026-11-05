import AVFoundation
import CoreGraphics

/// Records a voice note, or the screen through macOS's capture toolbar, for one chat at a time.
@Observable final class Recorder {
    enum Kind { case voice, screen }
    struct Failure: LocalizedError { let errorDescription: String? }

    private(set) var kind: Kind?
    private(set) var chatID: Int64?
    private(set) var started = Date.now
    /// The screen capture ended and its file is being shrunk.
    private(set) var finishing = false
    /// A finished screen capture, waiting for Send.
    private(set) var ready: URL?
    /// Called with the chat id when a screen capture ends, stopped or cancelled, so the panel can come back.
    @ObservationIgnored var onScreenEnded: (Int64) -> Void = { _ in }
    @ObservationIgnored private var audio: AVAudioRecorder?
    @ObservationIgnored private var screen: Process?
    @ObservationIgnored private var file: URL?

    func start(_ kind: Kind, for chat: Chat) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch kind {
        case .voice:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw Failure(errorDescription: "Allow Perch to use the microphone in System Settings.")
            }
            let url = dir.appending(path: "Voice note.m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            guard recorder.record() else { throw Failure(errorDescription: "Couldn't start recording.") }
            audio = recorder
            file = url
        case .screen:
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw Failure(errorDescription: "Allow Perch to record the screen in System Settings, then reopen Perch.")
            }
            // The system toolbar asks what to record (a display, a window or an area), offers a countdown and the
            // mic under Options, and puts a stop button in the menu bar. Esc cancels.
            let url = dir.appending(path: "Screen recording.mov")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            process.arguments = ["-iU", "-Jvideo", "-x", url.path]
            try process.run()
            screen = process
            file = url
            Task { await waitForScreen(process, url: url) }
        }
        self.kind = kind
        chatID = chat.id
        started = .now
    }

    /// The file to send: the voice note, stopped now, or the finished screen capture.
    func stop() async throws -> URL? {
        defer { reset() }
        if let ready { return ready }
        audio?.stop()
        return audio == nil ? nil : file
    }

    func discard() {
        audio?.stop()
        audio?.deleteRecording()
        screen?.terminate()  // SIGTERM ends the toolbar session without writing a file
        reset()
    }

    private func waitForScreen(_ process: Process, url: URL) async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        guard screen === process, let chatID else { return }  // discarded meanwhile
        screen = nil
        if FileManager.default.fileExists(atPath: url.path) {
            finishing = true
            let shrunk = await Self.shrink(url)
            guard self.chatID == chatID else { return }  // discarded while shrinking
            ready = shrunk
            finishing = false
        } else {
            reset()  // cancelled in the toolbar
        }
        onScreenEnded(chatID)
    }

    /// Screen recordings run about 1.7 MB a second, past iMessage's limit within a minute, so re-encode as HEVC.
    /// The toolbar can also take a screenshot instead; that comes back as an image and is sent as one.
    private static func shrink(_ url: URL) async -> URL {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            let image = url.deletingLastPathComponent().appending(path: "Screenshot.png")
            return (try? FileManager.default.moveItem(at: url, to: image)) != nil ? image : url
        }
        let small = url.deletingLastPathComponent().appending(path: "Screen recording.mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVC1920x1080),
              (try? await export.export(to: small, as: .mp4)) != nil else { return url }
        return small
    }

    private func reset() {
        audio = nil
        screen = nil
        file = nil
        ready = nil
        kind = nil
        chatID = nil
        finishing = false
    }
}
