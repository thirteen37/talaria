import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import HermesKit

/// Covers the auth-exhaustion fast-fail that keeps a fully-rejected NIO-SSH
/// login from stalling until the server's LoginGraceTime — the iOS "connection
/// spinner never stops, no error shown" bug. The end-to-end path needs a live
/// SSH server (out of scope for unit tests), so these lock the three composable
/// pieces the fix is built from: the delegate's exhaustion signal, the
/// resolve-once latch, and the race that surfaces it during channel-open.
@Suite
struct NIOSSHAuthFailFastTests {
    // MARK: - Auth delegate exhaustion contract

    @Test
    func authDelegateFiresOnExhaustedWhenNoCredentialMatches() throws {
        // Server advertises both methods, but we hold neither credential —
        // the delegate must signal exhaustion and offer nil rather than stall.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let fired = ExhaustionFlag()
        let delegate = NIOSSHAuthDelegate(
            username: "me", privateKey: nil, password: nil,
            onExhausted: { fired.set() }
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: [.password, .publicKey],
            nextChallengePromise: promise
        )
        #expect(try promise.futureResult.wait() == nil)
        #expect(fired.value)
    }

    @Test
    func authDelegateExhaustsWhenServerOffersNoMatchingMethod() throws {
        // We have a password, but the server advertises only publickey: nothing
        // matches, so the delegate must exhaust (not offer the password into a
        // method the server won't accept, and not stall waiting).
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let fired = ExhaustionFlag()
        let delegate = NIOSSHAuthDelegate(
            username: "me", privateKey: nil, password: "pw",
            onExhausted: { fired.set() }
        )
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(
            availableMethods: [.publicKey],
            nextChallengePromise: promise
        )
        #expect(try promise.futureResult.wait() == nil)
        #expect(fired.value)
    }

    // MARK: - Rejection message (shared by the factory and the ACP transport)

    @Test
    func authRejectedMessageNamesEveryOfferedCredential() {
        // Both configured: the message must mention the password too, so a user
        // with both set doesn't only re-check the key.
        #expect(NIOSSHAuthDelegate.authRejectedMessage(hasKey: true, hasPassword: true)
            == "The server rejected the key and password. Check the username and credentials for this server.")
        #expect(NIOSSHAuthDelegate.authRejectedMessage(hasKey: true, hasPassword: false)
            == "The server rejected the key. Check the username and key for this server.")
        #expect(NIOSSHAuthDelegate.authRejectedMessage(hasKey: false, hasPassword: true)
            == "The server rejected the password. Check the username and password for this server.")
    }

    // MARK: - Auth latch (resolve at most once)

    @Test
    func authLatchFailsFutureWithAuthErrorOnExhaustion() throws {
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let latch = NIOSSHAuthLatch(eventLoop: loop, message: "The server rejected the key.")
        latch.onExhausted()
        #expect(throws: SSHTransportError.self) { _ = try latch.future.wait() }
    }

    @Test
    func authLatchResolveAfterFailureIsASafeNoOp() throws {
        // Connection-close cleanup calls resolve() even after onExhausted already
        // failed the latch. It must be a no-op, not a "resolved twice" crash.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let latch = NIOSSHAuthLatch(eventLoop: loop, message: "The server rejected the password.")
        latch.onExhausted()
        latch.resolve()
        #expect(throws: SSHTransportError.self) { _ = try latch.future.wait() }
    }

    @Test
    func authLatchResolveSucceedsAndLateExhaustionIsNoOp() throws {
        // The success path: auth went through, the connection later closes and
        // resolve() succeeds the latch. A late, spurious onExhausted must not
        // crash by failing an already-succeeded promise.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let latch = NIOSSHAuthLatch(eventLoop: loop, message: "The server rejected the key.")
        latch.resolve()
        latch.onExhausted()
        #expect(throws: Never.self) { _ = try latch.future.wait() }
    }

    @Test
    func authLatchSurfacesItsMessageVerbatim() throws {
        // The credential-aware message built in `connect` (e.g. naming both a key
        // and a password when both were offered) must ride along on the error so
        // a user with both set knows to re-check both.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let message = "The server rejected the key and password. Check the username and credentials for this server."
        let latch = NIOSSHAuthLatch(eventLoop: loop, message: message)
        latch.onExhausted()
        do {
            _ = try latch.future.wait()
            Issue.record("Expected the latch to fail")
        } catch let SSHTransportError.authFailed(detail) {
            #expect(detail == message)
        }
    }

    // MARK: - Race: auth exhaustion vs channel open

    @Test
    func raceFailsFastWhenAuthExhaustsBeforeChannelOpens() throws {
        // The core of the bug: the child-channel-open never resolves because the
        // rejected connection just sits open. Racing the auth latch must surface
        // the auth error immediately instead of hanging.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let neverOpens = loop.makePromise(of: Channel.self)
        let authExhausted = loop.makePromise(of: Void.self)
        let raced = NIOSSHConnectionFactory.raceAuthExhaustion(
            neverOpens.futureResult,
            authExhausted: authExhausted.futureResult,
            on: loop
        )
        authExhausted.fail(SSHTransportError.authFailed("rejected"))
        loop.run()
        #expect(throws: SSHTransportError.self) { _ = try raced.wait() }
    }

    @Test
    func raceResolvesOnceWhenAuthExhaustsThenChannelOpenAlsoFails() throws {
        // On a rejected login both signals fire: the latch fails first, then the
        // queued child-open fails as NIOSSH tears the connection down. The race
        // must resolve exactly once — an unguarded cascade would crash here with
        // "promise resolved twice".
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let childOpen = loop.makePromise(of: Channel.self)
        let authExhausted = loop.makePromise(of: Void.self)
        let raced = NIOSSHConnectionFactory.raceAuthExhaustion(
            childOpen.futureResult,
            authExhausted: authExhausted.futureResult,
            on: loop
        )
        authExhausted.fail(SSHTransportError.authFailed("rejected"))
        loop.run()
        childOpen.fail(SSHTransportError.other("connection closed"))
        loop.run()
        #expect(throws: SSHTransportError.self) { _ = try raced.wait() }
    }

    @Test
    func raceSucceedsWhenChannelOpensBeforeAuthExhausts() throws {
        // The happy path: auth succeeded, the channel opens, and the auth latch
        // never fails. The raced result must hand back the opened channel.
        let loop = EmbeddedEventLoop()
        defer { try? loop.syncShutdownGracefully() }
        let opens = loop.makePromise(of: Channel.self)
        let authExhausted = loop.makePromise(of: Void.self)
        let raced = NIOSSHConnectionFactory.raceAuthExhaustion(
            opens.futureResult,
            authExhausted: authExhausted.futureResult,
            on: loop
        )
        let channel = EmbeddedChannel(loop: loop)
        opens.succeed(channel)
        loop.run()
        #expect(throws: Never.self) { _ = try raced.wait() }
        _ = try? channel.finish()
    }
}

/// Thread-safe one-shot flag for asserting an `onExhausted` callback fired.
final class ExhaustionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    func set() { lock.lock(); defer { lock.unlock() }; fired = true }
}
