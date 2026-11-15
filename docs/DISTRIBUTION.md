# Arkvello distribution

Arkvello is an independent SwiftUI/AppKit macOS application using the embedded 7-Zip engine. It is not an official version of 7-Zip, and is not affiliated with or endorsed by Igor Pavlov or the 7-Zip project. The official 7-Zip website is https://www.7-zip.org/. The Arkvello repository is https://github.com/IzusX/arkvello.

## Release prerequisites

- macOS 14 or later, Xcode 16.4 / Swift 6, and the command-line tools are required to build. The application targets macOS 14+ and packages arm64 and x86_64 slices.
- The original application code, documentation and build scripts are MIT-licensed, Copyright (c) 2026 IzusX, with the exclusions in the root `LICENSE`. `Vendor/7zip` and other upstream material retain their own licenses. Bridge code compiled into `libsevenzip.dylib` is LGPL-2.1-or-later. **The complete bundle is not solely MIT-licensed.** Preserve the root license, full upstream license texts, source-file notices and unRAR restriction in every applicable distribution.
- Releases currently use ad-hoc signatures, not Developer ID signing or Apple notarization. A universal binary proves slice presence, not working behavior on both platforms. Intel runtime behavior has not been verified locally. CI runs native tests and builds on separate Apple Silicon and Intel macOS 15 runners; interactive app and Finder behavior still need manual verification on both platforms.
- Use stable versions of the form `1.2.3`, with no leading zeros, suffix, or `v` in `APP_VERSION`. Release tags have the corresponding `v1.2.3` form. Local scripts receive the repository explicitly where needed.

The application bundle is `Arkvello.app`; its executable/module is `Arkvello`, Quick Look extension is `ArkvelloQuickLook`, and app identifier is `io.github.izusx.arkvello`. Keep the upstream engine names `Vendor/7zip`, `Scripts/build-7zip.sh` and `libsevenzip.dylib` unchanged.

The app's About window identifies Arkvello as an independent project, credits the engine, and opens `Contents/Resources/Licenses/` with the MIT license, full upstream license texts, third-party notices and distribution instructions. The DMG also includes the MIT license and upstream notices in its `Licenses` folder. The generated Cask prints a Gatekeeper installation note; it does not change macOS security settings.

## Build and package locally

Run from the project root. Use `bash` explicitly; script executable bits are not required.

```bash
ARCHS='arm64 x86_64' bash Scripts/build-7zip.sh
# Tests execute natively, after the engine exists.
swift test
ARCHS='arm64 x86_64' APP_VERSION=1.2.3 BUILD_NUMBER=1 bash Scripts/build-app.sh
APP_VERSION=1.2.3 bash Scripts/build-dmg.sh
```

`build-dmg.sh` checks the bundle version, verifies both architectures in the app, engine, and Quick Look extension, and verifies the bundle signature. It creates:

- `dist/Arkvello-1.2.3-universal.dmg`, containing `Arkvello.app`, an `/Applications` symlink, license texts, these instructions, and source-availability information.
- `dist/SHA256SUMS`, initially covering the DMG.

The packager allows local uncommitted work. **A local DMG alone is not a complete public release:** do not distribute it without the corresponding source and notices below. The source-availability notice assumes the publisher supplies the companion source archive.

## Versioned source and LGPL availability

The engine is dynamically linked as `Arkvello.app/Contents/Frameworks/libsevenzip.dylib`. `THIRD_PARTY_LICENSES.md` identifies LGPL-2.1-or-later, BSD notices, public-domain files and the unRAR restriction. Preserve the complete upstream `Vendor/7zip/DOC/License.txt`, `copying.txt`, and `unRarLicense.txt` texts verbatim, together with the root `LICENSE` and applicable source-file notices. Include these licenses in the binary package and corresponding source archive.

The unRAR sources cannot be used to re-create the proprietary RAR compression algorithm or develop a RAR (WinRAR) compatible archiver. Distribution of modified unRAR sources must retain that restriction in documentation and source comments. Arkvello uses the engine for RAR decompression, not RAR creation.

Every public binary release must include **`Arkvello-VERSION-source.tar.gz` alongside the DMG**, not merely a link to moving upstream sources or a promise of future access. Publish both under the matching tag at https://github.com/IzusX/arkvello/releases. The release workflow verifies vendored source and license files are tracked in the tagged commit, rejects changed or untracked source inputs, and runs `git archive HEAD` for the entire versioned project tree. This includes `Vendor/7zip`, bridge modifications, application sources, and build scripts. Do not replace the vendor directory with an unexpanded Git submodule or rely on Git LFS pointer files as source. Keep source assets accessible for recipients in accordance with the applicable licenses.

For a separately reviewed manual release, start from the exact clean committed revision used to build the binaries; ensure all vendor sources are tracked, then create the archive and regenerate checksums:

```bash
VERSION=1.2.3
# Inspect tracking and cleanliness first. git archive omits untracked files.
git status --short
git ls-files Vendor/7zip
git archive --format=tar --prefix="Arkvello-$VERSION-source/" HEAD | gzip -n > "dist/Arkvello-$VERSION-source.tar.gz"
(cd dist && shasum -a 256 "Arkvello-$VERSION-universal.dmg" "Arkvello-$VERSION-source.tar.gz" > SHA256SUMS)
```

