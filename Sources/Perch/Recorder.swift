import AppKit
import AVFoundation
import CoreGraphics

/// Records a voice note, or the screen through CleanShot X (or macOS's capture toolbar without it), for one chat at a time.
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
    /// Where the running screen capture is stopped.
    private(set) var stopHint = ""
    /// A voice note's loudness so far, 0...1, about 16 a second, the latest 120.
    private(set) var levels: [CGFloat] = []
    /// Called with the chat id when a screen capture ends, stopped or cancelled, so the panel can come back.
    @ObservationIgnored var onScreenEnded: (Int64) -> Void = { _ in }
    @ObservationIgnored private var audio: AVAudioRecorder?
    @ObservationIgnored private var screen: Process?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var meter: Task<Void, Never>?

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
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw Failure(errorDescription: "Couldn't start recording.") }
            audio = recorder
            file = url
            meter = Task {
                while !Task.isCancelled, let audio {
                    audio.updateMeters()
                    let db = CGFloat(audio.averagePower(forChannel: 0))  // -160 is silence, 0 is full scale
                    levels = Array((levels + [min(1, max(0, (db + 50) / 40))]).suffix(120))
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
        case .screen where NSWorkspace.shared.urlForApplication(withBundleIdentifier: "pl.maketheweb.cleanshotx") != nil:
            // CleanShot's recorder picks the area, window or display, and has pause, restart and stop.
            NSWorkspace.shared.open(URL(string: "cleanshot://record-screen")!)
            stopHint = "Recording in CleanShot"
            let since = Date.now
            watch = Task { await waitForCleanShot(since: since) }
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
            stopHint = "Stop with ⌃⌘⎋"  // the menu bar's Stop Sharing cancels instead, without a file
            Task { await waitForScreen(process, url: url) }
        }
        self.kind = kind
        chatID = chat.id
        started = .now
    }

    /// The file to send: the voice note, stopped now and brought up to a normal level, or the finished screen capture.
    func stop() async throws -> URL? {
        defer { reset() }
        if let ready { return ready }
        audio?.stop()
        guard audio != nil, let file else { return nil }
        return await Self.louder(file)
    }

    /// A Mac's microphone level is often set low (input volume 27% here left notes peaking 20 to 33 dB under full
    /// scale, too quiet to hear). Scale the note so its loudest moment sits at -1 dBFS, by at most 30 dB, into a
    /// new file of the same name. Returns the original if it's already loud or can't be read.
    nonisolated static func louder(_ url: URL) async -> URL {
        await Task.detached {
            guard let input = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
                  (try? input.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return url }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            var peak: Float = 0
            for c in 0..<channelCount { for i in 0..<count { peak = max(peak, abs(channels[c][i])) } }
            let gain = min(0.89 / max(peak, .leastNonzeroMagnitude), 31.6)
            guard gain > 1.12 else { return url }  // within 1 dB already
            for c in 0..<channelCount { for i in 0..<count { channels[c][i] *= gain } }
            let out = url.deletingLastPathComponent().appending(path: "louder").appending(path: url.lastPathComponent)
            guard (try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                  let output = try? AVAudioFile(forWriting: out, settings: input.fileFormat.settings,
                                                commonFormat: .pcmFormatFloat32, interleaved: false),
                  (try? output.write(from: buffer)) != nil else { return url }
            output.close()
            return out
        }.value
    }

    func discard() {
        audio?.stop()
        audio?.deleteRecording()
        screen?.terminate()  // SIGTERM ends the toolbar session without writing a file
        watch?.cancel()
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

    /// CleanShot can't hand a recording back, but it keeps every capture in its media folder, one folder each.
    /// Take the first new video there once it stops growing, which is when CleanShot has finished writing it.
    private func waitForCleanShot(since: Date) async {
        let media = URL.homeDirectory.appending(path: "Library/Application Support/CleanShot/media")
        var lastSize = -1
        while !Task.isCancelled, let chatID {
            if let video = Self.capture(in: media, since: since) {
                let size = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0, size == lastSize {
                    ready = video.pathExtension.lowercased() == "mov" ? await Self.shrink(video) : video
                    return onScreenEnded(chatID)
                }
                lastSize = size
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    static func capture(in media: URL, since: Date) -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return folders
            .filter { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) > since }
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .first { ["mp4", "mov", "gif"].contains($0.pathExtension.lowercased()) }
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
        meter?.cancel()
        meter = nil
        levels = []
        audio = nil
        screen = nil
        file = nil
        ready = nil
        stopHint = ""
        watch = nil
        kind = nil
        chatID = nil
        finishing = false
    }
}
