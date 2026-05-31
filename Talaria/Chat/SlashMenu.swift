import HermesKit
import SwiftUI

struct SlashMenu: View {
    let commands: [AvailableCommand]
    let select: (AvailableCommand) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0

    // Minimum row height keeps compact command lists readable; measured content
    // height below handles stacked iOS rows and larger text sizes.
    private let rowMinHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 4
    private let menuWidth: CGFloat = 320
    private let maxHeight: CGFloat = 240

    private var menuHeight: CGFloat? {
        min(contentHeight > 0 ? contentHeight : estimatedContentHeight, maxHeight)
    }

    private var estimatedContentHeight: CGFloat {
        let count = CGFloat(commands.count)
        guard count > 0 else { return estimatedRowHeight }
        return count * estimatedRowHeight + (count - 1) * rowSpacing
    }

    private var estimatedRowHeight: CGFloat {
        usesStackedRows ? 52 : rowMinHeight
    }

    private var usesStackedRows: Bool {
        #if os(iOS)
        true
        #else
        dynamicTypeSize.isAccessibilitySize
        #endif
    }

    var body: some View {
        ScrollView {
            commandRows
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: menuWidth, alignment: .leading)
        .background(contentHeightReader)
        .frame(height: menuHeight)
        .onPreferenceChange(SlashMenuContentHeightKey.self) { height in
            if abs(height - contentHeight) > 0.5 {
                contentHeight = height
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(radius: 8, y: 4)
    }

    private var commandRows: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(commands, id: \.name) { command in
                Button {
                    select(command)
                } label: {
                    rowContent(for: command)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Button-free copy of the rows used only for height measurement, so the
    /// reader doesn't reconstruct a throwaway `Button`/closure tree. Shares
    /// `rowContent` with `commandRows`, so the measured height matches exactly.
    private var measuredRows: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(commands, id: \.name) { command in
                rowContent(for: command)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowContent(for command: AvailableCommand) -> some View {
        rowLabel(for: command)
            .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func rowLabel(for command: AvailableCommand) -> some View {
        if usesStackedRows {
            stackedCommandLabel(command)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                commandName(command)
                    .fixedSize(horizontal: true, vertical: false)
                commandDescription(command)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func commandName(_ command: AvailableCommand) -> some View {
        Text("/\(command.name)")
            .font(.callout.weight(.semibold))
            .foregroundColor(.primary)
    }

    @ViewBuilder
    private func stackedCommandLabel(_ command: AvailableCommand) -> some View {
        let description = descriptionText(for: command)
        // Two independent Text views in a VStack rather than a concatenated
        // `Text + Text("\n…")` — separate views lay out and draw reliably.
        VStack(alignment: .leading, spacing: 2) {
            commandName(command)
            if !description.isEmpty {
                commandDescription(command)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commandDescription(_ command: AvailableCommand) -> some View {
        Text(descriptionText(for: command))
            .font(.caption)
            // NOT `.secondary`: the hierarchical secondary style renders invisibly
            // over the menu's `.regularMaterial` on-device (vibrancy flattens it to
            // ~zero alpha — confirmed by on-device style probes). A dimmed `.primary`
            // stays visible and still adapts to light/dark.
            .foregroundColor(.primary)
            .opacity(secondaryTextOpacity)
            .truncationMode(.tail)
    }

    /// Matches the system secondary-label contrast without relying on the
    /// `.secondary` hierarchical style (see `commandDescription`).
    private let secondaryTextOpacity: Double = 0.6

    private func descriptionText(for command: AvailableCommand) -> String {
        let description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }

        switch command.name {
        case "help":
            return "List available commands"
        case "model":
            return "Show or switch models"
        case "tools":
            return "List available tools"
        case "context":
            return "Show conversation message counts"
        case "reset":
            return "Clear conversation history"
        case "compact":
            return "Compress conversation context"
        case "steer":
            return "Inject guidance into the running turn"
        case "queue":
            return "Show queued work"
        default:
            return ""
        }
    }

    private var contentHeightReader: some View {
        measuredRows
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .allowsHitTesting(false)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SlashMenuContentHeightKey.self, value: proxy.size.height)
                }
            }
    }
}

private struct SlashMenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
