import Foundation

public enum LogLevel: String, Sendable, Equatable, CaseIterable, Codable {
    case debug
    case info
    case warn
    case error
    case unknown

    public init(string: String) {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        switch s {
        case "debug", "dbg", "trace": self = .debug
        case "info", "inf": self = .info
        case "warn", "warning", "wrn": self = .warn
        case "error", "err", "fatal", "crit", "critical": self = .error
        default: self = .unknown
        }
    }
}

public struct LogLine: Sendable, Equatable {
    public let timestamp: Date?
    public let level: LogLevel
    public let component: String
    public let message: String
    public let raw: String

    public init(timestamp: Date?, level: LogLevel, component: String, message: String, raw: String) {
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
        self.raw = raw
    }
}

public protocol HermesLogTailing: Sendable {
    func tail(component: String?) -> AsyncThrowingStream<LogLine, Error>
}

public enum HermesLogs {
    /// Parse a single log line into a structured `LogLine`. Recognizes:
    ///   * Bracketed form `[ISO8601] [LEVEL] component: msg`
    ///   * Python-logging form `YYYY-MM-DD HH:MM:SS,mmm LEVEL component: msg`
    ///     — the actual hermes log layout, optionally followed by an
    ///     `[session-uuid]` bracket between LEVEL and component.
    /// Free-form lines (tracebacks, printf escapees) fall through with
    /// `level = .unknown, component = ""`.
    public static func parse(_ raw: String) -> LogLine {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parseBracketed(trimmed) {
            return LogLine(
                timestamp: parsed.timestamp,
                level: parsed.level,
                component: parsed.component,
                message: parsed.message,
                raw: raw
            )
        }
        if let parsed = parsePythonLogging(trimmed) {
            return LogLine(
                timestamp: parsed.timestamp,
                level: parsed.level,
                component: parsed.component,
                message: parsed.message,
                raw: raw
            )
        }
        return LogLine(timestamp: nil, level: .unknown, component: "", message: trimmed, raw: raw)
    }

    private struct Parsed {
        let timestamp: Date?
        let level: LogLevel
        let component: String
        let message: String
    }

