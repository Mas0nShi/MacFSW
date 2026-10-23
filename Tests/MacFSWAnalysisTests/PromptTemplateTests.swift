import Foundation
import XCTest

@testable import MacFSWAnalysis

final class PromptTemplateTests: XCTestCase {
    func testRendererSubstitutesKnownPlaceholders() {
        let rendered = MacFSWPromptTemplateRenderer.render(
            "Report on {{process_name}} in {{output_language}}.",
            substitutions: ["process_name": "Safari", "output_language": "Japanese"]
        )
        XCTAssertEqual(rendered, "Report on Safari in Japanese.")
    }

    func testRendererLeavesUnknownPlaceholdersVerbatim() {
        let rendered = MacFSWPromptTemplateRenderer.render(
            "{{process_name}} and {{topp_paths}}",
            substitutions: ["process_name": "Safari"]
        )
        XCTAssertEqual(rendered, "Safari and {{topp_paths}}")
    }

    func testPlaceholderNameExtraction() {
        let names = MacFSWPromptTemplateRenderer.placeholderNames(
            in: "{{event_samples}} text {{output_language}} {{not-valid}} {{topp_paths}}"
        )
        XCTAssertEqual(names, ["event_samples", "output_language", "topp_paths"])

        XCTAssertEqual(
            MacFSWPromptTemplateRenderer.unknownPlaceholderNames(
                in: "{{event_samples}} {{topp_paths}}"
            ),
            ["topp_paths"]
        )
    }

    func testBuiltInTemplatesHaveStableUniqueIDsAndRequiredPlaceholders() {
        let builtIns = MacFSWAnalysisPromptTemplateCatalog.builtIns
        XCTAssertEqual(builtIns.count, 4)
        XCTAssertEqual(Set(builtIns.map(\.id)).count, builtIns.count, "ids must be unique")
        XCTAssertEqual(
            MacFSWAnalysisPromptTemplateCatalog.defaultTemplate.id,
            MacFSWAnalysisPromptTemplateCatalog.securityTriage.id
        )

        for template in builtIns {
            XCTAssertTrue(template.isBuiltIn)
            let names = MacFSWPromptTemplateRenderer.placeholderNames(
                in: template.systemPromptTemplate + template.userPromptTemplate
            )
            XCTAssertTrue(names.contains("event_samples"), "\(template.name) must show event samples")
            XCTAssertTrue(names.contains("output_language"), "\(template.name) must honor the language setting")
            XCTAssertTrue(
                MacFSWPromptTemplateRenderer.unknownPlaceholderNames(
                    in: template.systemPromptTemplate + template.userPromptTemplate
                ).isEmpty,
                "\(template.name) must not reference unknown placeholders"
            )
        }
    }

    func testOutputLanguagePromptNames() {
        XCTAssertEqual(
            MacFSWAnalysisOutputLanguage.simplifiedChinese.promptName(resolvingSystemWith: Locale(identifier: "en_US")),
            "Simplified Chinese"
        )
        XCTAssertEqual(
            MacFSWAnalysisOutputLanguage.system.promptName(resolvingSystemWith: Locale(identifier: "ja_JP")),
            "Japanese"
        )
        XCTAssertEqual(
            MacFSWAnalysisOutputLanguage.english.promptName(resolvingSystemWith: Locale(identifier: "ja_JP")),
            "English"
        )
    }
}
