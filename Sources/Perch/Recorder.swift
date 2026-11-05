import AVFoundation
import CoreGraphics

/// Records a voice note, or the screen with the mic, for one chat at a time.
@Observable final class Recorder {
    enum Kind { case voice, screen }
    struct Failure: LocalizedError { let errorDescription: String? }

    private(set) var kind: Kind?
    private(set) var chatID: Int64?
    private(set) var started = Date.now
    /// Stopped, and the file is being finished (screen recordings are re-encoded).
    private(set) var finishing = false
    @ObservationIgnored private var audio: AVAudioRecorder?
    @ObservationIgnored private var screen: Process?
    @ObservationIgnored private var file: URL?

    func start(_ kind: Kind, for chat: Chat) async throws {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switch kind {
        case .voice:
            guard mic else { throw Failure(errorDescription: "Allow Perch to use the microphone in System Settings.") }
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
            let url = dir.appending(path: "Screen recording.mov")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/sbin/screencapture")
            // shortcut: records the main display only; pass -D<n> to follow the panel's display.
            process.arguments = ["-v", "-x"] + (mic ? ["-g"] : []) + [url.path]
            try process.run()
            screen = process
            file = url
        }
        self.kind = kind
        chatID = chat.id
        started = .now
    }

    /// Stops and returns the file to send. A screen recording runs about 1.7 MB a second, past iMessage's
    /// limit within a minute, so it is re-encoded as HEVC first.
    func stop() async throws -> URL? {
        guard let file else { return nil }
        finishing = true
        defer { reset() }
        audio?.stop()
        guard let screen else { return file }
        screen.interrupt()  // SIGINT: screencapture writes out the movie and exits
        while screen.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        let small = file.deletingLastPathComponent().appending(path: "Screen recording.mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetHEVC1920x1080),
              (try? await export.export(to: small, as: .mp4)) != nil else { return file }
        return small
    }

    func discard() {
        audio?.stop()
        audio?.deleteRecording()
        screen?.interrupt()
        reset()
    }

    private func reset() {
        audio = nil
        screen = nil
        file = nil
        kind = nil
        chatID = nil
        finishing = false
    }
}
