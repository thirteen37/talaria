import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers `reasoning.available`'s replace semantics at the ``LocalChatViewModel``
/// level: a `.agentThoughtSnapshot` update *overwrites* the active thought block
/// instead of appending. Repeated snapshots (cumulative or reformatted) must leave
/// a SINGLE `.thought` bubble whose text equals the latest snapshot — the fix for
/// the stray/truncated duplicate "Thinking" block.
@MainActor
@Suite
struct ChatThoughtSnapshotTests {
    /// `LocalChatViewModel` holds its `SessionManager` weakly, so a test must keep
    /// the manager alive itself.
    private let live = LiveManagers()

    private func makeViewModel(
        id: SessionId,
        backend: MockChatBackend
    ) async throws -> LocalChatViewModel {
        let manager = SessionManager(backendFactory: { backend })
        live.keep(manager)
        let session = try await manager.openExisting(id: id, cwd: "/tmp")
        return LocalChatViewModel(manager: manager, sessionId: session.id, cwd: "/tmp")
    }

    private func wait(
        for condition: @escaping () -> Bool,
        _ message: Comment
    ) async {
        for _ in 0 ..< 400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(message)
    }

    @Test
    func repeatedSnapshotsReplaceLeaveSingleThoughtBubble() async throws {
        let backend = MockChatBackend(sessionId: "snap-replace")
        let vm = try await makeViewModel(id: "snap-replace", backend: backend)
        await vm.start()

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "snap-replace",
            update: .agentThoughtSnapshot(Content(content: .text("first part"))))))
        await wait(for: { vm.messages.contains { $0.kind == .thought } },
                   "thought bubble never appeared")

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "snap-replace",
            update: .agentThoughtSnapshot(Content(content: .text("first part and second part"))))))
        await wait(for: { vm.messages.first(where: { $0.kind == .thought })?.text == "first part and second part" },
                   "second snapshot did not replace the thought bubble")

        // Exactly one thought bubble, carrying only the latest snapshot — no
        // append-stacked duplicate.
        let thoughtBubbles = vm.messages.filter { $0.kind == .thought }
        #expect(thoughtBubbles.count == 1)
        #expect(thoughtBubbles.first?.text == "first part and second part")
    }

    @Test
    func reformattedSnapshotReplacesRatherThanAppends() async throws {
        // A snapshot that is NOT a byte-exact prefix-extension of the prior one
        // (whitespace reformat: "a b" → "a  b") must still replace the block. The
        // old suffix-math path would have appended the full second text → the
        // stray, duplicated Thinking block.
        let backend = MockChatBackend(sessionId: "snap-reformat")
        let vm = try await makeViewModel(id: "snap-reformat", backend: backend)
        await vm.start()

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "snap-reformat",
            update: .agentThoughtSnapshot(Content(content: .text("a b"))))))
        await wait(for: { vm.messages.contains { $0.kind == .thought } },
                   "thought bubble never appeared")

        backend.emit(.sessionUpdate(SessionNotification(
            sessionId: "snap-reformat",
            update: .agentThoughtSnapshot(Content(content: .text("a  b"))))))
        await wait(for: { vm.messages.first(where: { $0.kind == .thought })?.text == "a  b" },
                   "reformatted snapshot did not replace the thought bubble")

        let thoughtBubbles = vm.messages.filter { $0.kind == .thought }
        #expect(thoughtBubbles.count == 1)
        #expect(thoughtBubbles.first?.text == "a  b")
    }
}
