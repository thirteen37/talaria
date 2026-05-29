#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardPortAllocatorTests {
    @Test
    func allocateReturnsAUserspacePort() throws {
        let port = try DashboardPortAllocator.allocate()
        // Kernel ephemeral range starts well above 1024; anything we can
        // realistically reach without privilege is non-zero and below 65536.
        #expect(port > 1024)
        #expect(port < 65536)
    }

    @Test
    func twoSequentialAllocationsDoNotReuseTheSamePort() throws {
        // The kernel rotates through the ephemeral range. Asking back-to-
        // back should hand us distinct ports the vast majority of the time;
        // collisions are not impossible but are vanishingly rare and would
        // surface as a flake worth investigating, not as a spurious failure.
        let a = try DashboardPortAllocator.allocate()
        let b = try DashboardPortAllocator.allocate()
        #expect(a != b)
    }
}
#endif
