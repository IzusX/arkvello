import ArchiveCore
import Combine
import Foundation
import Testing
@testable import Arkvello

private func row(_ name: String, size: UInt64 = 1, directory: Bool = false) -> PaneRowItem {
    .disk(DiskEntryInfo(url: URL(fileURLWithPath: "/fixture/\(name)"), name: name, relativeDisplayPath: nil,
                       isDirectory: directory, isSymlink: false, isArchiveContainer: false,
                       size: size, modifiedDate: nil, posixAttributes: ""))
}

private final class SearchLoader: PaneContentLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    var recorded: [String] { lock.withLock { queries } }
    func load(_ request: PaneLoadRequest, cancellation: CancellationFlag) throws -> PaneLoadResult {
        #expect(!Thread.isMainThread)
        lock.withLock { queries.append(request.filterText) }
        return PaneLoadResult(items: [row(request.filterText.isEmpty ? "initial" : request.filterText)])
    }
}

private final class WorkGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var started = false
    var didStart: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        started = true
        while !released { condition.wait() }
    }
    func markStarted() { condition.lock(); started = true; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !predicate() {
        if ContinuousClock.now > deadline { throw ArchiveError.internalError("Test timed out") }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("Search and large lists") @MainActor
struct SearchTests {
    @Test("Pane selection publishes changes for toolbar actions")
    func toolbarSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: url)
        let app = AppViewModel(initialFolder: root, sessionPersistenceEnabled: false)
        await app.leftPane.loadingTask?.value
        await app.rightPane.loadingTask?.value
        var changes = 0
        let subscription = app.objectWillChange.sink { changes += 1 }
        let item = try #require(app.leftPane.rows.first { $0.name == "file.txt" })
        app.leftPane.selectedIDs = [item.id]
        #expect(changes > 0)
        #expect(app.activePane.selectedActionableRows.first?.name == "file.txt")
        withExtendedLifetime(subscription) {}
    }

    @Test("Typing a burst launches only the final recursive query")
    func debounce() async {
        let loader = SearchLoader()
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/fixture"), loader: loader)
        await pane.loadingTask?.value
        pane.filterText = "f"
        pane.filterText = "fi"
        pane.filterText = "final"
        for _ in 0..<3 { await pane.loadingTask?.value }
        #expect(loader.recorded == ["", "final"])
        #expect(pane.rows.last?.name == "final")
        #expect(!pane.isLoading)
    }

    @Test("Navigation cancels a pending search before it starts")
    func navigationDuringDebounce() async {
        let loader = SearchLoader()
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/fixture"), loader: loader)
        await pane.loadingTask?.value
        pane.filterText = "old"
        let abandoned = pane.loadingTask
        pane.navigate(to: .diskFolder(URL(fileURLWithPath: "/new")))
        await pane.loadingTask?.value
        await abandoned?.value
        #expect(loader.recorded == ["", "old"])
        #expect(pane.location == .diskFolder(URL(fileURLWithPath: "/new")))
    }

    @Test("Large presentations sort off-main, retain folder priority and build selection indexes")
    func presentation() async throws {
        let items = (0..<20_000).reversed().map { row("file\($0)", size: UInt64($0)) } + [row("folder", directory: true)]
        let options = PaneDisplayOptions(query: "", deepSearch: false, sortField: .size, ascending: false,
                                         relativePaths: false, stripPrefix: "", hasParent: true)
        let result = try await PaneLoadWorker().run {
            #expect(!Thread.isMainThread)
            return try PanePresentation.build(items: items, options: options, cancellation: CancellationFlag())
        }
        #expect(result.rows.prefix(3).map(\.name) == ["..", "folder", "file19999"])
        #expect(result.fileCount == 20_000)
        #expect(result.folderCount == 1)
        #expect(result.indexByID[row("file19999").id] == 2)
        #expect(throws: CancellationError.self) {
            let flag = CancellationFlag(); flag.cancel()
            _ = try PanePresentation.build(items: items, options: options, cancellation: flag)
        }
    }

    @Test("Local filtering reuses loaded metadata and empty results finish loading")
    func localFilter() async {
        let loader = SearchLoader()
        let pane = PaneViewModel(side: .left, initialFolder: URL(fileURLWithPath: "/fixture"), loader: loader)
        await pane.loadingTask?.value
        pane.isDeepSearch = false
        await pane.loadingTask?.value
        pane.filterText = "no match"
        for _ in 0..<3 { await pane.loadingTask?.value }
        #expect(loader.recorded == ["", ""])
        #expect(pane.rows.map(\.name) == [".."])
        #expect(!pane.isLoading)
        #expect(pane.statusSummaryText.contains("Файлов: 0"))
        pane.filterText = ""
        for _ in 0..<3 { await pane.loadingTask?.value }
        #expect(pane.rows.last?.name == "initial")
        #expect(loader.recorded == ["", ""])
    }

    @Test("Archive search is bounded, cancellable and respects hidden ancestors and subtree boundaries")
    func archiveLimit() throws {
        let paths = (0..<8001).map { "folder/file\($0).txt" } + [".hidden/file.txt", "other/file.txt"]
        let entries = paths.enumerated().map { index, path in
            ArchiveEntry(index: UInt32(index), path: path, name: (path as NSString).lastPathComponent,
                size: 1, packedSize: 1, modifiedDate: nil, posixMode: 0, attributes: "", crc32: nil,
                method: nil, symlinkTarget: nil, isDirectory: false, isEncrypted: false, isSymlink: false)
        }
        let tree = VirtualArchiveTree(entries: entries)
        let limited = tree.matchingNodes(under: "folder", query: "file", includeDirectories: false,
                                        showHidden: false, limit: 8000, checkCancellation: {})
        #expect(limited.truncated)
        #expect(limited.nodes.count == 8000)
        let specific = tree.matchingNodes(under: "", query: "file8000", includeDirectories: false,
                                         showHidden: false, limit: 8000, checkCancellation: {})
        #expect(specific.nodes.map(\.path) == ["folder/file8000.txt"])
        #expect(!specific.truncated)
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try tree.matchingNodes(under: "", query: "absent", includeDirectories: true, showHidden: true, limit: 8000) {
                checks += 1
                if checks == 30 { throw CancellationError() }
            }
        }
    }

    @Test("Recursive disk results report truncation, and a narrower query still scans beyond the old limit")
    func diskLimit() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Empty files avoid disk payload and exercise the real enumerator boundary.
        for index in 0..<8001 { try Data().write(to: root.appendingPathComponent("file\(index)")) }
        let pane = PaneViewModel(side: .left, initialFolder: root)
        await pane.loadingTask?.value
        #expect(pane.rows.count == 8002) // Ordinary listing has no recursive result cap.
        pane.isFlatView = true
        await pane.loadingTask?.value
        #expect(pane.rows.count == 8001)
        #expect(pane.resultsTruncated)
        #expect(pane.statusSummaryText.contains("8000"))
        pane.filterText = "file8000"
        for _ in 0..<3 { await pane.loadingTask?.value }
        #expect(pane.rows.map(\.name) == ["..", "file8000"])
        #expect(!pane.resultsTruncated)
    }
}

