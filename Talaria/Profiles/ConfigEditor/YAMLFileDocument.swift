import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var hermesYAML: UTType { UTType(filenameExtension: "yaml") ?? .plainText }
}

struct YAMLFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.hermesYAML, .text, .data] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = s
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
