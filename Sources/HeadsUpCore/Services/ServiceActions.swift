/// The Services section of the action catalogue (Action autocomplete spec): Start or Stop for
/// each service by its state, and Restart for a running one. A model may only suggest them
/// with the user's confirmation, which shows the command and the folder (F1).
/// A service from services.json that breaks a rule has no Start: it can't start until fixed.
/// While a restart waits, all three are offered: Start and Restart start it at once, and Stop
/// cancels the restart.
@MainActor
enum ServiceActions {
    static func make(services: ServiceStore) -> [Action] {
        var actions: [Action] = []
        for definition in services.definitions {
            let id = definition.id
            let subtitle = Strings.Services.actionSubtitle(command: definition.command, cwd: definition.cwd)
            func confirmation(_ verb: String) -> SuggestPolicy {
                .confirm(
                    Confirmation(verb: verb, name: definition.name, command: definition.command, cwd: definition.cwd))
            }
            let live = services.state(id).isLive
            let waiting = services.isWaitingToRestart(id)
            if (!live || waiting) && definition.problems.isEmpty {
                actions.append(
                    Action(
                        id: ActionID("service.start:\(id)"), title: Strings.Services.startAction(definition.name),
                        subtitle: subtitle, kind: .service, glyph: .server,
                        keywords: "service server run start launch \(definition.command)",
                        suggest: confirmation(Strings.Services.startVerb),
                        run: { [weak services] in services?.start(id) }))
            }
            if live || waiting {
                actions.append(
                    Action(
                        id: ActionID("service.stop:\(id)"), title: Strings.Services.stopAction(definition.name),
                        subtitle: subtitle, kind: .service, glyph: .server,
                        keywords: "service server run stop kill \(definition.command)",
                        suggest: confirmation(Strings.Services.stopVerb),
                        run: { [weak services] in services?.stop(id) }))
                actions.append(
                    Action(
                        id: ActionID("service.restart:\(id)"), title: Strings.Services.restartAction(definition.name),
                        subtitle: subtitle, kind: .service, glyph: .server,
                        keywords: "service server run restart \(definition.command)",
                        suggest: confirmation(Strings.Services.restartVerb),
                        run: { [weak services] in services?.restart(id) }))
            }
        }
        return actions
    }
}

extension ServiceActions {
    /// A suggested Start for a service already running, or a Stop or Restart for one that isn't:
    /// the button shows disabled, saying why (Yuki, slice 11).
    static func unavailable(_ id: SuggestedActionID, services: ServiceStore) -> UnavailableAction? {
        let parts = id.raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let definition = services.definitions.first(where: { $0.id == parts[1] }) else {
            return nil
        }
        let live = services.state(definition.id).isLive
        let stoppable = live || services.isWaitingToRestart(definition.id)
        switch parts[0] {
        case "service.start" where live:
            return UnavailableAction(
                title: Strings.Services.startAction(definition.name), glyph: .server,
                reason: Strings.Services.alreadyRunning(definition.name))
        case "service.stop" where !stoppable:
            return UnavailableAction(
                title: Strings.Services.stopAction(definition.name), glyph: .server,
                reason: Strings.Services.notRunning(definition.name))
        case "service.restart" where !stoppable:
            return UnavailableAction(
                title: Strings.Services.restartAction(definition.name), glyph: .server,
                reason: Strings.Services.notRunning(definition.name))
        default:
            return nil
        }
    }
}
