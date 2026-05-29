import HermesKit
import SwiftUI

/// Renders the result of a successful capability probe. Shared by the desktop
/// and iPhone profile editors.
struct ProbeCapabilityView: View {
    let result: HermesProbeResult

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Binary", value: result.binaryPath)
            row("Version", value: result.versionRaw)
            row("ACP supported", value: result.acpSupported ? "Yes" : "No")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
