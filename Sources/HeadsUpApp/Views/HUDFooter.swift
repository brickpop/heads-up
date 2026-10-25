import HeadsUpCore
import SwiftUI

/// The footer: keyboard hints on the left, or a toast in their place, and room on the
/// right for the Focus and Caffeine pills.
struct HUDFooter<Pills: View>: View {
    let left: FooterLeft
    /// Goes up with every toast, so a toast with the same text as the last is announced again.
    var toastID = 0
    /// The status pills on the right.
    @ViewBuilder var pills: Pills

    var body: some View {
        HStack(spacing: HUDStyle.Footer.hintGap) {
            switch left {
            case .hints(let hints):
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                    HintView(hint: hint)
                }
            case .toast(let text):
                ToastView(text: text)
            }
            Spacer(minLength: 0)
            pills
        }
        .font(.system(size: HUDStyle.Footer.fontSize))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, HUDStyle.Footer.padding)
        .onChange(of: toastID) {
            if case .toast(let text) = left {
                AccessibilityNotification.Announcement(text).post()
            }
        }
    }
}

extension HUDFooter where Pills == EmptyView {
    /// A footer with no pills, for previews.
    init(left: FooterLeft, toastID: Int = 0) {
        self.init(left: left, toastID: toastID, pills: { EmptyView() })
    }
}

/// One hint: its keycaps, then what they do.
private struct HintView: View {
    let hint: Hint

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            ForEach(Array(hint.keys.enumerated()), id: \.offset) { _, key in
                Keycap(key: key)
            }
            Text(hint.label)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A success message: the accent check and the text, in place of the hints for 2.6 s.
private struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            Image(systemName: Symbols.toastCheck)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(text)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
    }
}

#if DEBUG
    struct HUDFooterPreviews: PreviewProvider {
        private static let states: [FooterLeft] = [
            .hints(Strings.Hints.chat), .hints(Strings.Hints.suggestions), .hints(Strings.Hints.noMatch),
            .toast("Focus started · 25 min"),
        ]

        static var previews: some View {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 0) {
                    ForEach(Array(states.enumerated()), id: \.offset) { _, left in
                        HUDFooter(left: left).frame(height: HUDMetrics.footerHeight)
                    }
                }
                .frame(width: HUDLayout.maxWidth)
                .preferredColorScheme(scheme)
                .previewDisplayName(scheme == .light ? "Light" : "Dark")
            }
        }
    }
#endif
