/// The Focus section of the action catalogue (Action autocomplete spec).
@MainActor
enum FocusActions {
    static func make(focus: FocusStore, hud: HUDStore) -> [Action] {
        var actions = FocusSettings.focusLengths.map { minutes in
            Action(
                id: ActionID("focus.start:\(minutes)"), title: Strings.Focus.startAction(minutes),
                subtitle: Strings.Focus.startSubtitle, kind: .focus, glyph: .timer,
                keywords: "pomodoro focus timer work start", suggest: .oneClick,
                run: { [weak focus, weak hud] in
                    focus?.start(minutes: minutes)
                    hud?.selectTab(.focus)
                })
        }
        switch focus.phase {
        case .focus, .rest:
            let isBreak = if case .rest = focus.phase { true } else { false }
            actions.append(
                Action(
                    id: ActionID("focus.stop"), title: Strings.Focus.stopAction,
                    subtitle: Strings.Focus.stopSubtitle(break: isBreak), kind: .focus, glyph: .stop,
                    keywords: "pomodoro focus timer stop end cancel", suggest: .oneClick,
                    run: { [weak focus] in focus?.stop() }))
        default:
            break
        }
        actions.append(
            Action(
                id: ActionID("focus.break"), title: Strings.Focus.breakNowAction,
                subtitle: Strings.Focus.breakNowSubtitle, kind: .focus, glyph: .droplet,
                keywords: "pomodoro break rest", suggest: .oneClick,
                run: { [weak focus, weak hud] in
                    focus?.takeBreakNow()
                    hud?.selectTab(.focus)
                }))
        return actions
    }
}
