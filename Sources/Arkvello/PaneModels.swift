import AppKit
import ArchiveCore
import Foundation
import UniformTypeIdentifiers

enum PaneSide: String, Equatable, Sendable {
    case left
    case right

    var opposite: PaneSide {
        self == .left ? .right : .left
    }
}

enum SortField: String, CaseIterable, Sendable {
    case name
    case size
    case packedSize
    case modified
    case attributes
    case crc
    case method
}

struct PaneTabItem: Identifiable, Equatable {
    let id: UUID
    var location: NavigationLocation
    var backStack: [NavigationLocation]
    var forwardStack: [NavigationLocation]

    var title: String {
        switch location {
        case .diskFolder(let url):
            let name = url.lastPathComponent
            return (name.isEmpty || name == "/") ? "Macintosh HD" : name
        case .archive(_, let layers, let subpath):
            let cleanSub = VirtualArchiveTree.normalize(subpath)
            if !cleanSub.isEmpty, let leaf = cleanSub.split(separator: "/").last {
                return String(leaf)
            }
            return layers.last?.displayName ?? "Архив"
        }
    }

    var isArchiveTab: Bool {
        location.isInsideArchive
    }
}

struct DiskEntryInfo: Equatable, Hashable, Sendable {
    let url: URL
    let name: String
    let relativeDisplayPath: String?
    let isDirectory: Bool
    let isSymlink: Bool
    let isArchiveContainer: Bool
    let size: UInt64?
    let modifiedDate: Date?
    let posixAttributes: String
}

enum PaneRowItem: Identifiable, Equatable, Sendable {
    case parentDirectory
    case disk(DiskEntryInfo)
    case archive(VirtualArchiveNode)

    var id: String {
        switch self {
        case .parentDirectory:
            return "..parent.."
        case .disk(let d):
            return "disk:\(d.url.path)"
        case .archive(let a):
            return "arc:\(a.path)"
        }
    }

    var name: String {
        switch self {
        case .parentDirectory: return ".."
        case .disk(let d): return d.name
        case .archive(let a): return a.name
        }
    }

    func displayLabel(showRelativePath: Bool, stripPrefix: String = "") -> String {
        guard showRelativePath, !isParentRow else { return name }
        switch self {
        case .parentDirectory:
            return ".."
        case .disk(let d):
            return d.relativeDisplayPath ?? d.name
        case .archive(let a):
            let cleanStrip = VirtualArchiveTree.normalize(stripPrefix)
            if !cleanStrip.isEmpty && a.path.hasPrefix(cleanStrip + "/") {
                return String(a.path.dropFirst(cleanStrip.count + 1))
            }
            return a.path
        }
    }

    var isParentRow: Bool {
        if case .parentDirectory = self { return true }
        return false
    }

    var isDirectory: Bool {
        switch self {
        case .parentDirectory: return true
        case .disk(let d): return d.isDirectory
        case .archive(let a): return a.isDirectory
        }
    }

    var isEncrypted: Bool {
        if case .archive(let a) = self { return a.isEncrypted }
        return false
    }

    var isSymlink: Bool {
        switch self {
        case .parentDirectory: return false
        case .disk(let d): return d.isSymlink
        case .archive(let a): return a.isSymlink
        }
    }

    var isArchiveFile: Bool {
        switch self {
        case .parentDirectory:
            return false
        case .disk(let d):
            return d.isArchiveContainer
        case .archive(let a):
            guard !a.isDirectory else { return false }
            let ext = (a.name as NSString).pathExtension.lowercased()
            return SevenZipEngine.browsableArchiveExtensions.contains(ext)
        }
    }

    var size: UInt64? {
        switch self {
        case .parentDirectory: return nil
        case .disk(let d): return d.isDirectory ? nil : d.size
        case .archive(let a): return a.displaySize
        }
    }

    var packedSize: UInt64? {
        switch self {
        case .parentDirectory, .disk: return nil
        case .archive(let a): return a.displayPackedSize
        }
    }

    var modifiedDate: Date? {
        switch self {
        case .parentDirectory: return nil
        case .disk(let d): return d.modifiedDate
        case .archive(let a): return a.modifiedDate
        }
    }

    var attributes: String {
        switch self {
        case .parentDirectory: return ""
        case .disk(let d): return d.posixAttributes
        case .archive(let a): return a.attributes
        }
    }

    var crcHex: String {
        if case .archive(let a) = self { return a.crcHex ?? "" }
        return ""
    }

    var method: String {
        if case .archive(let a) = self { return a.method ?? "" }
        return ""
    }

    @MainActor
    var icon: NSImage {
        switch self {
        case .parentDirectory:
            return NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "На уровень вверх")
                ?? NSWorkspace.shared.icon(for: .folder)
        case .disk(let d):
            let img = NSWorkspace.shared.icon(forFile: d.url.path)
            img.size = NSSize(width: 16, height: 16)
            return img
        case .archive(let a):
            if a.isDirectory {
                let img = NSWorkspace.shared.icon(for: .folder)
                img.size = NSSize(width: 16, height: 16)
                return img
            }
            let ext = (a.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let img = NSWorkspace.shared.icon(for: type)
            img.size = NSSize(width: 16, height: 16)
            return img
        }
    }
}

@MainActor
enum ByteFormatting {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.includesUnit = true
        f.isAdaptive = true
        return f
    }()

    static func string(for bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        if bytes == 0 { return "0 Б" }
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "dd.MM.yyyy HH:mm"
        return df
    }()

    static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }

    nonisolated static func posixPermissionString(mode: Int, isDir: Bool, isLink: Bool) -> String {
        let typeChar: Character = isLink ? "l" : (isDir ? "d" : "-")
        let flags: [(Int, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var out = String(typeChar)
        for (bit, ch) in flags {
            out.append((mode & bit) != 0 ? ch : "-")
        }
        return out
    }
}

struct SidebarShortcut: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let url: URL
}
