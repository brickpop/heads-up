import Foundation

/// What the Focus tab shows at one moment, ready to draw: every string, choice and state the
/// view needs, so it holds no logic (contract, slice 3). The view calls
/// `FocusStore.screen(at:)` each second while the HUD shows.
public enum FocusScreen: Equatable, Sendable {
    case idle(Idle)
    case running(Running)
    case breakPrompt(BreakPrompt)
    case backPrompt(BackPrompt)
    case snoozed(Snoozed)

    public struct Idle: Equatable, Sendable {
        public let label: String
        /// The selected length as a timer: "25:00".
        public let timer: String
        public let today: String
        public let lengths: [LengthCard]
        public let breaksOffer: String
        public let start: String
    }

    /// One of the 25 / 40 / 50 cards.
    public struct LengthCard: Equatable, Sendable {
        public let minutes: Int
        public let title: String
        public let hint: String
        public let isSelected: Bool
        /// "40 min, Steady block, selected": what VoiceOver says for the card.
        public let accessibilityLabel: String
    }

    /// A focus or a break, running or paused.
    public struct Running: Equatable, Sendable {
        public let label: String
        public let timer: String
        public let timerAccessibility: String
        public let subtitle: String
        public let progress: Double
        /// "Stop" in a focus, "End break" in a break; both call `stopRun()`.
        public let stopTitle: String
        /// "Pause" or "Resume"; both call `togglePause()`.
        public let pauseTitle: String
        public let pauseGlyph: Glyph
    }

    public struct BreakPrompt: Equatable, Sendable {
        public let label: String
        public let title: String
        public let options: [OptionCard]
        public let lengths: [LengthChoice]
        /// The break length picked, in minutes: the one `lengths` marks selected.
        public let selectedLength: Int
        /// "Done": ends the loop, back to idle.
        public let done: String
        public let snooze: SnoozeGroup
        public let startBreak: String
    }

    /// "Snooze 2m | 5m | 10m", on both prompts. A segment snoozes for its length.
    public struct SnoozeGroup: Equatable, Sendable {
        /// "Snooze": the group's label, not a button.
        public let label: String
        public let choices: [SnoozeChoice]
    }

    /// One snooze length. `isDefault` marks Settings › Focus › Snooze length, which esc uses.
    public struct SnoozeChoice: Equatable, Sendable {
        public let minutes: Int
        /// "5m"
        public let title: String
        public let isDefault: Bool
        /// "Snooze, 5 minutes"
        public let accessibilityLabel: String
    }

    /// A break activity in the break prompt.
    public struct OptionCard: Equatable, Sendable {
        public let id: BreakOption.ID
        public let label: String
        public let glyph: Glyph
        /// "5 min"
        public let length: String
        public let isSelected: Bool
        /// "Walk, 5 min, selected": what VoiceOver says for the card.
        public let accessibilityLabel: String
    }

    /// One segment of the break length control.
    public struct LengthChoice: Equatable, Sendable {
        public let minutes: Int
        public let title: String
        public let isSelected: Bool
    }

    public struct BackPrompt: Equatable, Sendable {
        public let label: String
        public let title: String
        public let today: String
        /// The focus lengths to start: 25, 40 and 50, and the last focus's length if it was
        /// typed and isn't one of these. The selected one is the last focus's at first.
        public let lengths: [LengthCard]
        /// "Done": ends the loop, back to idle.
        public let done: String
        public let snooze: SnoozeGroup
        /// "Start 40 min focus", for the selected length.
        public let start: String
    }

    public struct Snoozed: Equatable, Sendable {
        public let label: String
        /// "Prompt returns in 4:12"
        public let title: String
        public let showNow: String
    }
}

/// Settings → Focus, ready to draw (contract, slice 3).
public struct FocusSettingsScreen: Equatable, Sendable {
    public let focusLength: Int
    public let snoozeMinutes: Int
    public let openHudOnEnd: Bool
    public let autoStartNextFocus: Bool
    public let options: [OptionChip]

    /// A break option chip, with its length pill and remove button.
    public struct OptionChip: Equatable, Sendable {
        public let id: BreakOption.ID
        public let label: String
        public let glyph: Glyph
        /// "5m"
        public let length: String
        /// False for the last option: there is always one to pick.
        public let canRemove: Bool
    }
}

