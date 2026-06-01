import Foundation
import HermesKit
import Testing
@testable import Talaria

/// `ProfileEditorState.isDirty(in:)` drives the navigation guard that warns
/// before discarding in-progress edits, so its truth table is the load-bearing
/// logic for Bug 3. The dialog / pinned-Save-bar UI is verified manually.
@MainActor
@Suite
struct ProfileEditorStateTests {
    /// A `ProfileDirectory` backed by a throwaway on-disk store so each test
    /// gets isolated, clean storage.
    private func makeDirectory() -> ProfileDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditorStateTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
        return ProfileDirectory(store: ProfileStore(url: url))
    }

    @Test
    func untouchedPendingDraftIsNotDirty() {
        let directory = makeDirectory()
        let state = ProfileEditorState()
        let new = ServerProfile(name: "New Server", kind: .ssh)
        state.pendingDraft = new
        state.pendingBaseline = new
        state.select(new.id, in: directory)
        #expect(!state.isDirty(in: directory))
    }

    @Test
    func editedPendingDraftIsDirty() {
        let directory = makeDirectory()
        let state = ProfileEditorState()
        let new = ServerProfile(name: "New Server", kind: .ssh)
        state.pendingDraft = new
        state.pendingBaseline = new
        state.select(new.id, in: directory)
        var edited = new
        edited.host = "example.com"
        state.updateDraft(edited)
        #expect(state.isDirty(in: directory))
    }

    @Test
    func persistedProfileEqualToDiskIsNotDirty() async {
        let directory = makeDirectory()
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h")
        await directory.upsert(profile)
        let state = ProfileEditorState()
        state.select(profile.id, in: directory)
        #expect(!state.isDirty(in: directory))
    }

    @Test
    func editedPersistedProfileIsDirty() async {
        let directory = makeDirectory()
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h")
        await directory.upsert(profile)
        let state = ProfileEditorState()
        state.select(profile.id, in: directory)
        var edited = profile
        edited.host = "changed"
        state.updateDraft(edited)
        #expect(state.isDirty(in: directory))
    }

    @Test
    func changedPasswordMakesAnUnchangedProfileDirty() async {
        let directory = makeDirectory()
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h", authMethod: .password)
        await directory.upsert(profile)
        let state = ProfileEditorState()
        state.select(profile.id, in: directory)
        // Simulate typing into the password field (loadedPassword stays "" since
        // no password is stored — PasswordKeychain is a no-op on macOS anyway).
        state.passwordInput = "rotated"
        #expect(state.isDirty(in: directory))
    }
}
