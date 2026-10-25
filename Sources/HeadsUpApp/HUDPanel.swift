import AppKit
import HeadsUpCore
import SwiftUI

/// The HUD window (ADR-001 §7): a borderless panel that takes key focus without
/// activating HeadsUp, so the app the user was in stays frontmost. It shows on every
/// Space and over full-screen apps. It is created once and shown and hidden after that.
///
/// HUDStore drives it through the `HUDWindow` port, and it reports key changes back.
/// The panel is clear: `HUDFrameView` draws the rounded material and border, and macOS
/// draws the window shadow around the material's shape. `HUDLayout` places it; its height
/// follows the SwiftUI content, growing downward from a fixed top edge.
final class HUDPanel: NSPanel, HUDWindow {
    private let hud: HUDStore
    private let hosting: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?
    /// The frame of the screen the HUD shows on, while it shows. Every resize keeps its top edge.
    private var screenFrame: CGRect?

    init(hud: HUDStore, content: some View) {
        self.hud = hud
        hosting = NSHostingController(rootView: AnyView(content))
        // The content owns the height (ADR-001 amendment 1): it reports its ideal size, and
        // the panel takes the height from it. The width stays the panel's, from HUDLayout.
        hosting.sizingOptions = [.preferredContentSize]
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
        contentViewController = hosting

        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HUDPanel is never loaded from a nib")
    }

    // A borderless window can't become key unless it says so; the HUD needs key for typing.
    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        hud.didBecomeKey()
    }

    override func resignKey() {
        super.resignKey()
        hud.didResignKey()
    }

    // MARK: HUDWindow

    /// Shows the HUD on the screen under the pointer. An auto-open (`makeKey` false) shows over
    /// other windows while the keyboard stays with the user's app.
    func show(makeKey: Bool) {
        if !isVisible {
            // NSScreen.screens starts with the main screen, the fallback.
            guard
                let screen = HUDLayout.screen(
                    under: NSEvent.mouseLocation, in: NSScreen.screens.map(\.frame))
            else { return }
            screenFrame = screen
            setFrame(HUDLayout.frame(screen: screen, contentHeight: contentHeight), display: true)
        }
        if makeKey {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
        // The shadow follows the material's shape: redraw it once the window is on screen.
        invalidateShadow()
    }

    func hide() {
        orderOut(nil)
        screenFrame = nil
    }

    // MARK: Size

    /// The SwiftUI content's height, or the collapsed height before it has reported one.
    private var contentHeight: CGFloat {
        let preferred = hosting.preferredContentSize.height
        return preferred > 0 ? preferred : HUDMetrics.collapsedHeight
    }

    private func fitToContent() {
        guard let screenFrame else { return }
        let next = HUDLayout.frame(screen: screenFrame, contentHeight: contentHeight)
        guard next != frame else { return }
        setFrame(next, display: true)
    }

    /// Every resize, ours or AppKit's, keeps the top edge where HUDLayout put it.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var anchored = frameRect
        if let screenFrame {
            anchored.origin.y = screenFrame.maxY - HUDLayout.topOffset - anchored.height
        }
        super.setFrame(anchored, display: flag)
        invalidateShadow()
    }
}