extension FocusStore {
    /// The Focus tab at `now`. `locale` and `timeZone` set how "break at" reads (12 or 24 hours).
    public func screen(at now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> FocusScreen {
        switch phase {
        case .idle:
            return .idle(idleScreen())
        case .focus(let run):
            let breakAt = run.endsAt ?? now.addingTimeInterval(run.timeLeft(at: now))
            return .running(
                runningScreen(
                    run, now: now, label: run.isPaused ? Strings.Focus.focusPaused : Strings.Focus.focusing,
                    subtitle: Strings.Focus.sessionSubtitle(
                        minutes: run.minutes, breakAt: Self.clockTime(breakAt, locale: locale, timeZone: timeZone)),
                    stopTitle: Strings.Focus.stop))
        case .rest(let run, _):
            return .running(
                runningScreen(
                    run, now: now,
                    label: run.isPaused ? Strings.Focus.breakPaused : Strings.Focus.breakLabel(activity.label),
                    subtitle: Strings.Focus.breakSubtitle, stopTitle: Strings.Focus.endBreak))
        case .prompt(.breakPrompt(let manual)):
            return .breakPrompt(breakPromptScreen(manual: manual))
        case .prompt(.backPrompt):
            let next = nextFocusLength
            return .backPrompt(
                FocusScreen.BackPrompt(
                    label: Strings.Focus.breakFinished, title: Strings.Focus.readyToGetBack,
                    today: Strings.Focus.todayStats(today),
                    lengths: backPromptLengths.map { minutes in
                        let hint =
                            FocusSettings.focusLengths.contains(minutes)
                            ? Strings.Focus.lengthHint(minutes) : Strings.Focus.lastFocusHint
                        return lengthCard(minutes, hint: hint, selected: minutes == next)
                    },
                    done: Strings.Focus.done, snooze: snoozeGroup, start: Strings.Focus.startFocusOf(next)))
        case .snoozed(let until, _):
            return .snoozed(
                FocusScreen.Snoozed(
                    label: Strings.Focus.snoozedLabel,
                    title: Strings.Focus.promptReturns(Format.clock(until.timeIntervalSince(now))),
                    showNow: Strings.Focus.showNow))
        }
    }

    /// Settings → Focus now.
    public var settingsScreen: FocusSettingsScreen {
        let focus = settings.settings.focus
        let canRemove = canRemoveBreakOption
        return FocusSettingsScreen(
            focusLength: focus.focusLength, snoozeMinutes: focus.snoozeMinutes, openHudOnEnd: focus.openHudOnEnd,
            autoStartNextFocus: focus.autoStartNextFocus,
            options: focus.breakOptions.map { option in
                FocusSettingsScreen.OptionChip(
                    id: option.id, label: option.label, glyph: option.icon.glyph,
                    length: Strings.FocusSettings.minutesShort(option.length), canRemove: canRemove)
            })
    }

    /// Whether Add would add an option with this label: anything but blanks.
    public static func canAddBreakOption(label: String) -> Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// False while only one option is left.
    public var canRemoveBreakOption: Bool {
        settings.settings.focus.breakOptions.count > 1
    }

    /// Stop in a focus, End break in a break.
    public func stopRun() {
        switch phase {
        case .focus: stop()
        case .rest: endBreak()
        default: break
        }
    }

    /// Pause or Resume, whichever applies.
    public func togglePause() {
        switch phase {
        case .focus(let run), .rest(let run, _):
            if run.isPaused { resume() } else { pause() }
        default:
            break
        }
    }

    // MARK: Building the screens

    private func idleScreen() -> FocusScreen.Idle {
        FocusScreen.Idle(
            label: Strings.Focus.idleLabel, timer: Format.clock(Double(focusLength) * 60),
            today: Strings.Focus.todayStats(today),
            lengths: FocusSettings.focusLengths.map { minutes in
                lengthCard(minutes, hint: Strings.Focus.lengthHint(minutes), selected: minutes == focusLength)
            },
            breaksOffer: Strings.Focus.breaksOffer(settings.settings.focus.breakOptions),
            start: Strings.Focus.startFocus)
    }

    private func runningScreen(
        _ run: FocusRun, now: Date, label: String, subtitle: String, stopTitle: String
    ) -> FocusScreen.Running {
        let left = run.timeLeft(at: now)
        return FocusScreen.Running(
            label: label, timer: Format.clock(left),
            timerAccessibility: Strings.Focus.timeLeftAccessibility(Format.spokenMinutes(left, rounding: .up)),
            subtitle: subtitle, progress: run.progress(at: now), stopTitle: stopTitle,
            pauseTitle: run.isPaused ? Strings.Focus.resume : Strings.Focus.pause,
            pauseGlyph: run.isPaused ? .play : .pause)
    }

    private func breakPromptScreen(manual: Bool) -> FocusScreen.BreakPrompt {
        let options = settings.settings.focus.breakOptions
        let selected = activity.id
        let label =
            if let minutes = promptMinutes, !manual {
                Strings.Focus.sessionDone(minutes: minutes, today: today.sessions)
            } else if today.sessions == 0 {
                Strings.Focus.noSessionsYet
            } else {
                Strings.Focus.todayStats(today)
            }
        return FocusScreen.BreakPrompt(
            label: label, title: Strings.Focus.timeForABreak,
            options: options.map { option in
                FocusScreen.OptionCard(
                    id: option.id, label: option.label, glyph: option.icon.glyph,
                    length: Strings.Focus.minutes(option.length), isSelected: option.id == selected,
                    accessibilityLabel: Strings.Focus.cardAccessibility(
                        title: option.label, hint: Strings.Focus.minutes(option.length),
                        selected: option.id == selected))
            },
            lengths: FocusSettings.breakLengths.map { minutes in
                FocusScreen.LengthChoice(
                    minutes: minutes, title: Strings.Focus.minutes(minutes), isSelected: minutes == breakLength)
            },
            selectedLength: breakLength,
            done: Strings.Focus.done,
            snooze: snoozeGroup,
            startBreak: Strings.Focus.startBreak(breakLength))
    }

    private func lengthCard(_ minutes: Int, hint: String, selected: Bool) -> FocusScreen.LengthCard {
        let title = Strings.Focus.minutes(minutes)
        return FocusScreen.LengthCard(
            minutes: minutes, title: title, hint: hint, isSelected: selected,
            accessibilityLabel: Strings.Focus.cardAccessibility(title: title, hint: hint, selected: selected))
    }

    private var snoozeGroup: FocusScreen.SnoozeGroup {
        let standard = settings.settings.focus.snoozeMinutes
        return FocusScreen.SnoozeGroup(
            label: Strings.Focus.snooze,
            choices: FocusSettings.snoozeLengths.map { minutes in
                FocusScreen.SnoozeChoice(
                    minutes: minutes, title: Strings.Focus.snoozeChoice(minutes), isDefault: minutes == standard,
                    accessibilityLabel: Strings.Focus.snoozeAccessibility(minutes))
            })
    }

    /// A time of day as the user's clock shows it: "3:30 PM", or "15:30" in 24-hour locales.
    static func clockTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
