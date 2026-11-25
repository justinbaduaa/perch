import AppKit
import AVFoundation
import Contacts
import SwiftUI
import UserNotifications

/// What Perch asks macOS for. Each feature works the first time once these are granted, instead of stopping to ask.
enum Access: CaseIterable, Identifiable {
    case fullDisk, contacts, messages, accessibility, notifications, microphone, screen

    var id: Self { self }

    var title: String {
        switch self {
        case .fullDisk: "Full Disk Access"
        case .contacts: "Contacts"
        case .messages: "Messages"
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .microphone: "Microphone"
        case .screen: "Screen Recording"
        }
    }

    var reason: String {
        switch self {
        case .fullDisk: "Read your conversations"
        case .contacts: "Names and photos"
        case .messages: "Send for you"
        case .accessibility: "Reactions, replies and chat actions"
        case .notifications: "Remind me"
        case .microphone: "Voice notes"
        case .screen: "Screenshots and recordings"
        }
    }

    var symbol: String {
        switch self {
        case .fullDisk: "lock"
        case .contacts: "person.crop.circle"
        case .messages: "message"
        case .accessibility: "accessibility"
        case .notifications: "bell"
        case .microphone: "mic"
        case .screen: "record.circle"
        }
    }

    /// Asked for in Settings rather than in a prompt over the window.
    var inSettings: Bool { self == .fullDisk || self == .accessibility || self == .screen }

    /// Its pane in System Settings, where a refused grant can be changed.
    var settings: URL {
        let privacy = "x-apple.systempreferences:com.apple.preference.security?"
        let link = switch self {
        case .fullDisk: privacy + "Privacy_AllFiles"
        case .contacts: privacy + "Privacy_Contacts"
        case .messages: privacy + "Privacy_Automation"
        case .accessibility: privacy + "Privacy_Accessibility"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
        case .microphone: privacy + "Privacy_Microphone"
        case .screen: privacy + "Privacy_ScreenCapture"
        }
        return URL(string: link)!
    }
}

/// Which grants Perch has, checked live while the setup window is open.
@Observable final class Permissions {
    private(set) var granted: Set<Access> = []
    /// Contacts were just allowed, so names and photos can load.
    @ObservationIgnored var onContacts: () -> Void = {}
    /// Prompted for since launch.
    @ObservationIgnored private var asked: Set<Access> = []

    var needed: [Access] { Access.allCases.filter { $0 != .screen || !Recorder.usesCleanShot } }

    var missing: [Access] { needed.filter { !granted.contains($0) } }

    func refresh() async {
        var now: Set<Access> = []
        if MessagesDB.readable { now.insert(.fullDisk) }
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { now.insert(.contacts) }
        if await Self.messages(ask: false) == noErr { now.insert(.messages) }
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized { now.insert(.notifications) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        if CGPreflightScreenCaptureAccess() { now.insert(.screen) }
        if now != granted { withAnimation(.smooth(duration: 0.25)) { granted = now } }
    }

    /// The first press shows macOS's prompt. Settings opens instead for Full Disk Access, which has none, for a
    /// grant refused before, which macOS won't prompt for again, and for a second press on a grant whose prompt
    /// only points to Settings.
    func request(_ access: Access) async {
        let refused = await refused(access)
        if access == .fullDisk || asked.contains(access) && access.inSettings || refused {
            NSWorkspace.shared.open(access.settings)
        } else {
            asked.insert(access)
            switch access {
            case .fullDisk: break
            case .contacts: if (try? await CNContactStore().requestAccess(for: .contacts)) == true { onContacts() }
            case .messages: _ = await Self.messages(ask: true)
            case .accessibility:
                let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared state
                _ = AXIsProcessTrustedWithOptions(prompt)  // also lists Perch in the pane, switched off
            case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .screen: _ = CGRequestScreenCaptureAccess()
            }
        }
        await refresh()
    }

    private func refused(_ access: Access) async -> Bool {
        switch access {
        case .contacts: CNContactStore.authorizationStatus(for: .contacts) == .denied
        case .messages: await Self.messages(ask: false) == OSStatus(errAEEventNotPermitted)
        case .notifications: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        default: false
        }
    }

    /// Every prompt macOS can show over the window, one after another, then Settings for the first grant that
    /// needs it.
    func requestAll() async {
        for access in missing where !access.inSettings { await request(access) }
        if let next = missing.first(where: \.inSettings) { await request(next) }
    }

    /// Whether Perch may control Messages, which is how plain sends go out. Asking needs Messages running.
    private static func messages(ask: Bool) async -> OSStatus {
        let id = "com.apple.MobileSMS"
        if ask, NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
        return await Task.detached {  // blocks while the prompt is up
            var target = AEAddressDesc()
            _ = id.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        }.value
    }
}

/// Every grant on one screen, each with its own button, checked off as macOS reports it.
struct SetupView: View {
    let permissions: Permissions
    let close: () -> Void

    var body: some View {
        let needed = permissions.needed, missing = permissions.missing
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up Perch").font(.title2.weight(.bold))
                    Text("Allow these once and nothing asks again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 22)
            VStack(spacing: 2) {
                ForEach(needed) { access in
                    row(access, next: access == missing.first)
                }
            }
            HStack(spacing: 6) {
                Text("\(needed.count - missing.count) of \(needed.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if missing.isEmpty {
                    Button("Done", action: close).buttonStyle(.borderedProminent)
                } else {
                    Button("Later", action: close).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 10)
                    Button("Allow All") { Task { await permissions.requestAll() } }.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding([.horizontal, .top], 12)
            .padding(.top, 8)
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 22)  // the top already clears the title bar
        .frame(width: 420)
        .task {
            while !Task.isCancelled {  // grants change in Settings, outside Perch
                await permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ access: Access, next: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: access.symbol).font(.system(size: 16)).foregroundStyle(.white.opacity(0.8)).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(access.title).font(.callout.weight(.semibold))
                    Text(access.reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if permissions.granted.contains(access) {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(access == .fullDisk ? "Open Settings" : "Allow") { Task { await permissions.request(access) } }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
            if access == .fullDisk && !permissions.granted.contains(.fullDisk) {
                // Full Disk Access has no prompt: Perch goes in the pane's list by hand, and a drag from here does it.
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                    Text("Drag Perch into the list").font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(.rect)
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(next ? .white.opacity(0.06) : .clear, in: .rect(cornerRadius: 14, style: .continuous))
    }
}
