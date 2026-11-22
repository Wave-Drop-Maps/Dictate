// Works out whether there's a text box to type into, and types the transcript there.

import AppKit
import ApplicationServices

enum InsertionTarget {
    /// A text field/area has keyboard focus.
    case editable(AXUIElement, app: String)
    /// We're confident nothing typeable has focus (e.g. Finder's file list, the desktop).
    case notEditable(app: String)
    /// The app doesn't tell us (some browsers/games). We paste anyway.
    case unknown(app: String)

    var appName: String {
        switch self {
        case .editable(_, let app), .notEditable(let app), .unknown(let app): return app
        }
    }
}

enum TextInserter {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Focused controls that definitely can't take typed text.
    private static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXCell", "AXRow", "AXButton", "AXMenuButton",
        "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXImage", "AXWindow", "AXSplitGroup",
        "AXToolbar", "AXTabGroup", "AXMenu", "AXMenuBar", "AXMenuItem", "AXDisclosureTriangle", "AXIncrementor",
        "AXScrollBar", "AXColorWell", "AXSegmentedControl", "AXScrollArea",
        "AXWebArea",  // a web page itself has focus, not a text box on it
    ]

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Chromium/Electron apps (Chrome, Brave, Edge, Arc, Discord, VS Code, Claude…) only build their
    /// accessibility tree on demand; `prepare()` asks for it as soon as you start talking.
    private static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chrome Framework")
            || $0.contains("Chromium Framework") || $0.contains("Edge Framework") || $0.contains("Brave")
        }
    }

    /// Called when recording starts, so browsers have their accessibility info ready by the time we paste.
    static func prepare() {
        guard let app = NSWorkspace.shared.frontmostApplication, isChromiumBased(app) else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func currentTarget() -> InsertionTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown(app: "") }
        let name = app.localizedName ?? "this app"
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return .unknown(app: name) }  // our own window
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)  // never hang on a frozen app
        let chromium = isChromiumBased(app)
        if chromium {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        // Busy apps (a browser playing video) can be slow to answer, so ask up to three times.
        var focused: CFTypeRef?
        var error = AXError.failure
        for attempt in 0..<3 {
            if attempt > 0 { usleep(150_000) }
            AXUIElementSetMessagingTimeout(appElement, attempt == 0 ? 0.5 : 1.0)
            focused = nil
            error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
            if error == .success { break }
        }
        debugLog("focus query app=\(app.bundleIdentifier ?? "?") axError=\(error.rawValue)")
        if error == .noValue { return .notEditable(app: name) }  // nothing at all has keyboard focus
        guard error == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .unknown(app: name)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        if isEditable(element) { return .editable(element, app: name) }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        debugLog("focused role=\(role) app=\(app.bundleIdentifier ?? "?")")
        if nonTextRoles.contains(role) { return .notEditable(app: name) }
        // Finder only takes text in its rename/search fields (caught above); the desktop and windows don't.
        if app.bundleIdentifier == "com.apple.finder" { return .notEditable(app: name) }
        return .unknown(app: name)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let subrole = attribute(element, kAXSubroleAttribute) as? String, subrole == "AXSecureTextField" {
            return true
        }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if textRoles.contains(role) { return true }
        if attribute(element, "AXEditableAncestor") != nil { return true }  // web contenteditable
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue, attribute(element, kAXSelectedTextRangeAttribute) != nil
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
