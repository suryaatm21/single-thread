import AppKit
import SingleThreadCore

/// A borderless, click-through window that sits directly above one target
/// window and dims, blurs, and labels it.
final class OverlayWindow: NSWindow {
    let targetID: UInt32
    private let content: OverlayContentView

    init(targetID: UInt32) {
        self.targetID = targetID
        content = OverlayContentView(frame: .zero)
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Normal level, ordered right above the target: a floating overlay
        // would also cover the focused window wherever the two overlap.
        level = .normal
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ spec: OverlaySpec, appKitFrame: CGRect) {
        if frame != appKitFrame {
            setFrame(appKitFrame, display: false)
        }
        content.apply(spec)
    }
}

final class OverlayContentView: NSView {
    static let amber = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.0, alpha: 1)
    static let cornerRadius: CGFloat = 12

    private let blurView = NSVisualEffectView()
    private let dimView = NSView()
    private let labelBox = NSView()
    private let titleField = OverlayContentView.makeField(weight: .semibold)
    private let subtitleField = OverlayContentView.makeField(weight: .regular)
    private let statusField = OverlayContentView.makeField(weight: .medium)
    private let stack = NSStackView()
    /// Topmost subview, so the blur and dim views never paint over the border.
    private let borderView = NSView()
    private var lastSpec: OverlaySpec?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        blurView.blendingMode = .behindWindow
        blurView.material = .hudWindow
        // The app is never active; without this the view drops to its
        // inactive look, which has no blur.
        blurView.state = .active
        blurView.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        blurView.autoresizingMask = [.width, .height]
        addSubview(blurView)

        dimView.wantsLayer = true
        dimView.autoresizingMask = [.width, .height]
        addSubview(dimView)

        labelBox.wantsLayer = true
        // Opaque enough to stay readable in dim-only mode, where text behind is sharp.
        labelBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        labelBox.layer?.cornerRadius = 14
        labelBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelBox)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(subtitleField)
        stack.addArrangedSubview(statusField)
        stack.setCustomSpacing(8, after: subtitleField)
        labelBox.addSubview(stack)

        NSLayoutConstraint.activate([
            labelBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: labelBox.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: labelBox.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: labelBox.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: labelBox.bottomAnchor, constant: -14),
        ])

        borderView.wantsLayer = true
        borderView.layer?.borderColor = Self.amber.cgColor
        borderView.layer?.cornerRadius = Self.cornerRadius
        borderView.layer?.borderWidth = 4
        borderView.autoresizingMask = [.width, .height]
        borderView.isHidden = true
        addSubview(borderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        updateFonts()
    }

    func apply(_ spec: OverlaySpec) {
        guard spec != lastSpec else { return }
        let previous = lastSpec
        lastSpec = spec

        blurView.isHidden = !spec.style.blur
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(spec.style.dimAlpha).cgColor

        if let label = spec.label {
            labelBox.isHidden = false
            titleField.stringValue = label.title
            subtitleField.stringValue = label.subtitle ?? ""
            subtitleField.isHidden = label.subtitle == nil
            statusField.stringValue = label.status ?? ""
            statusField.isHidden = label.status == nil
            statusField.textColor = spec.needsAttention ? Self.amber : NSColor.white.withAlphaComponent(0.75)
        } else {
            labelBox.isHidden = true
        }

        if spec.needsAttention != previous?.needsAttention {
            setAttention(spec.needsAttention)
        }
        updateFonts()
    }

    private func setAttention(_ on: Bool) {
        borderView.isHidden = !on
        borderView.layer?.removeAllAnimations()
        guard on else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderView.layer?.add(pulse, forKey: "pulse")
    }

    /// Scales the label with the window so small windows stay legible.
    private func updateFonts() {
        let base = min(bounds.width, bounds.height)
        let titleSize = max(15, min(30, base / 14))
        titleField.font = .systemFont(ofSize: titleSize, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: max(11, titleSize * 0.5), weight: .regular)
        statusField.font = .systemFont(ofSize: max(12, titleSize * 0.55), weight: .medium)
    }

    private static func makeField(weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.textColor = .white
        field.alignment = .center
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.font = .systemFont(ofSize: 15, weight: weight)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// Resizable rounded-rect mask; behind-window blur ignores layer corner
    /// masks, so the effect view needs its own.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
