// The floating pill (GPU-accelerated waveform while recording) and toast messages.

import AppKit
import QuartzCore
import SwiftUI

// MARK: - Recording pill

enum OverlayState: Equatable { case hidden, recording, handsFree, transcribing }

/// Smoothed loudness → bar heights, shared by the pill and the menu bar.
final class LevelMeter {
    private let lock = NSLock()
    private var envelope: CGFloat = 0
    private var history = [CGFloat](repeating: 0, count: 16)

    func push(_ raw: CGFloat) {
        lock.lock()
        // Fast attack so syllables pop immediately; smooth release so bars don't jitter between phonemes.
        if raw > envelope {
            envelope = envelope * 0.35 + raw * 0.65
        } else {
            envelope = envelope * 0.78 + raw * 0.22
        }
        history.removeFirst()
        history.append(envelope)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        envelope = 0
        for i in history.indices { history[i] = 0 }
        lock.unlock()
    }

    /// `count` bars, loudest in the middle, smoothly interpolated across recent loudness history.
    func targets(count: Int, phase: CGFloat) -> [CGFloat] {
        lock.lock()
        let snap = history
        lock.unlock()

        let mid = CGFloat(count - 1) / 2
        let lastIdx = CGFloat(snap.count - 1)
        return (0..<count).map { i in
            let dist = abs(CGFloat(i) - mid) / max(mid, 1)
            // Fractional lookup into history for smooth ripple outward from center.
            let pos = max(0, lastIdx - dist * 4.0)
            let lo = Int(floor(pos))
            let hi = min(snap.count - 1, lo + 1)
            let frac = pos - CGFloat(lo)
            let level = snap[lo] * (1 - frac) + snap[hi] * frac
            let shape = 1 - 0.50 * dist
            let wobble = 0.88 + 0.12 * sin(phase * 2.6 + CGFloat(i) * 1.5)
            return max(0.13, min(1, level * 1.35 * shape * wobble))
        }
    }
}

/// GPU-backed pill view using Core Animation sublayers so animations never redraw bitmaps or stall WindowServer.
final class PillView: NSView {
    var state: OverlayState = .hidden {
        didSet { updateLayerVisibility() }
    }
    let meter: LevelMeter

    private let bgLayer = CALayer()
    private let dotLayer = CALayer()
    private var barLayers: [CALayer] = []
    private var dotSpinLayers: [CALayer] = []
    private var bars = [CGFloat](repeating: 0.13, count: 7)
    private var phase: CGFloat = 0

    init(meter: LevelMeter) {
        self.meter = meter
        super.init(frame: NSRect(x: 0, y: 0, width: 74, height: 24))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Allow dragging the pill out of the way on first click without activating SpeakFn or stealing focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func setupLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false

        bgLayer.backgroundColor = NSColor(white: 0.10, alpha: 0.92).cgColor
        bgLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        bgLayer.borderWidth = 1
        bgLayer.cornerCurve = .continuous
        root.addSublayer(bgLayer)

        dotLayer.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        dotLayer.cornerRadius = 3
        root.addSublayer(dotLayer)

        for _ in 0..<7 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 1.5
            root.addSublayer(bar)
            barLayers.append(bar)
        }

        for _ in 0..<3 {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
            dot.cornerRadius = 2.5
            dot.backgroundColor = NSColor.white.cgColor
            root.addSublayer(dot)
            dotSpinLayers.append(dot)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        bgLayer.frame = b
        bgLayer.cornerRadius = b.height / 2
        layoutSublayers(in: bounds)
        CATransaction.commit()
    }

    private func updateLayerVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let showWave = state == .recording || state == .handsFree
        let showDots = state == .transcribing
        dotLayer.isHidden = !showWave
        for bar in barLayers { bar.isHidden = !showWave }
        for dot in dotSpinLayers { dot.isHidden = !showDots }
        layoutSublayers(in: bounds)
        CATransaction.commit()
    }

    func tick() {
        guard state != .hidden else { return }
        phase += 0.065
        let targets = meter.targets(count: bars.count, phase: phase)
        for i in bars.indices {
            bars[i] += (targets[i] - bars[i]) * 0.28
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutSublayers(in: bounds)
        CATransaction.commit()
    }

    private func layoutSublayers(in b: NSRect) {
        let midY = b.midY
        switch state {
        case .hidden:
            break
        case .recording, .handsFree:
            let baseColor = state == .handsFree ? NSColor.systemOrange : NSColor.systemRed
            let alpha = 0.78 + 0.22 * sin(phase * 2.2)
            dotLayer.backgroundColor = baseColor.withAlphaComponent(alpha).cgColor
            dotLayer.position = CGPoint(x: 14, y: midY)

            let barWidth: CGFloat = 3, gap: CGFloat = 3
            var x: CGFloat = 25
            let maxHeight = max(4, b.height - 12)
            for (i, level) in bars.enumerated() {
                let h = max(3, level * maxHeight)
                barLayers[i].frame = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                x += barWidth + gap
            }
        case .transcribing:
            for (i, dot) in dotSpinLayers.enumerated() {
                let a = 0.3 + 0.7 * max(0, sin(phase * 3.2 - CGFloat(i) * 0.9))
                dot.opacity = Float(a)
                dot.position = CGPoint(x: 15.5 + CGFloat(i) * 9.5, y: midY)
            }
        }
    }
}

