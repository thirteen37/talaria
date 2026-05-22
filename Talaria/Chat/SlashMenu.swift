import HermesKit
import SwiftUI

struct SlashMenu: View {
    let commands: [AvailableCommand]
    let select: (AvailableCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(commands, id: \.name) { command in
                Button {
                    select(command)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(command.name)")
                            .font(.callout.weight(.semibold))
                        Text(command.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(radius: 8, y: 4)
    }
}
