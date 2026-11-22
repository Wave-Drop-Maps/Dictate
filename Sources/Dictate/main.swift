// Dictate — private, fully local push-to-talk dictation for macOS.
// Entry point. `--transcribe <file>` prints a transcript (handy for checking the model).

import AppKit
import ApplicationServices

let arguments = CommandLine.arguments

/// `--transcribe <audio file>`: transcribe a file and print the text and timings.
if let i = arguments.firstIndex(of: "--transcribe"), i + 1 < arguments.count {
    let url = URL(fileURLWithPath: arguments[i + 1])
    let done = DispatchSemaphore(value: 0)
    Task {
        let transcriber = Transcriber()
        do {
            let start = Date()
            try await transcriber.load()
            let loaded = Date()
            let text = try await transcriber.transcribe(file: url)
            print(text)
            print(String(format: "[load %.2fs, transcribe %.2fs]",
                         loaded.timeIntervalSince(start), Date().timeIntervalSince(loaded)))
        } catch {
            print("ERROR: \(error)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
