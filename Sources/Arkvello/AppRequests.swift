import AppKit
import ArchiveCore
import Foundation

struct OperationBannerState: Equatable {
    var title: String
    var detail: String
    var fraction: Double?
    var isRunning: Bool
    var isError: Bool
}

struct PasswordPromptRequest: Identifiable {
    let id = UUID()
    var owner: UUID? = nil
    let archiveURL: URL
    let isRetryAfterFailure: Bool
    let completion: (String?, Bool) -> Void
}

struct CompressSheetRequest: Identifiable {
    let id = UUID()
    let inputURLs: [URL]
    let defaultDestinationFolder: URL
    let suggestedArchiveName: String
}

struct ExtractSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
    let archiveURL: URL
    let selectedPaths: [String]
    let stripPrefix: String
    let defaultDestinationFolder: URL
}

struct RenameSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
    let row: PaneRowItem
}

struct NewFolderSheetRequest: Identifiable {
    let id = UUID()
    let paneSide: PaneSide
}

struct PropertiesSheetRequest: Identifiable {
    let id = UUID()
    let location: NavigationLocation
    let summary: ArchiveSummary?
    let selectedRows: [PaneRowItem]
}

struct OverwriteConflictSheetRequest: Identifiable {
    let id = UUID()
    let conflict: OverwriteConflict
    let respond: (OverwriteDecision) -> Void
}

struct ChecksumSheetRequest: Identifiable {
    let id = UUID()
    let itemName: String
    let itemSize: UInt64?
    let digests: [ArchiveHashDigest]
}

