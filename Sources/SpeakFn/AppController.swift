// App lifecycle, the Fn key state machine, audio ducking, and delivering text.
//
//  • Hold Fn            → records while held, transcribes on release, types it.
//  • Double-tap Fn      → hands-free until Fn is tapped again (Esc cancels).
//  • Fn + another key   → ignored (normal Fn and window-tiling shortcuts keep working, even in hands-free).
//  • Every transcript is also left on the clipboard.

import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

final class AppController: NSObject, NSApplicationDelegate {
    enum Mode: Equatable {
        case idle
        case holding(TimeInterval)
        case tapPending(UUID)
        case handsFree(finishingOnUp: Bool)
        case transcribing
    }

    let meter = LevelMeter()
    lazy var overlay = Overlay(meter: meter)
    var indicator: MenuBarIndicator?
    let toaster = Toaster()
    let settings = SettingsWindowController()
    let transcriber = Transcriber()
    let audioQueue = DispatchQueue(label: "dictate.audio", qos: .userInteractive)
    lazy var recorder = Recorder(queue: audioQueue)

    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var mode: Mode = .idle
    var fnIsDown = false
    var fnUsedAsModifier = false
    var ignoreNextFnUp = false
    var eventTap: CFMachPort?
    var mouseModifierMonitor: Any?
    var lastTranscript = ""
    var launchedAtLogin = false
    var safetyStop: DispatchWorkItem?
    var lastMeterPush: CFAbsoluteTime = 0

    let tapMaxDuration: TimeInterval = 0.38   // hardware press duration under this counts as a tap
    let doubleTapWindow: TimeInterval = 0.50  // second tap must land within this window
    let maxRecording: TimeInterval = 10 * 60  // hands-free safety limit
    let minSpeechSamples = 4_000              // under 0.25 s of audio = accidental press, ignore quietly

    private static let nonFnModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    var prefs: Prefs { Prefs.shared }

