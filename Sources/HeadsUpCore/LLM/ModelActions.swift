/// The model section of the action catalogue: "Switch model to …" for each model that isn't
/// active. A model may never suggest one (F1).
@MainActor
enum ModelActions {
    static func make(endpoints: EndpointService, select: @escaping @MainActor (Endpoint.ID) -> Void) -> [Action] {
        endpoints.endpoints.filter { $0.id != endpoints.activeID }.map { endpoint in
            let id = endpoint.id
            let provider = endpoint.tag.providerText
            return Action(
                id: ActionID("model.switch:\(id)"), title: Strings.Models.switchAction(endpoint.name),
                subtitle: Strings.Models.detail(provider: provider, model: endpoint.model), kind: .model, glyph: .cpu,
                keywords: "model switch use \(endpoint.name) \(provider) \(endpoint.model)", suggest: .never,
                run: { select(id) })
        }
    }
}
