import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Pluggable strategy for pulling the remote snapshot file (already
/// produced by `sqlite3 .backup` on the host) back to a local path.
///
/// Introduced so the macOS production transfer (system `sftp`) and the
/// cross-platform transfer (NIO-SSH `exec cat`) sit behind the same call
/// site. ``RemoteSnapshot`` picks the right one at construction.
public protocol RemoteSnapshotTransfer: Sendable {
    /// Streams the file at `remotePath` on the host into `to` on the
    /// local filesystem. Implementations are expected to fail loudly on
    /// non-zero remote exit, oversize content, or local I/O errors.
    func fetch(remotePath: String, to: URL) async throws

    /// Uploads the local file at `localURL` to `remotePath` on the host.
    ///
    /// Implementations write to a sibling remote temp path and then
    /// atomically rename it over `remotePath`, so a concurrent reader (the
    /// Hermes agent's own `memory` tool, say) never observes a half-written
    /// file. The parent directory is created if missing. This is the first
    /// non-dashboard *write* path — the only surface that needs it today is
    /// the Memory editor (`MEMORY.md` / `USER.md`), which has no dashboard
    /// route. See `docs/security.md`.
    func upload(from localURL: URL, to remotePath: String) async throws
}

// MARK: - SFTP subprocess transfer (macOS only)

#if os(macOS)

/// macOS production transfer that shells out to `/usr/bin/sftp -b -` with
/// a single `get` command. This is what every release before the NIO-SSH
/// work shipped — kept intact so the default path stays byte-for-byte
/// identical and so users with agent-only profiles (no NIO support yet)
/// still have a working snapshot pipeline.
public struct SFTPSubprocessTransfer: RemoteSnapshotTransfer {
    private let profile: ServerProfile

    public init(profile: ServerProfile) {
        self.profile = profile
    }

    public func fetch(remotePath: String, to: URL) async throws {
        guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }

        var arguments: [String] = []
        if let port = profile.port {
            arguments += ["-P", String(port)]
        }
        if let identityFile = profile.identityFile {
            arguments += ["-i", identityFile]
        }
        arguments += ["-b", "-"]
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments.append(destination)

        // Download to a sibling tmp file then atomically rename, so any
        // SessionsBrowser query still holding an open handle to the old
        // state.db keeps reading the previous inode instead of tripping on
        // torn pages mid-transfer. Same-filesystem rename, so it's atomic.
        let tmpURL = to.appendingPathExtension("downloading-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmpURL)

        let batch = Self.sftpGetCommand(remoteTmp: remotePath, localPath: tmpURL.path) + "\n"
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sftp"),
            arguments: arguments,
            stdin: Data(batch.utf8),
            timeout: 60
        )
        if result.timedOut {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSHTransportError.commandTimeout("sftp get timed out after 60s")
        }
        if result.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpURL)
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SSHTransportError.transferFailed(stderr)
        }
        guard FileManager.default.fileExists(atPath: tmpURL.path) else {
            throw SSHTransportError.transferFailed("sftp succeeded but local file is missing at \(tmpURL.path)")
        }
        try NIOSSHCatTransfer.installAtomically(from: tmpURL, to: to)
    }

    public func upload(from localURL: URL, to remotePath: String) async throws {
        guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw SSHTransportError.transferFailed("local upload source is missing at \(localURL.path)")
        }

        var arguments: [String] = []
        if let port = profile.port {
            arguments += ["-P", String(port)]
        }
        if let identityFile = profile.identityFile {
            arguments += ["-i", identityFile]
        }
        arguments += ["-b", "-"]
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments.append(destination)

        // Upload to a sibling remote temp then rename over the target, so a
        // concurrent reader of `remotePath` (the agent's own memory tool)
        // never sees a torn write. Same-filesystem rename → atomic.
        let remoteTmp = "\(remotePath).uploading-\(UUID().uuidString)"
        let batch = Self.sftpPutCommands(localPath: localURL.path, remoteTmp: remoteTmp, remotePath: remotePath)
            .joined(separator: "\n") + "\n"
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sftp"),
            arguments: arguments,
            stdin: Data(batch.utf8),
            timeout: 60
        )
        if result.timedOut {
            throw SSHTransportError.commandTimeout("sftp put timed out after 60s")
        }
        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SSHTransportError.transferFailed(stderr)
        }
    }

    /// Visible for testing. Builds the single-line sftp batch command
    /// that pulls the remote temp file to the local cache path. Both
    /// paths are double-quoted so a space in either (e.g. a Mac user
    /// with a space in their short name → `/Users/John Doe/...`) doesn't
    /// get parsed as two sftp arguments. sftp uses backslash to escape
    /// inside double quotes.
    static func sftpGetCommand(remoteTmp: String, localPath: String) -> String {
        "get \(sftpQuote(remoteTmp)) \(sftpQuote(localPath))"
    }

    /// Visible for testing. Builds the sftp batch lines that upload `localPath`
    /// to `remotePath` via a temp + rename. The leading `-` on `mkdir` tells
    /// sftp batch mode to ignore a failure (the `memories/` dir already
    /// existing is the normal case); `put`/`rename` keep their default
    /// abort-on-error so a real failure surfaces a non-zero exit. OpenSSH's
    /// `rename` uses the `posix-rename@openssh.com` extension, which overwrites
    /// the destination atomically. All paths are double-quoted (sftp escapes
    /// with backslash inside double quotes) so spaces don't split arguments.
    static func sftpPutCommands(localPath: String, remoteTmp: String, remotePath: String) -> [String] {
        var commands: [String] = []
        let parent = (remotePath as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != "/", parent != "." {
            commands.append("-mkdir \(sftpQuote(parent))")
        }
        commands.append("put \(sftpQuote(localPath)) \(sftpQuote(remoteTmp))")
        commands.append("rename \(sftpQuote(remoteTmp)) \(sftpQuote(remotePath))")
        return commands
    }

    private static func sftpQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

#endif

// MARK: - NIO-SSH `exec cat` transfer (cross-platform)

/// Cross-platform transfer that streams the remote file over a fresh
/// NIO-SSH connection by running `cat -- '<remotePath>'`.
///
/// **Why a fresh connection per fetch:** the plan recommends single-shot
/// connections in v1 — pooling adds complexity (especially around the
/// TOFU prompt firing twice on a fresh remote) and we haven't measured a
/// latency problem yet. If it becomes one, factor a `NIOSSHConnection`
/// actor that vends multiple child channels.
///
/// **Integrity:** SSH MACs guarantee the bytes on the wire weren't
/// tampered with; the downstream `PRAGMA integrity_check` on the SQLite
/// file detects torn pages or truncation. The 256 MiB cap is a safety
/// net against a misconfigured `remotePath` pointing at a huge file.
public struct NIOSSHCatTransfer: RemoteSnapshotTransfer {
    /// 256 MiB. A typical Hermes `state.db` is ≤ 100 MB after years of
    /// use; the cap rejects misconfigured paths (e.g. `remotePath` pointed
    /// at `/dev/zero`) without trusting the remote shell to bound output.
    public static let maxBytes: Int = 256 * 1024 * 1024

    /// Whole-round-trip cap for the `cat` exec, matching the system-ssh
    /// `SFTPSubprocessTransfer` deadline. Without this, a hung remote
    /// read (NFS-backed `state.db` whose server is blocked, a stalled
    /// remote shell, a sleeping container) would leave the snapshot
    /// refresh awaiting indefinitely — on iOS that's terminal because
    /// this is the only fetch implementation.
    public static let fetchTimeout: TimeAmount = .seconds(60)

    private let profile: ServerProfile
    private let credentialProvider: SSHCredentialProvider
    private let hostKeyStore: HostKeyStore
    private let hostKeyConfirmer: HostKeyConfirmer?
    private let passphrase: String?
    private let group: EventLoopGroup

    public init(
        profile: ServerProfile,
        credentialProvider: SSHCredentialProvider,
        hostKeyStore: HostKeyStore,
        hostKeyConfirmer: HostKeyConfirmer? = nil,
        passphrase: String? = nil,
        group: EventLoopGroup = SSHEventLoopGroup.shared
    ) {
        self.profile = profile
        self.credentialProvider = credentialProvider
        self.hostKeyStore = hostKeyStore
        self.hostKeyConfirmer = hostKeyConfirmer
        self.passphrase = passphrase
        self.group = group
    }

    public func fetch(remotePath: String, to: URL) async throws {
        let connection = try await makeConnection()
        // No `defer { connection.close().wait() }` — calling
        // EventLoopFuture.wait() from an async function blocks a
        // cooperative-pool thread (anti-pattern flagged by swift-nio).
        // Instead, close explicitly on every exit path.
        do {
            try await fetchOnConnection(
                connection: connection,
                remotePath: remotePath,
                to: to
            )
        } catch {
            _ = try? await connection.close().get()
            throw error
        }
        _ = try? await connection.close().get()
    }

    public func upload(from localURL: URL, to remotePath: String) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw SSHTransportError.transferFailed("local upload source is missing at \(localURL.path)")
        }
        // Memory files are a few KB; reading the payload into memory keeps the
        // stdin-streaming handler simple. The 256 MiB `maxBytes` cap still
        // guards the read against a pathologically large source.
        let payload: Data
        do {
            payload = try Data(contentsOf: localURL)
        } catch {
            throw SSHTransportError.transferFailed("could not read upload source: \(error.localizedDescription)")
        }
        if payload.count > Self.maxBytes {
            throw SSHTransportError.transferFailed("upload source exceeds \(Self.maxBytes)-byte cap (got \(payload.count))")
        }

        let connection = try await makeConnection()
        do {
            try await uploadOnConnection(connection: connection, payload: payload, remotePath: remotePath)
        } catch {
            _ = try? await connection.close().get()
            throw error
        }
        _ = try? await connection.close().get()
    }

    /// Opens a fresh authenticated SSH connection, reusing the same auth and
    /// host-key delegates as the snapshot fetch — `upload` deliberately adds no
    /// new trust surface. Typed host-key / auth errors are funneled through the
    /// ACP transport's translator so both transports surface identical errors.
    private func makeConnection() async throws -> Channel {
        guard let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }
        let port = profile.port ?? 22
        let user = profile.user ?? NSUserName()

        let privateKey = try credentialProvider.privateKey(for: profile, passphrase: passphrase)
        let password = try credentialProvider.password(for: profile)
        if privateKey == nil, password == nil {
            throw SSHTransportError.authFailed("profile has no identity file or password configured")
        }
        let authDelegate = NIOSSHAuthDelegate(username: user, privateKey: privateKey, password: password)
        let hostKeyDelegate = NIOSSHHostKeyVerifier(store: hostKeyStore, host: host, port: port, confirmUnknown: hostKeyConfirmer)

        let bootstrap = ClientBootstrap(group: group)
            // Match the dashboard connection's connect bound so a stalled SYN
            // doesn't pin the UI for ~75s on macOS's default TCP backoff.
            .connectTimeout(.seconds(15))
            // Build the (non-Sendable) `SSHClientConfiguration` and install the
            // handler on the event loop so neither crosses the `@Sendable`
            // initializer boundary; only the Sendable delegates are captured.
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(SSHClientConfiguration(
                                userAuthDelegate: authDelegate,
                                serverAuthDelegate: hostKeyDelegate
                            )),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }

        do {
            return try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // Typed host-key / auth errors raised by our delegates would
            // otherwise escape unwrapped and be reclassified as a generic
            // `.ioFailed` by RemoteSnapshot.runFetch. Funnel them through
            // the same translator the dashboard transport uses so both
            // surface identical typed errors for the same conditions.
            throw NIOSSHConnectError.map(error, host: host, port: port)
        }
    }

    private func fetchOnConnection(connection: Channel, remotePath: String, to: URL) async throws {
        let tmpURL = to.appendingPathExtension("downloading-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tmpURL)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        guard let writeHandle = try? FileHandle(forWritingTo: tmpURL) else {
            throw SSHTransportError.transferFailed("could not open local tmp file at \(tmpURL.path)")
        }
        // `FileHandle.close()` is best-effort and idempotent in practice;
        // a defer that doesn't await is safe (it's a synchronous Foundation
        // call), so we keep it for the always-cleanup leg.
        defer { try? writeHandle.close() }

        let command = "cat -- \(ShellQuoting.shellQuote(remotePath))"
        let result: CatResultBox
        do {
            result = try await runExec(connection: connection, command: command, writeHandle: writeHandle)
        } catch let typed as SSHTransportError {
            // Preserve the typed error (most importantly the
            // `.commandTimeout` that `runExec` raises on a 60s stall) so
            // `RemoteSnapshot.runFetch` routes it through `.sshFailed`
            // instead of collapsing every cause into `.sftpFailed`.
            try? FileManager.default.removeItem(at: tmpURL)
            throw typed
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSHTransportError.transferFailed(error.localizedDescription)
        }

        if let error = result.error {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSHTransportError.transferFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpURL)
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHTransportError.transferFailed(stderr.isEmpty ? "remote cat exited \(result.exitCode)" : stderr)
        }
        if result.bytesWritten > Self.maxBytes {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSHTransportError.transferFailed("remote file exceeds \(Self.maxBytes)-byte cap (got \(result.bytesWritten))")
        }
        try? writeHandle.close()
        // `replaceItemAt` ships on every Apple platform back to iOS 4 /
        // macOS 10.6, so both transports can share the same install path.
        // Avoids the previous iOS-only `removeItem` + `moveItem` pair,
        // which left a window where the snapshot didn't exist on disk —
        // a concurrent `HermesDB.open` would have seen file-not-found.
        try Self.installAtomically(from: tmpURL, to: to)
    }

    private func uploadOnConnection(connection: Channel, payload: Data, remotePath: String) async throws {
        let remoteTmp = "\(remotePath).uploading-\(UUID().uuidString)"
        let command = Self.writeCommand(remoteTmp: remoteTmp, remotePath: remotePath)
        let result: WriteResultBox
        do {
            result = try await runWriteExec(connection: connection, command: command, payload: payload)
        } catch let typed as SSHTransportError {
            throw typed
        } catch {
            throw SSHTransportError.transferFailed(error.localizedDescription)
        }

        if let error = result.error {
            throw SSHTransportError.transferFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHTransportError.transferFailed(stderr.isEmpty ? "remote write exited \(result.exitCode)" : stderr)
        }
    }

    /// Visible for testing. The remote shell line that receives the file on
    /// stdin and atomically installs it: create the parent dir if missing,
    /// `cat` stdin into a sibling temp, then `mv -f` it over the target (a
    /// same-directory rename, atomic on POSIX filesystems) so a concurrent
    /// reader never sees a partial write. Every path is single-quoted (no
    /// shell expansion) exactly like the `cat` fetch command.
    static func writeCommand(remoteTmp: String, remotePath: String) -> String {
        let quote = ShellQuoting.shellQuote
        let parent = (remotePath as NSString).deletingLastPathComponent
        var prefix = ""
        if !parent.isEmpty, parent != "/", parent != "." {
            prefix = "mkdir -p \(quote(parent)) && "
        }
        return "\(prefix)cat > \(quote(remoteTmp)) && mv -f \(quote(remoteTmp)) \(quote(remotePath))"
    }

    /// Shared atomic-install helper for both transports. `replaceItemAt`
    /// is atomic on the same filesystem and (unlike `moveItem`) preserves
    /// the *existing* destination's inode for any reader that already
    /// opened it — important when SessionsBrowser holds an open SQLite
    /// handle while we swap state.db underneath.
    static func installAtomically(from tmpURL: URL, to localURL: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: localURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw SSHTransportError.transferFailed("rename \(tmpURL.lastPathComponent) → \(localURL.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

}

/// Per-fetch child-channel handler. Drives the `cat` exec, streams
/// stdout to the file (off the event loop, so the shared single-threaded
/// `SSHEventLoopGroup.shared` doesn't stall the live dashboard/chat channels
/// during multi-MB transfers), accumulates stderr, captures the exit code, and
/// fulfills `complete` on channel close.
///
/// Writes are serialized through a dedicated `DispatchQueue` so out-of-
/// order chunks never interleave on disk, and we still tear the channel
/// down on the event loop the moment a write fails or the size cap is
/// breached.
/// `@unchecked Sendable`: all handler state is read and written exclusively on
/// the channel's event loop. The background `writeQueue` only ever touches the
/// captured `FileHandle` and the local chunk — never the handler's own mutable
/// state — and hops back to the event loop (`eventLoop.execute`) before calling
/// `fail` or reading `result`. The conformance lets those on-loop hops capture
/// `self`, and lets the timeout timer hold a reference, without tripping
/// strict-concurrency capture checks.
final class NIOSSHCatHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let writeHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "com.talaria.HermesKit.NIOSSHCatHandler.write")
    private var complete: EventLoopPromise<NIOSSHCatTransfer.CatResultBox>?
    private var result = NIOSSHCatTransfer.CatResultBox()
    private var failed = false
    private var bytesQueued: Int = 0
    // Set by the fetch-timeout timer (event-loop scheduled). Read in
    // channelInactive when fulfilling the promise.
    private var timedOut = false

    init(command: String, writeHandle: FileHandle, complete: EventLoopPromise<NIOSSHCatTransfer.CatResultBox>) {
        self.command = command
        self.writeHandle = writeHandle
        self.complete = complete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let option = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        option.assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).assumeIsolated().whenFailure { [weak self] error in
            self?.fail(error: error)
            context.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = envelope.data else { return }
        switch envelope.type {
        case .channel:
            let chunk = Data(bytes.readableBytesView)
            // Track queued bytes synchronously so the cap fires on the
            // event loop (no race with the dispatch queue draining writes
            // in the background). The actual write happens off-loop.
            bytesQueued += chunk.count
            result.bytesWritten = bytesQueued
            if bytesQueued > NIOSSHCatTransfer.maxBytes {
                // Tear down the child channel — caller reports oversize
                // and cleans up the tmp file.
                context.close(promise: nil)
                return
            }
            let handle = writeHandle
            let eventLoop = context.eventLoop
            // Capture the `Channel`, not `context`: the
            // `ChannelHandlerContext` is invalidated the moment the
            // handler is removed from the pipeline (which can happen
            // before this deferred hop runs, e.g. on a remote half-close
            // while a multi-MB write is still draining on the dispatch
            // queue). Touching `context` after removal is undefined and
            // trips swift-nio's debug preconditions. The `Channel`
            // reference stays valid; `close(promise: nil)` is idempotent
            // and safe to call after the channel is already closing.
            let channel = context.channel
            writeQueue.async { [weak self] in
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    // Bind to a local `let` so the event-loop hop captures a
                    // constant rather than the mutable weak `self` binding.
                    let handler = self
                    eventLoop.execute {
                        handler?.fail(error: error)
                        channel.close(promise: nil)
                    }
                }
            }
        case .stdErr:
            result.stderr += String(decoding: bytes.readableBytesView, as: UTF8.self)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            result.exitCode = exit.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Drain any in-flight writes before fulfilling the promise — the
        // caller must never see "succeeded" while bytes are still queued.
        // `writeQueue.sync` would block the SSH event loop (single-thread
        // shared ELG), freezing every other channel on it including the
        // live dashboard and chat channels. Instead, post an `.async` to the *serial*
        // write queue: it can only run after every prior write has
        // finished, then we hop back to the loop to fulfill the promise.
        //
        // Read `self.result` inside the final hop, not here: a late
        // chunk-write failure posts `eventLoop.execute { self.fail(...) }`
        // back to the loop, which can land after channelInactive has run
        // but before the drain hop completes. Snapshotting `result` here
        // would freeze the no-error baseline and silently drop the late
        // error, surfacing a truncated file as a "successful" fetch.
        result.timedOut = timedOut
        let queue = writeQueue
        let eventLoop = context.eventLoop
        let promise = complete
        complete = nil
        queue.async {
            eventLoop.execute { [self] in
                promise?.succeed(result)
            }
        }
        context.fireChannelInactive()
    }

    /// Called by ``NIOSSHCatTransfer.runExec``'s fetch-timeout timer
    /// before it force-closes the child channel. Must be invoked on the
    /// channel's event loop (the timer schedules it there). The flag is
    /// read in `channelInactive` when the post-close promise is
    /// fulfilled.
    func markTimedOut() {
        timedOut = true
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error: error)
        context.close(promise: nil)
    }

    private func fail(error: Error) {
        guard !failed else { return }
        failed = true
        result.error = error
        complete?.succeed(result)
        complete = nil
    }
}

