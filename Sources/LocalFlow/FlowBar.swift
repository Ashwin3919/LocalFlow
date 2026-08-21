import AppKit

/// The floating waveform shown while dictating.
///
/// There is deliberately no background panel — just a dot and a row of bars
/// drawn straight onto the desktop, so it reads as floating rather than as a
/// piece of chrome sliding in. It must never take keyboard focus away from the
/// app being dictated into, so it is a `.nonactivatingPanel` that explicitly
/// refuses to become key or main.
@MainActor
final class FlowBar {
    enum State: Equatable {
        case listening(locked: Bool)
    }

    static let size = NSSize(width: 236, height: 44)

    private var panel: NonActivatingPanel?
    private let content = WaveformView()
    private var frameTimer: Timer?
    /// Invalidates an in-flight fade-out so a `flash` arriving mid-hide is not
    /// ordered off screen by the previous hide's completion handler.
    private var hideToken = 0

    /// Supplies the newest `n` loudness samples, oldest first.
    var levelsProvider: ((Int) -> [Float])?

    func show(_ state: State) {
        guard Settings.shared.flowBarEnabled else { return }
        content.apply(state: state)
        present()
        startAnimating()
    }

    func hide() {
        stopAnimating()
        guard let panel else { return }
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    /// Briefly show a message, then fade out. Used for errors and cancellations
    /// only — the success path never shows text, because it finishes faster
    /// than a label can be read.
    func flash(_ message: String, seconds: TimeInterval = 1.3) {
        guard Settings.shared.flowBarEnabled else { return }
        content.applyMessage(message)
        present()
        stopAnimating()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.content.currentMessage == message else { return }
            self.hide()
        }
    }

    // MARK: - Presentation

    private func present() {
        if panel == nil { build() }
        position()
        hideToken += 1          // cancel any pending fade-out
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel?.animator().alphaValue = 1
        }
        content.needsDisplay = true
    }

    private func build() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No window shadow: with a fully transparent window the shadow traces
        // the alpha of the bars themselves, which reads as fuzz, not depth.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        content.frame = NSRect(origin: .zero, size: Self.size)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        self.panel = panel
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: (visible.midX - Self.size.width / 2).rounded(),
            y: (visible.minY + 96).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
    }

    // MARK: - Animation

    private func startAnimating() {
        stopAnimating()
        // 30 fps is smooth to the eye and cheap: ~30 rounded rects per frame,
        // and it only runs while the bar is on screen.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.content.push(levels: self.levelsProvider?(WaveformView.barCount) ?? [])
                self.content.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopAnimating() {
        frameTimer?.invalidate()
        frameTimer = nil
    }
}

/// `NSPanel` still becomes key for borderless windows unless told otherwise.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The waveform

/// Draws a symmetric bar waveform that scrolls right-to-left.
///
/// Each bar is one loudness sample from `AudioRecorder`'s history, so the shape
/// on screen is the shape of what was actually said. Bars ease toward their
/// target height rather than snapping, which is what stops it strobing.
private final class WaveformView: NSView {
    static let barCount = 30

    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 3.2
    private let minimumBar: CGFloat = 3
    private let maximumBar: CGFloat = 26

    /// What is drawn this frame; chases `target`.
    private var displayed = [CGFloat](repeating: 0, count: WaveformView.barCount)
    private var target = [CGFloat](repeating: 0, count: WaveformView.barCount)

    private var isLocked = false
    private(set) var currentMessage: String?

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    // MARK: State

    func apply(state: FlowBar.State) {
        currentMessage = nil
        if case .listening(let locked) = state {
            isLocked = locked
        }
    }

    func applyMessage(_ message: String) {
        currentMessage = message
        target = [CGFloat](repeating: 0, count: Self.barCount)
    }

    /// Feed real loudness samples, oldest first.
    func push(levels: [Float]) {
        guard levels.count == Self.barCount else { return }
        for index in 0..<Self.barCount {
            target[index] = CGFloat(levels[index])
        }
        for index in 0..<Self.barCount {
            displayed[index] += (target[index] - displayed[index]) * 0.32
        }
    }

    // MARK: Theme

    /// White ink on dark, black ink on light. Resolved per frame rather than
    /// cached, so switching appearance takes effect on the next redraw with no
    /// observer to keep in sync.
    private var ink: NSColor {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .white
            : .black
    }

    /// A soft halo in the opposite colour. Without the old frosted panel the
    /// bars sit directly on whatever is behind them, so black ink over a dark
    /// terminal would otherwise vanish.
    private func applyHalo() {
        let shadow = NSShadow()
        shadow.shadowColor = (ink == .white ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let currentMessage {
            drawCentred(currentMessage)
            return
        }

        let dotX: CGFloat = 14
        NSGraphicsContext.saveGraphicsState()
        applyHalo()
        drawStateDot(at: NSPoint(x: dotX, y: bounds.midY))
        drawWaveform(in: NSRect(
            x: dotX + 16,
            y: bounds.minY,
            width: bounds.maxX - (dotX + 16) - 14,
            height: bounds.height
        ))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawStateDot(at centre: NSPoint) {
        let radius: CGFloat = 4
        let rect = NSRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        )
        // Amber while hands-free is locked, so "the mic is still live" is
        // visible at a glance; red for ordinary push-to-talk.
        let colour = isLocked
            ? NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.23, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.36, alpha: 1)
        colour.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawWaveform(in rect: NSRect) {
        let stride = barWidth + barGap
        let totalWidth = CGFloat(Self.barCount) * stride - barGap
        let startX = rect.minX + max(0, (rect.width - totalWidth) / 2)
        let base = ink

        for index in 0..<Self.barCount {
            let amplitude = max(0, min(1, displayed[index]))
            let height = minimumBar + (maximumBar - minimumBar) * amplitude
            let x = startX + CGFloat(index) * stride
            guard x + barWidth <= rect.maxX else { break }

            let bar = NSRect(
                x: x,
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
            // Quiet bars sit back rather than disappearing, so the row still
            // looks deliberate when you are not speaking.
            base.withAlphaComponent(0.28 + 0.72 * amplitude).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }

    private func drawCentred(_ text: String) {
        NSGraphicsContext.saveGraphicsState()
        applyHalo()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: ink.withAlphaComponent(0.85)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}
