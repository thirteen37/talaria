import HermesKit
import SwiftUI

/// Window-owned (not view-owned) holder for the Doctor run state. Sits on
/// `ServerWindowHarness` like `UpdatesHarness`, so a run survives
/// Browse navigation that destroys `DoctorView`. The view is a thin observer.
@MainActor
@Observable
final class DoctorHarness {
    var report: DoctorReport?
    var isRunning = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    var expanded: Set<Int> = []

    let runner: HermesAdminRunning?
    private var runTask: Task<Void, Never>?

    init(runner: HermesAdminRunning?) { self.runner = runner }

    func runDoctor() { run { try await HermesDoctor.run(runner: $0) } }
    func runFix()    { run { try await HermesDoctor.runFix(runner: $0) } }

    /// Owns the Task so it is NOT tied to the view's lifecycle — the whole
    /// point of the fix. A run started here keeps going and writes back to
    /// the (harness-held) state even if the user navigates away mid-run.
    private func run(_ op: @escaping @Sendable (HermesAdminRunning) async throws -> DoctorReport) {
        guard let runner else { return }
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            self.isRunning = true
            defer { self.isRunning = false }
            self.lastError = nil
            self.banners?.dismiss(key: "doctor")
            do {
                let r = try await op(runner)
                self.report = r
                self.expanded = Set(r.sections.map(\.id))
            } catch {
                self.lastError = error.localizedDescription
                self.banners?.surfaceError("doctor", error.localizedDescription)
            }
        }
    }

    func cancelRun() { runTask?.cancel(); runTask = nil }

    /// Awaits the in-flight run, if any. Lets tests deterministically wait
    /// for the harness-owned Task; harmless in app code.
    func waitForCompletion() async { await runTask?.value }
}

struct DoctorView: View {
    let doctor: DoctorHarness
    let profile: ServerProfile
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var dashboardReachable: Bool?
    @State private var dashboardReachabilityError: String?

    init(
        doctor: DoctorHarness,
        profile: ServerProfile,
        client: DashboardClient? = nil,
        hermesVersion: HermesVersion? = nil
    ) {
        self.doctor = doctor
        self.profile = profile
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            // The prereq/reachability rows are useful whenever there's a
            // dashboard to probe, even where no admin runner exists (iPad,
            // where `runner` is always nil). Only show the hard "unavailable"
            // state when neither a runner nor a dashboard client is present.
            if doctor.runner == nil && client == nil {
                ContentUnavailableView(
                    "Doctor unavailable",
                    systemImage: "stethoscope",
                    description: Text("Open a server with a Hermes binary or a reachable dashboard to run diagnostics.")
                )
            } else {
                content
            }
        }
        .navigationTitle("Doctor")
        .dismissesBanner("doctor", from: banners)
        // Wire the window banner hub into the window-owned harness so its run
        // errors route to the top-of-window strip.
        .onAppear { doctor.banners = banners }
        .task(id: client != nil) {
            await probeDashboard()
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            prereqSection
            Divider()
            if doctor.runner != nil {
                doctorRunSection
            } else {
                // No CLI admin runner on this platform (e.g. iPad). The prereq
                // rows above still apply; the full `hermes doctor` capture
                // needs a local/SSH Hermes binary.
                ContentUnavailableView(
                    "Run Doctor unavailable here",
                    systemImage: "stethoscope",
                    description: Text("Running the full diagnostic needs a local or SSH Hermes binary. The prerequisite checks above still apply.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hard errors now route to the top-of-window strip (via the harness'
        // `banners`); no in-surface error banner remains here.
    }

    @ViewBuilder
    private var doctorRunSection: some View {
        HStack(spacing: 8) {
            Button {
                doctor.runDoctor()
            } label: {
                Label("Run Doctor", systemImage: "play.fill")
            }
            .disabled(doctor.isRunning)

            if doctor.report?.suggestsFix == true {
                Button {
                    doctor.runFix()
                } label: {
                    Label("Run Fixes", systemImage: "wrench.and.screwdriver")
                }
                .disabled(doctor.isRunning)
            }

            if let report = doctor.report {
                Button {
                    copyBundle(report)
                } label: {
                    Label("Copy bundle", systemImage: "doc.on.doc")
                }
            }

            if doctor.isRunning { ProgressView().controlSize(.small) }

            Spacer()
            if let report = doctor.report {
                Text("Exit \(report.exitCode)")
                    .font(.caption)
                    .foregroundStyle(report.exitCode == 0 ? .green : .orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        Divider()

        if let report = doctor.report {
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

    @ViewBuilder
    private func reportView(_ report: DoctorReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.sections) { section in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { doctor.expanded.contains(section.id) },
                            set: { newValue in
                                if newValue { doctor.expanded.insert(section.id) } else { doctor.expanded.remove(section.id) }
                            }
                        )
                    ) {
                        Text(colorizedBody(section.body))
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

    /// Renders a section body as a single `AttributedString` (one per section,
    /// not a `VStack` of per-line `Text`s) so contiguous text selection and the
    /// "Copy bundle" path — which uses `report.raw` — stay intact. Each line is
    /// tinted by its leading status glyph.
    private func colorizedBody(_ body: String) -> AttributedString {
        var result = AttributedString()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            var piece = AttributedString(String(line))
            if let color = color(for: HermesDoctor.lineStatus(String(line))) {
                piece.foregroundColor = color
            }
            result += piece
            if i < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    private func color(for status: DoctorLineStatus) -> Color? {
        switch status {
        case .ok:      return .green
        case .warning: return .orange
        case .failure: return .red
        case .hint:    return .secondary
        case .plain:   return nil   // default foreground
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
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let summary = """
        Talaria \(appVersion)
        Profile: \(profile.name) (\(profile.kind == .ssh ? "ssh" : "local"))
        Host: \(profile.host ?? "-")

        \(report.raw)
        """
        Pasteboard.copy(summary)
    }
}
