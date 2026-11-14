import Foundation

public struct VirtualArchiveNode: Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSyntheticDirectory: Bool
    public let entry: ArchiveEntry?
    public let aggregatedSize: UInt64
    public let aggregatedPackedSize: UInt64
    public let itemCount: Int

    public var id: String { path }

    public var displaySize: UInt64? {
        if isDirectory {
            return aggregatedSize > 0 || itemCount > 0 ? aggregatedSize : entry?.size
        }
        return entry?.size
    }

    public var displayPackedSize: UInt64? {
        if isDirectory {
            return aggregatedPackedSize > 0 ? aggregatedPackedSize : entry?.packedSize
        }
        return entry?.packedSize
    }

    public var modifiedDate: Date? { entry?.modifiedDate }
    public var attributes: String { entry?.attributes ?? (isDirectory ? "D" : "") }
    public var crcHex: String? { entry?.crcHex }
    public var method: String? { entry?.method }
    public var isEncrypted: Bool { entry?.isEncrypted ?? false }
    public var isSymlink: Bool { entry?.isSymlink ?? false }
}

/// Indexes a flat `[ArchiveEntry]` list into a navigable folder hierarchy matching 7zFM behavior,
/// synthesizing intermediate folders when an archive stores only leaf file paths.
public struct VirtualArchiveTree: Sendable {
    private struct MutableNode {
        var path: String
        var name: String
        var isDirectory: Bool
        var entry: ArchiveEntry?
        var children: Set<String> = []
        var aggregatedSize: UInt64 = 0
        var aggregatedPackedSize: UInt64 = 0
        var descendantFileCount: Int = 0
    }

    private let nodesByPath: [String: VirtualArchiveNode]
    private let childrenByFolder: [String: [VirtualArchiveNode]]
    private let entries: [ArchiveEntry]

    public init(entries: [ArchiveEntry]) {
        self.entries = entries

        var map: [String: MutableNode] = [
            "": MutableNode(path: "", name: "", isDirectory: true, entry: nil)
        ]

        for entry in entries {
            let normalized = Self.normalize(entry.path)
            guard !normalized.isEmpty else { continue }

            let components = normalized.split(separator: "/").map(String.init)
            var parentPath = ""

            for (idx, part) in components.enumerated() {
                let currentPath = parentPath.isEmpty ? part : "\(parentPath)/\(part)"
                let isLast = (idx == components.count - 1)

                if isLast {
                    if var existing = map[currentPath] {
                        existing.entry = entry
                        existing.isDirectory = existing.isDirectory || entry.isDirectory
                        map[currentPath] = existing
                    } else {
                        map[currentPath] = MutableNode(
                            path: currentPath,
                            name: part,
                            isDirectory: entry.isDirectory,
                            entry: entry
                        )
                    }
                } else {
                    if map[currentPath] == nil {
                        map[currentPath] = MutableNode(
                            path: currentPath,
                            name: part,
                            isDirectory: true,
                            entry: nil
                        )
                    } else {
                        map[currentPath]?.isDirectory = true
                    }
                }

                map[parentPath, default: MutableNode(path: parentPath, name: "", isDirectory: true)].children.insert(currentPath)

                if !entry.isDirectory {
                    if let sz = entry.size {
                        map[parentPath]?.aggregatedSize &+= sz
                    }
                    if let psz = entry.packedSize {
                        map[parentPath]?.aggregatedPackedSize &+= psz
                    }
                    map[parentPath]?.descendantFileCount += 1
                }

                parentPath = currentPath
            }
        }

        var builtNodes: [String: VirtualArchiveNode] = [:]
        builtNodes.reserveCapacity(map.count)

        for (path, m) in map where !path.isEmpty {
            builtNodes[path] = VirtualArchiveNode(
                path: m.path,
                name: m.name,
                isDirectory: m.isDirectory,
                isSyntheticDirectory: m.isDirectory && m.entry == nil,
                entry: m.entry,
                aggregatedSize: m.aggregatedSize,
                aggregatedPackedSize: m.aggregatedPackedSize,
                itemCount: m.descendantFileCount
            )
        }

        var builtChildren: [String: [VirtualArchiveNode]] = [:]
        for (folderPath, m) in map where m.isDirectory {
            var list: [VirtualArchiveNode] = m.children.compactMap { builtNodes[$0] }
            list.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            builtChildren[folderPath] = list
        }

        self.nodesByPath = builtNodes
        self.childrenByFolder = builtChildren
    }

    public func children(in folderPath: String) -> [VirtualArchiveNode] {
        let key = Self.normalize(folderPath)
        return childrenByFolder[key] ?? []
    }

    public func node(at path: String) -> VirtualArchiveNode? {
        nodesByPath[Self.normalize(path)]
    }

    public static func parentPath(of folderPath: String) -> String? {
        let clean = normalize(folderPath)
        guard !clean.isEmpty else { return nil }
        guard let slash = clean.lastIndex(of: "/") else { return "" }
        return String(clean[..<slash])
    }

    /// Collects all concrete archive item indices covered by `selectedPaths` (including recursive folder contents),
    /// ready to pass directly to `OpenArchive.extract(indices:)`.
    public func extractionIndices(for selectedPaths: [String]) -> [UInt32] {
        let normalizedTargets = selectedPaths.map(Self.normalize).filter { !$0.isEmpty }
        guard !normalizedTargets.isEmpty else { return [] }

        var exactSet = Set<String>()
        var folderPrefixes: [String] = []

        for target in normalizedTargets {
            exactSet.insert(target)
            if nodesByPath[target]?.isDirectory == true {
                folderPrefixes.append(target + "/")
            }
        }

        var matched: [UInt32] = []
        for entry in entries {
            let p = Self.normalize(entry.path)
            if exactSet.contains(p) || folderPrefixes.contains(where: { p.hasPrefix($0) }) {
                matched.append(entry.index)
            }
        }
        return matched
    }

    public static func normalize(_ rawPath: String) -> String {
        rawPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
