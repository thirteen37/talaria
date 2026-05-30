import Foundation

/// Name-keyed, refcounted pool of profile-scoped dashboards. Two editing states
/// targeting the same Hermes profile (e.g. the single editor and one column of
/// the comparison) share a single underlying supervisor/client: the pool calls
/// the injected `acquire` closure **once per name** and the `release` closure
/// once the last holder leaves.
///
/// This dedup must live here because the **iOS** acquire path spawns a fresh
/// supervisor per call (there is no cross-window coordinator to refcount it),
/// so without the pool two same-name acquires would launch two remote
/// `hermes dashboard` processes. macOS already refcounts in its
/// `DashboardCoordinator`, but routing both platforms through the pool keeps the
/// editor logic platform-neutral.
///
/// Generic over the supervisor/client token types so the unit tests can exercise
/// the refcount contract with trivial stand-ins; the app instantiates it as
/// `ScopedDashboardPool<DashboardSupervisor, DashboardClient>`.
@MainActor
public final class ScopedDashboardPool<Supervisor, Client> {
    private struct Entry {
        let supervisor: Supervisor
        let client: Client
        var refCount: Int
    }

    private var entries: [String: Entry] = [:]
    private let acquireClosure: @MainActor (String) async throws -> (Supervisor, Client)
    private let releaseClosure: @MainActor (Supervisor) async -> Void

    public init(
        acquire: @escaping @MainActor (String) async throws -> (Supervisor, Client),
        release: @escaping @MainActor (Supervisor) async -> Void
    ) {
        self.acquireClosure = acquire
        self.releaseClosure = release
    }

    /// Returns the client for `name`, spawning a supervisor on the first holder
    /// and bumping the refcount for each subsequent one.
    public func acquire(_ name: String) async throws -> Client {
        if var entry = entries[name] {
            entry.refCount += 1
            entries[name] = entry
            return entry.client
        }
        let (supervisor, client) = try await acquireClosure(name)
        // A concurrent acquire for the same name may have populated the entry
        // while we awaited the spawn. Adopt the existing client and drop this
        // duplicate supervisor so only one underlying dashboard survives.
        if var entry = entries[name] {
            entry.refCount += 1
            entries[name] = entry
            await releaseClosure(supervisor)
            return entry.client
        }
        entries[name] = Entry(supervisor: supervisor, client: client, refCount: 1)
        return client
    }

    /// Drops one hold on `name`; releases the underlying supervisor when the last
    /// holder leaves. A release for an unknown name is a no-op.
    public func release(_ name: String) async {
        guard var entry = entries[name] else { return }
        entry.refCount -= 1
        if entry.refCount <= 0 {
            entries.removeValue(forKey: name)
            await releaseClosure(entry.supervisor)
        } else {
            entries[name] = entry
        }
    }

    /// Releases every outstanding hold so no supervisor leaks at teardown. Safe
    /// to call after each holder has already released (it finds the pool empty).
    public func drain() async {
        for name in Array(entries.keys) {
            while entries[name] != nil {
                await release(name)
            }
        }
    }

    /// Number of distinct names with a live supervisor. For tests/assertions.
    public var activeCount: Int { entries.count }
}
