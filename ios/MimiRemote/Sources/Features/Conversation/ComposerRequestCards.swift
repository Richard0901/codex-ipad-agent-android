import SwiftUI

struct PendingApprovalActionCard: View {
    let approval: ApprovalSummary
    let isSendingDecision: Bool
    let onDecision: (String) -> Void

    @State private var persistentGrant: PersistentPermissionGrant?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(L10n.text("ui.type"), value: approval.kind)
                LabeledContent(L10n.text("ui.request"), value: approval.title)
                if let risk = approval.risk {
                    LabeledContent(L10n.text("ui.risk"), value: risk)
                }
                if let count = approval.count {
                    LabeledContent(L10n.text("ui.impact_items"), value: L10n.plural("ui.items_count", count: count))
                }
                DisclosureGroup(L10n.text("ui.approval_details")) {
                    if let body = approval.body {
                        Text(body)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(L10n.text("ui.approval_details_not_available"))
                            .foregroundStyle(.secondary)
                    }
                }

                if isSendingDecision {
                    Label(L10n.text("ui.decision_sent"), systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !approval.hasDecisionContext {
                    Label(L10n.text("ui.claude_bridge_provides_no_verifiable_command_path_or"), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                approvalButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(L10n.text("ui.waiting_for_approval"), systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
        }
        // 审批卡位于输入框上方，用户无需跳转到 Inspector 才能作出决定。
        .accessibilityElement(children: .contain)
        .sheet(item: $persistentGrant) { grant in
            PersistentPermissionConfirmationSheet(grant: grant) {
                onDecision("acceptWithPermissionUpdate")
            }
        }
    }

    private var approvalButtons: some View {
        ControlGroup {
            Button(role: .destructive) {
                onDecision("decline")
            } label: {
                Label(L10n.text("ui.reject"), systemImage: "xmark.circle")
            }
            .disabled(isSendingDecision)
            .accessibilityLabel(L10n.text("ui.deny_approval"))
            .accessibilityHint(L10n.text("ui.deny_is_always_available"))

            Button {
                onDecision("accept")
            } label: {
                Label(L10n.text("ui.approve_once"), systemImage: "checkmark.circle.fill")
            }
            .disabled(isSendingDecision || !approval.hasDecisionContext)
            .accessibilityLabel(L10n.text("ui.approval_36f0d72e"))
            .accessibilityValue(approval.hasDecisionContext ? L10n.text("ui.available") : L10n.text("ui.approval_details_not_available"))
            .accessibilityHint(approval.hasDecisionContext ? L10n.text("ui.approve_this_request") : L10n.text("ui.approval_details_are_missing_and_cannot_be_approved"))

            if approval.canPersistPermission, let rules = approval.persistentPermissionRules {
                Button {
                    persistentGrant = PersistentPermissionGrant(
                        id: approval.id,
                        approvalTitle: approval.title,
                        rules: rules
                    )
                } label: {
                    Label(L10n.text("ui.always_allowed"), systemImage: "checkmark.shield")
                }
                .disabled(isSendingDecision || !approval.hasDecisionContext)
                .accessibilityHint(L10n.text("ui.after_confirmation_write_the_precise_rules_suggested_by"))
            }
        }
        .controlGroupStyle(.navigation)
        .controlSize(.large)
    }
}

struct PersistentPermissionGrant: Identifiable {
    let id: String
    let approvalTitle: String
    let rules: [String]
}

struct PersistentPermissionConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let grant: PersistentPermissionGrant
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.current_request")) {
                    Text(grant.approvalTitle)
                }
                Section(L10n.text("ui.will_always_be_allowed")) {
                    ForEach(grant.rules, id: \.self) { rule in
                        Text(rule)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Text(L10n.text("ui.claude_will_append_the_above_precise_rules_to"))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.text("ui.confirm_always_allow"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.confirm_permission")) {
                        onConfirm()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PendingUserInputActionCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let request: AgentUserInputRequest
    let isSubmitting: Bool
    let onSubmit: ([String: [String]]) -> Void

    @State private var selectedAnswers: [String: Set<String>] = [:]
    @State private var freeformAnswers: [String: String] = [:]

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(request.questions) { question in
                questionBlock(question)
            }

            HStack(spacing: 10) {
                Button(L10n.text("ui.skip")) {
                    onSubmit([:])
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSubmitting)

                Button {
                    onSubmit(answerPayload)
                } label: {
                    if isSubmitting {
                        Label(L10n.text("ui.submitting"), systemImage: "hourglass")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    } else {
                        Label(L10n.text("ui.submit_additional_information"), systemImage: "arrow.up.circle.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tokens.accent)
                .controlSize(.large)
                .disabled(isSubmitting || !canSubmit)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tokens.accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var header: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.callout.weight(.semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("ui.supplementary_information"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.accent)
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if isSubmitting {
                    Label(L10n.text("ui.answer_sent"), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func questionBlock(_ question: AgentUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(question.question)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !question.options.isEmpty {
                if question.allowsMultipleSelection {
                    Text(L10n.text("ui.multiple_selections_possible"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                optionButtons(for: question)
            }
            if question.isOther || question.options.isEmpty {
                answerField(for: question)
            }
        }
    }

    private func optionButtons(for question: AgentUserInputQuestion) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(question.options) { option in
                let isSelected = selectedAnswers[question.id, default: []].contains(option.label)
                Button {
                    if question.allowsMultipleSelection {
                        if isSelected {
                            selectedAnswers[question.id, default: []].remove(option.label)
                        } else {
                            selectedAnswers[question.id, default: []].insert(option.label)
                        }
                    } else {
                        selectedAnswers[question.id] = [option.label]
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(option.label, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? tokens.accent : nil)
                .disabled(isSubmitting)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        if question.isSecret {
            SecureField(L10n.text("ui.other"), text: binding(for: question.id))
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)
        } else {
            TextField(L10n.text("ui.other"), text: binding(for: question.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .disabled(isSubmitting)
        }
    }

    private func binding(for questionID: String) -> Binding<String> {
        Binding(
            get: { freeformAnswers[questionID] ?? "" },
            set: { freeformAnswers[questionID] = $0 }
        )
    }

    private var answerPayload: [String: [String]] {
        var payload: [String: [String]] = [:]
        for question in request.questions {
            let answers = answers(for: question)
            if !answers.isEmpty {
                payload[question.id] = answers
            }
        }
        return payload
    }

    private var canSubmit: Bool {
        if request.questions.isEmpty {
            return true
        }
        return request.questions.allSatisfy { !answers(for: $0).isEmpty }
    }

    private func answers(for question: AgentUserInputQuestion) -> [String] {
        let selected = selectedAnswers[question.id] ?? []
        var values = question.options.map(\.label).filter { selected.contains($0) }
        let freeform = (freeformAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeform.isEmpty {
            values.append(freeform)
        }
        return values
    }
}
