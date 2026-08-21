import AppKit

/// The small floating pill shown near the bottom of the screen while dictating.
///
/// It must never take keyboard focus away from the app being dictated into, so
/// it is a `.nonactivatingPanel` that explicitly refuses to become key or main.
@MainActor
final class FlowBar {
    enum State {
        case listening(locked: Bool)
        case transcribing
        case cleaning

        var caption: String {
            switch self {
            case .listening(let locked): locked ? "Hands-free — Esc to cancel" : "Listening…"
            case .transcribing: "Transcribing…"
            case .cleaning: "Polishing…"
            }
        }
    }

    private var panel: NonActivatingPanel?
    private let content = FlowBarView()
    private var meterTimer: Timer?

    var levelProvider: (() -> Float)?

    func show(_ state: State) {
        guard Settings.shared.flowBarEnabled else { return }
        content.caption = state.caption
        switch state {
        case .listening: content.showsMeter = true
        case .transcribing, .cleaning: content.showsMeter = false
        }

        if panel == nil {
            panel = makePanel()
        }
        position()
        panel?.orderFrontRegardless()
        content.needsDisplay = true
        startMeter(state)
    }

    func hide() {
        meterTimer?.invalidate()
        meterTimer = nil
        panel?.orderOut(nil)
    }

    /// Briefly show a message, then fade out. Used for errors and cancellations.
    func flash(_ message: String, seconds: TimeInterval = 1.4) {
        guard Settings.shared.flowBarEnabled else { return }
        content.caption = message
        content.showsMeter = false
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
        content.needsDisplay = true
        meterTimer?.invalidate()
        meterTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.content.caption == message else { return }
            self.hide()
        }
    }

    // MARK: - Private

    private func startMeter(_ state: State) {
        meterTimer?.invalidate()
        guard case .listening = state else {
            content.level = 0
            return
        }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.content.level = self.levelProvider?() ?? 0
                self.content.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func makePanel() -> NonActivatingPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = content
        return panel
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: 240, height: 44)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 90
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// `NSPanel` still becomes key for borderless windows unless told otherwise.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FlowBarView: NSView {
    var caption: String = "Listening…"
    var level: Float = 0
    var showsMeter: Bool = true

    private let barCount = 14

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        pill.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        var textOrigin = NSPoint(x: 16, y: bounds.midY - 7)

        if showsMeter {
            drawMeter(in: NSRect(x: 14, y: bounds.midY - 9, width: 62, height: 18))
            textOrigin.x = 86
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0)
        ]
        (caption as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func drawMeter(in rect: NSRect) {
        let spacing: CGFloat = 4
        let width: CGFloat = 2.5
        let clamped = CGFloat(max(0, min(1, level)))

        for index in 0..<barCount {
            let x = rect.minX + CGFloat(index) * spacing
            guard x + width <= rect.maxX else { break }
            // Taller in the middle so it reads as a waveform rather than a bar chart.
            let centre = CGFloat(barCount - 1) / 2
            let falloff = 1 - abs(CGFloat(index) - centre) / (centre + 1)
            let height = max(2, rect.height * clamped * falloff)
            let bar = NSRect(
                x: x,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
            let alpha = 0.35 + 0.65 * Double(clamped)
            NSColor(calibratedRed: 0.35, green: 0.78, blue: 1.0, alpha: alpha).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }
}
