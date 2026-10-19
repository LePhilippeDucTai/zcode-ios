import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Autorisation d'un outil : résumé, détail repliable, une option par bouton, consigne écrite si l'hôte l'accepte.
struct PermissionCard: View {
    let prompt: PermissionPrompt
    let respond: (InteractionAnswer) -> Void
    /// Calculé à la création de la carte : un diff local ne doit pas être refait à chaque frappe dans la consigne.
    private let preview: PermissionPreview?

    init(prompt: PermissionPrompt, respond: @escaping (InteractionAnswer) -> Void) {
        self.prompt = prompt
        self.respond = respond
        preview = prompt.preview
    }
    @State private var feedback = ""
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.request.summary).font(.callout).textSelection(.enabled)
            switch preview {
            case .diff(let diff)?:
                VStack(alignment: .leading, spacing: 4) {
                    if let path = diff.path {
                        DiffStatsLabel(path: path, additions: diff.additions, deletions: diff.deletions)
                    }
                    DiffView(file: diff, maxLines: 200)
                }
            case .command(let command, let description)?:
                if let description { Text(description).font(.caption).foregroundStyle(.secondary) }
                CodeBlock(language: nil, code: "$ " + String(command.prefix(20_000)), copyText: command)
            case .fetch(let url, let instruction)?:
                Text(url).font(.callout.monospaced()).lineLimit(3).textSelection(.enabled)
                if let instruction { Text(instruction).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
            case .text(let text)?:
                DisclosureGroup("Détails", isExpanded: $showingDetail) {
                    CodeBlock(language: nil, code: String(text.prefix(20_000)))
                }
                .font(.callout)
            case nil:
                EmptyView()
            }
            ForEach(prompt.buttons, id: \.optionId) { option in
                Button(role: option.kind == .deny ? .destructive : nil) { respond(prompt.answer(option, feedback: feedback)) } label: {
                    Text(ChatLabels.permissionOption(option)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .fontWeight(option.kind == .allowOnce ? .semibold : .regular)
                .accessibilityIdentifier("interaction-option-\(option.optionId)")
            }
            if let option = prompt.feedbackOption {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(option.optionId == PermissionPrompt.refineOptionId
                              ? "Ce qu'il faut changer…" : "Refuser et dire à l'agent quoi faire…",
                              text: $feedback, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("interaction-feedback")
                    Button("Envoyer") {
                        if let answer = prompt.answer(withFeedback: feedback) { respond(answer) }
                    }
                    .disabled(prompt.answer(withFeedback: feedback) == nil)
                    .accessibilityIdentifier("interaction-feedback-send")
                }
            }
        }
    }
}

/// Questions de l'agent, une à la fois (choix simple : passe à la suite ; choix multiple ; réponse libre).
struct QuestionsCard: View {
    let respond: (InteractionAnswer) -> Void
    /// Première action de l'utilisateur : suspend le compte à rebours.
    let touched: () -> Void
    @State private var form: QuestionForm

    init(questions: [UserInputQuestion], respond: @escaping (InteractionAnswer) -> Void, touched: @escaping () -> Void) {
        _form = State(initialValue: QuestionForm(questions: questions))
        self.respond = respond
        self.touched = touched
    }

    var body: some View {
        if let question = form.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let header = question.header, !header.isEmpty {
                        Text(header).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if form.questions.count > 1 {
                        Text("\(form.index + 1)/\(form.questions.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(question.question).font(.callout).textSelection(.enabled)
                ForEach(question.options, id: \.value) { option in
                    Button { choose(option.value) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: question, option.value)).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                if let description = option.description, !description.isEmpty {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(form.isSelected(option.value) ? .isSelected : [])
                    .accessibilityIdentifier("interaction-choice-\(option.value)")
                }
                TextField("Autre réponse…", text: Binding(
                    get: { form.customAnswer },
                    set: { touched(); form.setCustom($0) }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("interaction-feedback")
                HStack {
                    if form.canGoBack {
                        Button("Précédent") { touched(); form.back() }
                            .accessibilityIdentifier("interaction-back")
                    }
                    Button("Ignorer", role: .cancel) { respond(.decline) }
                        .accessibilityIdentifier("interaction-decline")
                    Spacer()
                    Button(form.isLast ? "Envoyer" : "Continuer") {
                        touched()
                        if form.isLast { respond(form.answer) } else { form.next() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("interaction-submit")
                }
            }
        }
    }

    private func choose(_ value: String) {
        touched()
        if form.choose(value) { respond(form.answer) }           // dernière question en choix simple : envoyée
    }

    private func icon(for question: UserInputQuestion, _ value: String) -> String {
        let selected = form.isSelected(value)
        if question.multiSelect == true { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

/// Plan à valider (ExitPlanMode) : approuver et implémenter, demander des changements, ou refuser.
struct PlanApprovalCard: View {
    let request: UserInputRequest
    let respond: (InteractionAnswer) -> Void
    @State private var feedback = ""
    @State private var showingPlan = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = request.planText {
                // Extrait seulement : un long plan pousserait les boutons hors de la zone visible du dock.
                MarkdownText(markdown: plan)
                    .frame(maxHeight: 160, alignment: .top)
                    .clipped()
                Button("Lire le plan en entier") { showingPlan = true }.font(.caption)
            } else {
                Text(request.questions?.first?.question ?? request.prompt).font(.callout)
            }
            Button { respond(PlanApproval.approve(request)) } label: {
                Text("Approuver et implémenter").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("interaction-submit")
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Demander des changements…", text: $feedback, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("interaction-feedback")
                Button("Envoyer") {
                    if let answer = PlanApproval.requestChanges(feedback, to: request) { respond(answer) }
                }
                .disabled(PlanApproval.requestChanges(feedback, to: request) == nil)
                .accessibilityIdentifier("interaction-feedback-send")
            }
            Button("Refuser le plan", role: .destructive) { respond(.decline) }
                .font(.callout)
                .accessibilityIdentifier("interaction-decline")
        }
        .sheet(isPresented: $showingPlan) {
            NavigationStack {
                ScrollView {
                    MarkdownText(markdown: request.planText ?? "").padding()
                }
                .navigationTitle("Plan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("OK") { showingPlan = false } }
                }
            }
        }
    }
}

/// Demande sans questions : choix proposés par l'hôte et/ou saisie libre (masquée si sensible, jamais conservée).
struct SimpleInputCard: View {
    let request: UserInputRequest
    let respond: (InteractionAnswer) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.prompt).font(.callout).textSelection(.enabled)
            ForEach(request.options ?? [], id: \.optionId) { choice in
                Button { respond(.choice(choice)) } label: {
                    Text(choice.label).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("interaction-option-\(choice.optionId)")
            }
            if request.freeText == true {
                HStack(alignment: .bottom, spacing: 8) {
                    Group {
                        if request.sensitive == true {
                            SecureField("Réponse", text: $text)
                        } else {
                            TextField("Réponse", text: $text, axis: .vertical).lineLimit(1...4)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("interaction-feedback")
                    Button("Envoyer") {
                        if let answer = InteractionAnswer.text(text) { respond(answer) }
                    }
                    .disabled(InteractionAnswer.text(text) == nil)
                    .accessibilityIdentifier("interaction-submit")
                }
            }
            Button("Ignorer", role: .cancel) { respond(.decline) }
                .font(.callout)
                .accessibilityIdentifier("interaction-decline")
        }
    }
}
