/// The Caffeine section of the action catalogue (Action autocomplete spec).
@MainActor
enum CaffeineActions {
    static func make(caffeine: CaffeineStore) -> [Action] {
        var actions: [Action] = []
        if caffeine.isOn && caffeine.endsAt != nil {
            for minutes in CaffeineStore.extendMinutes {
                actions.append(
                    Action(
                        id: ActionID("caffeine.extend:\(minutes)"), title: Strings.Caffeine.extendAction(minutes),
                        subtitle: Strings.Caffeine.extendSubtitle, kind: .caffeine, glyph: .plus,
                        keywords: "caffeine awake extend more add longer", suggest: .oneClick,
                        run: { [weak caffeine] in caffeine?.extend(minutes: minutes) }))
            }
        }
        if caffeine.isOn {
            actions.append(
                Action(
                    id: ActionID("caffeine.off"), title: Strings.Caffeine.offAction,
                    subtitle: Strings.Caffeine.offSubtitle, kind: .caffeine, glyph: .cup,
                    keywords: "caffeine awake sleep off stop", suggest: .oneClick,
                    run: { [weak caffeine] in caffeine?.turnOff() }))
        }
        for duration in [CaffeineDuration.oneHour, .twoHours, .untilOff] {
            actions.append(
                Action(
                    id: ActionID("caffeine.on:\(duration.rawValue)"), title: Strings.Caffeine.keepAwakeAction(duration),
                    subtitle: Strings.Caffeine.keepAwakeSubtitle, kind: .caffeine, glyph: .cup,
                    keywords: "caffeine awake sleep screensaver on", suggest: .oneClick,
                    run: { [weak caffeine] in caffeine?.keepAwake(duration) }))
        }
        return actions
    }
}
