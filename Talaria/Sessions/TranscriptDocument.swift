import SwiftUI
import UniformTypeIdentifiers

/// A JSONL session transcript wrapped for `.fileExporter`. The text is produced
/// by `SessionTranscriptExporter`; the file is exported as JSONL (falling back to
/// the JSON content type when the OS doesn't recognize the `jsonl` extension).
/// Read support exists only to satisfy `FileDocument`; Talaria never imports these.
struct TranscriptDocument: FileDocument {
    static let readableContentTypes: [UTType] = [Self.contentType]
    static let writableContentTypes: [UTType] = [Self.contentType]

    /// JSONL has no registered UTType, so derive one from the extension and fall
    /// back to plain JSON when the OS can't.
    static let contentType: UTType = UTType(filenameExtension: "jsonl") ?? .json

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
