# Arkvello

**English** | [Русский](README.ru.md)

[![CI](https://github.com/IzusX/arkvello/actions/workflows/ci.yml/badge.svg)](https://github.com/IzusX/arkvello/actions/workflows/ci.yml)

A native macOS file and archive manager with its own `SwiftUI` + `AppKit NSTableView` interface and the embedded **7-Zip 26.06** engine (`libsevenzip.dylib`). Project repository: [IzusX/arkvello](https://github.com/IzusX/arkvello).

Arkvello is an independent application, not an official version of 7-Zip for macOS. It is not affiliated with or endorsed by Igor Pavlov or the 7-Zip project. Official 7-Zip website: [www.7-zip.org](https://www.7-zip.org/).

## Features

- **Seamless navigation between disk folders, archives, and nested archives**: browse folders and archive contents in the same pane without extracting the entire archive first. `Enter` opens an archive; `Backspace` / `⌘↑` / `..` goes up one level.
- **One or two panes (`F9`)**: a single-pane view when opening an archive from Finder, or a two-pane layout with `F5 Copy` / `F6 Move` between folders and archives. `Tab` switches the active pane.
- **Quick previews and editing**:
  - `Space` opens system `Quick Look` (`QLPreviewPanel`) for files inside archives.
  - Double-click / `Enter` opens a file in an external application. After saving changes, Arkvello offers to update it inside the archive (`7z`, `zip`, `tar`, `wim`).
- **Drag and drop with Finder**: drag files from an archive into Finder using `NSFilePromiseProvider`, or from Finder into an archive.
- **The full 7-Zip 26.06 engine runs in process**: read 70+ formats (`7z`, `zip`, `rar`/`rar5`, `tar`, `gz`, `bz2`, `xz`, `zstd`, `dmg`, `iso`, `apfs`, `cab`, `wim`, `.001`, and more); create and update `7z`/`zip`/`tar`/`wim`; use AES-256 and filename encryption (`-mhe=on`). Passwords stay in process and are not exposed in command-line arguments.

Nested archives can be browsed and extracted. To modify one, extract it to disk first: automatically writing changes back through a chain of enclosing archives is not supported yet.

Folder and archive loading, tree construction, and nested archive extraction run in the background. The pane displays loading progress and a cancel button; results from a folder or tab you have left do not replace the current list. Engine cancellation is cooperative: an individual system call or format handler may finish later, but its result is no longer applied.

Search starts after a 250 ms typing pause. Filtering, row preparation, and sorting run in the background; regular folder listings have no row limit. Recursive search and flat view display up to 8,000 matches with an explicit truncation indicator. This is a traversal sample sorted for display, rather than the first 8,000 entries of a globally sorted tree; narrow the query for more precise results.

Archive creation, modification and extraction, copying, moving, and preview preparation run one operation at a time. Repeating a command while an operation finishes or cancels does not start a competing write. Progress updates are coalesced, password prompts from panes and operations are shown sequentially, and cancelling releases a pending overwrite decision. Disk copies stage a complete file or folder before replacing the destination; a preparation failure preserves the existing item. Cancellation does not roll back completed items in a batch, and an individual system copy call may finish later.

## Additional features

- Pane tabs (`⌘T`, `⌘W`) and restoration of open folders and archives on the next launch.
- Flat view and search through archive subfolders; manual ZIP encoding selection (UTF-8, CP866, Windows-1251, KOI8-R, CP437, Windows-1252). Legacy encoding detection is heuristic; select the encoding manually for ambiguous filenames.
- Copy and paste through the system clipboard (`⌘C` / `⌘V`). Files copied from an archive are first extracted to a temporary folder.
- Smart extraction that avoids duplicate root folders, with a comparison of existing and incoming files when a conflict occurs.
- Checksums for files on disk and inside archives, with copying and comparison against an expected hash.
- Exclusion of macOS housekeeping files or preservation of extended attributes through AppleDouble. Passwords can be saved in macOS Keychain; separate Touch ID support is not implemented.

## Finder integration

In Settings (`⌘,`), you can install the app in `/Applications` and choose the formats it opens by default. System file associations are not changed automatically.

The app provides five Finder services: Extract Here, Extract to Subfolder, Add to 7z, Add to Archive…, and Test Archive. Their location and availability depend on macOS settings (Services / Quick Actions).

The bundle includes `ArkvelloQuickLook.appex` to preview an archive's file listing with `Space` in Finder. For archives with encrypted filenames, the extension displays a notice without requesting a password. The extension is ad-hoc signed: a successful build does not guarantee that macOS has activated it. Check the Quick Look extensions section in System Settings if needed. The app has no Developer ID signature or Apple notarization.

`⌘T` opens a tab; `⇧⌘T` tests archive integrity.

## Install a release

Open the DMG from [GitHub Releases](https://github.com/IzusX/arkvello/releases),
drag `Arkvello.app` into `Applications`, and eject the image.
If macOS blocks launch, try opening the app once, then use
System Settings → Privacy & Security → Open Anyway if you trust the release.
See [Apple's instructions](https://support.apple.com/en-us/102445).

Install through the [IzusX Homebrew tap](https://github.com/IzusX/homebrew-tap):

```bash
brew install --cask IzusX/tap/arkvello
```

The tap checks published releases daily; its workflow can also be started manually after a release.
About Arkvello → Licenses… opens the license files bundled with the app.

## Build and run

```bash
# 1. Build the 7-Zip 26.06 engine library (Vendor/lib/libsevenzip.dylib)
bash Scripts/build-7zip.sh

# 2. Run core, application, and Quick Look renderer tests
swift test

# 3. Build the app in dist/Arkvello.app
bash Scripts/build-app.sh
open "dist/Arkvello.app"
```

The application module and executable are named `Arkvello`, the extension is `ArkvelloQuickLook`, and the application identifier is `io.github.izusx.arkvello`. The engine retains the names `Vendor/7zip`, `Scripts/build-7zip.sh`, and `libsevenzip.dylib`.

## Universal builds and releases

One bundle supports Apple Silicon and Intel (macOS 14+):

```bash
ARCHS='arm64 x86_64' APP_VERSION=0.1.0 BUILD_NUMBER=1 bash Scripts/build-app.sh
APP_VERSION=0.1.0 bash Scripts/build-dmg.sh
```

Packaging produces `dist/Arkvello.app`, `dist/Arkvello-0.1.0-universal.dmg`, and `dist/SHA256SUMS`. Every public release must include the corresponding source archive, `Arkvello-0.1.0-source.tar.gz`, alongside the DMG.
Both architectures are included in the app, engine, and Quick Look extension. For a quick local build, omitting `ARCHS` uses the current Mac's architecture. Including both architectures does not replace runtime testing on Apple Silicon and Intel.

GitHub Actions checks every branch push and pull request: tests and app/Quick Look builds on Apple Silicon and Intel with macOS 15 / Xcode 16.4. Pushing a `vX.Y.Z` tag runs these checks, then builds and publishes a Universal DMG, the complete source archive, checksums, and the `arkvello` Homebrew cask with the actual SHA-256. The separate tap verifies release assets and updates its cask through its own workflow without a personal access token.

Builds are ad-hoc signed, without Developer ID or notarization. If macOS blocks a downloaded app, try opening it once, then use System Settings → Privacy & Security → Open Anyway. There is no need to disable Gatekeeper globally.

Build, tap, release, and engine library replacement instructions: [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

Application structure: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Local validation results and remaining manual release checks (in Russian): [docs/VALIDATION.md](docs/VALIDATION.md).

## Licenses

Original Arkvello application code, documentation, and build scripts are distributed under the [MIT License](LICENSE), Copyright (c) 2026 IzusX, with the exclusions stated there. This MIT permission does not cover `Vendor/7zip`, third-party materials, or the `Bridge` code compiled into the engine. The bridge code in `libsevenzip.dylib` is LGPL-2.1-or-later.

The `libsevenzip.dylib` engine is built from 7-Zip 26.06 sources and the bridge. GNU LGPL v2.1+, BSD 3-Clause, BSD 2-Clause, upstream public-domain designations, and the unRAR restriction apply. The unRAR sources cannot be used to recreate the RAR compression algorithm or develop a RAR (WinRAR)-compatible archiver. Arkvello supports RAR extraction, not RAR creation.

**The complete bundle is not solely MIT-licensed.** Full third-party notices and licenses, source availability, and dynamic library replacement instructions: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md). Upstream license texts are preserved in `Vendor/7zip/DOC/License.txt`, `copying.txt`, and `unRarLicense.txt`.
