import Foundation
import Observation
import MacFSWAnalysis

@MainActor
@Observable
final class AnalysisTemplateStore {
    private(set) var customTemplates: [MacFSWAnalysisPromptTemplate] = []
    var selectedTemplateID: UUID = MacFSWAnalysisPromptTemplateCatalog.defaultTemplate.id {
        didSet {
            guard !isLoading else {
                return
            }
            persist()
        }
    }

    @ObservationIgnored
    var onError: ((Error) -> Void)?

    let builtInTemplates = MacFSWAnalysisPromptTemplateCatalog.builtIns

    private let settingsStore: MacFSWSettingsStore
    @ObservationIgnored
    private var isLoading = false

    init(settingsStore: MacFSWSettingsStore) {
        self.settingsStore = settingsStore
        load()
    }

    var allTemplates: [MacFSWAnalysisPromptTemplate] {
        builtInTemplates + customTemplates
    }

    var selectedTemplate: MacFSWAnalysisPromptTemplate {
        allTemplates.first { $0.id == selectedTemplateID }
            ?? MacFSWAnalysisPromptTemplateCatalog.defaultTemplate
    }

    /// Returns the freshly-created copy so the caller can open the editor
    /// on it directly.
    @discardableResult
    func duplicate(_ template: MacFSWAnalysisPromptTemplate) -> MacFSWAnalysisPromptTemplate {
        let copy = MacFSWAnalysisPromptTemplate(
            id: UUID(),
            name: "\(template.name) Copy",
            summary: template.summary,
            systemPromptTemplate: template.systemPromptTemplate,
            userPromptTemplate: template.userPromptTemplate,
            isBuiltIn: false
        )
        customTemplates.append(copy)
        persist()
        return copy
    }

    func update(_ template: MacFSWAnalysisPromptTemplate) {
        guard !template.isBuiltIn,
              let index = customTemplates.firstIndex(where: { $0.id == template.id }) else {
            return
        }
        customTemplates[index] = template
        persist()
    }

    func delete(id: UUID) {
        guard let index = customTemplates.firstIndex(where: { $0.id == id }) else {
            return
        }
        customTemplates.remove(at: index)
        if selectedTemplateID == id {
            selectedTemplateID = MacFSWAnalysisPromptTemplateCatalog.defaultTemplate.id
        } else {
            persist()
        }
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
        }
        let state = settingsStore.loadPromptTemplateState()
        customTemplates = state.customTemplates
        let known = Set((builtInTemplates + state.customTemplates).map(\.id))
        if let selected = state.selectedTemplateID, known.contains(selected) {
            selectedTemplateID = selected
        } else {
            selectedTemplateID = MacFSWAnalysisPromptTemplateCatalog.defaultTemplate.id
        }
    }

    private func persist() {
        let state = MacFSWAnalysisPromptTemplateState(
            customTemplates: customTemplates,
            selectedTemplateID: selectedTemplateID
        )
        do {
            try settingsStore.savePromptTemplateState(state)
        } catch {
            onError?(error)
        }
    }
}
