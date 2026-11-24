// Works out whether there's a text box to type into across window switches/drags, and types the transcript there.
// All Accessibility IPC runs on `axQueue` so the main run loop and keyboard tap never stall.

import AppKit
import ApplicationServices

enum InsertionOutcome {
    /// Ready to paste `textToPaste` (which includes smart leading space if needed) into the active/restored target.
    case paste(textToPaste: String)
    /// Confident nothing typeable has focus (e.g. Finder file list, static web page with no text box).
    case notEditable(app: String)
}

final class TextInserter: @unchecked Sendable {
    static let shared = TextInserter()

    private struct SavedTarget {
        let pid: pid_t
        let appName: String
        let window: AXUIElement?
        let element: AXUIElement
    }

    private let axQueue = DispatchQueue(label: "speakfn.ax", qos: .userInitiated)
    private var chromiumCache: [String: Bool] = [:]

    /// Most recent non-SpeakFn application that was active.
    private var lastExternalApp: NSRunningApplication?
    private var sessionActive = false
    /// Confirmed editable field seen at recording start or when explicitly clicked during recording.
    private var sessionEditableTarget: SavedTarget?
    /// True if the user dragged a window (mouse-down → drag > 6 pt) since the last clean text-box click.
    private var recentInteractionWasDrag = false
    private var mouseDownLocation: NSPoint?
    private var workspaceObserver: NSObjectProtocol?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView",
    ]

    /// Focused controls that definitely can't take typed text once the AX tree is ready.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXCell", "AXRow", "AXButton", "AXMenuButton",
        "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXImage", "AXWindow", "AXSplitGroup",
        "AXToolbar", "AXTabGroup", "AXMenu", "AXMenuBar", "AXMenuItem", "AXDisclosureTriangle", "AXIncrementor",
        "AXScrollBar", "AXColorWell", "AXSegmentedControl", "AXScrollArea",
        "AXWebArea",  // a static web page itself has focus, not an input on it
    ]

    /// Roles that Chromium/Electron transiently report while waking up AX or switching windows.
    private static let transientContainerRoles: Set<String> = [
        "AXWindow", "AXWebArea", "AXGroup", "AXUnknown", "AXScrollArea", "AXSplitGroup",
    ]

    /// Known web/canvas editor class/id substrings where keyboard paste works even if role is AXWebArea/AXGroup.
    private static let customEditorHints = [
        "docs-texteventtarget", "monaco", "xterm", "prosemirror", "cm-content", "codemirror",
        "ql-editor", "slate-editor", "lexical", "ace_text-input", "notion-page-content",
    ]

    private init() {}

    /// Starts observing app switches and mouse clicks/drags so window changes mid-dictation stay tracked.
    func startMonitoring() {
        if let front = NSWorkspace.shared.frontmostApplication,
            front.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            axQueue.async { [weak self] in
                self?.lastExternalApp = front
                self?.prepareApp(front)
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.axQueue.async {
                    self.lastExternalApp = app
                    if self.sessionActive {
                        self.prepareApp(app)
                        self.refreshSessionTargetAfterFocusChange(in: app, delayMs: 90)
                    }
                }
            }
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.mouseDownLocation = NSEvent.mouseLocation
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            let up = NSEvent.mouseLocation
            let down = self.mouseDownLocation ?? up
            self.mouseDownLocation = nil
            let dragged = hypot(up.x - down.x, up.y - down.y) > 6.0

            self.axQueue.async {
                guard self.sessionActive else { return }
                self.recentInteractionWasDrag = dragged
                guard !dragged else { return }
                // User clicked (not dragged) — check after 70 ms if they clicked a new text box in any window.
                self.axQueue.asyncAfter(deadline: .now() + 0.07) {
                    guard self.sessionActive, let app = self.effectiveTargetApp() else { return }
                    self.prepareApp(app)
                    if let snap = self.captureEditableTarget(in: app) {
                        self.sessionEditableTarget = snap
                        self.recentInteractionWasDrag = false
                        debugLog("updated session text box in \(snap.appName)")
                    }
                }
            }
        }
    }

    /// Reactivates the last external app when SpeakFn's own Settings window closes, so windowless SpeakFn never traps focus.
    func restoreExternalFocusIfNeeded() {
        axQueue.async { [weak self] in
            guard let self,
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
                let prev = self.lastExternalApp, !prev.isTerminated
            else { return }
            prev.activate()
        }
    }

    /// Called when recording starts. Runs asynchronously on `axQueue` so `Fn` down never blocks.
    func beginSession() {
        axQueue.async { [weak self] in
            guard let self else { return }
            self.sessionActive = true
            self.recentInteractionWasDrag = false
            self.sessionEditableTarget = nil
            guard let app = self.effectiveTargetApp() else { return }
            self.prepareApp(app)
            if let snap = self.captureEditableTarget(in: app) {
                self.sessionEditableTarget = snap
                debugLog("captured initial text box in \(snap.appName)")
            } else if self.isChromiumBased(app) {
                // Chromium may still be building its AX tree right after prepareApp; re-check once after 140 ms.
                self.axQueue.asyncAfter(deadline: .now() + 0.14) {
                    guard self.sessionActive, self.sessionEditableTarget == nil,
                        let current = self.effectiveTargetApp(), current.processIdentifier == app.processIdentifier
                    else { return }
                    self.sessionEditableTarget = self.captureEditableTarget(in: current)
                }
            }
        }
    }

    func endSession() {
        axQueue.async { [weak self] in
            self?.sessionActive = false
            self?.sessionEditableTarget = nil
            self?.recentInteractionWasDrag = false
        }
    }

    /// Resolves where to insert `cleanText`, restoring focus if moving a window displaced it, and computes smart spacing.
    func resolveForDelivery(_ cleanText: String) async -> InsertionOutcome {
        await withCheckedContinuation { continuation in
            axQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .paste(textToPaste: cleanText))
                    return
                }
                let saved = self.sessionEditableTarget
                let wasDrag = self.recentInteractionWasDrag
                self.sessionActive = false
                self.sessionEditableTarget = nil
                self.recentInteractionWasDrag = false

                let outcome = self.resolveSync(cleanText: cleanText, savedTarget: saved, recentDrag: wasDrag)
                continuation.resume(returning: outcome)
            }
        }
    }

    // MARK: - Core resolution on `axQueue`

    private func resolveSync(cleanText: String, savedTarget: SavedTarget?, recentDrag: Bool) -> InsertionOutcome {
        // 1. If SpeakFn itself is frontmost, check if the user explicitly clicked SpeakFn's "Try it" field.
        if let front = NSWorkspace.shared.frontmostApplication,
            front.bundleIdentifier == Bundle.main.bundleIdentifier
        {
            if isSpeakFnTryFieldFocused(pid: front.processIdentifier) {
                return .paste(textToPaste: cleanText)
            }
            // Otherwise SpeakFn accidentally has focus — reactivate the real external app first!
            if let prev = lastExternalApp, !prev.isTerminated {
                debugLog("SpeakFn had focus; restoring \(prev.localizedName ?? "previous app")")
                prev.activate()
                usleep(65_000)
            }
        }

        guard let app = effectiveTargetApp() else {
            return .paste(textToPaste: cleanText)
        }
        let appName = app.localizedName ?? "this app"
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return .paste(textToPaste: cleanText)
        }

        let current = inspectApp(app)
        switch current {
        case .editable(let element, _):
            let spaced = Self.withSmartSpacing(cleanText, for: element)
            return .paste(textToPaste: spaced)

        case .unknown:
            // If the user just dragged a window and we have a confirmed text box from this session, restore it.
            if recentDrag, let saved = savedTarget, restoreSavedTarget(saved) {
                let spaced = Self.withSmartSpacing(cleanText, for: saved.element)
                return .paste(textToPaste: spaced)
            }
            return .paste(textToPaste: cleanText)

        case .notEditable:
            // If the user started dictating in a real text box and then moved/peeked at another window (or dragged a
            // window's title bar so AXWindow got focus), restore their text box instead of failing!
            if let saved = savedTarget, restoreSavedTarget(saved) {
                debugLog("restored displaced text box in \(saved.appName)")
                let spaced = Self.withSmartSpacing(cleanText, for: saved.element)
                return .paste(textToPaste: spaced)
            }
            return .notEditable(app: appName)
        }
    }

    private enum RawTarget {
        case editable(AXUIElement, app: String)
        case notEditable(app: String)
        case unknown(app: String)
    }

    private func inspectApp(_ app: NSRunningApplication) -> RawTarget {
        let name = app.localizedName ?? "this app"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        let chromium = isChromiumBased(app)
        if chromium {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        // Poll up to 4 times (off the main thread!) if the app hasn't answered OR if Chromium transiently
        // reports a container role (AXWindow / AXWebArea) while finishing window-switch focus hydration.
        var element: AXUIElement?
        var lastError = AXError.failure
        let delaysUs: [useconds_t] = [0, 55_000, 85_000, 110_000]

        for (attempt, delay) in delaysUs.enumerated() {
            if delay > 0 { usleep(delay) }
            AXUIElementSetMessagingTimeout(appElement, attempt == 0 ? 0.35 : 0.6)
            let (found, err) = focusedElementInActiveWindow(appElement: appElement, pid: app.processIdentifier)
            lastError = err
            if let found {
                element = found
                AXUIElementSetMessagingTimeout(found, 0.25)
                if Self.isEditable(found) {
                    return .editable(found, app: name)
                }
                let role = Self.attribute(found, kAXRoleAttribute) as? String ?? ""
                // Keep polling briefly if Chromium/Electron is still hydrating a newly switched window.
                if chromium && Self.transientContainerRoles.contains(role) && attempt < delaysUs.count - 1 {
                    continue
                }
                break
            }
        }

        debugLog("focus query app=\(app.bundleIdentifier ?? "?") axError=\(lastError.rawValue)")
        if element == nil && lastError == .noValue {
            return .notEditable(app: name)
        }
        guard let element else {
            return .unknown(app: name)
        }

        if Self.isEditable(element) {
            return .editable(element, app: name)
        }
        let role = Self.attribute(element, kAXRoleAttribute) as? String ?? ""
        debugLog("focused role=\(role) app=\(app.bundleIdentifier ?? "?")")

        // Check if focus is inside an iframe/sub-area that has its own deeper focused element.
        if role == "AXWebArea" || role == "AXGroup" || role == "AXWindow" {
            if let deeper = Self.axElementAttribute(element, kAXFocusedUIElementAttribute),
                !CFEqual(deeper, element)
            {
                AXUIElementSetMessagingTimeout(deeper, 0.25)
                if Self.isEditable(deeper) {
                    return .editable(deeper, app: name)
                }
            }
        }

        if Self.nonTextRoles.contains(role) {
            return .notEditable(app: name)
        }
        if app.bundleIdentifier == "com.apple.finder" {
            return .notEditable(app: name)
        }
        return .unknown(app: name)
    }

    /// Queries focus while guarding against Chromium's multi-window quirk where `appElement`'s focused element
    /// momentarily still points to the *other* window after switching windows.
    private func focusedElementInActiveWindow(appElement: AXUIElement, pid: pid_t) -> (AXUIElement?, AXError) {
        let activeWin = Self.axElementAttribute(appElement, kAXFocusedWindowAttribute)
            ?? Self.axElementAttribute(appElement, kAXMainWindowAttribute)

        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &raw)
        if err == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let elem = raw as! AXUIElement
            // Verify `elem` belongs to `activeWin` when the app has multiple windows.
            if let activeWin, let elemWin = Self.containingWindow(of: elem), !CFEqual(activeWin, elemWin) {
                debugLog("app focus pointed to background window; querying active window directly")
                if let winFocused = Self.axElementAttribute(activeWin, kAXFocusedUIElementAttribute) {
                    return (winFocused, .success)
                }
                return (activeWin, .success)
            }
            return (elem, .success)
        }

        // Fallback: ask the active window directly, then system-wide AX focus.
        if let activeWin, let winFocused = Self.axElementAttribute(activeWin, kAXFocusedUIElementAttribute) {
            return (winFocused, .success)
        }
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, 0.25)
        if let sysElem = Self.axElementAttribute(sysWide, kAXFocusedUIElementAttribute) {
            var elemPid: pid_t = 0
            if AXUIElementGetPid(sysElem, &elemPid) == .success, elemPid == pid {
                return (sysElem, .success)
            }
        }
        if let activeWin {
            return (activeWin, .success)
        }
        return (nil, err)
    }

    private func captureEditableTarget(in app: NSRunningApplication) -> SavedTarget? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let (elem, _) = focusedElementInActiveWindow(appElement: appElement, pid: app.processIdentifier)
        guard let elem else { return nil }
        AXUIElementSetMessagingTimeout(elem, 0.2)
        guard Self.isEditable(elem) else { return nil }
        let win = Self.containingWindow(of: elem)
            ?? Self.axElementAttribute(appElement, kAXFocusedWindowAttribute)
        return SavedTarget(
            pid: app.processIdentifier,
            appName: app.localizedName ?? "this app",
            window: win,
            element: elem
        )
    }

    private func refreshSessionTargetAfterFocusChange(in app: NSRunningApplication, delayMs: Int) {
        axQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self, self.sessionActive else { return }
            if let snap = self.captureEditableTarget(in: app) {
                self.sessionEditableTarget = snap
                self.recentInteractionWasDrag = false
            }
        }
    }

    private func restoreSavedTarget(_ saved: SavedTarget) -> Bool {
        guard let running = NSRunningApplication(processIdentifier: saved.pid), !running.isTerminated else {
            return false
        }
        AXUIElementSetMessagingTimeout(saved.element, 0.25)
        // Verify the saved element still exists in the window hierarchy.
        guard Self.attribute(saved.element, kAXRoleAttribute) != nil else { return false }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != saved.pid {
            running.activate()
            usleep(55_000)
        }
        if let win = saved.window {
            AXUIElementSetMessagingTimeout(win, 0.25)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(saved.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(35_000)
        return true
    }

    private func isSpeakFnTryFieldFocused(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        guard let elem = Self.axElementAttribute(appElement, kAXFocusedUIElementAttribute) else { return false }
        return Self.isEditable(elem)
    }

    private func effectiveTargetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication {
            if front.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
            if isSpeakFnTryFieldFocused(pid: front.processIdentifier) {
                return front
            }
        }
        if let prev = lastExternalApp, !prev.isTerminated {
            return prev
        }
        return NSWorkspace.shared.frontmostApplication
    }

    private func prepareApp(_ app: NSRunningApplication) {
        guard isChromiumBased(app) else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)"
        if let cached = chromiumCache[key] { return cached }
        guard let url = app.bundleURL else {
            chromiumCache[key] = false
            return false
        }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let result = names.contains {
            $0.hasPrefix("Electron Framework") || $0.contains("Chrome Framework")
                || $0.contains("Chromium Framework") || $0.contains("Edge Framework") || $0.contains("Brave")
                || $0.contains("Arc")
        }
        chromiumCache[key] = result
        return result
    }

    // MARK: - Static AX helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axElementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let val = attribute(element, name), CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return (val as! AXUIElement)
    }

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if let role = attribute(element, kAXRoleAttribute) as? String, role == "AXWindow" {
            return element
        }
        if let win = axElementAttribute(element, kAXWindowAttribute) {
            return win
        }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let cur = current, let parent = axElementAttribute(cur, kAXParentAttribute) else { return nil }
            if let role = attribute(parent, kAXRoleAttribute) as? String, role == "AXWindow" {
                return parent
            }
            current = parent
        }
        return nil
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let subrole = attribute(element, kAXSubroleAttribute) as? String,
            subrole == "AXSecureTextField" || subrole == "AXSearchField"
        {
            return true
        }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if textRoles.contains(role) { return true }
        if attribute(element, "AXEditableAncestor") != nil || attribute(element, "AXHighestEditableAncestor") != nil {
            return true
        }
        if let editable = attribute(element, "AXEditable") as? Bool, editable {
            return true
        }
        // Check DOM id / class list for canvas/custom web editors (Google Docs, Monaco, xterm, ProseMirror, etc.).
        if let domId = (attribute(element, "AXDOMIdentifier") as? String)?.lowercased(),
            customEditorHints.contains(where: { domId.contains($0) })
        {
            return true
        }
        if let domClasses = attribute(element, "AXDOMClassList") as? [String] {
            let joined = domClasses.joined(separator: " ").lowercased()
            if customEditorHints.contains(where: { joined.contains($0) }) {
                return true
            }
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue,
            attribute(element, kAXSelectedTextRangeAttribute) != nil
                || attribute(element, kAXInsertionPointLineNumberAttribute) != nil
        {
            return true
        }
        return false
    }

    /// Adds a leading space when you dictate straight after a word, so "hello" + "world" doesn't become
    /// "helloWorld". Only when the app tells us what's before the cursor; otherwise unchanged.
    static func withSmartSpacing(_ text: String, for element: AXUIElement) -> String {
        guard let first = text.first, !",.!?;:)]}'’\"”".contains(first) else { return text }
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute),
            CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return text }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return text }
        guard range.location > 0 else { return text }
        var before = CFRange(location: range.location - 1, length: 1)
        guard let param = AXValueCreate(.cfRange, &before) else { return text }
        var out: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
            let previous = (out as? String)?.last
        else {
            return text
        }
        if previous.isWhitespace || "([{\"'“‘/-@#".contains(previous) { return text }
        return " " + text
    }

    /// Presses ⌘V in whatever app has focus.
    static func pressPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)  // V
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
