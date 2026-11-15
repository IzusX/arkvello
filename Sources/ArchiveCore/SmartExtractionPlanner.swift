import Foundation

public struct ExtractionPlan: Equatable, Sendable {
    public let finalDestinationDirectory: URL
    public let effectiveStripPrefix: String?

    public init(finalDestinationDirectory: URL, effectiveStripPrefix: String?) {
        self.finalDestinationDirectory = finalDestinationDirectory
        self.effectiveStripPrefix = effectiveStripPrefix
    }
}

/// Implements 7-Zip's "Eliminate duplication of root folder" (`ElimDup`) and smart "Extract Here" rules.
public enum SmartExtractionPlanner {
    public static func archiveBaseName(for archiveURL: URL) -> String {
        let name = archiveURL.lastPathComponent
        let compoundSuffixes = [
            ".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma",
            ".7z.001", ".zip.001", ".rar.001"
        ]
        for suffix in compoundSuffixes where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let stem = archiveURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Extracted" : stem
    }

    /// Computes destination directory and `stripPrefix` for dialog/toolbar extraction.
    /// When `eliminateRootDuplication` is enabled and the archive's root contains a single folder whose name matches
    /// the target subfolder (`Project/Project/...`), strips that redundant outer folder automatically.
    public static func planDialogExtraction(
        archiveURL: URL,
        tree: VirtualArchiveTree,
        selectedPaths: [String],
        currentStripPrefix: String,
        baseDestination: URL,
        createArchiveSubfolder: Bool,
        eliminateRootDuplication: Bool
    ) -> ExtractionPlan {
        let cleanStrip = VirtualArchiveTree.normalize(currentStripPrefix)

        guard selectedPaths.isEmpty else {
            return ExtractionPlan(
                finalDestinationDirectory: createArchiveSubfolder
                    ? baseDestination.appendingPathComponent(archiveBaseName(for: archiveURL), isDirectory: true)
                    : baseDestination,
                effectiveStripPrefix: cleanStrip.isEmpty ? nil : cleanStrip
            )
        }

        let visibleRootChildren = tree.children(in: "").filter {
            $0.name != "__MACOSX" && !$0.name.hasPrefix("._") && $0.name != ".DS_Store"
        }

        if createArchiveSubfolder {
            let subName = archiveBaseName(for: archiveURL)
            let destDir = baseDestination.appendingPathComponent(subName, isDirectory: true)

            if eliminateRootDuplication,
               visibleRootChildren.count == 1,
               let soleRoot = visibleRootChildren.first,
               soleRoot.isDirectory,
               soleRoot.name.caseInsensitiveCompare(subName) == .orderedSame {
                return ExtractionPlan(
                    finalDestinationDirectory: destDir,
                    effectiveStripPrefix: soleRoot.path
                )
            }

            return ExtractionPlan(
                finalDestinationDirectory: destDir,
                effectiveStripPrefix: nil
            )
        } else {
            // If user already chose a destination folder named `Project` and archive has single root `Project/`,
            // `ElimDup` also prevents `.../Project/Project/...`!
            if eliminateRootDuplication,
               visibleRootChildren.count == 1,
               let soleRoot = visibleRootChildren.first,
               soleRoot.isDirectory,
               soleRoot.name.caseInsensitiveCompare(baseDestination.lastPathComponent) == .orderedSame {
                return ExtractionPlan(
                    finalDestinationDirectory: baseDestination,
                    effectiveStripPrefix: soleRoot.path
                )
            }

            return ExtractionPlan(
                finalDestinationDirectory: baseDestination,
                effectiveStripPrefix: nil
            )
        }
    }

    /// Smart "Extract Here" rule for Finder right-click action:
    /// - Single root item (1 folder or 1 file) -> extracts directly into `parentFolder` without extra wrapper;
    /// - Multiple root items -> creates `parentFolder/<ArchiveBaseName>/` so Desktop/Downloads is never flooded.
    public static func planSmartExtractHere(
        archiveURL: URL,
        tree: VirtualArchiveTree
    ) -> ExtractionPlan {
        let parentFolder = archiveURL.standardizedFileURL.deletingLastPathComponent()
        let visibleRootChildren = tree.children(in: "").filter {
            $0.name != "__MACOSX" && !$0.name.hasPrefix("._") && $0.name != ".DS_Store"
        }

        if visibleRootChildren.count <= 1 {
            return ExtractionPlan(
                finalDestinationDirectory: parentFolder,
                effectiveStripPrefix: nil
            )
        } else {
            let subName = archiveBaseName(for: archiveURL)
            return ExtractionPlan(
                finalDestinationDirectory: parentFolder.appendingPathComponent(subName, isDirectory: true),
                effectiveStripPrefix: nil
            )
        }
    }
}