### Modify or replace the LGPL library

Unpack the corresponding source asset and modify `Vendor/7zip` and/or `Bridge/sevenzip_bridge.cpp`. From its root, rebuild the dynamically linked engine:

```bash
ARCHS='arm64 x86_64' bash Scripts/build-7zip.sh
```

Copy `Vendor/lib/libsevenzip.dylib` into `Contents/Frameworks/` in a writable copy of `Arkvello.app`, replacing the existing library. Keep the library interface compatible with the app. Modifying a signed bundle invalidates its signature; re-sign the local modified bundle and verify it:

```bash
codesign --force --deep --sign - '/path/to/Arkvello.app'
codesign --verify --deep --strict '/path/to/Arkvello.app'
```

This is local ad-hoc signing, not Apple notarization. See LGPL §6 and the actual license texts for recipient rights and distributor obligations, including modification and reverse engineering for debugging such modifications. The project does not restrict exercising those LGPL rights. Preserve copyright and license notices in modified and redistributed source.

## CI release behavior

`.github/workflows/ci.yml` runs on branch pushes, pull requests, manual dispatch, and as a reusable workflow. It uses Xcode 16.4 on `macos-15` (Apple Silicon) and `macos-15-intel`, running native engine builds, all tests, app/Quick Look builds, signature verification and a source-cleanliness check.

`.github/workflows/release.yml` runs only on pushed `v` version tags and rejects tags that are not stable semantic versions. It requires the reusable CI checks on both architectures to pass, then builds the universal app on `macos-15` with Xcode 16.4, `APP_VERSION` and `BUILD_NUMBER`, and packages the DMG. The source archive, actual generated cask, and `SHA256SUMS` are uploaded as artifacts before a separate release job publishes them. External actions are pinned to commit SHAs.

Only the release job receives `contents: write`; the build job has read-only repository permissions. There is no manual publishing trigger. A rerun does not overwrite an existing release: `gh release create` fails if it already exists. Check the corresponding source and license contents before creating tags; CI checks do not replace review of the release contents and third-party obligations.

## Generate a Homebrew cask

Pass the GitHub owner/repository explicitly and the actual finished DMG. The script computes SHA-256 from that file; it does not emit a placeholder or fetch a fake checksum.

```bash
bash Scripts/generate-cask.sh 1.2.3 IzusX/arkvello \
  dist/Arkvello-1.2.3-universal.dmg > dist/arkvello.rb
```

The cask token is `arkvello`, and its download URL is `https://github.com/IzusX/arkvello/releases/download/vVERSION/Arkvello-VERSION-universal.dmg`. CI passes `github.repository` explicitly and includes the generated file as a release asset, so forks must use their own owner/repository. The separate `IzusX/homebrew-tap` repository runs its own update workflow daily or by manual dispatch. It downloads the latest stable release assets, verifies all SHA-256 entries and the cask identity/version/DMG checksum, runs Homebrew style and audit checks, then commits the cask using its own built-in `GITHUB_TOKEN`. No cross-repository personal access token is required. This is an independently maintained tap, not an official Homebrew cask submission.

The separate GitHub repository `IzusX/homebrew-tap` hosts the generated file at `Casks/arkvello.rb`. Once the initial release and tap update have completed, users can install with:

```bash
brew install --cask IzusX/tap/arkvello
```

The application release workflow does not push to the tap. After each release, run `gh workflow run update-arkvello.yml --repo IzusX/homebrew-tap` for immediate availability, or wait for its daily check. The tap update job runs `brew style Casks/arkvello.rb` and `brew audit --cask IzusX/tap/arkvello` before publishing the change; pushes and pull requests also have tap checks. With no published release, the updater reports a failure rather than inventing a download URL or checksum.

To publish the next release from a clean, reviewed `main` revision after CI passes:

```bash
git tag v1.2.3
git push origin v1.2.3
# Wait for Arkvello Release to succeed, then:
gh workflow run update-arkvello.yml --repo IzusX/homebrew-tap
```

Pushing a version tag publishes a public release. Initial branch pushes only run CI. If a tag build fails, fix the cause and use a new version tag, or rerun a failed job when its source revision is still correct; do not move published release tags.

For integrity checking, download `SHA256SUMS` and the assets into the same directory and run `shasum -a 256 -c SHA256SUMS`. These are integrity hashes, not independently authenticated publisher signatures.

## Install and Gatekeeper

Open the DMG and drag `Arkvello.app` to `Applications`, then eject the image. The app is **not Developer ID signed or notarized**; ad-hoc signing does not identify a trusted publisher, and macOS may block a downloaded copy. Inspect the source and release provenance before deciding whether to run it.

If macOS blocks launch, try opening the app once, then go to **System Settings → Privacy & Security → Open Anyway** for this app and confirm the system prompt. Availability and wording depend on macOS policy; managed Macs may prohibit overrides. Do not globally disable Gatekeeper, and do not automatically strip quarantine attributes. Neither the cask nor these scripts remove quarantine. Quick Look extension activation is also subject to system policy; a successfully built or copied extension is not proof that macOS has enabled it.
