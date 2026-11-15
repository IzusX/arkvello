import ArchiveCore
import Foundation

enum DiskTransfer {
    static func transfer(_ sources: [URL], to folder: URL, move: Bool, cancellation: CancellationFlag,
                         overwrite: (OverwriteConflict) -> OverwriteDecision,
                         progress: (ArchiveProgress) -> Void) throws {
        let fm = FileManager.default
        var applyAll: OverwriteDecision?
        for (index, source) in sources.enumerated() {
            try cancellation.check()
            var target = folder.appendingPathComponent(source.lastPathComponent)
            let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if resolvedTarget == resolvedSource {
                if move { continue }
                target = unusedCopyURL(target)
            } else {
                if isDirectory.boolValue && resolvedTarget.hasPrefix(resolvedSource + "/") {
                    throw ArchiveError.invalidArgument("Нельзя копировать папку внутрь неё самой")
                }
                if fm.fileExists(atPath: target.path) {
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
                    let src = try? source.resourceValues(forKeys: keys)
                    let dst = try? target.resourceValues(forKeys: keys)
                    let decision = applyAll ?? overwrite(OverwriteConflict(existingPath: target.path,
                        existingSize: dst?.fileSize.map { UInt64(max(0, $0)) }, existingModifiedDate: dst?.contentModificationDate,
                        newPath: source.path, newSize: src?.fileSize.map { UInt64(max(0, $0)) }, newModifiedDate: src?.contentModificationDate))
                    try cancellation.check()
                    if decision == .replaceAll || decision == .skipAll { applyAll = decision }
                    switch decision {
                    case .cancel: throw ArchiveError.cancelled
                    case .skip, .skipAll: continue
                    case .autoRename: target = unusedCopyURL(target)
                    case .replace, .replaceAll: break
                    }
                }
            }
            progress(ArchiveProgress(completedBytes: UInt64(index), totalBytes: UInt64(sources.count), currentItem: source.lastPathComponent))
            // Publish only a complete copy. A failed or cancelled copy preserves
            // both the old destination and the source, including for a move.
            try StagedReplacement.publish(at: target) { staged in
                try fm.copyItem(at: source, to: staged)
                try cancellation.check()
            }
            try cancellation.check()
            if move { try fm.removeItem(at: source) }
            progress(ArchiveProgress(completedBytes: UInt64(index + 1), totalBytes: UInt64(sources.count), currentItem: source.lastPathComponent))
        }
    }

    private static func unusedCopyURL(_ target: URL) -> URL {
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? "_copy" : "_copy\(index)"
            let candidate = target.deletingLastPathComponent().appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
