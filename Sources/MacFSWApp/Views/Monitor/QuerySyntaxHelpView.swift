import MacFSWCore
import SwiftUI

/// Query language reference shown from the command bar. Fields come from
/// the parser's catalog, so the reference cannot drift from what parses.
struct QuerySyntaxHelpView: View {
    let onUseExample: (String) -> Void

    private static let operators: [(String, String)] = [
        ("key:value", "contains, case-insensitive; * and ? are wildcards"),
        ("key=value", "equals"),
        ("key!=value", "does not equal"),
        ("key>n  >=  <  <=", "numeric comparison"),
        ("a,b", "either value"),
        ("a b", "both conditions"),
        ("a OR b", "either condition"),
        ("NOT a   -a", "exclude"),
        ("( … )", "group"),
        ("word", "search every field"),
    ]

    private static let examples = [
        "path:/Library/LaunchAgents mutation:true",
        "op:rename,unlink -process:mdworker",
        "(op:chmod OR op:chown) path:/Library",
        "apple:false signing:com.example.*",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Syntax") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Self.operators, id: \.0) { syntax, meaning in
                            GridRow {
                                Text(syntax).font(.system(.callout, design: .monospaced))
                                Text(meaning).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                section("Examples") {
                    ForEach(Self.examples, id: \.self) { example in
                        Button {
                            onUseExample(example)
                        } label: {
                            Text(example)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .help("Use this query")
                    }
                }

                section("Fields") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(MacFSWQueryFieldCatalog.descriptors, id: \.canonicalKey) { descriptor in
                            GridRow {
                                Text(descriptor.canonicalKey).font(.system(.callout, design: .monospaced))
                                Text(descriptor.summary).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
