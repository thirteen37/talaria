import Charts
import HermesKit
import SwiftUI

/// Selectable look-back window for the Usage screen, passed straight through to
/// `GET /api/analytics/usage?days=N`.
enum UsageRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        }
    }
}

@MainActor
@Observable
final class UsageHarness {
    var analytics: DashboardUsageAnalytics?
    var isLoading: Bool = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    /// The active look-back window. Changing it re-queries.
    var range: UsageRange = .month

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    /// Loads usage analytics for the current range. Read-only and dashboard-only
    /// (`/api/analytics/usage`) — there's no CLI fallback.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            analytics = try await client.getUsageAnalytics(days: range.rawValue)
            lastError = nil
            banners?.dismiss(key: "usage")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("usage", error.localizedDescription)
        }
    }

    /// Switches the look-back window and re-queries. A no-op if unchanged so a
    /// repeated tap on the current segment doesn't fire a redundant request.
    func setRange(_ newRange: UsageRange) async {
        guard newRange != range else { return }
        range = newRange
        await refresh()
    }

    /// True once a load has completed and the window holds no sessions — drives
    /// the empty state instead of an all-zero dashboard.
    var isEmpty: Bool {
        guard let analytics, !isLoading else { return false }
        return (analytics.totals.totalSessions ?? 0) == 0 && analytics.daily.isEmpty
    }
}

