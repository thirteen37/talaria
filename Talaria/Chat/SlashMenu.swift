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
        guard count > 0 else { return rowMinHeight }
        return count * rowMinHeight + (count - 1) * rowSpacing
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
        .fixedSize(horizontal: false, vertical: true)
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
                    rowLabel(for: command)
                    .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowLabel(for command: AvailableCommand) -> some View {
        if usesStackedRows {
            VStack(alignment: .leading, spacing: 2) {
                commandName(command)
                commandDescription(command)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    }

    private func commandDescription(_ command: AvailableCommand) -> some View {
        Text(command.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .truncationMode(.tail)
    }

    private var contentHeightReader: some View {
        commandRows
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