@Suite("Operation coordination") @MainActor
struct OperationTests {
    @Test("A real overwrite waits for sheet dismissal and cancellation releases it without a response")
    func overwriteSheetLifecycle() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = src.appendingPathComponent("file.txt"), target = dst.appendingPathComponent("file.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)
        let app = AppViewModel(initialFolder: dst, sessionPersistenceEnabled: false)
        await app.leftPane.loadingTask?.value
        await app.rightPane.loadingTask?.value
        app.handleDroppedURLs([source], into: .left)
        try await waitUntil { app.overwriteConflictSheet != nil }
        app.overwriteConflictSheet?.respond(.replace)
        #expect(app.overwriteConflictSheet == nil)
        #expect(app.operations.isRunning)
        #expect(try String(contentsOf: target, encoding: .utf8) == "old")
        app.finishOverwritePrompt()
        await app.operations.task?.value
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
        app.handleDroppedURLs([source], into: .left)
        try await waitUntil { app.overwriteConflictSheet != nil }
        app.cancelRunningOperation()
        await app.operations.task?.value
        #expect(app.overwriteConflictSheet == nil)
        #expect(!app.operations.isRunning)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }

    @Test("A cancelling operation keeps exclusive admission until native work returns")
    func exclusiveCancellation() async throws {
        let coordinator = OperationCoordinator()
        let gate = WorkGate()
        defer { gate.release() }
        var completions = 0
        var wasCancelled = false
        let firstAccepted = coordinator.start(work: { _, _ in gate.wait() }, progress: { _ in }) { result in
            completions += 1
            if case .failure(let error) = result { wasCancelled = (error as? ArchiveError) == .cancelled }
        }
        #expect(firstAccepted)
        try await waitUntil { gate.didStart }
        coordinator.cancel()
        #expect(coordinator.isRunning)
        let overlapAccepted = coordinator.start(work: { _, _ in Issue.record("Overlapping operation") }, progress: { _ in }, completion: { _ in })
        #expect(!overlapAccepted)
        gate.release()
        await coordinator.task?.value
        #expect(completions == 1)
        #expect(wasCancelled)
        #expect(!coordinator.isRunning)
        let secondAccepted = coordinator.start(work: { _, _ in }, progress: { _ in }, completion: { _ in completions += 1 })
        #expect(secondAccepted)
        await coordinator.task?.value
        #expect(completions == 2)
    }

    @Test("Cancellation releases a worker waiting for an overwrite reply, including late and early cancellation")
    func overwriteCancellation() async throws {
        let coordinator = OperationCoordinator()
        let reply = OperationReply<OverwriteDecision>()
        let gate = WorkGate()
        coordinator.start(work: { flag, _ in
            gate.markStarted()
            #expect(reply.wait(cancellation: flag, cancelledValue: .cancel) == .cancel)
        }, progress: { _ in }, completion: { _ in })
        // Cancel on the main actor while the callback is blocked in a GCD worker.
        try await waitUntil { gate.didStart }
        coordinator.cancel()
        await coordinator.task?.value
        reply.resolve(.replace) // A late button response must not change the cancelled answer.
        let flag = CancellationFlag(); flag.cancel()
        #expect(OperationReply<OverwriteDecision>().wait(cancellation: flag, cancelledValue: .cancel) == .cancel)
    }

    @Test("Native progress is coalesced and cannot overwrite a subsequent operation")
    func progress() async throws {
        let coordinator = OperationCoordinator()
        let firstGate = WorkGate()
        defer { firstGate.release() }
        var callbacks = 0
        coordinator.start(work: { _, report in
            for index in 0..<10_000 { report(ArchiveProgress(completedBytes: UInt64(index), totalBytes: 10_000)) }
            firstGate.wait()
        }, progress: { _ in callbacks += 1 }, completion: { _ in })
        try await waitUntil { firstGate.didStart }
        try await waitUntil { callbacks > 0 }
        #expect(callbacks < 10)
        firstGate.release()
        await coordinator.task?.value
        let secondGate = WorkGate()
        defer { secondGate.release() }
        coordinator.start(work: { _, _ in secondGate.wait() }, progress: { _ in Issue.record("Stale progress") }, completion: { _ in })
        let snapshot = callbacks
        try await Task.sleep(for: .milliseconds(120))
        #expect(callbacks == snapshot)
        secondGate.release()
        await coordinator.task?.value
    }

    @Test("Password replies wait for dismissal and prompts for the same URL have independent owners")
    func passwordQueue() {
        let queue = PasswordPromptQueue()
        let url = URL(fileURLWithPath: "/protected.zip")
        let left = UUID(), right = UUID()
        var shown: PasswordPromptRequest?
        var replies: [String] = []
        queue.onChange = { shown = $0 }
        queue.enqueue(owner: left, archiveURL: url, isRetryAfterFailure: false) { password, _ in replies.append(password ?? "cancel-left") }
        let abandoned = shown
        queue.enqueue(owner: right, archiveURL: url, isRetryAfterFailure: false) { password, _ in replies.append(password ?? "cancel-right") }
        queue.cancel(for: url, owner: left)
        #expect(shown == nil)
        #expect(replies.isEmpty)
        queue.didDismiss()
        #expect(replies == ["cancel-left"])
        #expect(shown != nil)
        abandoned?.completion("stale", true)
        #expect(replies == ["cancel-left"])
        shown?.completion("right", false)
        #expect(replies == ["cancel-left"])
        queue.didDismiss()
        #expect(replies == ["cancel-left", "right"])
        #expect(!queue.hasRequests)
    }

    @Test("Queued password prompts stay suspended through a retry")
    func suspendedPasswordQueue() {
        let queue = PasswordPromptQueue()
        var shown: PasswordPromptRequest?
        queue.onChange = { shown = $0 }
        queue.enqueue(archiveURL: URL(fileURLWithPath: "/first"), isRetryAfterFailure: false) { _, _ in queue.isSuspended = true }
        queue.enqueue(archiveURL: URL(fileURLWithPath: "/second"), isRetryAfterFailure: false) { _, _ in }
        shown?.completion("password", false)
        queue.didDismiss()
        #expect(shown == nil)
        queue.isSuspended = false
        #expect(shown?.archiveURL.lastPathComponent == "second")
        queue.dismiss()
        queue.didDismiss()
        #expect(!queue.hasRequests)
    }
}

@Suite("Safe disk transfers")
struct DiskTransferTests {
    @Test("Cancelled replacement and failed move preserve original files")
    func safeReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = src.appendingPathComponent("file")
        let target = dst.appendingPathComponent("file")
        try Data("new".utf8).write(to: file)
        try Data("original".utf8).write(to: target)
        let flag = CancellationFlag()
        #expect(throws: CancellationError.self) {
            try DiskTransfer.transfer([file], to: dst, move: true, cancellation: flag,
                overwrite: { _ in .replace }, progress: { _ in flag.cancel() })
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try String(contentsOf: file, encoding: .utf8) == "new")
        // The source disappears after conflict resolution, before the staged copy.
        #expect(throws: (any Error).self) {
            try DiskTransfer.transfer([file], to: dst, move: true, cancellation: CancellationFlag(), overwrite: { _ in
                try? fm.removeItem(at: file)
                return .replace
            }, progress: { _ in })
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try fm.contentsOfDirectory(atPath: dst.path) == ["file"])
    }

    @Test("Auto rename preserves existing copies and move publishes before deleting its source")
    func autoRenameAndMove() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = src.appendingPathComponent("file.txt")
        try Data("new".utf8).write(to: file)
        try Data("old".utf8).write(to: dst.appendingPathComponent("file.txt"))
        try Data("old-copy".utf8).write(to: dst.appendingPathComponent("file_copy.txt"))
        try DiskTransfer.transfer([file], to: dst, move: true, cancellation: CancellationFlag(), overwrite: { _ in .autoRename }, progress: { _ in })
        #expect(!fm.fileExists(atPath: file.path))
        #expect(try String(contentsOf: dst.appendingPathComponent("file_copy2.txt"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: dst.appendingPathComponent("file_copy.txt"), encoding: .utf8) == "old-copy")
        #expect(throws: (any Error).self) {
            try DiskTransfer.transfer([dst], to: dst, move: false, cancellation: CancellationFlag(), overwrite: { _ in .replace }, progress: { _ in })
        }
    }
}
