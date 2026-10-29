import Foundation

/// A focus or a break of any length, typed in the prompt: `/start 35`, `/break 5 min`
/// (ADR-001 addendum: any length). Pure.
public enum QuickTimer: Equatable, Sendable {
    case focus(Int)
    case `break`(Int)
    case invalid(Problem)

    public enum Kind: Equatable, Sendable {
        case focus, `break`

        /// The lengths it may have, in whole minutes.
        public var range: ClosedRange<Int> {
            self == .focus ? FocusSettings.anyFocusRange : FocusSettings.anyBreakRange
        }
    }

    /// Why a typed command can't start: shown in a row that can't be picked.
    public enum Problem: Equatable, Sendable {
        /// 0, more than the bounds, or more digits than an `Int` holds.
        case outOfRange(Kind)
        /// Anything that isn't whole minutes: "/start abc", "/start 3.5".
        case notANumber(Kind)

        public var text: String {
            switch self {
            case .outOfRange(let kind): Strings.Focus.anyLengthBounds(kind)
            case .notANumber(let kind): Strings.Focus.typeTheMinutes(kind)
            }
        }
    }

    /// `/start` or `/break`, one space, whole minutes, then optionally `m` or `min`, with or
    /// without a space; any case. Nil for any other input, including the command word alone,
    /// which still filters the catalogue.
    public static func parse(_ query: String) -> QuickTimer? {
        let lowered = query.lowercased()
        let kind: Kind
        let rest: Substring
        if lowered.hasPrefix("/start ") {
            kind = .focus
            rest = lowered.dropFirst("/start ".count)
        } else if lowered.hasPrefix("/break ") {
            kind = .break
            rest = lowered.dropFirst("/break ".count)
        } else {
            return nil
        }
        let argument = rest.trimmingCharacters(in: .whitespaces)
        let digits = argument.prefix { $0.isASCII && $0.isNumber }
        let unit = argument.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, ["", "m", "min"].contains(unit) else { return .invalid(.notANumber(kind)) }
        guard let minutes = Int(digits), kind.range.contains(minutes) else { return .invalid(.outOfRange(kind)) }
        return kind == .focus ? .focus(minutes) : .break(minutes)
    }
}

/// The row a valid typed command puts on top: "Start 35 min focus" · "focus · ends 3:42 PM".
/// It is made for each query, outside the catalogue, so a model can never suggest it (F1).
@MainActor
enum QuickTimerActions {
    static func make(
        kind: QuickTimer.Kind, minutes: Int, focus: FocusStore, hud: HUDStore?, now: Date, calendar: Calendar
    ) -> Action {
        let isFocus = kind == .focus
        let ends = now.addingTimeInterval(Double(minutes) * focus.machine.secondsPerMinute)
        return Action(
            id: ActionID(isFocus ? "focus.start:any:\(minutes)" : "focus.break:any:\(minutes)"),
            title: isFocus ? Strings.Focus.startAction(minutes) : Strings.Focus.takeBreakAction(minutes),
            subtitle: replaces(focus.phase, now: now)
                ?? Strings.Focus.endsSubtitle(break: !isFocus, at: Format.time(ends, calendar: calendar)),
            kind: .focus, glyph: isFocus ? .timer : .droplet, keywords: "", suggest: .never,
            run: { [weak focus, weak hud] in
                if isFocus { focus?.start(minutes: minutes) } else { focus?.takeBreak(minutes: minutes) }
                hud?.selectTab(.focus)
            })
    }

    /// "replaces your focus · 12 min left", while a focus or a break runs or is paused.
    private static func replaces(_ phase: FocusPhase, now: Date) -> String? {
        switch phase {
        case .focus(let run):
            Strings.Focus.replaces(break: false, minutesLeft: Format.wholeMinutes(run.timeLeft(at: now), rounding: .up))
        case .rest(let run, _):
            Strings.Focus.replaces(break: true, minutesLeft: Format.wholeMinutes(run.timeLeft(at: now), rounding: .up))
        case .idle, .prompt, .snoozed:
            nil
        }
    }
}
