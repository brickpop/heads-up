import AppKit
import SwiftUI

/// The colors, sizes and motion of the HUD's parts, from the visual language and the
/// header, autocomplete and footer specs. The frame's sizes are in `HUDMetrics`, and the
/// window's placement is in the core's `HUDLayout`.
///
/// Colors are system colors, so they follow light and dark, the accent color and
/// Increase Contrast without extra code.
enum HUDStyle {
    enum Colors {
        /// How strong the gray fills are. `.stronger` is the default (Yuki's slice 1 review);
        /// set `.lighter` to compare with the first mapping on the Mac.
        static let fills = FillStrength.stronger

        /// `--line-strong`: hairlines and borders.
        static var line: Color { Color(nsColor: .separatorColor) }
        /// `--raise`: the active tab, and an inactive tab under the pointer.
        static var raise: Color {
            Color(nsColor: fills == .stronger ? .tertiarySystemFill : .quaternarySystemFill)
        }
        /// `--sel`: the selected suggestion. Gray, not accent-filled.
        static var selection: Color {
            Color(nsColor: fills == .stronger ? .secondarySystemFill : .tertiarySystemFill)
        }
        /// `--chip`: the square icon chips on rows.
        static var chip: Color {
            Color(nsColor: fills == .stronger ? .tertiarySystemFill : .quaternarySystemFill)
        }
        /// `--danger`: failures, as an icon, a dot or short text, never a large fill.
        static var alert: Color { .red }
        /// `--warn`: something the user should act on, as an icon or short text.
        static var warn: Color { .orange }
    }

    /// The two mappings of the gray fills to the system fill colors, one step apart.
    enum FillStrength {
        case lighter, stronger
    }

    /// The width of a hairline: one device pixel, or a full point with Increase Contrast.
    static func lineWidth(contrast: ColorSchemeContrast, displayScale: CGFloat) -> CGFloat {
        contrast == .increased ? 1 : 1 / displayScale
    }

    enum Header {
        static let padding: CGFloat = 10
        /// The space between tabs.
        static let gap: CGFloat = 6
    }

    enum Tabs {
        /// Tabs are 44 pt tall; an inactive tab is a 44 × 44 square.
        static let size: CGFloat = 44
        static let cornerRadius: CGFloat = 10
        static let iconSize: CGFloat = 18
        /// The horizontal padding inside the active tab.
        static let padding: CGFloat = 13
        /// The space between the active tab's icon and its prompt.
        static let gap: CGFloat = 10
        static let dotSize: CGFloat = 6
        /// The activity dot's distance from the tab's top-right corner.
        static let dotInset: CGFloat = 8
    }

    enum Prompt {
        static let fontSize: CGFloat = 16
    }

    enum Suggestions {
        /// The list's padding around its rows.
        static let padding: CGFloat = 8
        /// Past this height the list scrolls.
        static let maxHeight: CGFloat = 440
        static let chipSize: CGFloat = 34
        static let chipCornerRadius: CGFloat = 8
        static let chipIconSize: CGFloat = 15
        static let rowCornerRadius: CGFloat = 10
        static let rowVerticalPadding: CGFloat = 10
        static let rowHorizontalPadding: CGFloat = 12
        static let rowGap: CGFloat = 14
        /// A row with a chip: the chip plus its padding. Rows have a fixed height, so the
        /// list knows its height without measuring.
        static let rowHeight: CGFloat = chipSize + 2 * rowVerticalPadding
        /// The "No matching actions" line.
        static let noMatchHeight: CGFloat = 36
        static let titleSize: CGFloat = 14
        static let subtitleSize: CGFloat = 12
        static let kindSize: CGFloat = 12
        static let noMatchSize: CGFloat = 13
    }

    enum Footer {
        static let padding: CGFloat = 14
        static let fontSize: CGFloat = 12
        /// The space between hints, and between status pills.
        static let hintGap: CGFloat = 16
        /// The space between a hint's keycaps and its label.
        static let keyGap: CGFloat = 4
    }

    enum Notice {
        static let height: CGFloat = 36
        static let cornerRadius: CGFloat = 10
        static let padding: CGFloat = 12
        /// The space around the bar, inside the body.
        static let margin: CGFloat = 8
        static let gap: CGFloat = 8
        static let fontSize: CGFloat = 13
    }

    enum Keycap {
        static let height: CGFloat = 18
        static let cornerRadius: CGFloat = 4
        static let fontSize: CGFloat = 11
        static let padding: CGFloat = 5
    }

    enum Motion {
        /// 200 ms ease-out, `cubic-bezier(0, 0, .58, 1)`: tab widths and selection fills.
        /// No springs or bounces anywhere.
        static var standard: Animation { .timingCurve(0, 0, 0.58, 1, duration: 0.2) }
    }
}
