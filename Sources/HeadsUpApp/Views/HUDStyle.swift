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
        /// `--raise2`: the footer pills, and the model chip while its menu is open.
        static var raise2: Color { Color(nsColor: .secondarySystemFill) }
        /// `--track`: the empty part of a progress bar.
        static var track: Color { Color(nsColor: .tertiarySystemFill) }
        /// `--green`: a running service.
        static var running: Color { .green }
        /// `--code-bg`: log drawers and code blocks. Black at 4 % in light, 25 % in dark.
        static var codeBackground: Color {
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return NSColor.black.withAlphaComponent(dark ? 0.25 : 0.04)
                })
        }
        static var alert: Color { .red }
        /// `--warn`: something the user should act on, as an icon or short text.
        static var warn: Color { .orange }
    }

    /// The two mappings of the gray fills to the system fill colors, one step apart.
    enum FillStrength {
        case lighter, stronger
    }

    /// The extra space between lines that makes the line height `lineHeight` times the font size,
    /// from the system font's own metrics (SwiftUI's lineSpacing adds to the natural height).
    static func lineSpacing(size: CGFloat, lineHeight: CGFloat, monospaced: Bool = false) -> CGFloat {
        let font =
            monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let natural = font.ascender - font.descender + font.leading
        return max(0, size * lineHeight - natural)
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
        /// The padding above and below a two-line notice.
        static let detailPadding: CGFloat = 8
    }

    enum Settings {
        /// The Settings tab's height: its content's, between these two.
        static let minHeight: CGFloat = 380
        static let maxHeight: CGFloat = 480
        static let navWidth: CGFloat = 160
        static let navPadding: CGFloat = 8
        static let navRowHeight: CGFloat = 34
        static let navRowCornerRadius: CGFloat = 10
        static let navIconWidth: CGFloat = 18
        /// The space between groups of the sub-nav, around their hairline.
        static let navGroupGap: CGFloat = 6
        static let paneTopPadding: CGFloat = 16
        static let paneSidePadding: CGFloat = 20
        static let paneBottomPadding: CGFloat = 20
        /// The space between a section's title, its notes, cards and lists.
        static let sectionSpacing: CGFloat = 12
        static let titleSize: CGFloat = 18
        static let listCornerRadius: CGFloat = 12
        static let rowHorizontalPadding: CGFloat = 12
        static let rowVerticalPadding: CGFloat = 10
        static let labelSize: CGFloat = 13
        static let helpSize: CGFloat = 12
        /// Card padding, for the settings-file card.
        static let cardPadding: CGFloat = 16
    }

    enum Recorder {
        static let height: CGFloat = 26
        static let cornerRadius: CGFloat = 8
        static let padding: CGFloat = 6
        /// The accent border while recording.
        static let recordingBorder: CGFloat = 2
    }

    enum Welcome {
        static let iconSize: CGFloat = 48
        static let titleSize: CGFloat = 22
        static let padding: CGFloat = 24
        static let spacing: CGFloat = 16
        static let stepIconSize: CGFloat = 18
        static let stepsMaxWidth: CGFloat = 440
    }

    enum Focus {
        static let topPadding: CGFloat = 22
        static let sidePadding: CGFloat = 24
        static let bottomPadding: CGFloat = 24
        /// The space between a view's blocks.
        static let gap: CGFloat = 20
        static let labelSize: CGFloat = 11
        /// The big timer: SF Pro Display Light, tabular, tracking −1.5.
        static let timerSize: CGFloat = 64
        static let timerTracking: CGFloat = -1.5
        /// "Time for a break", "Ready to get back to it?"
        static let titleSize: CGFloat = 28
        /// "Prompt returns in 4:12"
        static let snoozedTitleSize: CGFloat = 22
        static let statsSize: CGFloat = 13
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 14
        static let cardGap: CGFloat = 10
        static let cardNumberSize: CGFloat = 22
        static let cardHintSize: CGFloat = 12
        /// The selected card's accent border.
        static let selectedBorder: CGFloat = 2
        static let optionMinWidth: CGFloat = 150
        static let optionChipSize: CGFloat = 30
        static let progressHeight: CGFloat = 6
    }

    enum Caffeine {
        static let chipSize: CGFloat = 56
        static let chipCornerRadius: CGFloat = 14
        static let chipIconSize: CGFloat = 24
        /// The pause badge on the chip while paused on battery.
        static let badgeSize: CGFloat = 20
        static let titleSize: CGFloat = 24
        static let headerGap: CGFloat = 14
        static let extendPadding: CGFloat = 12
        static let extendCornerRadius: CGFloat = 10
    }

    enum Services {
        static let padding: CGFloat = 8
        /// Past this height the tab scrolls.
        static let maxHeight: CGFloat = 480
        static let headerPadding: CGFloat = 12
        static let rowCornerRadius: CGFloat = 10
        static let rowPadding: CGFloat = 10
        static let rowGap: CGFloat = 12
        static let statusDotSize: CGFloat = 10
        /// The Start / Stop button's fixed width.
        static let buttonWidth: CGFloat = 84
        static let warningDotSize: CGFloat = 6
        static let drawerHeight: CGFloat = 180
        /// The drawer starts under the row's text, past the chip.
        static let drawerLeading: CGFloat = 60
        static let drawerCornerRadius: CGFloat = 8
        static let drawerPadding: CGFloat = 10
        static let logFontSize: CGFloat = 11.5
        /// Line height 1.6 at 11.5 pt.
        static let logLineSpacing: CGFloat = 7
        static let metaSize: CGFloat = 12
        static let emptyTitleSize: CGFloat = 15
        /// The space between a log line's time and its text.
        static let logTimeGap: CGFloat = 12
    }

    enum ServiceForm {
        static let portWidth: CGFloat = 100
        static let envKeyWidth: CGFloat = 160
    }

    enum ModelChip {
        static let height: CGFloat = 28
        static let padding: CGFloat = 10
        static let chevronSize: CGFloat = 9
    }

    enum ModelMenu {
        static let chipSize: CGFloat = 32
        static let rowPadding: CGFloat = 8
    }

    enum Endpoints {
        static let formCornerRadius: CGFloat = 12
        static let formPadding: CGFloat = 14
        static let gridGap: CGFloat = 10
        static let tagPadding: CGFloat = 6
    }

    enum Outline {
        static let height: CGFloat = 24
        static let padding: CGFloat = 8
        static let cornerRadius: CGFloat = 8
    }

    enum Chat {
        /// The conversation's height: its content's, between these two.
        static let minHeight: CGFloat = 160
        static let maxHeight: CGFloat = 440
        static let toolbarHeight: CGFloat = 40
        static let toolbarPadding: CGFloat = 18
        static let topPadding: CGFloat = 18
        static let sidePadding: CGFloat = 20
        static let bottomPadding: CGFloat = 20
        static let messageGap: CGFloat = 16
        static let blockGap: CGFloat = 10
        static let bodySize: CGFloat = 14
        /// Line heights, as multiples of the font size: replies, the user's bubble, and code.
        static let replyLineHeight: CGFloat = 1.55
        static let bubbleLineHeight: CGFloat = 1.5
        static let codeLineHeight: CGFloat = 1.6
        static let headingLineHeight: CGFloat = 1.2
        static let bubbleVerticalPadding: CGFloat = 9
        static let bubbleHorizontalPadding: CGFloat = 14
        static let bubbleRadius: CGFloat = 16
        /// The bubble's corner next to the user's side.
        static let bubbleTailRadius: CGFloat = 4
        static let userMaxWidth: CGFloat = 0.78
        static let assistantMaxWidth: CGFloat = 0.92
        static let thinkingDotSize: CGFloat = 7
        static let codeSize: CGFloat = 12.5
        /// The space on each side of inline code, inside the text (kerning, not characters).
        static let codeKern: CGFloat = 3
        /// How close to the bottom still counts as at the bottom, for following a reply.
        static let followSlack: CGFloat = 40
        static let codeHeaderHeight: CGFloat = 30
        static let codeRadius: CGFloat = 10
        static let codeVerticalPadding: CGFloat = 12
        static let codeHorizontalPadding: CGFloat = 14
        static let listMarkerWidth: CGFloat = 20
        static let listGap: CGFloat = 10
        static let listItemGap: CGFloat = 6
        static let listDotSize: CGFloat = 5
        static let quoteBarWidth: CGFloat = 3
        static let quotePadding: CGFloat = 12
        static let tableRadius: CGFloat = 10
        static let tableCellVertical: CGFloat = 7
        static let tableCellHorizontal: CGFloat = 12
        static let tableHeaderSize: CGFloat = 12
        static let tableCellSize: CGFloat = 13
        static let ruleMargin: CGFloat = 8
        static let rowChipSize: CGFloat = 22
        static let rowButtonHeight: CGFloat = 26
        /// Buttons waiting out the F6 guard.
        static let unarmedOpacity: Double = 0.5
        static let detailsLineLimit = 6
    }

    enum Attachments {
        /// A thumbnail in the header, before the prompt.
        static let headerSize: CGFloat = 30
        static let headerRadius: CGFloat = 6
        /// A thumbnail above the user's bubble.
        static let bubbleWidth: CGFloat = 120
        static let bubbleHeight: CGFloat = 80
        static let bubbleRadius: CGFloat = 10
        static let gap: CGFloat = 6
        static let badgeSize: CGFloat = 10
        /// The Pinned and Attach buttons in the Chat tab.
        static let buttonSize: CGFloat = 28
        /// The drop ring around the HUD while an image is dragged over it.
        static let dropRing: CGFloat = 2
        /// A collapsed HUD grows to this while something is dragged over it.
        static let dropMinHeight: CGFloat = 160
        static let dropIconSize: CGFloat = 28
    }

    enum Tools {
        static let rowChipSize: CGFloat = 22
        static let rowFontSize: CGFloat = 12
        static let separatorSize: CGFloat = 3
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 14
        static let cardChipSize: CGFloat = 36
        static let previewRadius: CGFloat = 6
        /// A Reminder title longer than this many lines gets Show all.
        static let reminderLines = 3
        static let eventTimeWidth: CGFloat = 96
        static let eventTimeHeight: CGFloat = 28
    }

    enum Actions {
        static let gap: CGFloat = 8
    }

    enum Pinned {
        static let saveDotSize: CGFloat = 6
    }

    enum Pill {
        static let height: CGFloat = 22
        static let padding: CGFloat = 8
        static let gap: CGFloat = 8
        static let iconGap: CGFloat = 4
    }

    enum FocusSettings {
        static let chipHeight: CGFloat = 30
        static let chipPadding: CGFloat = 10
        static let chipGap: CGFloat = 8
        static let lengthPillPadding: CGFloat = 6
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
