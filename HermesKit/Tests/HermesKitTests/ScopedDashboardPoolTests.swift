import Foundation
import Testing
@testable import HermesKit

@MainActor
@Suite
struct ScopedDashboardPoolTests {
    /// Records how many times the underlying acquire/release closures fired so we
    /// can assert the dedup contract independent of any real dashboard.
    private final class Counters {
        var acquires: [String] = []
        var releases: [Int] = []
    }

    /// Builds a pool whose supervisor token is a monotonically increasing Int so
    /// each spawn is distinguishable; the client token is the name.
    private func makePool(_ counters: Counters) -> ScopedDashboardPool<Int, String> {
        var nextSupervisor = 0
        return ScopedDashboardPool<Int, String>(
            acquire: { name in
                counters.acquires.append(name)
                nextSupervisor += 1
                return (nextSupervisor, name)
            },
            release: { supervisor in
                counters.releases.append(supervisor)
            }
        )
    }

    @Test
    func sameNameTwiceAcquiresOnce() async throws {
        let counters = Counters()
        let pool = makePool(counters)

        let a = try await pool.acquire("work")
        let b = try await pool.acquire("work")

        #expect(a == "work")
        #expect(b == "work")
        #expect(counters.acquires == ["work"])
        #expect(pool.activeCount == 1)
    }

    @Test
    func twoReleasesTriggerOneUnderlyingRelease() async throws {
        let counters = Counters()
        let pool = makePool(counters)

        _ = try await pool.acquire("work")
        _ = try await pool.acquire("work")
        await pool.release("work")
        #expect(counters.releases.isEmpty)   // still one holder

        await pool.release("work")
        #expect(counters.releases == [1])    // last holder left → underlying release
        #expect(pool.activeCount == 0)
    }

    @Test
    func distinctNamesAcquireIndependently() async throws {
        let counters = Counters()
        let pool = makePool(counters)

        _ = try await pool.acquire("a")
        _ = try await pool.acquire("b")

        #expect(counters.acquires == ["a", "b"])
        #expect(pool.activeCount == 2)
    }

    @Test
    func releaseOfUnknownNameIsNoOp() async {
        let counters = Counters()
        let pool = makePool(counters)

        await pool.release("never")

        #expect(counters.releases.isEmpty)
        #expect(pool.activeCount == 0)
    }

    @Test
    func drainReleasesAllOutstandingHolds() async throws {
        let counters = Counters()
        let pool = makePool(counters)

        _ = try await pool.acquire("a")
        _ = try await pool.acquire("a")   // refcount 2
        _ = try await pool.acquire("b")

        await pool.drain()

        // One underlying release per name regardless of refcount.
        #expect(counters.releases.sorted() == [1, 2])
        #expect(pool.activeCount == 0)
    }

    @Test
    func reacquireAfterFullReleaseSpawnsAgain() async throws {
        let counters = Counters()
        let pool = makePool(counters)

        _ = try await pool.acquire("a")
        await pool.release("a")
        _ = try await pool.acquire("a")

        #expect(counters.acquires == ["a", "a"])
        #expect(counters.releases == [1])
    }
}