/// Active screen where the user is currently working (screen containing the mouse cursor, or main screen).
private func activeScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
}

/// Bottom-centre of the given screen.
private func bottomCentre(on screen: NSScreen?, width: CGFloat, height: CGFloat, lift: CGFloat) -> NSRect {
    let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(x: round(vf.midX - width / 2), y: round(vf.minY + lift), width: width, height: height)
}

private func makeFloatingPanel(clickable: Bool, movable: Bool = false) -> NSPanel {
    let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    // .popUpMenu floats reliably over full-screen Spaces and Stage Manager windows without fighting the menu bar.
    panel.level = .popUpMenu
    panel.ignoresMouseEvents = !clickable && !movable
    panel.isMovableByWindowBackground = movable
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    // Omit .stationary so 3-finger Space swipes and full-screen window transitions carry the pill smoothly.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    return panel
}

/// The recording pill. Never steals focus; follows you across screens & Spaces, and can be dragged if in the way.
final class Overlay: NSObject, NSWindowDelegate {
    private let panel = makeFloatingPanel(clickable: false, movable: true)
    private let view: PillView
    private var timer: Timer?
    private var currentScreenFrame: NSRect = .zero
    private var userDraggedOffset: NSPoint?  // relative to visibleFrame bottom-center if user dragged the pill
    private var isProgrammaticFrameChange = false

    init(meter: LevelMeter) {
        view = PillView(meter: meter)
        super.init()
        panel.contentView = view
        panel.delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameChange, let screen = panel.screen ?? activeScreen() else { return }
        let vf = screen.visibleFrame
        userDraggedOffset = NSPoint(x: panel.frame.midX - vf.midX, y: panel.frame.minY - vf.minY)
    }

    func show(_ state: OverlayState) {
        if state != .hidden && !UserDefaults.standard.bool(forKey: "showPill") {
            stopTimers()
            panel.orderOut(nil)
            return
        }
        let wasHidden = view.state == .hidden
        view.state = state
        guard state != .hidden else {
            stopTimers()
            panel.orderOut(nil)
            return
        }

        let width: CGFloat = state == .transcribing ? 50 : 74
        placePanel(width: width, force: wasHidden || panel.frame.width != width)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        if timer == nil {
            // 60 fps Core Animation tick; also checks ~4x/sec if the user moved to another display.
            var frameCount = 0
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.view.tick()
                frameCount &+= 1
                if frameCount % 15 == 0 {
                    self.followActiveScreenIfNeeded()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func placePanel(width: CGFloat, force: Bool) {
        let screen = activeScreen()
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard force || vf != currentScreenFrame else { return }
        currentScreenFrame = vf

        let target: NSRect
        if let offset = userDraggedOffset {
            let rawX = vf.midX + offset.x - width / 2
            let rawY = vf.minY + offset.y
            let clampedX = min(max(vf.minX + 8, rawX), vf.maxX - width - 8)
            let clampedY = min(max(vf.minY + 6, rawY), vf.maxY - 24 - 8)
            target = NSRect(x: round(clampedX), y: round(clampedY), width: width, height: 24)
        } else {
            target = bottomCentre(on: screen, width: width, height: 24, lift: 18)
        }

        let sizeChanged = panel.frame.size != target.size
        isProgrammaticFrameChange = true
        panel.setFrame(target, display: true)
        isProgrammaticFrameChange = false
        if sizeChanged {
            panel.invalidateShadow()
        }
    }

    private func followActiveScreenIfNeeded() {
        guard view.state != .hidden else { return }
        let width: CGFloat = view.state == .transcribing ? 50 : 74
        placePanel(width: width, force: false)
    }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
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
    private let panel = makeFloatingPanel(clickable: true, movable: false)
    private var hideWork: DispatchWorkItem?
    private var generation = 0  // so a fading-out toast can't hide the next one

    func show(_ model: ToastModel, seconds: TimeInterval = 6) {
        generation += 1
        let view = ToastView(model: model, dismiss: { [weak self] in self?.hide() })
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        panel.setFrame(bottomCentre(on: activeScreen(), width: size.width, height: size.height, lift: 14), display: true)
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
