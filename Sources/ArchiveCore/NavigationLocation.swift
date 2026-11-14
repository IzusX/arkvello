import Foundation

/// Represents one open archive layer in a seamless `disk <-> archive <-> nested archive` stack.
public struct ArchiveLayer: Equatable, Hashable, Sendable {
    /// Physical archive file on disk (either user's file or extracted temporary nested archive).
    public let archiveFileURL: URL
    /// Display name shown in breadcrumbs (e.g. `release.7z` or `inner.tar.gz`).
    public let displayName: String
    /// Parent folder path inside the outer location where this archive resides, so going up (`..`) restores context.
    public let parentSubpath: String
    /// True if `archiveFileURL` is an ephemeral temp file extracted from an outer archive.
    public let isTemporaryNestedFile: Bool

    public init(
        archiveFileURL: URL,
        displayName: String? = nil,
        parentSubpath: String = "",
        isTemporaryNestedFile: Bool = false
    ) {
        self.archiveFileURL = archiveFileURL
        self.displayName = displayName ?? archiveFileURL.lastPathComponent
        self.parentSubpath = VirtualArchiveTree.normalize(parentSubpath)
        self.isTemporaryNestedFile = isTemporaryNestedFile
    }
}

public struct BreadcrumbSegment: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let isArchiveBoundary: Bool
    public let targetLocation: NavigationLocation
}

/// Unified navigation state for a file manager pane, matching original 7zFM behavior:
/// directories on disk and folders inside archives (including nested archives) form one continuous tree.
public enum NavigationLocation: Equatable, Hashable, Sendable {
    case diskFolder(URL)
    case archive(rootDiskFolder: URL, layers: [ArchiveLayer], subpath: String)

    public var isInsideArchive: Bool {
        if case .archive = self { return true }
        return false
    }

    public var activeArchiveLayer: ArchiveLayer? {
        guard case .archive(_, let layers, _) = self else { return nil }
        return layers.last
    }

    public var archiveSubpath: String {
        guard case .archive(_, _, let sub) = self else { return "" }
        return sub
    }

    /// Computes the destination when the user triggers `..` / `Backspace` / `Cmd+Up`,
    /// returning both the parent location and the item name to highlight upon arrival.
    public func goingUp() -> (destination: NavigationLocation, highlightName: String?)? {
        switch self {
        case .diskFolder(let url):
            let standardized = url.standardizedFileURL
            guard standardized.path != "/" else { return nil }
            let parent = standardized.deletingLastPathComponent()
            return (.diskFolder(parent), standardized.lastPathComponent)

        case .archive(let rootDiskFolder, var layers, let subpath):
            let cleanSub = VirtualArchiveTree.normalize(subpath)
            if let parentSub = VirtualArchiveTree.parentPath(of: cleanSub) {
                let currentFolderName = cleanSub.split(separator: "/").last.map(String.init)
                return (.archive(rootDiskFolder: rootDiskFolder, layers: layers, subpath: parentSub), currentFolderName)
            }
            guard let popped = layers.popLast() else {
                return (.diskFolder(rootDiskFolder), nil)
            }
            if layers.isEmpty {
                return (.diskFolder(rootDiskFolder), popped.displayName)
            } else {
                return (
                    .archive(rootDiskFolder: rootDiskFolder, layers: layers, subpath: popped.parentSubpath),
                    popped.displayName
                )
            }
        }
    }

    public func enteringArchiveOnDisk(_ archiveURL: URL) -> NavigationLocation {
        let standardized = archiveURL.standardizedFileURL
        let parentDir = standardized.deletingLastPathComponent()
        let layer = ArchiveLayer(archiveFileURL: standardized)
        return .archive(rootDiskFolder: parentDir, layers: [layer], subpath: "")
    }

    public func enteringArchiveSubfolder(_ childSubpath: String) -> NavigationLocation {
        guard case .archive(let root, let layers, _) = self else { return self }
        return .archive(
            rootDiskFolder: root,
            layers: layers,
            subpath: VirtualArchiveTree.normalize(childSubpath)
        )
    }

    public func enteringNestedArchive(extractedTempURL: URL, displayName: String) -> NavigationLocation {
        guard case .archive(let root, var layers, let currentSubpath) = self else {
            return enteringArchiveOnDisk(extractedTempURL)
        }
        layers.append(
            ArchiveLayer(
                archiveFileURL: extractedTempURL,
                displayName: displayName,
                parentSubpath: currentSubpath,
                isTemporaryNestedFile: true
            )
        )
        return .archive(rootDiskFolder: root, layers: layers, subpath: "")
    }

    public var breadcrumbs: [BreadcrumbSegment] {
        var result: [BreadcrumbSegment] = []

        func appendDiskSegments(for folderURL: URL) {
            let comps = folderURL.standardizedFileURL.pathComponents
            var running = URL(fileURLWithPath: "/")
            for (idx, comp) in comps.enumerated() {
                if idx == 0 && comp == "/" {
                    result.append(
                        BreadcrumbSegment(
                            id: "disk:/",
                            title: "/",
                            isArchiveBoundary: false,
                            targetLocation: .diskFolder(URL(fileURLWithPath: "/"))
                        )
                    )
                } else {
                    running.appendPathComponent(comp)
                    result.append(
                        BreadcrumbSegment(
                            id: "disk:\(running.path)",
                            title: comp,
                            isArchiveBoundary: false,
                            targetLocation: .diskFolder(running)
                        )
                    )
                }
            }
        }

        switch self {
        case .diskFolder(let folderURL):
            appendDiskSegments(for: folderURL)

        case .archive(let rootDiskFolder, let layers, let subpath):
            appendDiskSegments(for: rootDiskFolder)
            for lIdx in layers.indices {
                let prefixLayers = Array(layers[...lIdx])
                let layer = layers[lIdx]

                // If nested archive lived inside a subfolder of the previous archive, emit those subfolder crumbs
                if lIdx > 0 && !layer.parentSubpath.isEmpty {
                    let prevLayers = Array(layers[..<lIdx])
                    let parts = layer.parentSubpath.split(separator: "/").map(String.init)
                    var runningSub = ""
                    for p in parts {
                        runningSub = runningSub.isEmpty ? p : "\(runningSub)/\(p)"
                        result.append(
                            BreadcrumbSegment(
                                id: "arc:\(lIdx - 1):\(runningSub)",
                                title: p,
                                isArchiveBoundary: false,
                                targetLocation: .archive(
                                    rootDiskFolder: rootDiskFolder,
                                    layers: prevLayers,
                                    subpath: runningSub
                                )
                            )
                        )
                    }
                }

                result.append(
                    BreadcrumbSegment(
                        id: "arc-root:\(lIdx):\(layer.displayName)",
                        title: layer.displayName,
                        isArchiveBoundary: true,
                        targetLocation: .archive(
                            rootDiskFolder: rootDiskFolder,
                            layers: prefixLayers,
                            subpath: ""
                        )
                    )
                )
            }

            let cleanSub = VirtualArchiveTree.normalize(subpath)
            if !cleanSub.isEmpty {
                let parts = cleanSub.split(separator: "/").map(String.init)
                var runningSub = ""
                for p in parts {
                    runningSub = runningSub.isEmpty ? p : "\(runningSub)/\(p)"
                    result.append(
                        BreadcrumbSegment(
                            id: "arc-sub:\(layers.count - 1):\(runningSub)",
                            title: p,
                            isArchiveBoundary: false,
                            targetLocation: .archive(
                                rootDiskFolder: rootDiskFolder,
                                layers: layers,
                                subpath: runningSub
                            )
                        )
                    )
                }
            }
        }

        return result
    }
}
