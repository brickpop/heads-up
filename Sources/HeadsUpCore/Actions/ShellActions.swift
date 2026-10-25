/// The actions of the HUD itself: the theme, Add a model, and Go to <tab>.
/// Each feature's slice adds its own provider, in catalogue order.
@MainActor
enum ShellActions {
    /// "Add a model", shown while there is no model to chat with.
    static func addModel(hud: HUDStore, chat: HUDChat) -> [Action] {
        guard chat.askTarget == .noModel else { return [] }
        return [
            Action(
                id: ActionID("model.add"), title: Strings.Actions.addModel,
                subtitle: Strings.Actions.addModelSubtitle, kind: .model, glyph: .cpu,
                keywords: "model llm endpoint add ollama openai", suggest: .never,
                run: { [weak hud] in hud?.showSettings(.models) })
        ]
    }

    /// "Toggle theme" flips the appearance you see now and stores it as a choice;
    /// "Use system appearance" shows once a choice is stored (UX part 2, §17).
    static func theme(settings: SettingsStore, appearance: SystemAppearance) -> [Action] {
        let current = settings.settings.general.appearance
        let systemIsDark = appearance.isDark
        let effectiveDark = current == .dark || (current == .system && systemIsDark)
        var actions = [
            Action(
                id: ActionID("theme.toggle"), title: Strings.Actions.toggleTheme,
                subtitle: Strings.Actions.toggleThemeSubtitle(current: current, systemIsDark: systemIsDark),
                kind: .action, glyph: .sliders, keywords: "theme dark light appearance", suggest: .never,
                run: { [weak settings] in settings?.update { $0.general.appearance = effectiveDark ? .light : .dark } })
        ]
        if current != .system {
            actions.append(
                Action(
                    id: ActionID("theme.system"), title: Strings.Actions.useSystemAppearance,
                    subtitle: Strings.Actions.useSystemSubtitle(current: current),
                    kind: .action, glyph: .sliders, keywords: "theme dark light appearance system", suggest: .never,
                    run: { [weak settings] in settings?.update { $0.general.appearance = .system } }))
        }
        return actions
    }

    /// "Go to <tab>", one per tab.
    static func goTo(hud: HUDStore) -> [Action] {
        Tab.allCases.map { tab in
            Action(
                id: ActionID("view.open:\(tab.rawValue)"), title: Strings.Actions.goTo(tab),
                subtitle: Strings.Actions.goToSubtitle(tab), kind: .view, glyph: tab.glyph,
                keywords: "open view go \(tab.rawValue)\(tab == .focus ? " pomodoro" : "")", suggest: .oneClick,
                run: { [weak hud] in hud?.selectTab(tab) })
        }
    }
}
