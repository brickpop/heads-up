import CoreGraphics

/// The HUD frame's own sizes. Where the window goes on the screen, and how wide it is,
/// is the core's `HUDLayout`.
enum HUDMetrics {
    /// The radius of the HUD's corners. The material's mask and the border both use it.
    static let cornerRadius: CGFloat = 16
    /// The header area: 10 pt padding around the 44 pt tabs.
    static let headerHeight: CGFloat = 64
    /// The footer area with hints, toast and pill.
    static let footerHeight: CGFloat = 38
    /// The height of the HUD when it shows only the header and the footer.
    static var collapsedHeight: CGFloat { headerHeight + footerHeight }
}
