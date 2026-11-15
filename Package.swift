// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLibDir = "\(packageRoot)/Vendor/lib"

let sharedLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(vendorLibDir)",
        "-lsevenzip",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", vendorLibDir
    ])
]

let package = Package(
    name: "Arkvello",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .executable(name: "Arkvello", targets: ["Arkvello"])
    ],
    targets: [
        .target(
            name: "CSevenZip",
            path: "Sources/CSevenZip",
            publicHeadersPath: "include",
            linkerSettings: sharedLinkerSettings
        ),
        .target(
            name: "ArchiveCore",
            dependencies: ["CSevenZip"],
            path: "Sources/ArchiveCore"
        ),
        .executableTarget(
            name: "Arkvello",
            dependencies: ["ArchiveCore"],
            path: "Sources/Arkvello"
        ),
        .target(name: "ArchivePreview", dependencies: ["CSevenZip"],
                path: "Extensions/ArkvelloQuickLook",
                exclude: ["PreviewProvider.swift", "Info.plist", "ArkvelloQuickLook.entitlements"],
                sources: ["ArchiveListing.swift"]),
        .testTarget(name: "ArchivePreviewTests", dependencies: ["ArchivePreview", "ArchiveCore"],
                    path: "Tests/ArchivePreviewTests"),
        .testTarget(name: "ArkvelloTests", dependencies: ["Arkvello"], path: "Tests/ArkvelloTests"),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore"],
            path: "Tests/ArchiveCoreTests"
        )
    ]
)
