import Foundation
import Testing
@testable import HermesKit

/// Pure command-construction tests for the remote *write* path added alongside
/// the Memory editor. The end-to-end SSH legs can't run without a host; these
/// pin the quoting and temp+rename shape that the round-trip relies on.
@Suite
struct RemoteFileTransferTests {
    // MARK: - sftp (macOS) put batch

    #if os(macOS)
    @Test
    func sftpPutCommandsMkdirPutRename() {
        let commands = SFTPSubprocessTransfer.sftpPutCommands(
            localPath: "/tmp/local.md",
            remoteTmp: ".hermes/memories/MEMORY.md.uploading-abc",
            remotePath: ".hermes/memories/MEMORY.md"
        )
        #expect(commands == [
            "-mkdir \".hermes/memories\"",
            "put \"/tmp/local.md\" \".hermes/memories/MEMORY.md.uploading-abc\"",
            "rename \".hermes/memories/MEMORY.md.uploading-abc\" \".hermes/memories/MEMORY.md\"",
        ])
    }

    @Test
    func sftpPutCommandsQuoteSpacesAndQuotes() {
        let commands = SFTPSubprocessTransfer.sftpPutCommands(
            localPath: "/Users/John Doe/m.md",
            remoteTmp: "dir name/MEMORY.md.tmp",
            remotePath: "dir name/MEMORY.md"
        )
        // Spaces stay inside the double-quoted argument so sftp doesn't split them.
        #expect(commands.contains("-mkdir \"dir name\""))
        #expect(commands.contains("put \"/Users/John Doe/m.md\" \"dir name/MEMORY.md.tmp\""))
        #expect(commands.contains("rename \"dir name/MEMORY.md.tmp\" \"dir name/MEMORY.md\""))
    }

    @Test
    func sftpPutCommandsSkipMkdirWithoutParent() {
        let commands = SFTPSubprocessTransfer.sftpPutCommands(
            localPath: "/tmp/x",
            remoteTmp: "MEMORY.md.tmp",
            remotePath: "MEMORY.md"
        )
        // No directory component → no mkdir line.
        #expect(commands.count == 2)
        #expect(commands.first == "put \"/tmp/x\" \"MEMORY.md.tmp\"")
    }
    #endif

    // MARK: - NIO `cat`/`mv` write command

    @Test
    func writeCommandMkdirCatMove() {
        let command = NIOSSHCatTransfer.writeCommand(
            remoteTmp: ".hermes/memories/MEMORY.md.uploading-abc",
            remotePath: ".hermes/memories/MEMORY.md"
        )
        #expect(command == "mkdir -p '.hermes/memories' && cat > '.hermes/memories/MEMORY.md.uploading-abc' && mv -f '.hermes/memories/MEMORY.md.uploading-abc' '.hermes/memories/MEMORY.md'")
    }

    @Test
    func writeCommandSingleQuotesPaths() {
        let command = NIOSSHCatTransfer.writeCommand(
            remoteTmp: "a'b/x.tmp",
            remotePath: "a'b/x"
        )
        // Single quotes are escaped with the '\'' idiom so an embedded quote
        // can't break out of the shell word.
        #expect(command.contains("mkdir -p 'a'\\''b' && "))
        #expect(command.contains("cat > 'a'\\''b/x.tmp'"))
        #expect(command.contains("mv -f 'a'\\''b/x.tmp' 'a'\\''b/x'"))
    }

    @Test
    func writeCommandSkipsMkdirWithoutParent() {
        let command = NIOSSHCatTransfer.writeCommand(remoteTmp: "MEMORY.md.tmp", remotePath: "MEMORY.md")
        #expect(command == "cat > 'MEMORY.md.tmp' && mv -f 'MEMORY.md.tmp' 'MEMORY.md'")
    }
}
