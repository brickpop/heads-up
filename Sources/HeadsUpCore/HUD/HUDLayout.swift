import Foundation

/// Where the HUD window goes on a screen (App shell spec, "HUD window"). The panel calls this
/// with the screen's frame in macOS screen coordinates, where y grows upward.
public enum HUDLayout {
    /// The HUD's width on a screen that is wide enough.
    public static let maxWidth: CGFloat = 760
    /// The total room kept free between the HUD and the screen's left and right edges.
    public static let screenMargin: CGFloat = 32
    /// From the top of the screen (menu bar included) to the HUD's top edge.
    public static let topOffset: CGFloat = 108
    /// The least room kept free below the HUD.
    public static let bottomMargin: CGFloat = 16

    /// The screen the HUD opens on: the one under the pointer, else the first (the main screen).
    public static func screen(under mouse: CGPoint, in screens: [CGRect]) -> CGRect? {
        screens.first { $0.contains(mouse) } ?? screens.first
    }

    /// The HUD's frame: centred, 760 pt wide or less on a narrow screen, its top edge 108 pt
    /// below the top of the screen. It grows downward with its content, and stops short of
    /// the bottom of the screen, where its body scrolls instead.
    public static func frame(screen: CGRect, contentHeight: CGFloat) -> CGRect {
        let width = min(maxWidth, screen.width - screenMargin)
        let top = screen.maxY - topOffset
        let height = max(0, min(contentHeight, top - screen.minY - bottomMargin))
        return CGRect(x: screen.midX - width / 2, y: top - height, width: width, height: height)
    }
}
