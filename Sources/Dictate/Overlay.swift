// The floating pill (waveform while recording) and toast messages (errors, "copied", etc.).

import AppKit
import SwiftUI

// MARK: - Recording pill

enum OverlayState: Equatable { case hidden, recording, handsFree, transcribing }

/// Smoothed loudness → bar heights, shared by the pill and the menu bar.
final class LevelMeter {
    private(set) var history = [CGFloat](repeating: 0, count: 12)

    func push(_ level: CGFloat) {
        history.removeFirst()
        history.append(level)
    }

    func reset() { history = history.map { _ in 0 } }

    /// `count` bars, loudest in the middle, gently varying over time.
    func targets(count: Int, phase: CGFloat) -> [CGFloat] {
        let mid = CGFloat(count - 1) / 2
        return (0..<count).map { i in
            let distance = abs(CGFloat(i) - mid) / max(mid, 1)
            let level = history[history.count - 1 - min(Int(abs(CGFloat(i) - mid)), history.count - 1)]
            let shape = 1 - 0.55 * distance
            let wobble = 0.85 + 0.15 * sin(phase * 3 + CGFloat(i) * 1.7)
            return max(0.12, min(1, level * 1.3 * shape * wobble))
        }
    }
}

/// Compact pill: a status dot and a smooth waveform while recording, three dots while transcribing.
final class PillView: NSView {
    var state: OverlayState = .hidden
    let meter: LevelMeter
    private var bars = [CGFloat](repeating: 0.12, count: 7)
    private(set) var phase: CGFloat = 0

    init(meter: LevelMeter) {
        self.meter = meter
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func tick() {
        phase += 0.1
        let targets = meter.targets(count: bars.count, phase: phase)
        for i in bars.indices { bars[i] += (targets[i] - bars[i]) * 0.35 }  // ease toward the target
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let pill = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), xRadius: b.height / 2, yRadius: b.height / 2)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        pill.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let midY = b.midY
        switch state {
        case .hidden:
            return
        case .recording, .handsFree:
            let dotColor = state == .handsFree ? NSColor.systemOrange : NSColor.systemRed
            dotColor.withAlphaComponent(0.75 + 0.25 * sin(phase * 2)).setFill()
            NSBezierPath(ovalIn: NSRect(x: 11, y: midY - 3, width: 6, height: 6)).fill()

            let barWidth: CGFloat = 3, gap: CGFloat = 3
            var x: CGFloat = 25
            let maxHeight = b.height - 12
            NSColor.white.setFill()
            for level in bars {
                let h = max(3, level * maxHeight)
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: midY - h / 2, width: barWidth, height: h), xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
                x += barWidth + gap
            }
        case .transcribing:
            for i in 0..<3 {
                let a = 0.3 + 0.7 * max(0, sin(phase * 3 - CGFloat(i) * 0.9))
                NSColor.white.withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: NSRect(x: 13 + CGFloat(i) * 9, y: midY - 2.5, width: 5, height: 5)).fill()
            }
        }
    }
}

/// Bottom-centre of the screen the mouse is on.
private func bottomCentre(width: CGFloat, height: CGFloat, lift: CGFloat) -> NSRect {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(x: vf.midX - width / 2, y: vf.minY + lift, width: width, height: height)
}

private func makeFloatingPanel(clickable: Bool) -> NSPanel {
    let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.ignoresMouseEvents = !clickable
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return panel
}

/// The recording pill. Never takes focus or clicks.
final class Overlay {
    private let panel = makeFloatingPanel(clickable: false)
    private let view: PillView
    private var timer: Timer?

    init(meter: LevelMeter) {
        view = PillView(meter: meter)
        panel.contentView = view
    }

    func show(_ state: OverlayState) {
        if state != .hidden && !UserDefaults.standard.bool(forKey: "showPill") {
            panel.orderOut(nil)
            return
        }
        view.state = state
        guard state != .hidden else {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
            return
        }
        let width: CGFloat = state == .transcribing ? 50 : 74
        panel.setFrame(bottomCentre(width: width, height: 24, lift: 18), display: true)
        panel.orderFrontRegardless()
        view.needsDisplay = true
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.view.tick() }
            RunLoop.main.add(t, forMode: .common)  // keeps animating while menus are open
            timer = t
        }
    }
}

// MARK: - Toasts

struct ToastAction {
    let title: String
    let handler: () -> Void
}

struct ToastModel {
    var symbol: String
    var tint: Color
    var title: String
    var message: String
    var action: ToastAction?
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // buttons work on first click
}

private struct ToastView: View {
    let model: ToastModel
    let dismiss: () -> Void
    @State private var actionDone = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                if !model.message.isEmpty {
                    Text(model.message).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .lineLimit(1)
            .fixedSize()
            if let action = model.action {
                Button {
                    action.handler()
                    actionDone = true
                } label: {
                    Text(actionDone && action.title == "Copy" ? "Copied" : action.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(actionDone ? 0.1 : 0.18), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 8)
        .background(Color(white: 0.1).opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        .fixedSize()
    }
}

/// Small floating message near the bottom of the screen. Clickable, but never steals focus.
final class Toaster {
    private let panel = makeFloatingPanel(clickable: true)
    private var hideWork: DispatchWorkItem?
    private var generation = 0  // so a fading-out toast can't hide the next one

    func show(_ model: ToastModel, seconds: TimeInterval = 6) {
        generation += 1
        let view = ToastView(model: model, dismiss: { [weak self] in self?.hide() })
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        panel.setFrame(bottomCentre(width: size.width, height: size.height, lift: 14), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        scheduleHide(after: seconds)
    }

    /// Auto-hides, but waits while the mouse is over the toast so its buttons can be clicked.
    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                self.scheduleHide(after: 1.5)
            } else {
                self.hide()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        let current = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        })
    }
}
