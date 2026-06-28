import Foundation
import HermesKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The outcome of summarizing a set of pending commits into a user-facing
/// changelog. `unavailable` carries a human-readable reason (model not on this
/// device, Apple Intelligence off, model still downloading, or a generation
/// error) so the caller can fall back to the plain "N commits behind" subtitle.
enum ChangelogSummary: Equatable, Sendable {
    case summary(headline: String, highlights: [String])
    case unavailable(reason: String)
}

/// Turns raw pending-commit subjects into a readable changelog. Injected into
/// ``UpdatesHarness`` so the device-bound FoundationModels work is isolated
/// behind a protocol the tests can stub.
protocol ChangelogSummarizing: Sendable {
    func summarize(commits: [PendingCommit]) async -> ChangelogSummary
}

/// Summarizes commits **on-device** via Apple Intelligence (FoundationModels).
/// The whole FoundationModels surface — symbol names, availability states — is
/// SDK/device-bound, so it lives behind ``ChangelogSummarizing`` and this one
/// file. The model always runs on the **local** Talaria device, even when the
/// git log came from a remote server.
struct FoundationModelsChangelogSummarizer: ChangelogSummarizing {
    /// Commits summarized per model call. 60 keeps each call well inside the
    /// ~4k-token on-device window *and* keeps output concrete — larger batches
    /// make the model generalize into vague filler.
    static let batchSize = 60
    /// Hard ceiling on how many pending commits we summarize at all. Hermes is a
    /// very active repo (hundreds of commits a day), so a long-stale checkout can
    /// be thousands behind; map-reduce over all of them would take a minute-plus
    /// per (constantly-changing) commit set. We summarize the newest
    /// `maxTotalCommits` and tell the user when we truncated.
    static let maxTotalCommits = 500
    /// Char ceiling per model call — a coarse token-budget proxy so one call's
    /// input can't overflow the window (60 subjects, or the reduce's highlight
    /// list).
    static let maxPromptChars = 8000

    func summarize(commits: [PendingCommit]) async -> ChangelogSummary {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return await Self.runOnDevice(commits: commits)
        } else {
            return .unavailable(reason: "On-device summaries require macOS 26 or iOS 26.")
        }
        #else
        return .unavailable(reason: "On-device summaries aren't available on this platform.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func runOnDevice(commits: [PendingCommit]) async -> ChangelogSummary {
        // Even with the deployment-target bump, the model can be unavailable at
        // runtime — ineligible device, Apple Intelligence off, or still
        // downloading — so check before opening a session.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .unavailable(reason: describe(reason))
        @unknown default:
            return .unavailable(reason: "On-device summaries are unavailable.")
        }

        let subjects = Array(commits.map(\.subject).prefix(maxTotalCommits))

        // Small range → a single pass, the common case.
        if subjects.count <= batchSize {
            guard let generated = await generate(lines: subjects, instructions: changelogInstructions) else {
                return .unavailable(reason: "The summary came back empty.")
            }
            return summary(from: generated)
        }

        // Large range → MAP each batch into concrete highlights, then REDUCE the
        // combined highlights into the final changelog. Each call stays inside the
        // window; the whole thing is deterministic (greedy) so it's cacheable.
        //
        // This is ~N sequential on-device calls, so bail between batches when a
        // re-check has superseded us (the harness cancels `changelogTask`) — the
        // returned value is discarded by the caller's post-cancellation guard, but
        // the early-out saves the remaining model calls.
        var highlights: [String] = []
        for batch in chunk(subjects, into: batchSize) {
            if Task.isCancelled { return .unavailable(reason: "Cancelled.") }
            if let generated = await generate(lines: batch, instructions: changelogInstructions) {
                highlights.append(contentsOf: generated.highlights)
            }
        }
        let merged = dedupePreservingOrder(highlights)
        guard !merged.isEmpty else { return .unavailable(reason: "The summary came back empty.") }