/// Per-upload child-channel handler. Requests the remote write command, streams
/// the file as stdin, half-closes our output side to deliver stdin EOF, then
/// accumulates stderr and captures the exit code. Modeled on
/// ``NIOSSHCatHandler`` but inverted (we write stdin instead of reading stdout);
/// the payload is small (memory files), so it's sent as a single channel-data
/// message rather than chunked off-loop.
///
/// `@unchecked Sendable`: all handler state is touched only on the channel's
/// event loop. The on-loop future continuations (exec reply, write completion)
/// capture `context`, which stays valid for the brief active window between
/// `channelActive` and the post-write half-close.
final class NIOSSHWriteHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let payload: [UInt8]
    private var complete: EventLoopPromise<NIOSSHCatTransfer.WriteResultBox>?
    private var result = NIOSSHCatTransfer.WriteResultBox()
    private var failed = false
    private var timedOut = false

    init(command: String, payload: Data, complete: EventLoopPromise<NIOSSHCatTransfer.WriteResultBox>) {
        self.command = command
        self.payload = Array(payload)
        self.complete = complete
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let option = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        option.assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest).assumeIsolated().whenComplete { [weak self] outcome in
            switch outcome {
            case .success:
                self?.sendPayload(context: context)
            case .failure(let error):
                self?.fail(error: error)
                context.close(promise: nil)
            }
        }
    }

    private func sendPayload(context: ChannelHandlerContext) {
        guard !payload.isEmpty else {
            // Empty file: nothing to stream, just signal stdin EOF so the
            // remote `cat` writes an empty file and `mv` installs it.
            context.close(mode: .output, promise: nil)
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.writeAndFlush(wrapOutboundOut(data)).assumeIsolated().whenComplete { [weak self] outcome in
            switch outcome {
            case .success:
                // Half-close our output side → remote stdin EOF → `cat` finishes.
                context.close(mode: .output, promise: nil)
            case .failure(let error):
                self?.fail(error: error)
                context.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = envelope.data else { return }
        // The write command emits no stdout; only stderr is of interest.
        if envelope.type == .stdErr {
            result.stderr += String(decoding: bytes.readableBytesView, as: UTF8.self)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            result.exitCode = exit.exitStatus
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        result.timedOut = timedOut
        let promise = complete
        complete = nil
        promise?.succeed(result)
        context.fireChannelInactive()
    }

    /// Called by ``NIOSSHCatTransfer.runWriteExec``'s timeout timer on the event
    /// loop before it force-closes the channel.
    func markTimedOut() {
        timedOut = true
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error: error)
        context.close(promise: nil)
    }

    private func fail(error: Error) {
        guard !failed else { return }
        failed = true
        result.error = error
        complete?.succeed(result)
        complete = nil
    }
}

extension NIOSSHCatTransfer {
    /// Captured outcome of a single `cat` exec invocation. `timedOut` is
    /// set only by the fetch-timeout path so the caller can distinguish a
    /// real stall from a legitimately-empty remote file (which would
    /// otherwise share the same `exitCode == 0 && bytesWritten == 0`
    /// signature).
    public struct CatResultBox: @unchecked Sendable {
        public var exitCode: Int = 0
        public var bytesWritten: Int = 0
        public var stderr: String = ""
        public var error: Error?
        public var timedOut: Bool = false

        public init() {}
    }

    fileprivate func runExec(
        connection: Channel,
        command: String,
        writeHandle: FileHandle
    ) async throws -> CatResultBox {
        let promise = connection.eventLoop.makePromise(of: CatResultBox.self)

        // Resolve the (non-Sendable, library) `NIOSSHHandler` and open the
        // session child channel entirely on the event loop, so it never
        // crosses an async boundary. The cat handler is installed inside the
        // on-loop initializer.
        let childChannel = try await connection.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
            let childPromise = connection.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                    childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            NIOSSHCatHandler(command: command, writeHandle: writeHandle, complete: promise)
                        )
                    }
                }
            } catch {
                childPromise.fail(error)
            }
            return childPromise.futureResult
        }.get()

        // Bound the await against ``fetchTimeout``. On expiry we flag the
        // handler (so the eventual `channelInactive` fulfills the promise
        // with `timedOut == true`) and force-close the channel to unblock
        // the await. Cleaning up the timer when the promise settles
        // normally avoids a dangling reference.
        let timeout = connection.eventLoop.scheduleTask(in: Self.fetchTimeout) {
            // On the event loop: read the handler back from the pipeline rather
            // than capturing it, then mark the timeout and tear the channel down.
            let handler = try? childChannel.pipeline.syncOperations.handler(type: NIOSSHCatHandler.self)
            handler?.markTimedOut()
            childChannel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }

        let result = try await promise.futureResult.get()
        if result.timedOut {
            // Re-shape into the typed timeout RemoteSnapshot.runFetch
            // already maps to `RemoteSnapshotError.sshFailed`. Use the
            // dedicated flag rather than inferring from empty state —
            // a legitimately empty `state.db` produces the same
            // `exitCode == 0 && bytesWritten == 0` signature, and we
            // must not collapse those into a spurious timeout error.
            throw SSHTransportError.commandTimeout("cat exec exceeded \(Self.fetchTimeout) — remote stalled")
        }
        return result
    }

    /// Captured outcome of a single write exec. Mirrors ``CatResultBox`` minus
    /// the byte counter (the write command emits no stdout to size).
    public struct WriteResultBox: @unchecked Sendable {
        public var exitCode: Int = 0
        public var stderr: String = ""
        public var error: Error?
        public var timedOut: Bool = false

        public init() {}
    }

    fileprivate func runWriteExec(
        connection: Channel,
        command: String,
        payload: Data
    ) async throws -> WriteResultBox {
        let promise = connection.eventLoop.makePromise(of: WriteResultBox.self)

        let childChannel = try await connection.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
            let childPromise = connection.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                sshHandler.createChannel(childPromise, channelType: .session) { childChannel, _ in
                    childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandler(
                            NIOSSHWriteHandler(command: command, payload: payload, complete: promise)
                        )
                    }
                }
            } catch {
                childPromise.fail(error)
            }
            return childPromise.futureResult
        }.get()

        let timeout = connection.eventLoop.scheduleTask(in: Self.fetchTimeout) {
            let handler = try? childChannel.pipeline.syncOperations.handler(type: NIOSSHWriteHandler.self)
            handler?.markTimedOut()
            childChannel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timeout.cancel() }

        let result = try await promise.futureResult.get()
        if result.timedOut {
            throw SSHTransportError.commandTimeout("write exec exceeded \(Self.fetchTimeout) — remote stalled")
        }
        return result
    }
}