    private static func parseBracketed(_ line: String) -> Parsed? {
        // [timestamp] [level] component: message
        guard line.hasPrefix("[") else { return nil }
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil
        guard scanner.scanString("[") != nil,
              let ts = scanner.scanUpToString("]"),
              scanner.scanString("]") != nil else {
            return nil
        }
        _ = scanner.scanCharacters(from: .whitespaces)

        var level: LogLevel = .unknown
        if scanner.scanString("[") != nil,
           let levelText = scanner.scanUpToString("]") {
            _ = scanner.scanString("]")
            level = LogLevel(string: levelText)
        }
        _ = scanner.scanCharacters(from: .whitespaces)

        let rest = String(line[scanner.currentIndex...])
        let component: String
        let message: String
        if let colon = rest.firstIndex(of: ":") {
            component = rest[rest.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            message = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            component = ""
            message = rest.trimmingCharacters(in: .whitespaces)
        }

        let timestamp = parseTimestamp(ts)
        return Parsed(timestamp: timestamp, level: level, component: component, message: message)
    }

    /// Parses Python's stdlib logging default format:
    ///   `YYYY-MM-DD HH:MM:SS,mmm LEVEL [session-uuid] component: message`
    /// where the `[session-uuid]` block is optional. Anchoring on the
    /// fixed-width date prefix avoids spurious matches on free-form lines
    /// that happen to start with a digit.
    private static func parsePythonLogging(_ line: String) -> Parsed? {
        // Cheapest possible structural check: index 4 and 7 must be '-' for
        // YYYY-MM-DD; without this the regex below burns time on every
        // stack-trace continuation line.
        let chars = Array(line)
        guard chars.count >= 23,
              chars[4] == "-", chars[7] == "-",
              chars[10] == " ",
              chars[13] == ":", chars[16] == ":" else {
            return nil
        }
        let tsString = String(chars[0..<23])
        let afterTimestamp = String(chars[23...]).trimmingCharacters(in: .whitespaces)
        // Next field: LEVEL (alphabetic, uppercase).
        guard let spaceAfterLevel = afterTimestamp.firstIndex(where: { $0.isWhitespace }) else {
            return nil
        }
        let levelText = String(afterTimestamp[afterTimestamp.startIndex..<spaceAfterLevel])
        guard !levelText.isEmpty, levelText.allSatisfy({ $0.isLetter }) else { return nil }
        let level = LogLevel(string: levelText)
        var rest = afterTimestamp[afterTimestamp.index(after: spaceAfterLevel)...].drop(while: { $0.isWhitespace })

        // Optional [session-id] bracket. Skip past it — useful as context
        // but doesn't fit any first-class LogLine field today.
        if rest.first == "[" {
            if let close = rest.firstIndex(of: "]") {
                rest = rest[rest.index(after: close)...].drop(while: { $0.isWhitespace })
            }
        }
        // `component: message`
        let restString = String(rest)
        let component: String
        let message: String
        if let colon = restString.firstIndex(of: ":") {
            component = restString[restString.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            message = String(restString[restString.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else {
            component = ""
            message = restString.trimmingCharacters(in: .whitespaces)
        }
        return Parsed(timestamp: parsePythonTimestamp(tsString), level: level, component: component, message: message)
    }

    /// `YYYY-MM-DD HH:MM:SS,mmm` — Python logging's default. The comma
    /// separator means stdlib ISO8601 parsers reject it; we swap in a dot
    /// and reuse the fractional-seconds formatter.
    static func parsePythonTimestamp(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Hermes runs in the host TZ (this is python's default logging
        // formatter behaviour). Without setting a TZ here Foundation
        // assumes UTC and the rendered times drift by the user's offset.
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: normalized)
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: value) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: value) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

#if os(macOS)
/// Polls `<hermesHome>/logs/*.log` for new bytes and emits parsed lines.
/// Re-scans the directory each tick so rotated/newly-created log files start
/// streaming without restart. Polling (~250ms) over DispatchSource keeps the
/// implementation simple — log volume in a Hermes daemon doesn't justify the
/// per-file source dance, and `tail -F` on the remote side already polls.
public struct LocalLogTailing: HermesLogTailing {
    public let hermesHome: String
    public let pollInterval: TimeInterval

    public init(hermesHome: String, pollInterval: TimeInterval = 0.25) {
        self.hermesHome = hermesHome
        self.pollInterval = pollInterval
    }

    public func tail(component: String?) -> AsyncThrowingStream<LogLine, Error> {
        let dir = URL(fileURLWithPath: (hermesHome as NSString).appendingPathComponent("logs"))
        let pollInterval = pollInterval
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                var offsets: [URL: UInt64] = [:]
                var buffers: [URL: Data] = [:]
                var initialised = false

                while !Task.isCancelled {
                    let urls = (try? FileManager.default.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    let logURLs = urls.filter { $0.pathExtension == "log" }

                    for url in logURLs where offsets[url] == nil {
                        // On first sweep, start at EOF so we don't dump
                        // historical content into the live view. New files
                        // that appear after start stream from byte 0.
                        if !initialised {
                            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                            offsets[url] = size
                        } else {
                            offsets[url] = 0
                        }
                        buffers[url] = Data()
                    }

                    for url in logURLs {
                        guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                        defer { try? handle.close() }
                        let currentSize = (try? handle.seekToEnd()) ?? 0
                        let lastOffset = offsets[url] ?? 0
                        if currentSize < lastOffset {
                            // file truncated (rotated in place): restart at 0
                            offsets[url] = 0
                            buffers[url] = Data()
                            continue
                        }
                        if currentSize == lastOffset { continue }
                        try? handle.seek(toOffset: lastOffset)
                        let data = (try? handle.readToEnd()) ?? Data()
                        // Advance by what we *actually* consumed, not the
                        // size measured before the read. If writes landed
                        // between seekToEnd and readToEnd, readToEnd would
                        // include them; trusting currentSize here would
                        // re-seek into already-emitted bytes on the next
                        // tick and produce duplicate lines.
                        offsets[url] = lastOffset + UInt64(data.count)

                        var buffer = buffers[url] ?? Data()
                        buffer.append(data)
                        emitLines(from: &buffer, component: component) { line in
                            continuation.yield(line)
                        }
                        buffers[url] = buffer
                    }

                    initialised = true
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Spawns `ssh ... tail -F <hermesHome>/logs/*.log` as a long-lived process and
/// emits each parsed line. Cancellation of the AsyncStream terminates the
/// underlying `ssh` (and the remote `tail`).
///
/// `hermesHome` is optional: when nil (or the explicit value uses `~`), the
/// tailer first runs a short remote command — wrapped in the profile's shell
/// mode — to resolve `${HERMES_HOME:-$HOME/.hermes}` against the remote
/// environment, then uses that absolute path for the tail. Resolution errors
/// flow through the stream like any other tail failure.
public struct RemoteLogTailing: HermesLogTailing {
    public let profile: ServerProfile
    public let hermesHome: String?

    public init(profile: ServerProfile, hermesHome: String? = nil) {
        self.profile = profile
        self.hermesHome = hermesHome
    }

    public func tail(component: String?) -> AsyncThrowingStream<LogLine, Error> {
        AsyncThrowingStream { continuation in
            guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
                continuation.finish(throwing: SSHTransportError.other("profile is not an SSH profile"))
                return
            }

            let processBox = RemoteTailProcessBox()
            continuation.onTermination = { _ in
                processBox.cancel()
            }

            let profileCopy = profile
            let hermesHomeCopy = hermesHome
            let comp = component
            Task {
                let resolved: String
                do {
                    resolved = try await Self.resolveHermesHome(
                        profile: profileCopy,
                        hermesHome: hermesHomeCopy
                    )
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                if processBox.isCancelled {
                    continuation.finish()
                    return
                }
                Self.startTail(
                    profile: profileCopy,
                    hermesHome: resolved,
                    host: host,
                    component: comp,
                    processBox: processBox,
                    continuation: continuation
                )
            }
        }
    }

    private static func startTail(
        profile: ServerProfile,
        hermesHome: String,
        host: String,
        component: String?,
        processBox: RemoteTailProcessBox,
        continuation: AsyncThrowingStream<LogLine, Error>.Continuation
    ) {
        var sshArgs: [String] = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let port = profile.port {
            sshArgs += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile {
            sshArgs += ["-i", identityFile]
        }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        sshArgs += ["--", destination]
        sshArgs.append(remoteTailScript(hermesHome: hermesHome))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let reader = AdminLineReader(handle: stdoutPipe.fileHandleForReading, label: "remoteLogs.stdout") { rawLine in
            let parsed = HermesLogs.parse(rawLine)
            if let comp = component, !comp.isEmpty {
                if !parsed.component.localizedCaseInsensitiveContains(comp) { return }
            }
            continuation.yield(parsed)
        }
        // Buffer ssh's stderr so we can attribute non-zero exits to it.
        // Without this, an auth failure / unreachable host / missing logs
        // directory / BatchMode rejection just finishes the stream
        // silently and the view shows an empty log with no banner.
        let stderrBuffer = StderrBuffer()
        let stderrReader = AdminLineReader(handle: stderrPipe.fileHandleForReading, label: "remoteLogs.stderr") { line in
            stderrBuffer.append(line)
        }

        process.terminationHandler = { proc in
            reader.finish()
            stderrReader.finish()
            if proc.terminationStatus != 0 {
                let stderr = stderrBuffer.snapshot()
                let classified = SSHTransport.classifyStderr(stderr)
                let detail: String
                switch classified {
                case .other:
                    detail = stderr.isEmpty
                        ? "remote log tail exited \(proc.terminationStatus)"
                        : stderr
                default:
                    detail = classified.errorDescription ?? "remote log tail failed"
                }
                continuation.finish(throwing: SSHTransportError.other(detail))
            } else {
                continuation.finish()
            }
        }

        // Start the process *before* publishing it to the box. Otherwise
        // there's a narrow window where attach() registers the process,
        // cancel() fires (consumer drops the stream just as resolve
        // returns), snapshots a non-running Process, skips terminate(),
        // and then run() spawns ssh+tail with nothing watching it — an
        // orphaned remote `tail -F` until the TCP connection drops.
        // Attaching after run() flips the ordering: if cancel beat us to
        // the lock, attach returns false and we terminate the freshly
        // spawned process ourselves before any readers start.
        do {
            try process.run()
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if !processBox.attach(process) {
            // Consumer cancelled while ssh was starting. Tear down the
            // process we just launched; terminationHandler will finish
            // the continuation.
            process.terminate()
            return
        }

        reader.start()
        stderrReader.start()
    }

    /// Resolves the remote Hermes home directory once, before the long-lived
    /// `tail` is spawned. Absolute literal paths short-circuit without making
    /// any SSH calls; nil / `~`-containing values run
    /// `buildRemoteHermesHomeResolveCommand` against the profile and parse
    /// its stdout. Exposed for tests.
    static func resolveHermesHome(profile: ServerProfile, hermesHome: String?) async throws -> String {
        if let value = hermesHome?.trimmingCharacters(in: .whitespaces),
           !value.isEmpty, value != "~", !value.hasPrefix("~/"), !value.contains("$") {
            return value
        }
        guard let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile has no host")
        }
        let resolveCommand = buildRemoteHermesHomeResolveCommand(
            hermesHome: hermesHome,
            remoteShellMode: profile.remoteShellMode,
            remoteShellPrefix: profile.remoteShellPrefix
        )
        var args: [String] = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let port = profile.port {
            args += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile {
            args += ["-i", identityFile]
        }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        args += ["--", destination, resolveCommand]

        let result: OneShotProcess.Result
        do {
            result = try await OneShotProcess.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: args,
                timeout: 10
            )
        } catch let failure as OneShotProcess.Failure {
            throw SSHTransportError.other(String(describing: failure))
        }
        if result.timedOut {
            throw SSHTransportError.other("remote home resolve timed out")
        }
        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let classified = SSHTransport.classifyStderr(stderr)
            let detail: String
            switch classified {
            case .other:
                detail = stderr.isEmpty ? "remote home resolve exited \(result.exitCode)" : stderr
            default:
                detail = classified.errorDescription ?? "remote home resolve failed"
            }
            throw SSHTransportError.other(detail)
        }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            throw SSHTransportError.other("remote home resolve returned empty path")
        }
        return path
    }

    /// Remote tail script. Plain `tail -F <home>/logs/*.log` glob-expands on
    /// the remote shell once at process start, so log files that appear
    /// *after* the tail begins (a new subsystem first writing its log, or
    /// rotation creating a different basename) are never followed. The loop
    /// below re-globs every 2 seconds and respawns `tail -F` whenever the
    /// file set changes; the gap during a respawn is bounded by the sleep,
    /// and `tail -n 0` prevents re-emitting historical lines on respawn.
    ///
    /// The logs directory is passed as the script's `$1` positional argument
    /// (not interpolated into the script body) — interpolating a
    /// `SSHTransport.shellQuote(...)` result inside an outer single-quoted
    /// `sh -c '...'` would inject single quotes and fragment the script when
    /// the remote login shell parses it.
    static func remoteTailScript(hermesHome: String) -> String {
        let logsPath = SSHTransport.shellQuote("\(hermesHome)/logs")
        // `sh -c '<body>' _ <quoted-path>` puts the path into `$1` while
        // leaving the script body in pristine single-quoted form. The `_`
        // takes the `$0` slot. `'"'"'` is the standard sh idiom for
        // embedding a literal single quote inside a single-quoted string.
        return """
        sh -c 'd="$1"; prev=""; pid=""; \
        trap '"'"'[ -n "$pid" ] && kill $pid 2>/dev/null'"'"' EXIT INT TERM; \
        while :; do \
          cur=$(ls -1 "$d"/*.log 2>/dev/null | sort -u); \
          if [ "$cur" != "$prev" ]; then \
            [ -n "$pid" ] && kill $pid 2>/dev/null; \
            if [ -n "$cur" ]; then \
              tail -n 0 -F $cur 2>/dev/null & \
              pid=$!; \
            else \
              pid=""; \
            fi; \
            prev="$cur"; \
          fi; \
          sleep 2; \
        done' _ \(logsPath)
        """
    }
}

/// Coordinates lifecycle of the ssh tail process with the AsyncStream's
/// `onTermination` callback when the home-resolve probe is in flight. The
/// box can be cancelled before the ssh process is even spawned (consumer
/// dropped the stream during resolve); once `attach` succeeds, the box owns
/// the running process and forwards cancellation as SIGTERM.
private final class RemoteTailProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Returns true if the process was registered. False means the consumer
    /// already cancelled and the caller should not run the process.
    func attach(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    func cancel() {
        lock.lock()
        let runningProcess = process
        cancelled = true
        lock.unlock()
        // No `isRunning` guard: `attach` always happens after `process.run()`
        // succeeds (see startTail), so a non-nil snapshot here means the
        // process was launched and `terminate()` is well-defined — either
        // it delivers SIGTERM or it's a no-op on an already-exited child.
        // The previous guard would skip the terminate when called before
        // `run()` returned, leaving an orphaned remote tail.
        if let p = runningProcess {
            p.terminate()
        }
    }
}

/// Tiny line-keyed ring buffer for ssh's stderr. Capped because a chatty
/// remote shell could otherwise grow this unbounded.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit: Int

    init(limit: Int = 200) {
        self.limit = limit
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func emitLines(from buffer: inout Data, component: String?, _ emit: (LogLine) -> Void) {
    while let nl = buffer.firstIndex(of: 0x0A) {
        var end = nl
        if end > buffer.startIndex, buffer[end - 1] == 0x0D {
            end -= 1
        }
        let data = buffer.subdata(in: buffer.startIndex..<end)
        let raw = String(decoding: data, as: UTF8.self)
        let line = HermesLogs.parse(raw)
        if let component, !component.isEmpty {
            if line.component.localizedCaseInsensitiveContains(component) {
                emit(line)
            }
        } else {
            emit(line)
        }
        buffer.removeSubrange(buffer.startIndex...nl)
    }
}
#endif
