import AppKit
import ArchiveCore
import Combine
import Foundation

/// Shared observable state and composition root. Commands live in domain extensions;
/// blocking work is admitted exclusively by OperationCoordinator.
@MainActor
final class AppViewModel: ObservableObject {
    let leftPane: PaneViewModel
    let rightPane: PaneViewModel

    @Published var isDualPane: Bool = false {
        didSet { persistSessionState() }
    }
    @Published var activeSide: PaneSide = .left
    @Published var recentArchiveURLs: [URL] = []
    @Published var operationBanner: OperationBannerState?
    @Published var isFinderOperationWindow = false
    var onFinderServiceRequested: (() -> Void)?
    var onFinderServiceFinished: (() -> Void)?

    @Published var modifiedEditSessions: [TempEditSession] = []

    @Published var eliminateRootDuplication: Bool = true {
        didSet { persistSessionState() }
    }
    @Published var excludeMacOSMetadataByDefault: Bool = true {
        didSet { persistSessionState() }
    }
    @Published var preserveMacXattrByDefault: Bool = false {
        didSet { persistSessionState() }
    }

    @Published var passwordPrompt: PasswordPromptRequest?
    @Published var compressSheet: CompressSheetRequest?
    @Published var extractSheet: ExtractSheetRequest?
    @Published var renameSheet: RenameSheetRequest?
    @Published var newFolderSheet: NewFolderSheetRequest?
    @Published var propertiesSheet: PropertiesSheetRequest?
    @Published var overwriteConflictSheet: OverwriteConflictSheetRequest?
    @Published var checksumSheet: ChecksumSheetRequest?
    @Published var showSettingsSheet: Bool = false

    var pendingOverwriteResolution: (() -> Void)?
    var paneSubscriptions = Set<AnyCancellable>()
    let sessionPersistenceEnabled: Bool
    let editSessions = ExternalEditSessionStore()
    let editCheckWorker = PaneLoadWorker()
    var editCheckID = UUID()
    let operations = OperationCoordinator()
    let passwordPrompts = PasswordPromptQueue()
    var currentCancellation: CancellationFlag? { operations.cancellation }
    let quickLookTempDir: URL
    let clipboardTempDir: URL
    var isRestoringSession = false

    init(initialFolder: URL? = nil, sessionPersistenceEnabled: Bool = true) {
        self.sessionPersistenceEnabled = sessionPersistenceEnabled
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home

        self.leftPane = PaneViewModel(side: .left, initialFolder: initialFolder ?? downloads)
        self.rightPane = PaneViewModel(side: .right, initialFolder: initialFolder ?? desktop)
        self.quickLookTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arkvello-QuickLook-\(UUID().uuidString)", isDirectory: true)
        self.clipboardTempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arkvello-Clipboard-\(UUID().uuidString)", isDirectory: true)

        passwordPrompts.onChange = { [weak self] in self?.passwordPrompt = $0 }
        wirePaneCallbacks(leftPane)
        wirePaneCallbacks(rightPane)
        if sessionPersistenceEnabled { restoreSessionIfAvailable() }
    }

    deinit {
        try? FileManager.default.removeItem(at: quickLookTempDir)
        try? FileManager.default.removeItem(at: clipboardTempDir)
    }

    var activePane: PaneViewModel {
        activeSide == .left ? leftPane : rightPane
    }

    var inactivePane: PaneViewModel {
        activeSide == .left ? rightPane : leftPane
    }

    static func archiveBaseName(for url: URL) -> String {
        SmartExtractionPlanner.archiveBaseName(for: url)
    }
}
