import AppKit

final class BuddyPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

protocol SpriteViewDelegate: AnyObject {
    func spriteDragStarted()
    func spriteDragged(to origin: NSPoint)
    func spriteDragEnded()
    func spritePoked()
}

final class SpriteView: NSView {
    weak var delegate: SpriteViewDelegate?
    // Dropped during evolution: buddy cannot be carried mid-brain-surgery.
    var dragEnabled = true
    private var dragging = false
    private var downPointInWindow: NSPoint = .zero
    private let sprite = CALayer()
    // Accessory overlay (glasses, hats, ...) - sublayer of sprite so facing
    // flips carry it along automatically.
    private let prop = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.magnificationFilter = .nearest
        sprite.minificationFilter = .nearest
        sprite.frame = bounds
        prop.magnificationFilter = .nearest
        prop.minificationFilter = .nearest
        prop.frame = sprite.bounds
        sprite.addSublayer(prop)
        layer?.addSublayer(sprite)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = bounds
        prop.frame = sprite.bounds
        CATransaction.commit()
    }

    func setImage(_ img: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = img
        CATransaction.commit()
    }

    func setProp(_ img: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        prop.contents = img
        CATransaction.commit()
    }

    func setFacingLeft(_ left: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.setAffineTransform(left ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        sprite.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        downPointInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, let win = window else { return }
        if !dragging {
            let d = hypot(event.locationInWindow.x - downPointInWindow.x,
                          event.locationInWindow.y - downPointInWindow.y)
            if d < 4 { return }
            dragging = true
            delegate?.spriteDragStarted()
        }
        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - downPointInWindow.x, y: mouse.y - downPointInWindow.y)
        win.setFrameOrigin(origin)
        delegate?.spriteDragged(to: origin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            delegate?.spriteDragEnded()
        } else {
            delegate?.spritePoked()
        }
        dragging = false
    }
}

final class SpeechBubble {
    private let panel: BuddyPanel
    private let label: NSTextField
    private let container: NSView
    private var hideTimer: Timer?
    private let maxTextWidth: CGFloat = 220
    private let padding: CGFloat = 10

    var isVisible: Bool { panel.isVisible }
    // Fires when the bubble goes away - the controller uses it to strip props
    // that were worn for the line being spoken.
    var onHide: (() -> Void)?

    init() {
        panel = BuddyPanel(size: NSSize(width: 240, height: 60))
        panel.ignoresMouseEvents = true

        container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        container.layer?.borderColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
        container.layer?.borderWidth = 3
        container.layer?.cornerRadius = 2

        label = NSTextField(wrappingLabelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        label.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false

        container.addSubview(label)
        panel.contentView = container
    }

    func show(_ text: String, near spriteFrame: NSRect, seconds: Double) {
        hideTimer?.invalidate()
        label.stringValue = text
        // Measure with the field's own cell so wrapping matches rendering exactly.
        let fit = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxTextWidth, height: 600))
        let textW = ceil(fit.width) + 2
        let textH = ceil(fit.height) + 2
        label.frame = NSRect(x: padding, y: padding, width: textW, height: textH)
        panel.setContentSize(NSSize(width: textW + padding * 2, height: textH + padding * 2))
        reposition(near: spriteFrame)
        panel.orderFrontRegardless()
        hideTimer = commonTimer(max(1.5, seconds), repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func reposition(near spriteFrame: NSRect) {
        let size = panel.frame.size
        var x = spriteFrame.midX - size.width / 2
        var y = spriteFrame.maxY + 8
        let screen = NSScreen.screens.first { $0.frame.intersects(spriteFrame) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
            if y + size.height > vis.maxY { y = spriteFrame.minY - size.height - 8 }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
        onHide?()
    }
}
