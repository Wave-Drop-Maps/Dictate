// Settings window and saved preferences.

import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

struct HistoryItem: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

enum ModelState: Equatable {
    case loading, downloading, ready, missing
    case failed(String)
}

/// User preferences (saved in UserDefaults) plus live status for the Settings window.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "soundVolume") } }
    @Published var showPill: Bool { didSet { defaults.set(showPill, forKey: "showPill") } }
    @Published var diagnostics: Bool { didSet { defaults.set(diagnostics, forKey: "diagnostics") } }
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            applyDockPolicy()
        }
    }
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false

    @Published var modelState: ModelState = .loading
    @Published var micAllowed = false
    @Published var accessibilityAllowed = false
    /// macOS's "Press 🌐 key to" setting must be "Do Nothing", or Fn also opens the emoji picker etc.
    @Published var fnKeyFree = true
    /// Recent transcripts — memory only, gone when SpeakFn quits.
    @Published var history: [HistoryItem] = []

    private init() {
        defaults.register(defaults: ["autoPaste": true, "sounds": true, "showPill": true, "diagnostics": false, "showInDock": true, "soundVolume": 0.5])
        autoPaste = defaults.bool(forKey: "autoPaste")
        sounds = defaults.bool(forKey: "sounds")
        soundVolume = defaults.double(forKey: "soundVolume")
        showPill = defaults.bool(forKey: "showPill")
        diagnostics = defaults.bool(forKey: "diagnostics")
        showInDock = defaults.bool(forKey: "showInDock")
        refreshStatus()
    }

    /// Dock icon on (like a normal app) or menu-bar only. The Settings window always gets a Dock icon while open.
    func applyDockPolicy(windowOpen: Bool = false) {
        NSApp.setActivationPolicy(showInDock || windowOpen ? .regular : .accessory)
    }

    func refreshStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        let login = SMAppService.mainApp.status
        let fnUsage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        let fnFree = fnUsage == 0
        if fnFree != fnKeyFree { fnKeyFree = fnFree }
        // Only publish real changes so the window doesn't redraw every refresh.
        if mic != micAllowed { micAllowed = mic }
        if ax != accessibilityAllowed { accessibilityAllowed = ax }
        if (login == .enabled) != launchAtLogin { launchAtLogin = login == .enabled }
        if (login == .requiresApproval) != loginNeedsApproval { loginNeedsApproval = login == .requiresApproval }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            debugLog("launch at login error: \(error)")
        }
        refreshStatus()
    }

    func addHistory(_ text: String) {
        history.insert(HistoryItem(date: Date(), text: text), at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }
}

// MARK: - Settings UI

private struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    var busy = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
                Text(detail).foregroundStyle(.secondary)
            } else if ok {
                Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                if let actionTitle, let action { Button(actionTitle, action: action) }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var onDownloadModel: () -> Void
    @State private var tryText = ""
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                statusSection
                Section("Try it") {
                    TextField("Click here, hold Fn and say something…", text: $tryText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                }
                Section("How to use") {
                    Label("Hold **Fn**, talk, let go — your words are typed where the cursor is", systemImage: "hand.tap")
                    Label("Double-tap **Fn** for hands-free. Press **Fn** again to finish", systemImage: "infinity")
                    Label("**Esc** cancels hands-free without typing anything", systemImage: "escape")
                    Label("The last result is always on your clipboard — **⌘V** pastes it again", systemImage: "doc.on.clipboard")
                }
                optionsSection
                historySection
            }
            .formStyle(.grouped)
            footer
        }
        .frame(width: 540, height: 720)
        .onReceive(timer) { _ in prefs.refreshStatus() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("SpeakFn").font(.title2.weight(.bold))
                Text("Private voice-to-text. Everything stays on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isAllReady {
                Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 4)
    }

    private var isAllReady: Bool {
        prefs.modelState == .ready && prefs.micAllowed && prefs.accessibilityAllowed
    }

    private var statusSection: some View {
        Section("Status") {
            switch prefs.modelState {
            case .ready:
                StatusRow(title: "Speech model", detail: "Ready · runs on this Mac", ok: true)
            case .loading:
                StatusRow(title: "Speech model", detail: "Loading…", ok: false, busy: true)
            case .downloading:
                StatusRow(title: "Speech model", detail: "Downloading (one time, ~470 MB)…", ok: false, busy: true)
            case .missing:
                StatusRow(
                    title: "Speech model", detail: "Not installed", ok: false, actionTitle: "Download (470 MB)",
                    action: onDownloadModel)
            case .failed(let message):
                StatusRow(
                    title: "Speech model", detail: "Problem", ok: false, actionTitle: "Re-download",
                    action: onDownloadModel)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            StatusRow(
                title: "Microphone", detail: prefs.micAllowed ? "Allowed" : "Not allowed", ok: prefs.micAllowed,
                actionTitle: "Fix…", action: { openPrivacyPane("Privacy_Microphone") })
            StatusRow(
                title: "Accessibility — Fn key & typing", detail: prefs.accessibilityAllowed ? "Allowed" : "Not allowed",
                ok: prefs.accessibilityAllowed, actionTitle: "Fix…",
                action: { openPrivacyPane("Privacy_Accessibility") })
            StatusRow(
                title: "Fn key", detail: prefs.fnKeyFree ? "Free for SpeakFn" : "Also used by macOS",
                ok: prefs.fnKeyFree, actionTitle: "Fix…",
                action: {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                })
            if !prefs.fnKeyFree {
                Text("In Keyboard settings, set “Press 🌐 key to” → “Do Nothing”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle(
                "Open SpeakFn when I log in",
                isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) }))
            if prefs.loginNeedsApproval {
                HStack {
                    Text("macOS needs you to approve this in Login Items.").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Toggle("Type the text for me (off = copy to clipboard only)", isOn: $prefs.autoPaste)
            Toggle("Show the recording pill", isOn: $prefs.showPill)
            Toggle("Show SpeakFn in the Dock (off = menu bar only)", isOn: $prefs.showInDock)
            Toggle("Play sounds", isOn: $prefs.sounds)
            if prefs.sounds {
                HStack(spacing: 10) {
                    Text("Sound volume")
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $prefs.soundVolume, in: 0.05...1) { editing in
                        if !editing { play(.start) }  // preview the new level when you let go
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            Toggle("Diagnostic log (key presses only, never your words)", isOn: $prefs.diagnostics)
        }
    }

    private var historySection: some View {
        Section("Recent — this session only, never saved") {
            if prefs.history.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            } else {
                ForEach(prefs.history) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).lineLimit(3).textSelection(.enabled)
                            Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CopyButton(text: item.text)
                    }
                }
                Button("Clear", role: .destructive) { prefs.history.removeAll() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Version \(appVersion) · No internet · No account · Nothing saved")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit SpeakFn") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }
}

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

/// While the Settings window is open SpeakFn shows in the Dock and ⌘-Tab; otherwise it lives in the menu bar.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onDownloadModel: () -> Void = {}

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 720),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "SpeakFn"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(
                rootView: SettingsView(onDownloadModel: { [weak self] in self?.onDownloadModel() }))
            w.delegate = self
            w.center()
            window = w
        }
        Prefs.shared.refreshStatus()
        Prefs.shared.applyDockPolicy(windowOpen: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window keeps SpeakFn running (Fn still works). Only Quit stops it.
    func windowWillClose(_ notification: Notification) {
        Prefs.shared.applyDockPolicy(windowOpen: false)
    }
}
