import Foundation

/// Builds a complete sibling replacement before touching an existing file or bundle.
/// Failed builds leave the original untouched; failed publication rolls the original back.
public enum StagedReplacement {
    public static func publish(
        at destination: URL,
        build: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(destination.lastPathComponent)
        let workspace = parent.appendingPathComponent(".sevenzip-publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        var retainWorkspace = false
        defer { if !retainWorkspace { try? fm.removeItem(at: workspace) } }
        let staged = workspace.appendingPathComponent(destination.lastPathComponent)
        let backup = workspace.appendingPathComponent("original-backup")
        try build(staged)
        guard fm.fileExists(atPath: staged.path) else {
            throw ArchiveError.ioError("Сборка не создала новый файл или приложение")
        }
        var savedOriginal = false
        if fm.fileExists(atPath: target.path) {
            try fm.moveItem(at: target, to: backup)
            savedOriginal = true
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if savedOriginal {
                do { try fm.moveItem(at: backup, to: target) }
                catch {
                    // Preserve the only surviving original if restoring fails.
                    retainWorkspace = true
                    throw ArchiveError.ioError("Не удалось восстановить исходник; резервная копия: \(backup.path)")
                }
            }
            throw error
        }
    }
}
