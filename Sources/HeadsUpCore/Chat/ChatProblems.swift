import Foundation

extension ChatStore {
    /// A problem row, ready to draw (UX part 1, §4; addendum 3, F7; addendum 4, the step limit).
    /// Once the user sends another message, or acts on it, it keeps its words without buttons.
    func row(_ problem: Problem, now: Date) -> ProblemRow {
        var row = content(problem)
        if problem.isSuperseded { row.buttons = [] }
        if let starting = problem.starting {
            row.text = starting
            row.buttons = []
        }
        return ProblemRow(
            id: problem.id, icon: row.icon, title: row.title, text: row.text, details: row.details,
            buttons: row.buttons, record: row.record, isArmed: guardAllows(problem.shownAt),
            armedAt: armedAt(problem.shownAt))
    }

    private struct Content {
        var icon: ProblemRow.Icon
        var title: String
        var text: String?
        var details: String?
        var buttons: [RowButton]
        var record: String?
    }

    private func content(_ problem: Problem) -> Content {
        func button(_ action: ProblemAction, _ title: String, primary: Bool = false, at date: Date? = nil) -> RowButton
        {
            RowButton(action: action, title: title, isPrimary: primary, enabledAt: date)
        }
        let tryAgain = button(.tryAgain, Strings.Chat.tryAgain)
        let editEndpoint = button(.editEndpoint, Strings.Chat.editEndpoint)
        switch problem.kind {
        case .noEndpoint:
            return Content(
                icon: .info, title: Strings.Chat.noModelTitle, text: Strings.Chat.noModelText,
                buttons: [button(.openSettings, Strings.Chat.openSettings, primary: true), tryAgain])
        case .stepLimit(let steps, let endpointID, let continued):
            let model = modelName(endpointID)
            return Content(
                icon: .info, title: Strings.Chat.stepLimitTitle(model, steps: steps),
                text: continued ? nil : Strings.Chat.stepLimitText,
                buttons: continued ? [] : [button(.continueAfterLimit, Strings.Chat.continueTitle)],
                record: continued ? Strings.Chat.stepLimitRecord(steps: steps) : nil)
        case .error(let error, let endpointID):
            let model = modelName(endpointID)
            switch error {
            case .offline:
                return Content(
                    icon: .warn, title: Strings.Chat.offlineTitle, text: Strings.Chat.offlineText, buttons: [tryAgain])
            case .unreachable(let host):
                return Content(
                    icon: .warn, title: Strings.Chat.unreachableTitle(sanitizeForDisplay(host, max: 80)),
                    text: Strings.Chat.unreachableText, buttons: [tryAgain])
            case .timeout:
                return Content(icon: .warn, title: Strings.Chat.timeoutTitle(model), buttons: [tryAgain])
            case .needsToken, .badToken:
                return Content(
                    icon: .danger, title: Strings.Chat.tokenTitle(model),
                    text: error == .needsToken ? Strings.Chat.needsTokenText : Strings.Chat.badTokenText,
                    buttons: [editEndpoint, tryAgain])
            case .rateLimited(let retryAfter):
                let seconds = retryAfter.map { Int($0.components.seconds) }
                return Content(
                    icon: .warn, title: Strings.Chat.busyTitle(model), text: Strings.Chat.busyText(seconds: seconds),
                    buttons: [
                        button(
                            .tryAgain, Strings.Chat.tryAgain,
                            at: seconds.map { problem.shownAt.addingTimeInterval(TimeInterval($0)) })
                    ])
            case .serverDown:
                let endpoint = endpoints.endpoint(endpointID)
                let server = endpoint.map { sanitizeForDisplay($0.tag.providerText, max: 64) } ?? model
                let service = endpoint.flatMap(endpoints.service(for:))
                var buttons = [tryAgain]
                if let service {
                    buttons.insert(
                        button(
                            .startService, Strings.Chat.start(sanitizeForDisplay(service.name, max: 64)), primary: true),
                        at: 0)
                }
                return Content(
                    icon: .warn, title: Strings.Chat.notRunningTitle(server), text: Strings.Chat.notRunningText,
                    buttons: buttons)
            case .modelMissing(let id):
                return Content(
                    icon: .danger, title: Strings.Chat.modelMissingTitle(sanitizeForDisplay(id, max: 80)),
                    text: Strings.Chat.modelMissingText, buttons: [editEndpoint])
            case .contextTooLong:
                return Content(
                    icon: .warn, title: Strings.Chat.tooLongTitle(model), text: Strings.Chat.tooLongText,
                    buttons: [button(.newChat, Strings.Chat.newChat), button(.switchModel, Strings.Chat.switchModel)])
            case .redirected(let host):
                return Content(
                    icon: .danger, title: Strings.Chat.redirectedTitle(model, host: sanitizeForDisplay(host, max: 80)),
                    text: Strings.Chat.redirectedText, buttons: [editEndpoint])
            case .server(let status, let message):
                return Content(
                    icon: .danger, title: Strings.Chat.serverTitle(model, status: status),
                    details: message.isEmpty ? nil : sanitizeForDisplay(message, max: 2000), buttons: [tryAgain])
            case .badResponse:
                return Content(
                    icon: .danger, title: Strings.Chat.badResponseTitle(model), text: Strings.Chat.badResponseText,
                    buttons: [tryAgain])
            case .keychainDenied:
                return Content(
                    icon: .danger, title: Strings.Chat.keychainDeniedTitle, text: Strings.Chat.keychainDeniedText,
                    buttons: [tryAgain])
            }
        }
    }

    /// The model's name for a row, cleaned for the app's own text (F16).
    private func modelName(_ endpointID: Endpoint.ID) -> String {
        sanitizeForDisplay(endpoints.endpoint(endpointID)?.name ?? Strings.Chat.theModel, max: 64)
    }
}
