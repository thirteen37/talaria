import HermesKit
import SwiftUI

struct DoctorView: View {
    let runner: HermesAdminRunning?
    let profile: ServerProfile
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var report: DoctorReport?
    @State private var isRunning = false
    @State private var lastError: String?
    @State private var expanded: Set<Int> = []
    @State private var dashboardReachable: Bool?
    @State private var dashboardReachabilityError: String?

    init(
        runner: HermesAdminRunning?,
        profile: ServerProfile,
        client: DashboardClient? = nil,
        hermesVersion: HermesVersion? = nil
    ) {
        self.runner = runner
        self.profile = profile
        self.client = client
        self.hermesVersion = hermesVersion
    }

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
        .task(id: client != nil) {
            await probeDashboard()
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            prereqSection
            Divider()
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

    @ViewBuilder
    private var prereqSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            prereqRow(
                ok: versionMeetsDashboard,
                label: versionLabel,
                detail: versionDetail
            )
            prereqRow(
                ok: dashboardReachable == true,
                label: "Dashboard reachable",
                detail: dashboardReachabilityDetail
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func prereqRow(ok: Bool, label: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var versionMeetsDashboard: Bool {
        guard let hermesVersion else { return false }
        return CapabilityTable().has(.requiresDashboard, in: hermesVersion)
    }

    private var versionLabel: String {
        if let hermesVersion {
            return "Hermes \(formatVersion(hermesVersion))"
        }
        return "Hermes version unknown"
    }

    private var versionDetail: String {
        if versionMeetsDashboard { return "≥ 0.14.0 (dashboard supported)" }
        return "Dashboard requires Hermes 0.14.0+ (run `pip install -U hermes-agent` and ensure the `[web]` extra is installed)."
    }

    private var dashboardReachabilityDetail: String? {
        if dashboardReachable == true { return "/api/status responded 200" }
        if let error = dashboardReachabilityError { return error }
        if client == nil { return "Waiting for the dashboard to come online." }
        return nil
    }

    private func probeDashboard() async {
        guard let client else {
            dashboardReachable = nil
            dashboardReachabilityError = nil
            return
        }
        do {
            _ = try await client.getStatus()
            dashboardReachable = true
            dashboardReachabilityError = nil
        } catch {
            dashboardReachable = false
            dashboardReachabilityError = error.localizedDescription
        }
    }

    private func formatVersion(_ v: HermesVersion) -> String {
        var s = "\(v.major).\(v.minor).\(v.patch)"
        if let pre = v.prerelease { s += "-\(pre)" }
        return s
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
