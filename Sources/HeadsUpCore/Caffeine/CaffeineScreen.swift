import Foundation

/// What the Caffeine tab shows at one moment, ready to draw (contract, slice 4), as
/// `FocusScreen` does for Focus. The view calls `CaffeineStore.screen(at:)` each second.
public struct CaffeineScreen: Equatable, Sendable {
    public let header: Header
    /// "Need a bit longer?" with +10 min and +1 h, only while on with an end time.
    public let extend: Extend?
    public let durationsLabel: String
    public let durations: [DurationCard]
    public let options: [OptionRow]
    /// The --danger note under the header when macOS refused, with Try Again (`retry()`).
    public let assertionNote: AssertionNote?
    /// Under the header while Caffeine is on and services also keep the Mac awake, 12 pt
    /// --ink-2: "Web dev server also keeps your Mac awake while it runs."
    public let heldLine: String?
    /// Under the header in --warn when macOS refused a service's hold: "macOS didn't let HeadsUp
    /// keep your Mac awake for Web dev server."
    public let refusedLine: String?

    public struct Header: Equatable, Sendable {
        public let title: String
        public let subtitle: String
        /// The switch: on also while paused on battery.
        public let isOn: Bool
        /// The chip: accent fill with a white cup while on, neutral while off or paused.
        public let chipAccent: Bool
        /// The small pause badge on the chip, while paused on battery.
        public let showsPauseBadge: Bool
        /// The small server badge on the chip: Caffeine is off, and services keep the Mac awake.
        public let showsServerBadge: Bool
        public let switchLabel: String
    }

    public struct AssertionNote: Equatable, Sendable {
        public let text: String
        public let tryAgain: String
    }

    public struct Extend: Equatable, Sendable {
        public let prompt: String
        /// +10 min and +1 h; each calls `extend(minutes: button.minutes)`.
        public let buttons: [ExtendButton]
    }

    public struct ExtendButton: Equatable, Sendable {
        public let minutes: Int
        public let title: String
    }

    /// One of the four cards: 15 min, 1 hour, 2 hours, Until off.
    public struct DurationCard: Equatable, Sendable {
        public let duration: CaffeineDuration
        public let title: String
        /// The last-used duration.
        public let isSelected: Bool
        /// "1 hour, selected": what VoiceOver says for the card.
        public let accessibilityLabel: String
    }

    /// A switch in the options list.
    public struct OptionRow: Equatable, Sendable {
        public let option: CaffeineOption
        public let title: String
        public let help: String
        public let isOn: Bool
        /// False for the one of the first two that is the last one on.
        public let isEnabled: Bool
        /// The tooltip while disabled: "Keep at least one on."
        public let disabledHelp: String?
    }
}

