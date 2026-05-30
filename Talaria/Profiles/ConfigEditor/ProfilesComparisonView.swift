import HermesKit
import SwiftUI

/// Read-only side-by-side comparison of two profiles' configs. Extracted from
/// the original `ProfilesView` so the structured editor's Compare mode reuses
/// the exact same rendering rather than duplicating it. Stateless — the
/// container owns the selection and the computed `ConfigComparison`.
struct ProfilesComparisonView: View {
    let comparison: ConfigComparison?
    let sourceName: String
    let destName: String
    let showDifferencesOnly: Bool
    let isLoading: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let comparison {
                    let sections = comparison.sections.filter {
                        !(showDifferencesOnly && !$0.hasDifferences)
                    }
                    if sections.isEmpty {
                        ContentUnavailableView(
                            "No differences",
                            systemImage: "checkmark.circle",
                            description: Text("These profiles' configs match.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                } else if !isLoading {
                    ContentUnavailableView(
                        "Nothing to compare",
                        systemImage: "rectangle.on.rectangle",
                        description: Text("Pick a second profile to compare against.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: SectionComparison) -> some View {
        let rows = showDifferencesOnly ? section.rows.filter { $0.status != .same } : section.rows
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    ConfigDiffRow(row: row, sourceName: sourceName, destName: destName)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(section.name).font(.headline)
                if section.hasDifferences {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Spacer()
            }
        }
    }
}

/// Side-by-side comparison row for one config key-path, adapting `DiffView`'s
/// two-column monospaced card. Tinted by status: changed → amber,
/// only-in-source → red, only-in-destination → green.
struct ConfigDiffRow: View {
    let row: ConfigRowComparison
    let sourceName: String
    let destName: String

    private var background: Color {
        switch row.status {
        case .same: return .gray.opacity(0.08)
        case .changed: return .orange.opacity(0.12)
        case .onlyInSource: return .red.opacity(0.12)
        case .onlyInDest: return .green.opacity(0.12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.keyPath)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                column(title: "Source (\(sourceName))", value: row.sourceValue)
                Divider()
                column(title: "Destination (\(destName))", value: row.destValue)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func column(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
