import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

struct PersistedSession: Codable {
    var isDualPane: Bool
    var showHiddenFiles: Bool
    var leftFolderPaths: [String]
    var leftActiveTabIndex: Int
    var rightFolderPaths: [String]
    var rightActiveTabIndex: Int
    var recentArchivePaths: [String]
    var eliminateRootDuplication: Bool
    var excludeMacOSMetadataByDefault: Bool
    var preserveMacXattrByDefault: Bool
}

enum SessionStore {
    private static let key = "io.github.izusx.arkvello.session.v2"

    static func load() -> PersistedSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    static func save(_ session: PersistedSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct FormatAssociationGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let extensions: [String]
    var defaultSelected: Bool
}

@MainActor
enum DefaultArchiverManager {
    static let groups: [FormatAssociationGroup] = [
        FormatAssociationGroup(
            id: "7z",
            title: "Архивы 7-Zip",
            subtitle: ".7z, .001",
            extensions: ["7z", "001"],
            defaultSelected: true
        ),
        FormatAssociationGroup(
            id: "rar",
            title: "Архивы RAR",
            subtitle: ".rar",
            extensions: ["rar"],
            defaultSelected: true
        ),
        FormatAssociationGroup(
            id: "zip",
            title: "Архивы ZIP",
            subtitle: ".zip, .zipx, .cbz, .jar",
            extensions: ["zip", "zipx", "cbz", "jar"],
            defaultSelected: true
        ),
        FormatAssociationGroup(
            id: "tar_unix",
            title: "Архивы TAR / GZip / BZip2 / XZ / Zstd",
            subtitle: ".tar, .tgz, .tbz2, .txz, .tzst, .gz, .bz2, .xz, .zst",
            extensions: ["tar", "tgz", "tbz2", "txz", "tzst", "gz", "bz2", "xz", "zst"],
            defaultSelected: true
        ),
        FormatAssociationGroup(
            id: "packages",
            title: "Пакеты и образы",
            subtitle: ".cab, .wim, .iso, .xar, .rpm, .deb, .cpio",
            extensions: ["cab", "wim", "iso", "xar", "rpm", "deb", "cpio"],
            defaultSelected: false
        )
    ]

    static var currentAppBundleURL: URL {
        let mainURL = Bundle.main.bundleURL
        if mainURL.pathExtension == "app" {
            return mainURL
        }
        let installed = URL(fileURLWithPath: "/Applications/Arkvello.app")
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        return mainURL
    }

    static var isInstalledInApplications: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Arkvello.app")
    }

    static func currentDefaultHandlerName(forExtension ext: String) -> String {
        guard let utType = UTType(filenameExtension: ext),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: utType) else {
            return "Не назначено"
        }
        return appURL.deletingPathExtension().lastPathComponent
    }

    static func applyDefaultAssociations(for extensions: [String]) async -> (succeeded: Int, failed: Int) {
        let appURL = currentAppBundleURL
        guard appURL.pathExtension == "app" else {
            return (0, extensions.count)
        }

        var uniqueTypes: [UTType] = []
        var seen = Set<String>()
        for ext in extensions {
            if let t = UTType(filenameExtension: ext), !seen.contains(t.identifier) {
                seen.insert(t.identifier)
                uniqueTypes.append(t)
            }
        }

        var ok = 0
        var fail = 0
        for utType in uniqueTypes {
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: utType) { error in
                        if let error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume(returning: ())
                        }
                    }
                }
                ok += 1
            } catch {
                fail += 1
            }
        }
        return (ok, fail)
    }

    static func installToApplicationsAndRegisterExtensions() throws -> URL {
        let sourceBundle = Bundle.main.bundleURL
        guard sourceBundle.pathExtension == "app" else {
            throw ArchiveError.invalidArgument("Запустите собранный Arkvello.app для копирования в /Applications")
        }

        let targetBundle = URL(fileURLWithPath: "/Applications/Arkvello.app")
        let fm = FileManager.default
        if sourceBundle.resolvingSymlinksInPath() != targetBundle.resolvingSymlinksInPath() {
            try StagedReplacement.publish(at: targetBundle) { stagedBundle in
                try fm.copyItem(at: sourceBundle, to: stagedBundle)
            }
        }

        // Refresh macOS LaunchServices, Finder Services menu, and Quick Look PlugInKit registration
        NSUpdateDynamicServices()

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if fm.isExecutableFile(atPath: lsregister) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: lsregister)
            proc.arguments = ["-f", targetBundle.path]
            try? proc.run()
            proc.waitUntilExit()
        }

        let qlAppex = targetBundle.appendingPathComponent("Contents/PlugIns/ArkvelloQuickLook.appex")
        if fm.fileExists(atPath: qlAppex.path) {
            let pk = Process()
            pk.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            pk.arguments = ["-a", qlAppex.path]
            try? pk.run()
            pk.waitUntilExit()

            let pkEnable = Process()
            pkEnable.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            pkEnable.arguments = ["-e", "use", "-i", "io.github.izusx.arkvello.quicklook"]
            try? pkEnable.run()
            pkEnable.waitUntilExit()
        }

        return targetBundle
    }
}

