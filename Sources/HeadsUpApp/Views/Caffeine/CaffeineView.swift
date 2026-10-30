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

    /// The focused duration card, while one is.
    @FocusState private var focusedCard: Int?

    var body: some View {
        let selected = screen.durations.firstIndex { $0.isSelected }
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
                CaffeineHeader(caffeine: caffeine, header: screen.header)
                if let note = screen.assertionNote {
                    AssertionNoteView(caffeine: caffeine, note: note)
                }
                // Services that also keep the Mac awake while Caffeine is on, then a service
                // hold macOS refused: under the header, past the chip.
                if let held = screen.heldLine {
                    HeaderLine(text: held, color: .secondary)
                }
                if let refused = screen.refusedLine {
                    // Announced once, when it's new, by RefusedHoldAnnouncer on the HUD's root.
                    HeaderLine(text: refused, color: HUDStyle.Colors.warn)
                }
            }
            if let extend = screen.extend {
                ExtendRow(caffeine: caffeine, extend: extend)
            }
            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                FocusLabel(text: screen.durationsLabel)
                HStack(spacing: HUDStyle.Focus.cardGap) {
                    ForEach(Array(screen.durations.enumerated()), id: \.element.duration) { index, card in
                        // A click turns Caffeine on with the card; the keyboard only picks it
                        // while off (`chooseDuration`).
                        FocusCard(
                            isSelected: card.isSelected, isTabStop: index == (selected ?? 0) || index == focusedCard,
                            focus: $focusedCard, index: index, select: { caffeine.selectDuration(card.duration) }
                        ) {
                            Text(card.title)
                                .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                        }
                    }
                }
                .cardGroupKeys(
                    labels: screen.durations.map(\.accessibilityLabel), selected: selected, focus: $focusedCard,
                    keyboardMoves: caffeine.cardMoves
                ) {
                    caffeine.chooseDuration(screen.durations[$0].duration)
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
                    // Secondary, not warn: pausing on battery is the user's option working. The
                    // server badge says a service, not Caffeine, keeps the Mac awake. The core
                    // never shows both.
                    if header.showsPauseBadge {
                        ChipBadge(symbol: Symbols.pauseBadge)
                    } else if header.showsServerBadge {
                        ChipBadge(symbol: Glyph.server.symbolName)
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

/// A small badge at the chip's bottom-right corner, on the material so it reads on either fill.
private struct ChipBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: HUDStyle.Caffeine.badgeSize))
            .foregroundStyle(.secondary)
            .background(Circle().fill(.regularMaterial))
    }
}

/// A 12 pt line under the header, starting under the title rather than the chip.
private struct HeaderLine: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Settings.helpSize))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, HUDStyle.Caffeine.chipSize + HUDStyle.Caffeine.headerGap)
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

/// Has VoiceOver say, once, that macOS refused a service's hold: when the refusal is new, while
/// the HUD is open, whichever tab shows. The refused line under the Caffeine header stays
/// silent, so visiting the tab doesn't repeat it (Rev).
struct RefusedHoldAnnouncer: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onChange(of: refused) { old, new in
            guard model.hud.isOpen else { return }
            let names = model.services.definitions.filter { new.contains($0.id) && !old.contains($0.id) }.map(\.name)
            guard !names.isEmpty else { return }
            AccessibilityNotification.Announcement(Strings.Caffeine.refusedFor(names)).post()
        }
    }

    /// The services whose hold macOS refused.
    private var refused: Set<ServiceDefinition.ID> {
        Set(model.services.awake.filter { $0.value == .refused }.keys)
    }
}
