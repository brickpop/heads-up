import HeadsUpCore
import SwiftUI

/// Settings → Focus: the break options the prompt offers, a field to add one, and the
/// Focus list: focus length, auto-start, snooze length, and opening the HUD when a session ends.
struct FocusSection: View {
    let model: AppModel

    /// The option being typed, and its length, until Add.
    @State private var newLabel = ""
    @State private var newLength = FocusSettings.newOptionLength

    var body: some View {
        let focus = model.focus
        let screen = focus.settingsScreen
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: Strings.FocusSettings.title)
            SavingOffLine(settings: model.settings)
            Text(Strings.FocusSettings.intro)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: HUDStyle.FocusSettings.chipGap) {
                ForEach(screen.options, id: \.id) { chip in
                    BreakOptionChip(focus: focus, chip: chip)
                }
            }

            HStack(spacing: HUDStyle.FocusSettings.chipGap) {
                TextField(Strings.FocusSettings.addPlaceholder, text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Picker(Strings.FocusSettings.length, selection: $newLength) {
                    ForEach(FocusSettings.breakLengths, id: \.self) { minutes in
                        Text(Strings.FocusSettings.minutesShort(minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(Strings.FocusSettings.add, action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(!FocusStore.canAddBreakOption(label: newLabel))
            }
            Text(Strings.FocusSettings.lengthHint)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(.secondary)

            SettingsList {
                SettingsRow(title: Strings.FocusSettings.focusLength) {
                    segmented(
                        Strings.FocusSettings.focusLength, FocusSettings.focusLengths,
                        selection: screen.focusLength, title: Strings.FocusSettings.minutes, set: focus.setFocusLength)
                }
                Hairline()
                SettingsRow(title: Strings.FocusSettings.autoStart, help: Strings.FocusSettings.autoStartHelp) {
                    switchControl(Strings.FocusSettings.autoStart, isOn: screen.autoStartNextFocus) {
                        focus.setAutoStartNextFocus($0)
                    }
                }
                Hairline()
                SettingsRow(title: Strings.FocusSettings.snoozeLength) {
                    segmented(
                        Strings.FocusSettings.snoozeLength, FocusSettings.snoozeLengths,
                        selection: screen.snoozeMinutes, title: Strings.FocusSettings.minutes,
                        set: focus.setSnoozeMinutes)
                }
                Hairline()
                SettingsRow(title: Strings.FocusSettings.openHud, help: Strings.FocusSettings.openHudHelp) {
                    switchControl(Strings.FocusSettings.openHud, isOn: screen.openHudOnEnd) {
                        focus.setOpenHudOnEnd($0)
                    }
                }
            }
        }
    }

    /// Add, or Enter in the field: adds the option and empties the field for the next one.
    private func add() {
        guard FocusStore.canAddBreakOption(label: newLabel) else { return }
        model.focus.addBreakOption(label: newLabel, minutes: newLength)
        newLabel = ""
    }

    private func segmented(
        _ label: String, _ values: [Int], selection: Int, title: @escaping (Int) -> String,
        set: @escaping @MainActor (Int) -> Void
    ) -> some View {
        Picker(label, selection: Binding(get: { selection }, set: { set($0) })) {
            ForEach(values, id: \.self) { value in
                Text(title(value)).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func switchControl(
        _ label: String, isOn: Bool, set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { set($0) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

/// One break option: its icon in accent, its label, a length pill that cycles
/// 2 → 5 → 10 → 20 → 50 min, and × to remove it (disabled for the last one).
private struct BreakOptionChip: View {
    let focus: FocusStore
    let chip: FocusSettingsScreen.OptionChip

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            Image(systemName: chip.glyph.symbolName)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(chip.label)
                .font(.system(size: HUDStyle.Settings.labelSize))
            Button {
                focus.cycleBreakOptionLength(chip.id)
            } label: {
                Text(chip.length)
                    .font(.system(size: HUDStyle.Settings.helpSize, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, HUDStyle.FocusSettings.lengthPillPadding)
                    .background(HUDStyle.Colors.raise2, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Strings.FocusSettings.changeLength)
            .accessibilityLabel(Strings.FocusSettings.changeLength)
            .accessibilityValue(chip.length)
            Button {
                focus.removeBreakOption(chip.id)
            } label: {
                Image(systemName: Symbols.close)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!chip.canRemove)
            .help(chip.canRemove ? Strings.FocusSettings.remove : Strings.FocusSettings.keepOne)
            .accessibilityLabel(Strings.FocusSettings.remove)
        }
        .padding(.horizontal, HUDStyle.FocusSettings.chipPadding)
        .frame(height: HUDStyle.FocusSettings.chipHeight)
        .overlay(
            Capsule().strokeBorder(
                HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chip.label)
    }
}