struct SettingsSheetView: View {
    @ObservedObject var appVM: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedGroupIDs: Set<String> = Set(
        DefaultArchiverManager.groups.filter(\.defaultSelected).map(\.id)
    )
    @State private var statusMessage: String?
    @State private var isApplying: Bool = false
    @State private var refreshToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Настройки и интеграция с macOS")
                .font(.headline)

            Form {
                Section("Поведение архиватора по умолчанию") {
                    Toggle(
                        "Устранять дублирование корневой папки при извлечении (ElimDup)",
                        isOn: $appVM.eliminateRootDuplication
                    )
                    Toggle(
                        "Исключать служебные файлы macOS (.DS_Store, ._*, __MACOSX) при сжатии",
                        isOn: $appVM.excludeMacOSMetadataByDefault
                    )
                    Toggle(
                        "Сохранять расширенные атрибуты macOS (xattr / теги Finder) по умолчанию",
                        isOn: $appVM.preserveMacXattrByDefault
                    )
                }

                Section("Интеграция с Finder (ПКМ и Quick Look)") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(DefaultArchiverManager.isInstalledInApplications
                                 ? "Установлен в /Applications/Arkvello.app"
                                 : "Приложение запущено вне папки /Applications")
                                .font(.callout.weight(.medium))
                            Text("Копирование в /Applications активирует пункты правой кнопки мыши в Finder («Службы / Быстрые действия») и предпросмотр архивов по пробелу.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Установить в /Applications") {
                            do {
                                let url = try DefaultArchiverManager.installToApplicationsAndRegisterExtensions()
                                statusMessage = "Установлено в \(url.path); службы Finder и Quick Look обновлены."
                                refreshToken = UUID()
                            } catch {
                                statusMessage = error.localizedDescription
                            }
                        }
                    }
                }

                Section("Форматы архивов по умолчанию (открытие двойным кликом)") {
                    ForEach(DefaultArchiverManager.groups) { group in
                        let primaryExt = group.extensions.first ?? "7z"
                        let currentHandler = DefaultArchiverManager.currentDefaultHandlerName(forExtension: primaryExt)
                        Toggle(isOn: Binding(
                            get: { selectedGroupIDs.contains(group.id) },
                            set: { on in
                                if on { selectedGroupIDs.insert(group.id) }
                                else { selectedGroupIDs.remove(group.id) }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(group.title)
                                    Text(group.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("Сейчас: \(currentHandler)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .id(refreshToken)
                            }
                        }
                    }

                    HStack {
                        Button("Назначить Arkvello по умолчанию для выбранных") {
                            let exts = DefaultArchiverManager.groups
                                .filter { selectedGroupIDs.contains($0.id) }
                                .flatMap(\.extensions)
                            isApplying = true
                            Task {
                                let res = await DefaultArchiverManager.applyDefaultAssociations(for: exts)
                                isApplying = false
                                refreshToken = UUID()
                                statusMessage = "Обновлено типов файлов: \(res.succeeded)"
                                    + (res.failed > 0 ? " (пропущено: \(res.failed))" : "")
                            }
                        }
                        .disabled(selectedGroupIDs.isEmpty || isApplying)

                        if isApplying {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Готово") {
                    appVM.persistSessionState()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 580, height: 560)
    }
}