    var isRecording: Bool {
        switch mode {
        case .holding, .tapPending, .handsFree: return true
        case .idle, .transcribing: return false
        }
    }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.shared.applyDockPolicy()
        buildMainMenu()
        if let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == kAEOpenApplication,
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        {
            launchedAtLogin = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("launch v\(appVersion), trusted=\(AXIsProcessTrusted()), atLogin=\(launchedAtLogin)")
        buildMenu()
        TextInserter.shared.startMonitoring()

        // Treat Fn + mouse click/drag (e.g. window drag gestures) as a modifier combo, not dictation.
        mouseModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self, self.fnIsDown else { return }
            self.fnUsedAsModifier = true
        }

        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // Cap main-thread dispatches to ~45 Hz so audio callbacks stay lightweight.
            guard now - self.lastMeterPush >= 0.020 else { return }
            self.lastMeterPush = now
            DispatchQueue.main.async { self.meter.push(level) }
        }
        settings.onDownloadModel = { [weak self] in self?.downloadModel() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { Prefs.shared.refreshStatus() }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        installEventTap()
        loadModel()
        let launchedQuietly = launchedAtLogin || CommandLine.arguments.contains("--background")
        if !launchedQuietly || !AXIsProcessTrusted() { settings.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioDucker.shared.restoreImmediately()
    }

    /// Closing the window never quits — SpeakFn keeps listening for Fn until you choose Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening SpeakFn again (Finder, Spotlight, Dock) shows the Settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func loadModel() {
        guard Transcriber.modelInstalled else {
            prefs.modelState = .missing
            refreshStatus()
            return
        }
        prefs.modelState = .loading
        refreshStatus()
        Task {
            do {
                try await transcriber.load()
                _ = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))  // warm up ANE
                debugLog("model ready")
                await MainActor.run {
                    self.prefs.modelState = .ready
                    self.refreshStatus()
                }
            } catch {
                debugLog("model load error: \(error)")
                await MainActor.run {
                    self.prefs.modelState = .failed(error.localizedDescription)
                    self.refreshStatus()
                }
            }
        }
    }

    func downloadModel() {
        prefs.modelState = .downloading
        refreshStatus()
        Task {
            do {
                try await transcriber.download()
                _ = try await transcriber.transcribe([Float](repeating: 0, count: 16_000))
                await MainActor.run {
                    self.prefs.modelState = .ready
                    self.refreshStatus()
                }
            } catch {
                await MainActor.run {
                    self.prefs.modelState = .failed("Download failed: \(error.localizedDescription)")
                    self.refreshStatus()
                }
            }
        }
    }

    // MARK: Keyboard

    func installEventTap() {
        // A tap created before Accessibility is granted stays disabled forever, so wait for it.
        guard AXIsProcessTrusted() else {
            refreshStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.installEventTap() }
            return
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            debugLog("tapCreate failed, retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.installEventTap() }
            return
        }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("event tap installed")
        refreshStatus()
        // Watchdog: macOS can switch a tap off. Turn it back on.
        let watchdog = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            debugLog("tap was disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    /// Runs on the main thread (the tap is attached to the main run loop). Must stay fast (<1 ms).
    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        if type == .keyDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == 53, case .handsFree = mode, !fnIsDown {  // Esc cancels hands-free
                cancel()
            } else if fnIsDown {
                fnUsedAsModifier = true  // Fn+key shortcut (arrows, tiling, F-keys), not dictation
            }
            return
        }
        guard type == .flagsChanged else { return }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let otherMods = !event.flags.intersection(Self.nonFnModifiers).isEmpty

        // Fn/Globe reports keycode 63 (built-in) or 179 (some external keyboards).
        if keycode != 63 && keycode != 179 {
            // Pressing Control/Command/Option/Shift while holding Fn (e.g. Fn+Ctrl+Arrow window tiling!)
            if fnIsDown && otherMods {
                fnUsedAsModifier = true
            }
            return
        }

        let down = event.flags.contains(.maskSecondaryFn)
        guard down != fnIsDown else { return }
        fnIsDown = down
        let ts = Double(event.timestamp) / 1_000_000_000.0
        debugLog("fn \(down ? "down" : "up") mode=\(mode) otherMods=\(otherMods)")
        down ? fnDown(at: ts, otherModifiersHeld: otherMods) : fnUp(at: ts)
    }

    func fnDown(at timestamp: TimeInterval, otherModifiersHeld: Bool) {
        if otherModifiersHeld {
            // User already held Ctrl/Cmd/Opt/Shift before pressing Fn (e.g. window tiling shortcut).
            fnUsedAsModifier = true
            return
        }
        switch mode {
        case .idle:
            guard prefs.modelState == .ready else {
                showNotReadyToast()
                return
            }
            startRecording(at: timestamp)
        case .tapPending:
            // Second tap: hands-free starts now and keeps the same recording running seamlessly.
            ignoreNextFnUp = true
            fnUsedAsModifier = false
            mode = .handsFree(finishingOnUp: false)
            play(.handsfree)
            if prefs.duckAudio && !AudioDucker.shared.isDucked {
                AudioDucker.shared.duck(ratio: prefs.duckLevel)
            }
            display(.handsFree)
        case .handsFree:
            // Wait for release so Fn+Ctrl+Arrow window shortcuts can still be used during hands-free!
            fnUsedAsModifier = false
            mode = .handsFree(finishingOnUp: true)
        case .holding, .transcribing:
            break
        }
    }

    func fnUp(at timestamp: TimeInterval) {
        if ignoreNextFnUp {
            ignoreNextFnUp = false
            return
        }
        switch mode {
        case .holding(let startTs):
            if fnUsedAsModifier {
                resetToIdle()
                return
            }
            let held = max(0, timestamp - startTs)
            if held < tapMaxDuration {
                // Quick tap: keep listening briefly in case a second tap follows for hands-free.
                let token = UUID()
                mode = .tapPending(token)
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow) { [weak self] in
                    guard let self, self.mode == .tapPending(token) else { return }
                    self.resetToIdle()  // just a stray single tap
                }
            } else {
                finish()
            }

        case .handsFree(let finishingOnUp):
            if finishingOnUp && !fnUsedAsModifier {
                finish()
            } else {
                // Fn was used as part of a shortcut (e.g. Fn+Ctrl+Arrow window move); stay in hands-free!
                mode = .handsFree(finishingOnUp: false)
            }

        case .idle, .tapPending, .transcribing:
            break
        }
    }

    // MARK: Recording

    func startRecording(at timestamp: TimeInterval) {
        fnUsedAsModifier = false
        mode = .holding(timestamp)
        meter.reset()
        display(.recording)
        toaster.hide()
        TextInserter.shared.beginSession()

        // Chime & duck only once it's clearly dictation (~140 ms) — stray taps and Fn+Arrow shortcuts stay untouched.
        let started = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.mode == started, !self.fnUsedAsModifier else { return }
            play(.start)
            if self.prefs.duckAudio {
                AudioDucker.shared.duck(ratio: self.prefs.duckLevel)
            }
        }

        audioQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.start()
            } catch {
                debugLog("mic start error: \(error)")
                DispatchQueue.main.async {
                    self.resetToIdle()
                    self.showMicErrorToast(error)
                }
            }
        }

        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            self.finish()
            self.toaster.show(
                ToastModel(
                    symbol: "timer", tint: .orange, title: "Stopped after 10 minutes",
                    message: "Long recordings are split for safety. Your text is being typed now."), seconds: 5)
        }
        safetyStop?.cancel()
        safetyStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecording, execute: stop)
    }

    func resetToIdle() {
        safetyStop?.cancel()
        AudioDucker.shared.unduck()
        TextInserter.shared.endSession()
        audioQueue.async { [weak self] in self?.recorder.stop() }
        mode = .idle
        display(.hidden)
    }

    func cancel() {
        resetToIdle()
        play(.cancel)
    }

    func finish() {
        safetyStop?.cancel()
        AudioDucker.shared.unduck()
        play(.stop)
        mode = .transcribing
        display(.transcribing)
        audioQueue.async { [weak self] in
            guard let self else { return }
            let samples = self.recorder.stop()
            debugLog("finish: \(samples.count) samples")
            guard samples.count >= self.minSpeechSamples else {
                TextInserter.shared.endSession()
                DispatchQueue.main.async { self.deliver("", accidental: true) }
                return
            }
            Task {
                do {
                    let text = try await self.transcriber.transcribe(samples)
                    await self.deliverAsync(text, accidental: false)
                } catch {
                    debugLog("transcription error: \(error)")
                    TextInserter.shared.endSession()
                    await MainActor.run {
                        self.resetToIdle()
                        self.toaster.show(
                            ToastModel(
                                symbol: "exclamationmark.triangle.fill", tint: .orange,
                                title: "Couldn't transcribe that", message: error.localizedDescription))
                    }
                }
            }
        }
    }

    // MARK: Delivering text

    @MainActor
    func deliver(_ text: String, accidental: Bool) {
        Task { await deliverAsync(text, accidental: accidental) }
    }

    @MainActor
    func deliverAsync(_ text: String, accidental: Bool) async {
        debugLog("deliver: \(text.count) chars")
        guard !text.isEmpty else {
            mode = .idle
            display(.hidden)
            if !accidental {
                play(.notice)
                toaster.show(
                    ToastModel(
                        symbol: "waveform.slash", tint: .gray, title: "Didn't catch that",
                        message: "Hold Fn while you speak"), seconds: 2.5)
            }
            return
        }

        lastTranscript = text
        prefs.addHistory(text)
        setClipboard(text)  // always on the clipboard as a fallback

        guard prefs.autoPaste else {
            mode = .idle
            display(.hidden)
            toaster.show(
                ToastModel(
                    symbol: "doc.on.clipboard.fill", tint: .green, title: "Copied to clipboard",
                    message: "Press ⌘V to paste it."), seconds: 2.5)
            return
        }

        // Resolve target window & text box off the main thread so the UI never freezes.
        let outcome = await TextInserter.shared.resolveForDelivery(text)
        mode = .idle
        display(.hidden)

        switch outcome {
        case .notEditable(let app):
            debugLog("no text box in \(app)")
            play(.notice)
            toaster.show(
                ToastModel(
                    symbol: "text.cursor", tint: .orange, title: "No text box selected",
                    message: "Copied to clipboard — press ⌘V to paste",
                    action: ToastAction(title: "Copy") { [weak self] in self?.setClipboard(text) }),
                seconds: 8)
        case .paste(let textToPaste):
            paste(textToPaste, restoringClipboardTo: text)
        }
    }

    private func paste(_ text: String, restoringClipboardTo clean: String) {
        setClipboard(text)
        TextInserter.pressPaste()
        if text != clean {
            // Leave the clipboard without the extra leading space once the paste has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard NSPasteboard.general.string(forType: .string) == text else { return }
                self?.setClipboard(clean)
            }
        }
    }

    func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Messages

    func showNotReadyToast() {
        switch prefs.modelState {
        case .loading:
            toaster.show(
                ToastModel(
                    symbol: "hourglass", tint: .blue, title: "SpeakFn is starting up",
                    message: "The speech model is loading — try again in a few seconds."), seconds: 3)
        case .downloading:
            toaster.show(
                ToastModel(
                    symbol: "arrow.down.circle", tint: .blue, title: "Downloading speech model",
                    message: "This happens once. SpeakFn will be ready when it finishes."), seconds: 3)
        default:
            toaster.show(
                ToastModel(
                    symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Speech model not installed",
                    message: "Open SpeakFn's settings to set it up.",
                    action: ToastAction(title: "Open") { [weak self] in self?.settings.show() }))
        }
    }

    func showMicErrorToast(_ error: Error) {
        if case RecorderError.permissionDenied = error {
            toaster.show(
                ToastModel(
                    symbol: "mic.slash.fill", tint: .red, title: "Microphone access is off",
                    message: "Allow SpeakFn to use the microphone in System Settings.",
                    action: ToastAction(title: "Open") { openPrivacyPane("Privacy_Microphone") }))
        } else {
            toaster.show(
                ToastModel(
                    symbol: "mic.slash.fill", tint: .red, title: "Microphone unavailable",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    // MARK: Menu bar

    /// The app's own menu bar (shown while SpeakFn is the active app).
    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SpeakFn", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SpeakFn", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SpeakFn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Private, on-device dictation.\nSpeech model: NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0)\nRuns via FluidAudio (Apache-2.0).",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        ])
    }

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "c")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SpeakFn", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        indicator = MenuBarIndicator(item: statusItem, meter: meter)
    }

    /// Updates the recording pill and the menu bar together.
    func display(_ state: OverlayState) {
        overlay.show(state)
        indicator?.show(state)
    }

    func refreshStatus() {
        prefs.refreshStatus()
        let title: String
        switch prefs.modelState {
        case .loading: title = "Loading speech model…"
        case .downloading: title = "Downloading speech model…"
        case .missing: title = "⚠︎ Speech model not installed"
        case .failed: title = "⚠︎ Speech model failed to load"
        case .ready:
            title = eventTap == nil || !AXIsProcessTrusted() ? "⚠︎ Needs Accessibility permission" : "Ready — hold Fn to talk"
        }
        statusLine?.title = title
    }

    @objc func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        setClipboard(lastTranscript)
    }

    @objc func openSettings() { settings.show() }

    @objc func quit() { NSApp.terminate(nil) }
}
