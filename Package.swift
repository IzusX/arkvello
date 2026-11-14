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
    name: "SevenZipMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .executable(name: "SevenZipMac", targets: ["SevenZipMac"])
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
            name: "SevenZipMac",
            dependencies: ["ArchiveCore"],
            path: "Sources/SevenZipMac"
        ),
        .testTarget(
            name: "ArchiveCoreTests",
            dependencies: ["ArchiveCore"],
            path: "Tests/ArchiveCoreTests"
        )
    ]
)
