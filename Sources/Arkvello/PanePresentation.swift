import ArchiveCore
import Foundation

struct PaneDisplayOptions: Equatable, Sendable {
    let query: String
    let deepSearch: Bool
    let sortField: SortField
    let ascending: Bool
    let relativePaths: Bool
    let stripPrefix: String
    let hasParent: Bool
}

/// Built once on a worker. SwiftUI updates and selection changes do not rescan
/// the entire directory, compare metadata arrays or recreate every row ID.
struct PanePresentation: Sendable {
    let rows: [PaneRowItem]
    let ids: Set<String>
    let byID: [String: PaneRowItem]
    let indexByID: [String: Int]
    let folderCount: Int
    let fileCount: Int
    let totalSize: UInt64

    static func build(items: [PaneRowItem], options: PaneDisplayOptions,
                      cancellation: CancellationFlag) throws -> Self {
        var decorated: [(item: PaneRowItem, label: String)] = []
        for item in items {
            try cancellation.check()
            if !options.deepSearch && !options.query.isEmpty && !item.name.lowercased().contains(options.query) { continue }
            decorated.append((item, item.displayLabel(showRelativePath: options.relativePaths, stripPrefix: options.stripPrefix)))
        }
        try decorated.sort { a, b in
            try cancellation.check()
            if a.item.isDirectory != b.item.isDirectory { return a.item.isDirectory }
            let comparison: ComparisonResult
            switch options.sortField {
            case .name: comparison = a.label.localizedStandardCompare(b.label)
            case .size: comparison = compare(a.item.size ?? 0, b.item.size ?? 0)
            case .packedSize: comparison = compare(a.item.packedSize ?? 0, b.item.packedSize ?? 0)
            case .modified: comparison = compare(a.item.modifiedDate ?? .distantPast, b.item.modifiedDate ?? .distantPast)
            case .attributes: comparison = a.item.attributes.compare(b.item.attributes)
            case .crc: comparison = a.item.crcHex.compare(b.item.crcHex)
            case .method: comparison = a.item.method.localizedStandardCompare(b.item.method)
            }
            if comparison == .orderedSame {
                let tie = a.label.localizedStandardCompare(b.label)
                return tie == .orderedSame ? a.item.id < b.item.id : tie == .orderedAscending
            }
            return options.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        var rows: [PaneRowItem] = options.hasParent ? [.parentDirectory] : []
        var byID: [String: PaneRowItem] = [:]
        var indexByID: [String: Int] = [:]
        if options.hasParent { indexByID[PaneRowItem.parentDirectory.id] = 0 }
        var folders = 0
        var bytes: UInt64 = 0
        for value in decorated {
            try cancellation.check()
            indexByID[value.item.id] = rows.count
            rows.append(value.item)
            byID[value.item.id] = value.item
            if value.item.isDirectory { folders += 1 }
            bytes &+= value.item.size ?? 0
        }
        var ids = Set(byID.keys)
        if options.hasParent { ids.insert(PaneRowItem.parentDirectory.id) }
        return Self(rows: rows, ids: ids, byID: byID, indexByID: indexByID, folderCount: folders,
                    fileCount: decorated.count - folders, totalSize: bytes)
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
}
