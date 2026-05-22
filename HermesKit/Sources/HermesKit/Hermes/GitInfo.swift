import Foundation

public enum GitInfo {
    public static func branch(cwd: String) async -> String? {
        #if os(macOS)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readBranch(cwd: cwd))
            }
        }
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func readBranch(cwd: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let branch = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return branch.isEmpty ? nil : branch
        } catch {
            return nil
        }
    }
    #endif
}
