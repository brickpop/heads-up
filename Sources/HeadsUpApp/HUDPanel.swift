import AppKit
import HeadsUpCore
import SwiftUI

/// The HUD window (ADR-001 §7): a borderless panel that takes key focus without
/// activating HeadsUp, so the app the user was in stays frontmost. It shows on every
/// Space and over full-screen apps. It is created once and shown and hidden after that.
///
/// HUDStore drives it through the `HUDWindow` port, and it reports key changes back.
/// The panel is clear: `HUDFrameView` draws the rounded material and border, and macOS
/// draws the window shadow around the material's shape. `HUDLayout` places it and sets its
/// width, which no content changes; its height follows the SwiftUI content, growing downward
/// from a fixed top edge.
final class HUDPanel: NSPanel, HUDWindow {
    /// The HUD floats over other apps' windows and full-screen apps.
    static let hudLevel = NSWindow.Level.statusBar
    /// For HeadsUp's own panels and alerts, which must show above the HUD.
    static let aboveHUD = NSWindow.Level(rawValue: hudLevel.rawValue + 1)

    private let hud: HUDStore
    private let content: AnyView
    private let hosting: NSHostingController<AnyView>
    /// The HUD's width on its screen, which the content is laid out at.
    private var width = HUDLayout.maxWidth
    private var sizeObservation: NSKeyValueObservation?
    /// The frame of the screen the HUD shows on, while it shows. Every resize keeps its top edge.
    private var screenFrame: CGRect?
    /// Where the left button went down, to tell a click from a drag, and the modifier keys held.
    private var mouseDown: (point: NSPoint, modifiers: NSEvent.ModifierFlags)?
    /// How far the pointer may move between button down and up for it to count as a click.
    private static let clickSlop: CGFloat = 3

    init(hud: HUDStore, content: some View) {
        self.hud = hud
        self.content = AnyView(content)
        hosting = NSHostingController(rootView: Self.sized(self.content, width: width))
        // The content owns the height (ADR-001 amendment 1): it reports its ideal size, and
        // the panel takes the height from it. The width stays the panel's, from HUDLayout.
        hosting.sizingOptions = [.preferredContentSize]
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        level = Self.hudLevel
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

    // MARK: Clicks in the chat

    /// A plain click anywhere in the HUD while the conversation shows, on a message, between
    /// them or elsewhere, gives the keyboard back to the prompt. A drag that selected text keeps
    /// its selection and the keyboard, so ⌘C copies it. Buttons and links don't take the
    /// keyboard, so they leave it where it is.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown = (event.locationInWindow, event.modifierFlags)
            super.sendEvent(event)
            // Selectable text follows a drag in its own event loop and returns once the button
            // is up: then the click ended here, where the pointer is now.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                clickEnded(at: mouseLocationOutsideOfEventStream, clickCount: event.clickCount)
            }
        case .leftMouseUp:
            super.sendEvent(event)
            clickEnded(at: event.locationInWindow, clickCount: event.clickCount)
        default:
            super.sendEvent(event)
        }
    }

    private func clickEnded(at point: NSPoint, clickCount: Int) {
        guard let start = mouseDown else { return }
        mouseDown = nil
        // A double click selects a word, Shift extends a selection and Control opens its menu:
        // they keep the keyboard, like a drag.
        let plainKeys = start.modifiers.isDisjoint(with: [.shift, .control, .option, .command])
        let moved = hypot(point.x - start.point.x, point.y - start.point.y)
        guard clickCount == 1, plainKeys, moved <= Self.clickSlop,
            hud.tab == .chat, hud.chatView == .conversation
        else { return }
        // The prompt keeps the keyboard through a click on a button. After a click on a
        // message, or after a selection, a message's text holds it, or nothing does.
        if (firstResponder as? NSTextView)?.isEditable == true { return }
        NotificationCenter.default.post(name: .focusPrompt, object: self)
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
            let width = HUDLayout.frame(screen: screen, contentHeight: 0).width
            if width != self.width {
                self.width = width
                hosting.rootView = Self.sized(content, width: width)
            }
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

    // MARK: Permission prompts

    /// macOS is asking the user for a permission. Its prompt is another process's window, which
    /// can't be raised, so the HUD drops to the normal level under it, still in front of the
    /// other apps' windows. It is held open meanwhile: a click on the prompt takes the keyboard.
    func permissionPromptBegan() {
        hud.beginModal()
        level = .normal
        if isVisible { orderFrontRegardless() }
    }

    func permissionPromptEnded() {
        level = Self.hudLevel
        hud.endModal()
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

    /// The content at the HUD's width, with its top at the top of the window. The content
    /// then reports its height for that width, and a long line or a wide row wraps or is cut
    /// rather than widening the HUD. While the window catches up with a new height, the
    /// content stays under the header instead of moving up or down.
    private static func sized(_ content: AnyView, width: CGFloat) -> AnyView {
        AnyView(content.frame(width: width).frame(maxHeight: .infinity, alignment: .top))
    }

    /// Every resize, ours or AppKit's, keeps the width and the top edge where HUDLayout put
    /// them. AppKit resizes the window to the content's preferred size, which would otherwise
    /// move its left edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var anchored = frameRect
        if let screenFrame {
            let layout = HUDLayout.frame(screen: screenFrame, contentHeight: frameRect.height)
            anchored.origin.x = layout.minX
            anchored.size.width = layout.width
            anchored.origin.y = screenFrame.maxY - HUDLayout.topOffset - anchored.height
        }
        super.setFrame(anchored, display: flag)
        invalidateShadow()
    }
}
