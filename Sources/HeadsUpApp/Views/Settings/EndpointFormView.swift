import HeadsUpCore
import SwiftUI

/// The add or edit form under the endpoints, on the raised fill: name, model id, base URL with
/// its http note, the token in a secure field, the vision and tools options, the linked service,
/// Test connection with its result, and Add or Save. When the host changed with a saved token,
/// the buttons turn into the token question (F7).
struct EndpointFormView: View {
    let model: AppModel
    let form: EndpointFormScreen

    var body: some View {
        let endpoints = model.endpoints
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            FocusLabel(text: form.label)
            Grid(horizontalSpacing: HUDStyle.Endpoints.gridGap, verticalSpacing: HUDStyle.Endpoints.gridGap) {
                GridRow(alignment: .top) {
                    FormField(label: Strings.EndpointForm.name, problem: nil) {
                        TextField(Strings.EndpointForm.name, text: draft(form.name) { $0.name = $1 })
                    }
                    FormField(label: Strings.EndpointForm.modelID, problem: nil) {
                        TextField(Strings.EndpointForm.modelID, text: draft(form.modelID) { $0.modelID = $1 })
                            .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                    }
                }
                GridRow(alignment: .top) {
                    FormField(label: Strings.EndpointForm.baseURL, problem: nil) {
                        TextField(
                            Strings.EndpointForm.baseURL, text: draft(form.baseURL) { $0.baseURL = $1 },
                            prompt: Text(Strings.EndpointForm.baseURLPlaceholder)
                        )
                        .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                        if let note = form.baseURLNote {
                            Text(note.text)
                                .font(.system(size: HUDStyle.Settings.helpSize))
                                .foregroundStyle(note.style == .danger ? HUDStyle.Colors.alert : HUDStyle.Colors.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    FormField(label: Strings.EndpointForm.token, help: form.tokenHelp, problem: nil) {
                        // The token is only ever typed here. It is never shown back or spoken.
                        SecureField(
                            Strings.EndpointForm.token,
                            text: Binding(
                                get: { endpoints.draftToken },
                                set: { token in endpoints.updateDraft { $0.token = token } }),
                            prompt: Text(form.tokenPlaceholder)
                        )
                        .disabled(!form.tokenEnabled)
                        if let remove = form.removeToken {
                            Button(remove) { endpoints.removeToken() }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                        if let note = form.tokenRemovalNote {
                            HStack(spacing: HUDStyle.Footer.keyGap) {
                                Text(note)
                                    .font(.system(size: HUDStyle.Settings.helpSize))
                                    .foregroundStyle(.secondary)
                                if let keep = form.keepToken {
                                    Button(keep) { endpoints.keepToken() }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                }
                            }
                        }
                        if let problem = form.tokenProblem {
                            HStack(spacing: HUDStyle.Footer.keyGap) {
                                ProblemNote(text: problem)
                                if let tryAgain = form.tokenProblemTryAgain {
                                    Button(tryAgain) { endpoints.saveForm() }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HUDStyle.Settings.sectionSpacing) {
                    Toggle(
                        Strings.EndpointForm.images,
                        isOn: Binding(get: { form.imagesOn }, set: { on in endpoints.updateDraft { $0.imagesOn = on } })
                    )
                    Toggle(
                        Strings.EndpointForm.tools,
                        isOn: Binding(get: { form.toolsOn }, set: { on in endpoints.updateDraft { $0.toolsOn = on } }))
                }
                .toggleStyle(.checkbox)
                Text(form.optionsHelp)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
            }

            if let picker = form.service {
                Picker(
                    picker.label,
                    selection: Binding(
                        get: { picker.selectedID },
                        set: { id in endpoints.updateDraft { $0.serviceID = id } })
                ) {
                    ForEach(picker.choices, id: \.id) { choice in
                        Text(choice.title).tag(choice.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            if let result = form.result {
                TestResultView(model: model, result: result)
            }

            switch form.bar {
            case .none:
                HStack {
                    Spacer()
                    if let cancel = form.cancel {
                        Button(cancel) { endpoints.cancelForm() }
                            .buttonStyle(.borderless)
                    }
                    Button(form.test) { endpoints.testConnection() }
                        .buttonStyle(.bordered)
                        .disabled(!form.testEnabled)
                    Button(form.primary) { endpoints.saveForm() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!form.primaryEnabled)
                }
            case .tokenHost(let question, let keep, let remove):
                HStack {
                    Text(question)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(remove) { endpoints.answerTokenHost(keep: false) }
                        .buttonStyle(.borderless)
                    Button(keep) { endpoints.answerTokenHost(keep: true) }
                        .buttonStyle(.bordered)
                }
                .onAppear { AccessibilityNotification.Announcement(question).post() }
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: HUDStyle.Settings.labelSize))
        .padding(HUDStyle.Endpoints.formPadding)
        .background(HUDStyle.Colors.raise, in: RoundedRectangle(cornerRadius: HUDStyle.Endpoints.formCornerRadius))
    }

    /// A text binding to one field of the core's draft.
    private func draft(
        _ value: String, _ write: @escaping (inout EndpointDraft, String) -> Void
    ) -> Binding<String> {
        Binding(get: { value }, set: { text in model.endpoints.updateDraft { write(&$0, text) } })
    }
}

/// Test connection's result under the form: a spinner while it runs, then a green check, an
/// orange triangle with the server's models to pick from, or a red × with Start and Details.
private struct TestResultView: View {
    let model: AppModel
    let result: TestResultScreen

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            HStack(spacing: HUDStyle.Footer.keyGap) {
                switch result.style {
                case .running:
                    ProgressView().controlSize(.small)
                case .ok:
                    Image(systemName: Symbols.toastCheck).foregroundStyle(HUDStyle.Colors.running)
                case .warn:
                    Image(systemName: Symbols.warning).foregroundStyle(HUDStyle.Colors.warn)
                case .error:
                    Image(systemName: Symbols.failedDot).foregroundStyle(HUDStyle.Colors.alert)
                }
                Text(result.text)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .fixedSize(horizontal: false, vertical: true)
                if let start = result.start {
                    Button(start) { model.startTestService() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let openServices = result.openServices {
                    Button(openServices) { model.openTestServiceLogs() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let tryAgain = result.tryAgain {
                    Button(tryAgain) { model.endpoints.testConnection() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            // A menu of the server's models: picking one fills Model id. Nothing shows as chosen
            // before the user picks.
            if let models = result.models, !models.isEmpty, let prompt = result.modelPrompt {
                Menu(prompt) {
                    ForEach(models, id: \.self) { id in
                        Button(id) { model.endpoints.pickModel(id) }
                    }
                }
                .fixedSize()
            }
            if let details = result.details {
                DisclosureGroup(Strings.EndpointForm.details) {
                    Text(details)
                        .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: HUDStyle.Settings.helpSize))
            }
        }
        .onAppear { AccessibilityNotification.Announcement(result.text).post() }
        .onChange(of: result.text) { _, text in AccessibilityNotification.Announcement(text).post() }
    }
}