extension CaffeineStore {
    /// The Caffeine tab at `now`. `locale` and `timeZone` set how "ends at" reads.
    public func screen(at now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> CaffeineScreen {
        let options = self.options
        let keepOneOn = Strings.Caffeine.keepOneOn
        return CaffeineScreen(
            header: header(at: now, locale: locale, timeZone: timeZone),
            extend: isOn && endsAt != nil
                ? CaffeineScreen.Extend(
                    prompt: Strings.Caffeine.needLonger,
                    buttons: CaffeineStore.extendMinutes.map {
                        CaffeineScreen.ExtendButton(minutes: $0, title: Strings.Caffeine.plus($0))
                    }) : nil,
            durationsLabel: Strings.Caffeine.keepAwakeFor,
            durations: CaffeineDuration.allCases.map { duration in
                CaffeineScreen.DurationCard(
                    duration: duration, title: Strings.Caffeine.cardTitle(duration),
                    isSelected: duration == lastDuration,
                    accessibilityLabel: Strings.Caffeine.cardAccessibility(duration, selected: duration == lastDuration)
                )
            },
            options: [
                CaffeineScreen.OptionRow(
                    option: .keepDisplayOn, title: Strings.Caffeine.keepDisplayOn,
                    help: Strings.Caffeine.keepDisplayOnHelp, isOn: options.keepDisplayOn,
                    isEnabled: !(options.keepDisplayOn && !options.preventSystemSleep),
                    disabledHelp: options.keepDisplayOn && !options.preventSystemSleep ? keepOneOn : nil),
                CaffeineScreen.OptionRow(
                    option: .preventSystemSleep, title: Strings.Caffeine.preventSystemSleep,
                    help: Strings.Caffeine.preventSystemSleepHelp, isOn: options.preventSystemSleep,
                    isEnabled: !(options.preventSystemSleep && !options.keepDisplayOn),
                    disabledHelp: options.preventSystemSleep && !options.keepDisplayOn ? keepOneOn : nil),
                CaffeineScreen.OptionRow(
                    option: .onlyOnAC, title: Strings.Caffeine.onlyOnAC, help: Strings.Caffeine.onlyOnACHelp,
                    isOn: options.onlyOnAC, isEnabled: true, disabledHelp: nil),
            ],
            assertionNote: assertionProblem.map {
                CaffeineScreen.AssertionNote(
                    text: Strings.Caffeine.assertionNote($0), tryAgain: Strings.Caffeine.tryAgain)
            },
            heldLine: isOn && !applying.isEmpty ? Strings.Caffeine.alsoKeeps(applying) : nil,
            refusedLine: refused.isEmpty ? nil : Strings.Caffeine.refusedFor(refused))
    }

    /// The services that keep the Mac awake, or would but for the battery, in list order.
    private var applying: [String] {
        serviceHolds().filter { $0.awake != .refused }.map(\.name)
    }

    private var refused: [String] {
        serviceHolds().filter { $0.awake == .refused }.map(\.name)
    }

    private func header(at now: Date, locale: Locale, timeZone: TimeZone) -> CaffeineScreen.Header {
        let switchLabel = Strings.Caffeine.switchLabel
        guard isOn else {
            let holds = serviceHolds()
            let holding = holds.filter { $0.awake == .holding }.map(\.name)
            let paused = holds.filter { $0.awake == .pausedOnBattery }.map(\.name)
            // Held by services: the Mac *is* kept awake, though Caffeine's switch stays off.
            if !holding.isEmpty {
                return CaffeineScreen.Header(
                    title: Strings.Caffeine.keptAwakeBy(holding), subtitle: Strings.Caffeine.subtitleKeptAwake(holding),
                    isOn: false, chipAccent: true, showsPauseBadge: false, showsServerBadge: true,
                    switchLabel: switchLabel)
            }
            if !paused.isEmpty {
                return CaffeineScreen.Header(
                    title: Strings.Caffeine.titlePaused, subtitle: Strings.Caffeine.subtitleHeldPaused(paused),
                    isOn: false, chipAccent: false, showsPauseBadge: true, showsServerBadge: false,
                    switchLabel: switchLabel)
            }
            return CaffeineScreen.Header(
                title: Strings.Caffeine.titleOff, subtitle: Strings.Caffeine.subtitleOff, isOn: false,
                chipAccent: false, showsPauseBadge: false, showsServerBadge: false, switchLabel: switchLabel)
        }
        let left = endsAt.map { Format.minutes($0.timeIntervalSince(now), rounding: .nearest) }
        let endTime = endsAt.map { FocusStore.clockTime($0, locale: locale, timeZone: timeZone) }
        if pausedOnBattery {
            let subtitle =
                if let left, let endTime {
                    Strings.Caffeine.subtitlePaused(left, endsAt: endTime)
                } else {
                    Strings.Caffeine.resumesOnPower
                }
            return CaffeineScreen.Header(
                title: Strings.Caffeine.titlePaused, subtitle: subtitle, isOn: true, chipAccent: false,
                showsPauseBadge: true, showsServerBadge: false, switchLabel: switchLabel)
        }
        let subtitle =
            if let left, let endTime {
                Strings.Caffeine.subtitleLeft(left, endsAt: endTime)
            } else {
                Strings.Caffeine.subtitleUntilOff
            }
        return CaffeineScreen.Header(
            title: Strings.Caffeine.titleOn, subtitle: subtitle, isOn: true, chipAccent: true, showsPauseBadge: false,
            showsServerBadge: false, switchLabel: switchLabel)
    }
}
