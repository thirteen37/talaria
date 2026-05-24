import HermesKit
import SwiftUI

struct DoctorView: View {
    let runner: HermesAdminRunning?
    let profile: ServerProfile

    @State private var report: DoctorReport?
    @State private var isRunning = false
    @State private var lastError: String?
    @State private var expanded: Set<Int> = []

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "stethoscope",
                    description: Text("Open a profile with a Hermes binary to run Doctor.")
                )
            } else {
                content
            }
        }
        .navigationTitle("Doctor")
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Task { await runDoctor() }
                } label: {
                    Label("Run Doctor", systemImage: "play.fill")
                }
                .disabled(isRunning)

                if let report {
                    Button {
                        copyBundle(report)
                    } label: {
                        Label("Copy bundle", systemImage: "doc.on.doc")
                    }
                }

                if isRunning { ProgressView().controlSize(.small) }

                Spacer()
                if let report {
                    Text("Exit \(report.exitCode)")
                        .font(.caption)
                        .foregroundStyle(report.exitCode == 0 ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let report {
                reportView(report)
            } else {
                ContentUnavailableView(
                    "Doctor Has Not Run",
                    systemImage: "stethoscope",
                    description: Text("Tap Run Doctor to capture a diagnostic report.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .manageBanner(lastError)
    }

    @ViewBuilder
    private func reportView(_ report: DoctorReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.sections) { section in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(section.id) },
                            set: { newValue in
                                if newValue { expanded.insert(section.id) } else { expanded.remove(section.id) }
                            }
                        )
                    ) {
                        Text(section.body)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } label: {
                        Text(section.title)
                            .font(.headline)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runDoctor() async {
        guard let runner else { return }
        isRunning = true
        defer { isRunning = false }
        lastError = nil
        do {
            let r = try await HermesDoctor.run(runner: runner)
            report = r
            expanded = Set(r.sections.map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func copyBundle(_ report: DoctorReport) {
        #if os(macOS)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let summary = """
        Talaria \(appVersion)
        Profile: \(profile.name) (\(profile.kind == .ssh ? "ssh" : "local"))
        Host: \(profile.host ?? "-")

        \(report.raw)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        #endif
    }
}
