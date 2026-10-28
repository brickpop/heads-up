import HeadsUpCore
import SwiftUI

/// The Caffeine tab: the header with its chip and the large switch, the refusal note, the
/// extend row while on with an end time, the four duration cards, and the options. It redraws
/// once a second from the core's display model while the HUD is open.
struct CaffeineView: View {
    let caffeine: CaffeineStore
    /// The HUD is open: only then does the view tick.
    let isOpen: Bool

    var body: some View {
        EverySecond(isRunning: isOpen) { now in
            CaffeineScreenView(caffeine: caffeine, screen: caffeine.screen(at: now))
        }
        .padding(.top, HUDStyle.Focus.topPadding)
        .padding(.horizontal, HUDStyle.Focus.sidePadding)
        .padding(.bottom, HUDStyle.Focus.bottomPadding)
    }
}

private struct CaffeineScreenView: View {
    let caffeine: CaffeineStore
    let screen: CaffeineScreen

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
                CaffeineHeader(caffeine: caffeine, header: screen.header)
                if let note = screen.assertionNote {
                    AssertionNoteView(caffeine: caffeine, note: note)
                }
            }
            if let extend = screen.extend {
                ExtendRow(caffeine: caffeine, extend: extend)
            }
            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                FocusLabel(text: screen.durationsLabel)
                HStack(spacing: HUDStyle.Focus.cardGap) {
                    ForEach(screen.durations, id: \.duration) { card in
                        FocusCard(isSelected: card.isSelected, select: { caffeine.selectDuration(card.duration) }) {
                            Text(card.title)
                                .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                        }
                    }
                }
            }
            SettingsList {
                ForEach(Array(screen.options.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Hairline() }
                    SettingsRow(title: row.title, help: row.help) {
                        Toggle(row.title, isOn: Binding(get: { row.isOn }, set: { caffeine.setOption(row.option, $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(!row.isEnabled)
                            .help(row.disabledHelp ?? "")
                    }
                }
            }
        }
    }
}

/// The chip, the title and subtitle, and the large switch.
private struct CaffeineHeader: View {
    let caffeine: CaffeineStore
    let header: CaffeineScreen.Header

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: HUDStyle.Caffeine.headerGap) {
            Image(systemName: Glyph.cup.symbolName)
                .font(.system(size: HUDStyle.Caffeine.chipIconSize))
                .foregroundStyle(header.chipAccent ? Color.white : Color.secondary)
                .frame(width: HUDStyle.Caffeine.chipSize, height: HUDStyle.Caffeine.chipSize)
                .background(
                    header.chipAccent ? Color.accentColor : HUDStyle.Colors.chip,
                    in: RoundedRectangle(cornerRadius: HUDStyle.Caffeine.chipCornerRadius)
                )
                .overlay(alignment: .bottomTrailing) {
                    if header.showsPauseBadge {
                        // Secondary, not warn: pausing on battery is the user's option working.
                        Image(systemName: Symbols.pauseBadge)
                            .font(.system(size: HUDStyle.Caffeine.badgeSize))
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.regularMaterial))
                    }
                }
                .animation(reduceMotion ? nil : HUDStyle.Motion.standard, value: header.chipAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(header.title)
                    .font(.system(size: HUDStyle.Caffeine.titleSize, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(header.subtitle)
                    .font(.system(size: HUDStyle.Focus.statsSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: HUDStyle.Focus.gap)
            Toggle(header.switchLabel, isOn: Binding(get: { header.isOn }, set: { _ in caffeine.toggle() }))
                .toggleStyle(.switch)
                .controlSize(.regular)
                .labelsHidden()
        }
    }
}

/// macOS refused to keep the Mac awake: a red note and Try Again. Announced when it appears.
private struct AssertionNoteView: View {
    let caffeine: CaffeineStore
    let note: CaffeineScreen.AssertionNote

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            ProblemNote(text: note.text)
            Button(note.tryAgain, action: caffeine.retry)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.leading, HUDStyle.Caffeine.chipSize + HUDStyle.Caffeine.headerGap)
        .announcing(note.text)
    }
}

/// "Need a bit longer?" with +10 min and +1 h, on the raised fill.
private struct ExtendRow: View {
    let caffeine: CaffeineStore
    let extend: CaffeineScreen.Extend

    var body: some View {
        HStack(spacing: HUDStyle.Focus.cardGap) {
            Text(extend.prompt)
                .font(.system(size: HUDStyle.Settings.labelSize))
            Spacer(minLength: HUDStyle.Focus.gap)
            ForEach(extend.buttons, id: \.minutes) { button in
                Button(button.title) { caffeine.extend(minutes: button.minutes) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(HUDStyle.Caffeine.extendPadding)
        .background(HUDStyle.Colors.raise, in: RoundedRectangle(cornerRadius: HUDStyle.Caffeine.extendCornerRadius))
    }
}
