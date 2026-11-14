import CryptoKit
import Foundation

/// Manages extracting a single file from an archive into an isolated temp directory for viewing/editing
/// in an external macOS app, detecting atomic/in-place file saves, and writing updates back into the archive.
public final class TempEditSession: @unchecked Sendable {
    public let archiveURL: URL
    public let archiveEntryPath: String
    public let extractedFileURL: URL
    public let isArchiveUpdatable: Bool
    public let sessionDirectory: URL

    private let lock = NSLock()
    private var baselineDigest: SHA256.Digest
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedDirectoryFD: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private let watcherQueue = DispatchQueue(label: "com.sevenzipmac.tempedit.watcher")

    public init(
        archive: OpenArchive,
        entry: ArchiveEntry,
        password: String? = nil,
        onExternalModification: (@Sendable () -> Void)? = nil
    ) throws {
        guard !entry.isDirectory else {
            throw ArchiveError.invalidArgument("Нельзя открыть папку как редактируемый файл")
        }

        self.archiveURL = archive.url
        self.archiveEntryPath = VirtualArchiveTree.normalize(entry.path)
        self.isArchiveUpdatable = archive.summary.isUpdatable

        let rootTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SevenZipMac-Edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootTemp, withIntermediateDirectories: true)
        self.sessionDirectory = rootTemp

        try archive.extract(
            indices: [entry.index],
            to: rootTemp,
            stripPrefix: nil,
            fullPaths: true,
            overwrite: .overwriteAll,
            password: password
        )

        let targetURL = rootTemp.appendingPathComponent(self.archiveEntryPath)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw ArchiveError.ioError("Не удалось найти извлечённый временный файл")
        }
        self.extractedFileURL = targetURL
        self.baselineDigest = try Self.hashFile(at: targetURL)

        if let onExternalModification {
            startWatchingParentDirectory(onExternalModification: onExternalModification)
        }
    }

    deinit {
        cleanup()
    }

    /// Checks whether the extracted file on disk differs from the baseline version currently stored in the archive.
    /// Watching the parent directory + hashing handles macOS editors that save via atomic rename (TextEdit, Xcode, VS Code).
    public func hasUncommittedChanges() -> Bool {
        lock.lock()
        let currentBaseline = baselineDigest
        lock.unlock()

        guard let newDigest = try? Self.hashFile(at: extractedFileURL) else {
            return false
        }
        return newDigest != currentBaseline
    }

    /// Writes the modified file back into the archive at its original internal path (`archiveEntryPath`).
    public func commitChanges(
        options: CompressionOptions = CompressionOptions(),
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws {
        guard isArchiveUpdatable else {
            throw ArchiveError.unsupportedFormat("Этот формат архива доступен только для чтения")
        }
        guard FileManager.default.fileExists(atPath: extractedFileURL.path) else {
            throw ArchiveError.ioError("Временный файл был удалён")
        }

        try SevenZipEngine.createOrUpdateArchive(
            at: archiveURL,
            inputPaths: [archiveEntryPath],
            baseDirectory: sessionDirectory,
            options: options,
            password: password,
            progress: progress
        )

        let updatedDigest = try Self.hashFile(at: extractedFileURL)
        lock.lock()
        baselineDigest = updatedDigest
        lock.unlock()
    }

    public func cleanup() {
        lock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let watcher = directoryWatcher {
            watcher.cancel()
            directoryWatcher = nil
        }
        lock.unlock()

        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func startWatchingParentDirectory(onExternalModification: @escaping @Sendable () -> Void) {
        let parentDir = extractedFileURL.deletingLastPathComponent()
        let fd = open(parentDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        lock.lock()
        watchedDirectoryFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib, .extend],
            queue: watcherQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleChangeCheck(onExternalModification: onExternalModification)
        }

        source.setCancelHandler {
            close(fd)
        }

        directoryWatcher = source
        lock.unlock()
        source.resume()
    }

    private func scheduleChangeCheck(onExternalModification: @escaping @Sendable () -> Void) {
        lock.lock()
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasUncommittedChanges() else { return }
            onExternalModification()
        }
        debounceWorkItem = work
        lock.unlock()

        watcherQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    private static func hashFile(at url: URL) throws -> SHA256.Digest {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data)
    }
}
