import AppKit
import MacFSWAnalysis
import SwiftUI

/// Template list rendered inside `AnalysisSettingsPane`'s Prompt section:
/// each row shows name/summary + a Built-in badge, the currently-selected
/// row is checked, and per-row buttons cover Select / Duplicate / Edit /
/// Delete. Editing a built-in offers Duplicate & Edit instead.
struct AnalysisTemplateList: View {
    @Environment(MacFSWAppCoordinator.self) private var model
    @State private var editing: MacFSWAnalysisPromptTemplate?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.analysisTemplates.allTemplates) { template in
                AnalysisTemplateRow(
                    template: template,
                    isSelected: template.id == model.analysisTemplates.selectedTemplateID,
                    onSelect: { model.analysisTemplates.selectedTemplateID = template.id },
                    onEdit: {
                        if template.isBuiltIn {
                            let copy = model.analysisTemplates.duplicate(template)
                            model.analysisTemplates.selectedTemplateID = copy.id
                            editing = copy
                        } else {
                            editing = template
                        }
                    },
                    onDuplicate: {
                        let copy = model.analysisTemplates.duplicate(template)
                        model.analysisTemplates.selectedTemplateID = copy.id
                    },
                    onDelete: {
                        model.analysisTemplates.delete(id: template.id)
                    }
                )
            }
        }
        .sheet(item: $editing) { template in
            PromptTemplateEditorSheet(template: template) { updated in
                model.analysisTemplates.update(updated)
            }
        }
    }
}

private struct AnalysisTemplateRow: View {
    let template: MacFSWAnalysisPromptTemplate
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .onTapGesture(perform: onSelect)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name)
                        .fontWeight(.medium)
                    if template.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(template.isBuiltIn ? "Duplicate & Edit" : "Edit", action: onEdit)
            Button("Duplicate", action: onDuplicate)
            if !template.isBuiltIn {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PromptTemplateEditorSheet: View {
    let template: MacFSWAnalysisPromptTemplate
    let onSave: (MacFSWAnalysisPromptTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacFSWAnalysisPromptTemplate

    init(
        template: MacFSWAnalysisPromptTemplate,
        onSave: @escaping (MacFSWAnalysisPromptTemplate) -> Void
    ) {
        self.template = template
        self.onSave = onSave
        _draft = State(initialValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Prompt Template")
                .font(.title3.weight(.semibold))

            LabeledContent("Name") {
                TextField("", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Summary") {
                TextField("", text: $draft.summary)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $draft.systemPromptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .border(Color.secondary.opacity(0.3))
                    PlaceholderWarnings(template: draft.systemPromptTemplate)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("User Prompt")
                        .font(.caption.weight(.semibold))
                    TextEditor(text: $draft.userPromptTemplate)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .border(Color.secondary.opacity(0.3))
                    PlaceholderWarnings(template: draft.userPromptTemplate)
                }
            }

            PromptPlaceholderReference()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 620)
    }
}

private struct PlaceholderWarnings: View {
    let template: String

    var body: some View {
        let unknown = MacFSWPromptTemplateRenderer.unknownPlaceholderNames(in: template).sorted()
        VStack(alignment: .leading, spacing: 2) {
            if !unknown.isEmpty {
                Label(
                    "Unknown placeholder\(unknown.count > 1 ? "s" : ""): " + unknown.map { "{{\($0)}}" }.joined(separator: ", "),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.caption)
            }
            if !MacFSWPromptTemplateRenderer.placeholderNames(in: template).contains("event_samples") {
                Label(
                    "This template does not include {{event_samples}} — the model will not see individual events.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }
}

private struct PromptPlaceholderReference: View {
    var body: some View {
        DisclosureGroup("Placeholder Reference") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(MacFSWPromptTemplateRenderer.knownPlaceholders) { placeholder in
                    HStack(spacing: 8) {
                        Text(placeholder.token)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(placeholder.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(placeholder.token, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }
}
