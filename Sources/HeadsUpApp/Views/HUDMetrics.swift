import CoreGraphics

/// The HUD window's layout values. Every HUD view and the panel read their sizes from here,
/// so each value is written only once.
enum HUDMetrics {
    /// The HUD's width on a screen that is wide enough.
    static let width: CGFloat = 760
    /// The total room kept free between the HUD and the screen's left and right edges.
    static let screenMargin: CGFloat = 32
    /// The distance from the top of the screen (menu bar included) to the HUD's top edge.
    static let topOffset: CGFloat = 108
    /// The radius of the HUD's corners. The material's mask and the border both use it.
    static let cornerRadius: CGFloat = 16
    /// The header area: 10 pt padding around the 44 pt tabs.
    static let headerHeight: CGFloat = 64
    /// The footer area with hints, toast and pill.
    static let footerHeight: CGFloat = 38
    /// The height of the HUD when it shows only the header and the footer.
    static var collapsedHeight: CGFloat { headerHeight + footerHeight }

    /// The HUD's width on a screen of the given width: 760 pt, or less on a narrow screen.
    static func width(forScreenWidth screenWidth: CGFloat) -> CGFloat {
        min(width, screenWidth - screenMargin)
    }
}
