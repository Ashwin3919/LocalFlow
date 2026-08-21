import AppKit

/// The small floating pill shown near the bottom of the screen while dictating.
///
/// It must never take keyboard focus away from the app being dictated into, so
/// it is a `.nonactivatingPanel` that explicitly refuses to become key or main.
@MainActor
final class FlowBar {
    enum State: Equatable {
        case listening(locked: Bool)
        case transcribing
        case cleaning

        var caption: String? {
            switch self {
            case .listening: nil          // the waveform speaks for itself
            case .transcribing: "Transcribing"
            case .cleaning: "Polishing"
            }
        }
    }

    static let size = NSSize(width: 224, height: 44)

    private var panel: NonActivatingPanel?
    private var effect: NSVisualEffectView?
    private let content = WaveformView()
    private var frameTimer: Timer?

    /// Supplies the newest `n` loudness samples, oldest first.
    var levelsProvider: ((Int) -> [Float])?

    func show(_ state: State) {
        guard Settings.shared.flowBarEnabled else { return }
        content.apply(state: state)
        present()
        startAnimating(for: state)
    }

    func hide() {
        stopAnimating()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Briefly show a message, then fade out. Used for errors and cancellations.
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // A frosted background reads as part of macOS and adapts to light and
        // dark automatically, which a flat fill does not.
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.size.height / 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)

        panel.contentView = effect
        self.panel = panel
        self.effect = effect
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

    private func startAnimating(for state: State) {
        stopAnimating()
        // 30 fps is smooth to the eye and cheap: ~30 rounded rects per frame,
        // and it only runs while the bar is on screen.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .listening = state {
                    let levels = self.levelsProvider?(WaveformView.barCount) ?? []
                    self.content.push(levels: levels)
                } else {
                    self.content.advanceIndeterminate()
                }
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

    private var caption: String?
    private var isLocked = false
    private var indeterminatePhase: CGFloat = 0
    private(set) var currentMessage: String?

    override var isFlipped: Bool { false }
    // Vibrancy blends fills into the frosted backdrop, which mutes the blue and
    // cyan into grey. The caption still uses an adaptive system colour.
    override var allowsVibrancy: Bool { false }

    // MARK: State

    func apply(state: FlowBar.State) {
        currentMessage = nil
        caption = state.caption
        if case .listening(let locked) = state {
            isLocked = locked
        }
    }

    func applyMessage(_ message: String) {
        currentMessage = message
        caption = message
        target = [CGFloat](repeating: 0, count: Self.barCount)
    }

    /// Feed real loudness samples, oldest first.
    func push(levels: [Float]) {
        guard levels.count == Self.barCount else { return }
        for index in 0..<Self.barCount {
            target[index] = CGFloat(levels[index])
        }
        ease()
    }

    /// A slow travelling ripple for states where there is no microphone input,
    /// so "working on it" looks different from "listening to you".
    func advanceIndeterminate() {
        indeterminatePhase += 0.16
        for index in 0..<Self.barCount {
            let position = CGFloat(index) / CGFloat(Self.barCount - 1)
            let wave = sin(position * .pi * 2.2 - indeterminatePhase)
            // Fade the ripple out at both ends so it does not look clipped.
            let envelope = sin(position * .pi)
            target[index] = max(0, wave) * envelope * 0.32
        }
        ease()
    }

    private func ease() {
        for index in 0..<Self.barCount {
            displayed[index] += (target[index] - displayed[index]) * 0.32
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // A caption replaces the waveform entirely — a wave with no audio
        // behind it would be lying about what the app is doing.
        if let caption, currentMessage != nil {
            drawCentred(caption)
            return
        }

        let dotX: CGFloat = 16
        drawStateDot(at: NSPoint(x: dotX, y: bounds.midY))

        var waveRect = NSRect(
            x: dotX + 14,
            y: bounds.minY,
            width: bounds.maxX - (dotX + 14) - 16,
            height: bounds.height
        )

        if let caption {
            let captionWidth = drawCaption(caption, rightAlignedIn: bounds)
            waveRect.size.width -= captionWidth + 10
        }

        drawWaveform(in: waveRect)
    }

    private func drawStateDot(at centre: NSPoint) {
        let radius: CGFloat = 4
        let rect = NSRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        )
        // Amber while hands-free is locked, so the mode is visible at a glance.
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
            colour(forBar: index, amplitude: amplitude).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }

    /// Blue on the left easing to cyan on the right — the same family as the
    /// waveform glyph in the menu bar, so the two read as one app.
    private func colour(forBar index: Int, amplitude: CGFloat) -> NSColor {
        let position = CGFloat(index) / CGFloat(Self.barCount - 1)
        let from = NSColor(calibratedRed: 0.35, green: 0.55, blue: 1.00, alpha: 1)
        let to = NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.98, alpha: 1)
        let blended = from.blended(withFraction: position, of: to) ?? to
        // Quiet bars sit back rather than disappearing, so the row of dots
        // still looks deliberate when you are not speaking.
        let alpha = 0.30 + 0.70 * amplitude
        return blended.withAlphaComponent(alpha)
    }

    @discardableResult
    private func drawCaption(_ text: String, rightAlignedIn rect: NSRect) -> CGFloat {
        let attributes = Self.captionAttributes
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: rect.maxX - size.width - 16, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
        return size.width
    }

    private func drawCentred(_ text: String) {
        let attributes = Self.captionAttributes
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor
    ]
}
