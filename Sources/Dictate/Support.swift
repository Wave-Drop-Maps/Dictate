// Shared helpers: model location, diagnostic log, sounds.

import AppKit

/// Where the Parakeet speech model lives on disk (~470 MB, downloaded once).
let modelDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3")

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

// MARK: - Diagnostic log
// Off by default. Records key events and state changes only — never audio or transcript text.

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dictate.log")
private let logQueue = DispatchQueue(label: "dictate.log")
private let logFormatter = ISO8601DateFormatter()

func debugLog(_ message: String) {
    guard UserDefaults.standard.bool(forKey: "diagnostics") else { return }
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

// MARK: - Sounds

/// Interface sounds (Resources/*.wav): "drop_003" from Kenney's Interface Sounds, CC0.
enum Cue: String, CaseIterable {
    case start, stop, handsfree, cancel, notice
}

private let cueSounds: [Cue: NSSound] = {
    var sounds: [Cue: NSSound] = [:]
    for cue in Cue.allCases {
        // Separate NSSound per cue so overlapping sounds don't cut each other off.
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav"),
            let sound = NSSound(contentsOf: url, byReference: true)
        else { continue }
        sounds[cue] = sound
    }
    return sounds
}()

func play(_ cue: Cue) {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: "sounds"), let sound = cueSounds[cue] else { return }
    sound.stop()  // restart cleanly if it's still playing
    sound.volume = Float(defaults.object(forKey: "soundVolume") as? Double ?? 0.5)
    sound.play()
}

func openPrivacyPane(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}
