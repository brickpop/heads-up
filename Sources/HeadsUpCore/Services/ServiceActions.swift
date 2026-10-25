/// The Services section of the action catalogue (Action autocomplete spec): Start or Stop for
/// each service by its state, and Restart for a running one. A model may only suggest them
/// with the user's confirmation, which shows the command and the folder (F1).
/// A service from services.json that breaks a rule has no Start: it can't start until fixed.
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
            if services.state(id).isLive {
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
            } else if definition.problems.isEmpty {
                actions.append(
                    Action(
                        id: ActionID("service.start:\(id)"), title: Strings.Services.startAction(definition.name),
                        subtitle: subtitle, kind: .service, glyph: .server,
                        keywords: "service server run start launch \(definition.command)",
                        suggest: confirmation(Strings.Services.startVerb),
                        run: { [weak services] in services?.start(id) }))
            }
        }
        return actions
    }
}
