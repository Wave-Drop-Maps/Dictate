// Live status in the menu bar: "● Listening 0:07", "Hands-free 0:12 · Fn to finish", "Transcribing…".

import AppKit

final class MenuBarIndicator {
    private let item: NSStatusItem
    private let meter: LevelMeter
    private var state: OverlayState = .hidden
    private var started = Date()
    private var timer: Timer?
    private var bars = [CGFloat](repeating: 0.15, count: 5)
    private var phase: CGFloat = 0

    init(item: NSStatusItem, meter: LevelMeter) {
        self.item = item
        self.meter = meter
        showIdle()
    }

    func show(_ newState: OverlayState) {
        let wasRecording = state == .recording || state == .handsFree
        state = newState
        switch newState {
        case .hidden:
            timer?.invalidate()
            timer = nil
            showIdle()
            return
        case .recording, .handsFree:
            if !wasRecording { started = Date() }  // hands-free continues the same recording
        case .transcribing:
            break
        }
        render()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.render() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func showIdle() {
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Dictate")
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
    }

    private func render() {
        guard let button = item.button else { return }
        phase += 0.2
        let title: String
        let color: NSColor
        switch state {
        case .recording:
            color = .systemRed
            title = "Listening \(elapsed)"
        case .handsFree:
            color = .systemOrange
            title = "Hands-free \(elapsed) · Fn to finish"
        case .transcribing:
            color = .labelColor
            title = "Transcribing…"
        case .hidden:
            return
        }
        let targets = state == .transcribing
            ? (0..<bars.count).map { i in 0.25 + 0.35 * max(0, sin(phase - CGFloat(i) * 0.7)) }
            : meter.targets(count: bars.count, phase: phase)
        for i in bars.indices { bars[i] += (targets[i] - bars[i]) * 0.5 }
        button.image = barsImage(color: color)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(
            string: " " + title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .baselineOffset: 0.5,
            ])
    }

    private var elapsed: String {
        let seconds = Int(Date().timeIntervalSince(started))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// A tiny 5-bar waveform drawn in the given colour.
    private func barsImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 17, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            let width: CGFloat = 2, gap: CGFloat = 1.75
            var x: CGFloat = 0.5
            for level in self.bars {
                let h = max(2, level * (rect.height - 2))
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: rect.midY - h / 2, width: width, height: h), xRadius: 1, yRadius: 1
                ).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