struct UsageView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?

    @State private var harness: UsageHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Usage")
        .dismissesBanner("usage", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, matching the
        // other dashboard surfaces (Cron, Models).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = UsageHarness(client: client)
            h.banners = banners
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: UsageHarness) -> some View {
        Group {
            if harness.isEmpty {
                ContentUnavailableView(
                    "No usage yet",
                    systemImage: "chart.bar.xaxis",
                    description: Text("No sessions in the last \(harness.range.label). Start a chat to see token and cost analytics here.")
                )
            } else {
                dashboard(harness: harness)
                    // Dim the charts/totals while a load is in flight so the
                    // range picker and Refresh give feedback on every reload —
                    // the picker flips to the new window immediately, but the
                    // data behind it is the previous window's until the request
                    // returns (and on first load there's only the zeroed
                    // skeleton to dim).
                    .opacity(harness.isLoading ? 0.4 : 1)
            }
        }
        .toolbar { toolbar(harness: harness) }
        .overlay {
            if harness.isLoading {
                ProgressView()
            }
        }
        // Hard errors route to the top-of-window strip; only the capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Usage analytics via Hermes dashboard",
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    // MARK: - Dashboard

    @ViewBuilder
    private func dashboard(harness: UsageHarness) -> some View {
        let analytics = harness.analytics ?? DashboardUsageAnalytics()
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                totalsSection(analytics.totals)
                if !analytics.daily.isEmpty {
                    dailySection(analytics.daily)
                }
                if !analytics.byModel.isEmpty {
                    byModelSection(analytics.byModel)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Totals

    @ViewBuilder
    private func totalsSection(_ totals: DashboardUsageTotals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Totals")
                .font(.headline)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                StatCard(title: "Total tokens", value: UsageFormat.abbreviated(totals.totalTokens))
                StatCard(title: "Input tokens", value: UsageFormat.abbreviated(totals.totalInput ?? 0))
                StatCard(title: "Output tokens", value: UsageFormat.abbreviated(totals.totalOutput ?? 0))
                StatCard(title: "Cache reads", value: UsageFormat.abbreviated(totals.totalCacheRead ?? 0))
                StatCard(title: "Estimated cost", value: UsageFormat.cost(totals.totalEstimatedCost ?? 0))
                StatCard(title: "Actual cost", value: UsageFormat.cost(totals.totalActualCost ?? 0))
                StatCard(title: "Sessions", value: (totals.totalSessions ?? 0).formatted())
                StatCard(title: "API calls", value: (totals.totalApiCalls ?? 0).formatted())
            }
        }
    }

    // MARK: - Daily trend

    @ViewBuilder
    private func dailySection(_ daily: [DashboardUsageDaily]) -> some View {
        // Parse the `yyyy-MM-dd` day strings into `Date`s so the X axis is
        // *temporal*, not categorical: `AxisMarks(.automatic(desiredCount:))`
        // only thins ticks on a numeric/`Date` axis — on a String axis Charts
        // draws one label per day, which overlaps badly at the 30/90-day windows.
        let points = UsageView.dailyPoints(daily)
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokens per day")
                .font(.headline)
            Chart(points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6))
            }
            .frame(height: 220)

            Text("Estimated cost per day")
                .font(.headline)
                .padding(.top, 8)
            Chart(points) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Cost", point.cost)
                )
                .foregroundStyle(Color.green)
                PointMark(
                    x: .value("Day", point.date),
                    y: .value("Cost", point.cost)
                )
                .foregroundStyle(Color.green)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6))
            }
            .frame(height: 180)
        }
    }

    /// Parser for the route's `yyyy-MM-dd` day strings (SQLite
    /// `date(started_at,'unixepoch')`, UTC). POSIX locale + fixed UTC zone so it
    /// round-trips regardless of the device locale/zone.
    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Projects the daily rows onto a temporal series, dropping any row whose
    /// `day` fails to parse (the route guarantees `yyyy-MM-dd`, so this is just
    /// defensive — a malformed day is skipped rather than crashing the chart).
    private static func dailyPoints(_ daily: [DashboardUsageDaily]) -> [DailyPoint] {
        daily.compactMap { row in
            guard let date = dayParser.date(from: row.day) else { return nil }
            return DailyPoint(id: row.day, date: date, tokens: row.totalTokens, cost: row.estimatedCost ?? 0)
        }
    }

    // MARK: - By model

    @ViewBuilder
    private func byModelSection(_ byModel: [DashboardUsageByModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By model")
                .font(.headline)
            Chart(byModel) { row in
                BarMark(
                    x: .value("Tokens", row.totalTokens),
                    y: .value("Model", row.model)
                )
                .foregroundStyle(Color.accentColor)
            }
            .frame(height: max(120, CGFloat(byModel.count) * 44))

            VStack(spacing: 0) {
                ForEach(byModel) { row in
                    byModelRow(row)
                    if row.id != byModel.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
            #if os(macOS)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            #else
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            #endif
        }
    }

    @ViewBuilder
    private func byModelRow(_ row: DashboardUsageByModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(row.sessions ?? 0) session\((row.sessions ?? 0) == 1 ? "" : "s") · \(row.apiCalls ?? 0) API calls")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageFormat.abbreviated(row.totalTokens) + " tokens")
                Text(UsageFormat.cost(row.estimatedCost ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: UsageHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Picker("Range", selection: Binding(
                get: { harness.range },
                set: { newRange in Task { await harness.setRange(newRange) } }
            )) {
                ForEach(UsageRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .disabled(harness.isLoading)
            .help("Choose the look-back window")

            Button {
                Task { await harness.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload usage analytics")
        }
    }
}

/// A daily usage row projected onto a `Date` X axis for the trend charts.
private struct DailyPoint: Identifiable {
    let id: String
    let date: Date
    let tokens: Int
    let cost: Double
}

/// One labelled metric tile in the Usage totals grid.
private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        #else
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        #endif
    }
}

/// Number formatting shared across the Usage surface.
enum UsageFormat {
    /// Compact token/count rendering — `1.2M`, `12.3K`, or the grouped integer
    /// below 1,000. Keeps the stat tiles and per-model rows readable when token
    /// counts run into the millions.
    static func abbreviated(_ value: Int) -> String {
        let v = Double(value)
        switch abs(value) {
        case 1_000_000_000...:
            return trimmed(v / 1_000_000_000) + "B"
        case 1_000_000...:
            return trimmed(v / 1_000_000) + "M"
        case 1_000...:
            return trimmed(v / 1_000) + "K"
        default:
            return value.formatted()
        }
    }

    /// USD cost with cents (`$1.73`), or sub-cent precision for tiny amounts so a
    /// real-but-small spend doesn't render as a flat `$0.00`.
    static func cost(_ value: Double) -> String {
        if value > 0, value < 0.01 {
            return value.formatted(.currency(code: "USD").precision(.fractionLength(4)))
        }
        return value.formatted(.currency(code: "USD"))
    }

    private static func trimmed(_ value: Double) -> String {
        // One decimal place, dropping a trailing ".0" (so 12.0K reads as 12K).
        let s = String(format: "%.1f", value)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
