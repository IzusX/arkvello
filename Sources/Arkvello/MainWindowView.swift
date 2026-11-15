import AppKit
import ArchiveCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var appVM: AppViewModel

    private var browser: some View {
        NavigationSplitView {
            SidebarView(appVM: appVM)
                .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if !appVM.modifiedEditSessions.isEmpty {
                    ModifiedSessionsBanner(appVM: appVM)
                    Divider()
                }

                if let banner = appVM.operationBanner {
                    OperationStatusBar(
                        state: banner,
                        onCancel: { appVM.cancelRunningOperation() },
                        onDismiss: { appVM.operationBanner = nil }
                    )
                    Divider()
                }

                if appVM.isDualPane {
                    HSplitView {
                        FilePaneContainerView(
                            pane: appVM.leftPane,
                            appVM: appVM,
                            isActive: appVM.activeSide == .left
                        )
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

                        FilePaneContainerView(
                            pane: appVM.rightPane,
                            appVM: appVM,
                            isActive: appVM.activeSide == .right
                        )
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    FilePaneContainerView(
                        pane: appVM.leftPane,
                        appVM: appVM,
                        isActive: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    appVM.activePane.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!appVM.activePane.canGoBack)
                .help("Назад")

                Button {
                    appVM.activePane.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!appVM.activePane.canGoForward)
                .help("Вперёд")

                Button {
                    appVM.activePane.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(!appVM.activePane.canGoUp)
                .help("На уровень вверх (Backspace / ⌘↑)")
            }

            ToolbarItemGroup(placement: .principal) {
                Button {
                    appVM.presentAddCompressDialog()
                } label: {
                    Label("Добавить", systemImage: "plus.rectangle.on.folder")
                }
                .help("Создать архив или добавить файлы (⌘N)")

                Button {
                    appVM.presentExtractDialog()
                } label: {
                    Label("Извлечь", systemImage: "tray.and.arrow.up")
                }
                .help("Извлечь файлы из архива (⌘E)")

                Button {
                    appVM.testCurrentArchive()
                } label: {
                    Label("Тест", systemImage: "checkmark.shield")
                }
                .help("Проверить целостность архива (⇧⌘T)")

                Button {
                    appVM.computeChecksumsForSelection()
                } label: {
                    Label("Хеш", systemImage: "number")
                }
                .disabled(appVM.activePane.selectedActionableRows.first.map { $0.isDirectory } ?? true)
                .help("Вычислить CRC32, SHA-256 и XXH64 выбранного файла")

                Divider()

                if appVM.isDualPane {
                    Button {
                        appVM.copyOrMoveSelectionAcrossPanes(move: false)
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    .help("Копировать в соседнюю панель (F5)")

                    Button {
                        appVM.copyOrMoveSelectionAcrossPanes(move: true)
                    } label: {
                        Label("Переместить", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .help("Переместить в соседнюю панель (F6)")
                }

                Button {
                    appVM.presentNewFolderDialog()
                } label: {
                    Label("Папка", systemImage: "folder.badge.plus")
                }
                .help("Новая папка (F7)")

                Button {
                    appVM.deleteSelectedItems()
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                .disabled(appVM.activePane.selectedActionableRows.isEmpty)
                .help("Удалить выбранное (⌘⌫)")

                Button {
                    appVM.presentProperties()
                } label: {
                    Label("Свойства", systemImage: "info.circle")
                }
                .help("Свойства архива и выделенных объектов (⌘I)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appVM.toggleDualPane()
                } label: {
                    Image(systemName: appVM.isDualPane ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .help(appVM.isDualPane ? "Переключить в 1 панель (F9)" : "Двухпанельный режим (F9)")
            }
        }
    }

    var body: some View {
        Group {
            if appVM.isFinderOperationWindow {
                FinderOperationView(appVM: appVM)
            } else {
                browser
            }
        }
        .onChange(of: appVM.compressSheet?.id) { old, new in
            if old != nil && new == nil { appVM.finishFinderServiceIfIdle() }
        }
        .onChange(of: appVM.passwordPrompt?.id) { old, new in
            if old != nil && new == nil { appVM.finishFinderServiceIfIdle() }
        }
        .sheet(item: Binding(get: { appVM.passwordPrompt }, set: { if $0 == nil { appVM.passwordPrompts.dismiss() } }),
               onDismiss: { appVM.passwordPrompts.didDismiss(); appVM.finishFinderServiceIfIdle() }) { req in
            PasswordPromptSheet(request: req)
        }
        .sheet(item: $appVM.compressSheet) { req in
            CompressSheetView(
                request: req,
                defaultExcludeMacJunk: appVM.excludeMacOSMetadataByDefault,
                defaultPreserveXattr: appVM.preserveMacXattrByDefault
            ) { archiveURL, options, password, remember in
                appVM.executeCompression(
                    archiveURL: archiveURL,
                    inputURLs: req.inputURLs,
                    options: options,
                    password: password,
                    saveToKeychain: remember
                )
            }
        }
        .sheet(item: $appVM.extractSheet) { req in
            ExtractSheetView(
                request: req,
                defaultEliminateDup: appVM.eliminateRootDuplication
            ) { dest, createSub, elimDup, fullPaths, overwrite, pwd in
                appVM.executeExtraction(
                    request: req,
                    destinationFolder: dest,
                    createArchiveSubfolder: createSub,
                    eliminateDupRoot: elimDup,
                    fullPaths: fullPaths,
                    overwriteMode: overwrite,
                    passwordOverride: pwd
                )
            }
        }
        .sheet(item: $appVM.renameSheet) { req in
            SimpleNamePromptSheet(
                title: "Переименовать",
                fieldLabel: "Новое имя",
                confirmTitle: "Переименовать",
                text: req.row.name
            ) { newName in
                appVM.executeRename(request: req, newName: newName)
            }
        }
        .sheet(item: $appVM.newFolderSheet) { req in
            SimpleNamePromptSheet(
                title: "Новая папка",
                fieldLabel: "Имя папки",
                confirmTitle: "Создать",
                text: "Новая папка"
            ) { folderName in
                appVM.executeCreateFolder(request: req, folderName: folderName)
            }
        }
        .sheet(item: $appVM.propertiesSheet) { req in
            PropertiesSheetView(request: req)
        }
        .sheet(item: $appVM.checksumSheet) { req in
            ChecksumSheetView(request: req)
        }
        .sheet(item: $appVM.overwriteConflictSheet, onDismiss: { appVM.finishOverwritePrompt() }) { req in
            OverwriteConflictSheetView(request: req)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $appVM.showSettingsSheet) {
            SettingsSheetView(appVM: appVM)
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var appVM: AppViewModel

    var body: some View {
        List {
            Section("Места") {
                ForEach(appVM.sidebarShortcuts) { item in
                    Button {
                        appVM.activePane.navigate(to: .diskFolder(item.url))
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
            }

            if !appVM.recentArchiveURLs.isEmpty {
                Section("Недавние архивы") {
                    ForEach(appVM.recentArchiveURLs, id: \.path) { url in
                        Button {
                            appVM.activePane.openArchiveFile(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "archivebox")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Вид") {
                Toggle("Показывать скрытые файлы", isOn: Binding(
                    get: { appVM.activePane.showHiddenFiles },
                    set: { newVal in
                        appVM.leftPane.showHiddenFiles = newVal
                        appVM.rightPane.showHiddenFiles = newVal
                    }
                ))
                .font(.callout)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FilePaneContainerView: View {
    @ObservedObject var pane: PaneViewModel
    @ObservedObject var appVM: AppViewModel
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            if appVM.isDualPane {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(pane.tabs) { tab in
                            HStack(spacing: 6) {
                                Button {
                                    appVM.activeSide = pane.side
                                    pane.selectTab(tab.id)
                                } label: {
                                    Text(tab.title)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(minWidth: 60, maxWidth: 160)
                                }
                                .buttonStyle(.plain)
                                if pane.tabs.count > 1 {
                                    Button {
                                        appVM.activeSide = pane.side
                                        pane.closeTab(id: tab.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Закрыть вкладку")
                                }
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(tab.id == pane.activeTabID ? Color.primary.opacity(0.08) : Color.clear)
                        }
                    }
                }
                Button {
                    appVM.activeSide = pane.side
                    pane.openNewTab()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .help("Новая вкладка (⌘T)")
            }
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            PaneBreadcrumbBar(pane: pane, onFocus: {
                appVM.activeSide = pane.side
            })

            Divider()

            if pane.isNestedArchive {
                Text("Вложенный архив открыт только для чтения. Для изменения сначала извлеките его на диск.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }

            if let err = pane.errorBanner {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                    Button("Повторить") {
                        pane.reloadCurrentLocation(forceReopenArchive: true)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
                Divider()
            }

            FilePaneTableView(
                pane: pane,
                appVM: appVM,
                isActivePane: isActive
            )

            Divider()

            if pane.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загрузка…").font(.callout)
                    Spacer()
                    Button("Отменить") { pane.cancelLoading() }.controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                PaneFooterBar(pane: pane)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct PaneBreadcrumbBar: View {
    @ObservedObject var pane: PaneViewModel
    let onFocus: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    let crumbs = pane.location.breadcrumbs
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, seg in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }

                        Button {
                            onFocus()
                            pane.navigate(to: seg.targetLocation)
                        } label: {
                            HStack(spacing: 4) {
                                if seg.isArchiveBoundary {
                                    Image(systemName: "archivebox.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(seg.title)
                                    .font(.system(size: 12, weight: seg.isArchiveBoundary ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, seg.isArchiveBoundary ? 7 : 4)
                            .padding(.vertical, 2)
                            .background(
                                seg.isArchiveBoundary
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .foregroundStyle(seg.isArchiveBoundary ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)
            }

            Spacer(minLength: 4)

            if let summary = pane.activeArchiveSummary {
                HStack(spacing: 5) {
                    Text(summary.displayFormat.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                    if summary.isSolid {
                        Text("SOLID")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !pane.canModifyArchive {
                        Text("ЧТЕНИЕ")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            Menu {
                Toggle("Плоский список файлов", isOn: $pane.isFlatView)
                Toggle("Искать во вложенных папках", isOn: $pane.isDeepSearch)
                if pane.location.isInsideArchive {
                    Divider()
                    Picker("Кодировка имён", selection: $pane.archiveEncoding) {
                        ForEach(ArchiveNameEncoding.allCases) { encoding in
                            Text(encoding.title).tag(encoding)
                        }
                    }
                }
            } label: {
                Image(systemName: pane.isFlatView ? "list.bullet" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Плоский список, поиск и кодировка архива")
            .simultaneousGesture(TapGesture().onEnded { onFocus() })

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(pane.isDeepSearch ? "Поиск" : "Фильтр", text: $pane.filterText)
                    .focused($isSearchFocused)
                    .onChange(of: isSearchFocused) { _, focused in
                        if focused { onFocus() }
                    }
                    .onChange(of: pane.searchFieldFocusTrigger) { _, _ in
                        isSearchFocused = true
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 110)
                if !pane.filterText.isEmpty {
                    Button {
                        pane.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PaneFooterBar: View {
    @ObservedObject var pane: PaneViewModel

    var body: some View {
        HStack {
            Text(pane.statusSummaryText)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            if pane.location.isInsideArchive {
                Text("Пробел: просмотр · ⏎: открыть · ⌫: вверх")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ModifiedSessionsBanner: View {
    @ObservedObject var appVM: AppViewModel

    var body: some View {
        ForEach(appVM.modifiedEditSessions, id: \.extractedFileURL.path) { session in
            HStack(spacing: 10) {
                Image(systemName: "pencil.and.list.clipboard")
                    .foregroundStyle(.orange)
                Text("Файл «\(session.extractedFileURL.lastPathComponent)» был изменён во внешней программе. Обновить его внутри «\(session.archiveURL.lastPathComponent)»?")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Обновить в архиве") {
                    appVM.commitModifiedSession(session)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button("Не сохранять") {
                    appVM.discardModifiedSession(session)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.10))
        }
    }
}

private struct OperationStatusBar: View {
    let state: OperationBannerState
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if state.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: state.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(state.isError ? .red : .green)
            }

            Text(state.title + ":")
                .font(.system(size: 12, weight: .semibold))

            Text(state.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if state.isRunning, let frac = state.fraction {
                ProgressView(value: frac)
                    .frame(width: 120)
                Text("\(Int(frac * 100))%")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.isRunning {
                Button("Отмена", action: onCancel)
                    .controlSize(.small)
            } else {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(state.isError ? Color.red.opacity(0.09) : Color.accentColor.opacity(0.07))
    }
}
