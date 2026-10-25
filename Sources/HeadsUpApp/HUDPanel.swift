import AppKit
import SwiftUI

/// The HUD window (ADR-001 §7): a borderless panel that takes key focus without
/// activating HeadsUp, so the app the user was in stays frontmost. It shows on every
/// Space and over full-screen apps. It is created once and shown and hidden after that.
///
/// The panel is clear and exactly the size of the HUD: `HUDFrameView` draws the rounded
/// material and border, and macOS draws the window shadow around the material's shape.
final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: HUDFrameView())
        // Slice 0: the panel owns the size (HUDMetrics), so the view sets no constraints of its own.
        // From slice 1 the content owns the height (ADR-001 amendment 1).
        hosting.sizingOptions = []
        contentView = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HUDPanel is never loaded from a nib")
    }

    // A borderless window can't become key unless it says so; the HUD needs key for typing.
    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Shows the HUD on the screen under the pointer and makes it key, without activating the app.
    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            return
        }
        let width = HUDMetrics.width(forScreenWidth: screen.frame.width)
        let height = HUDMetrics.collapsedHeight
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - HUDMetrics.topOffset - height,
            width: width,
            height: height
        )
        setFrame(frame, display: true)
        makeKeyAndOrderFront(nil)
        // The shadow follows the material's shape: redraw it once the window is on screen at its new size.
        invalidateShadow()
    }

    func hide() {
        orderOut(nil)
    }
}