        if Task.isCancelled { return .unavailable(reason: "Cancelled.") }
        guard let reduced = await generate(lines: merged, instructions: reduceInstructions) else {
            // Reduce failed (rare — small input). Return `.unavailable` rather than
            // a degraded `.summary`: the latter would be cached against this commit
            // set, so a re-check would show the degraded list instead of retrying
            // the reduce. `.unavailable` isn't cached, so a re-check re-attempts.
            return .unavailable(reason: "Couldn't combine the changelog summary.")
        }
        return summary(from: reduced)
    }

    /// One model call: builds the prompt (char-capped), runs greedy structured
    /// generation, returns the `@Generable` result or nil on any throw.
    @available(macOS 26, iOS 26, *)
    private static func generate(lines: [String], instructions: String) async -> GeneratedChangelog? {
        let joined = lines.joined(separator: "\n")
        let body = joined.count > maxPromptChars ? String(joined.prefix(maxPromptChars)) : joined
        let session = LanguageModelSession(instructions: instructions)
        do {
            // Greedy sampling is deterministic — the same input always yields the
            // same text, so re-checks (and each map batch) don't reshuffle.
            let response = try await session.respond(
                to: "Input:\n\n\(body)",
                generating: GeneratedChangelog.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content
        } catch {
            return nil
        }
    }

    /// Cleans a `@Generable` result into a `ChangelogSummary`.
    private static func summary(from generated: GeneratedChangelog) -> ChangelogSummary {
        let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let highlights = generated.highlights
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !headline.isEmpty || !highlights.isEmpty else {
            return .unavailable(reason: "The summary came back empty.")
        }
        return .summary(
            headline: headline.isEmpty ? "Update available" : headline,
            highlights: highlights
        )
    }

    /// Case-insensitive de-dupe that preserves first-seen (newest-first) order, so
    /// the same highlight emitted by adjacent batches collapses to one.
    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            let key = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    private static func chunk(_ items: [String], into size: Int) -> [[String]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<Swift.min($0 + size, items.count)])
        }
    }

    @available(macOS 26, iOS 26, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence to summarize changes."
        case .modelNotReady:
            return "The on-device model is still downloading."
        @unknown default:
            return "On-device summaries are unavailable."
        }
    }

    /// Map / single-pass instructions: turn raw commit subjects into concrete
    /// highlights.
    private static let changelogInstructions = """
    You write a terse, concrete changelog for end users of the Hermes Agent CLI \
    from raw git commit subjects.

    Rules:
    - Summarize, don't transcribe. Merge near-duplicate commits; never one bullet \
    per commit. Aim for 3–6 highlights.
    - Be SPECIFIC. Each highlight names the actual feature, command, or fix that \
    changed (e.g. "Sandbox fallback for restricted Linux desktops", "GPU launch \
    flags for the desktop app"). A reader should learn what's new.
    - BANNED: vague filler with no content — never write "improved error handling", \
    "enhanced security", "better performance", "optimized X", "various fixes", or \
    any "improved/enhanced/better <generic noun>" phrase. Say WHAT changed.
    - Drop entirely: tests, CI, refactors, docs, chores, version bumps, lint, and \
    internal plumbing a user wouldn't notice.
    - Strip conventional-commit prefixes (feat:, fix:, scope()), PR numbers, and \
    file/module names.
    - Don't invent anything not supported by the commits.
    """

    /// Reduce instructions: combine the per-batch highlights into the final list.
    /// It must SELECT and DEDUPE concrete bullets — not re-summarize into vague
    /// themes (which is what a naive reduce produces).
    private static let reduceInstructions = """
    You are given a list of already-written changelog bullets from a large Hermes \
    Agent CLI update. SELECT and DEDUPE — do not rewrite into themes.

    Rules:
    - PREFER concrete, specific bullets that name an actual feature, command, or \
    fix. DROP any vague bullet that lacks a specific name ("improved performance", \
    "enhanced security", "various fixes", "better user experience") — discard them \
    entirely, don't keep or merge them.
    - Preserve the wording of the specific bullets you keep; don't abstract them.
    - Merge only true duplicates / near-duplicates.
    - Pick the most user-significant concrete items. Up to 8 highlights.
    - Don't invent anything not present in the input.
    """
    #endif
}

#if canImport(FoundationModels)
/// Structured output for the on-device summary. Kept private to the summarizer —
/// the rest of the app only sees ``ChangelogSummary``.
@available(macOS 26, iOS 26, *)
@Generable
private struct GeneratedChangelog {
    @Guide(description: "A 3–6 word headline naming the overall theme of this release")
    let headline: String
    @Guide(description: "Concrete user-facing changes, each naming a specific feature, command, or fix. Never one bullet per commit.", .maximumCount(8))
    let highlights: [String]
}
#endif
