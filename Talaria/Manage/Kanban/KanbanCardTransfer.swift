import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Custom drag type for Kanban cards, declared in
    /// `UTExportedTypeDeclarations` of both `Info.plist` and `Info-iOS.plist`.
    /// Scoping drops to this type means a column only accepts cards dragged from
    /// the board (not arbitrary text/files).
    static let kanbanCard = UTType(exportedAs: "com.talaria.kanban-card")
}

/// The payload carried during a card drag. `sourceStatus` lets the drop
/// destination ignore same-column drops without a board lookup.
struct KanbanCardTransfer: Codable, Transferable {
    let taskID: String
    let sourceStatus: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kanbanCard)
    }
}
