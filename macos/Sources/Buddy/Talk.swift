import AppKit

// The conversation input: a Spotlight-style borderless field that appears next
// to buddy (double-click or menu). Enter submits, Esc dismisses.
final class TalkPanel: NSPanel {
    var onSubmit: ((String) -> Void)?
    private let field = NSTextField()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 37),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.98, alpha: 1).cgColor
        container.layer?.borderColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
        container.layer?.borderWidth = 3
        container.layer?.cornerRadius = 2

        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        field.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        field.placeholderString = "say something to buddy"
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.frame = NSRect(x: 10, y: 10, width: 260, height: 18)
        field.target = self
        field.action = #selector(submit)
        container.addSubview(field)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    func open(near spriteFrame: NSRect) {
        var x = spriteFrame.midX - frame.width / 2
        var y = spriteFrame.maxY + 8
        if let vis = NSScreen.main?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - frame.width - 4)
            if y + frame.height > vis.maxY { y = spriteFrame.minY - frame.height - 8 }
        }
        setFrameOrigin(NSPoint(x: x, y: y))
        field.stringValue = ""
        makeKeyAndOrderFront(nil)
        field.becomeFirstResponder()
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        orderOut(nil)
        guard !text.isEmpty else { return }
        onSubmit?(text)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
