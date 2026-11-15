import AppKit
import ArchiveCore
import SwiftUI
import UniformTypeIdentifiers

private final class ArchivePromiseContext: NSObject {
    let archiveURL: URL
    let itemPath: String
    let itemName: String
    let stripPrefix: String
    let password: String?
    let encoding: ArchiveNameEncoding

    init(archiveURL: URL, itemPath: String, itemName: String, stripPrefix: String, password: String?, encoding: ArchiveNameEncoding) {
        self.archiveURL = archiveURL
        self.itemPath = itemPath
        self.itemName = itemName
        self.stripPrefix = stripPrefix
        self.password = password
        self.encoding = encoding
    }
}

final class KeyHandlingTableView: NSTableView {
    var onKeyAction: ((NSEvent) -> Bool)?
    var onBuildContextMenu: ((Int) -> NSMenu?)?
    var onBecameActive: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) { onPaste?() }

    override func mouseDown(with event: NSEvent) {
        onBecameActive?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let onKeyAction, onKeyAction(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBecameActive?()
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return onBuildContextMenu?(clickedRow)
    }
}

struct FilePaneTableView: NSViewRepresentable {
    @ObservedObject var pane: PaneViewModel
    @ObservedObject var appVM: AppViewModel
    let isActivePane: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(pane: pane, appVM: appVM)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tableView = KeyHandlingTableView()
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.focusRingType = .none

        let columnsSpec: [(id: SortField, title: String, width: CGFloat, minW: CGFloat, maxW: CGFloat, rightAlign: Bool)] = [
            (.name, "Имя", 280, 160, 2000, false),
            (.size, "Размер", 92, 70, 180, true),
            (.packedSize, "Сжатый", 92, 70, 180, true),
            (.modified, "Изменён", 128, 105, 200, false),
            (.attributes, "Атрибуты", 96, 75, 150, false),
            (.crc, "CRC", 80, 68, 120, false),
            (.method, "Метод", 120, 80, 260, false)
        ]

        for spec in columnsSpec {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id.rawValue))
            col.title = spec.title
            col.width = spec.width
            col.minWidth = spec.minW
            col.maxWidth = spec.maxW
            col.sortDescriptorPrototype = NSSortDescriptor(key: spec.id.rawValue, ascending: true)
            if spec.rightAlign {
                col.headerCell.alignment = .right
            }
            tableView.addTableColumn(col)
        }

        let coordinator = context.coordinator
        coordinator.tableView = tableView

        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.registerForDraggedTypes([.fileURL])

        tableView.onBecameActive = { [weak coordinator] in
            coordinator?.markPaneActive()
        }
        tableView.onCopy = { [weak coordinator] in
            coordinator?.markPaneActive()
            coordinator?.appVM.copySelectionToPasteboard()
        }
        tableView.onPaste = { [weak coordinator] in
            coordinator?.markPaneActive()
            coordinator?.appVM.pasteFromPasteboard()
        }
        tableView.onKeyAction = { [weak coordinator] event in
            coordinator?.handleKeyDown(event) ?? false
        }
        tableView.onBuildContextMenu = { [weak coordinator] clickedRow in
            coordinator?.buildContextMenu(clickedRow: clickedRow)
        }

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pane = pane
        coordinator.appVM = appVM
        guard let tableView = coordinator.tableView else { return }

        let newRowIDs = pane.rows.map(\.id)
        let isInsideArc = pane.location.isInsideArchive

        // Show archive-only columns (`Сжатый`, `CRC`, `Метод`) when browsing inside an archive
        for col in tableView.tableColumns {
            let raw = col.identifier.rawValue
            if raw == SortField.packedSize.rawValue || raw == SortField.crc.rawValue || raw == SortField.method.rawValue {
                col.isHidden = !isInsideArc
            }
        }

        // Sync header sort indicator
        for col in tableView.tableColumns {
            if col.identifier.rawValue == pane.sortField.rawValue {
                let indicator = NSImage(
                    systemSymbolName: pane.sortAscending ? "chevron.up" : "chevron.down",
                    accessibilityDescription: nil
                )
                tableView.setIndicatorImage(indicator, in: col)
            } else {
                tableView.setIndicatorImage(nil, in: col)
            }
        }

        if coordinator.renderedRows != pane.rows {
            coordinator.renderedRows = pane.rows
            coordinator.isProgrammaticSelectionSync = true
            tableView.reloadData()
            coordinator.syncTableSelection(to: pane.selectedIDs, scrollToFirst: newRowIDs != coordinator.renderedRowIDs)
            coordinator.renderedRowIDs = newRowIDs
            coordinator.isProgrammaticSelectionSync = false
        } else if coordinator.lastSyncedSelection != pane.selectedIDs {
            coordinator.isProgrammaticSelectionSync = true
            coordinator.syncTableSelection(to: pane.selectedIDs, scrollToFirst: false)
            coordinator.isProgrammaticSelectionSync = false
        }

        if isActivePane && coordinator.wasActivePane != isActivePane {
            if let window = tableView.window, window.firstResponder !== tableView {
                // Avoid stealing focus from active text fields (search bar or modal sheet)
                if !(window.firstResponder is NSTextView) {
                    window.makeFirstResponder(tableView)
                }
            }
        }
        coordinator.wasActivePane = isActivePane
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {
        var pane: PaneViewModel
        var appVM: AppViewModel
        weak var tableView: KeyHandlingTableView?

        var renderedRows: [PaneRowItem] = []
        var renderedRowIDs: [String] = []
        var lastSyncedSelection: Set<String> = []
        var isProgrammaticSelectionSync = false
        var wasActivePane = false

        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.name = "com.sevenzipmac.filepromises"
            q.qualityOfService = .userInitiated
            q.maxConcurrentOperationCount = 2
            return q
        }()

        init(pane: PaneViewModel, appVM: AppViewModel) {
            self.pane = pane
            self.appVM = appVM
        }

        func markPaneActive() {
            if appVM.activeSide != pane.side {
                appVM.activeSide = pane.side
            }
        }

        func syncTableSelection(to targetIDs: Set<String>, scrollToFirst: Bool) {
            guard let tableView else { return }
            var indexSet = IndexSet()
            for (idx, row) in renderedRows.enumerated() where targetIDs.contains(row.id) {
                indexSet.insert(idx)
            }
            if indexSet.isEmpty && !renderedRows.isEmpty && scrollToFirst {
                indexSet.insert(0)
            }
            tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
            if scrollToFirst, let first = indexSet.first {
                tableView.scrollRowToVisible(first)
            }
            lastSyncedSelection = targetIDs
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            renderedRows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard renderedRows.indices.contains(row),
                  let colID = tableColumn?.identifier,
                  let field = SortField(rawValue: colID.rawValue) else { return nil }

            let item = renderedRows[row]

            switch field {
            case .name:
                return makeNameCell(in: tableView, item: item)
            case .size:
                return makeTextCell(
                    in: tableView,
                    id: "SizeCell",
                    text: item.isParentRow || (item.isDirectory && item.size == nil) ? "" : ByteFormatting.string(for: item.size),
                    alignment: .right,
                    monospaced: true,
                    secondary: false
                )
            case .packedSize:
                return makeTextCell(
                    in: tableView,
                    id: "PackedCell",
                    text: item.isParentRow || item.packedSize == nil ? "" : ByteFormatting.string(for: item.packedSize),
                    alignment: .right,
                    monospaced: true,
                    secondary: true
                )
            case .modified:
                return makeTextCell(
                    in: tableView,
                    id: "DateCell",
                    text: item.isParentRow ? "" : ByteFormatting.dateString(item.modifiedDate),
                    alignment: .left,
                    monospaced: true,
                    secondary: true
                )
            case .attributes:
                return makeTextCell(
                    in: tableView,
                    id: "AttrCell",
                    text: item.attributes,
                    alignment: .left,
                    monospaced: true,
                    secondary: true
                )
            case .crc:
                return makeTextCell(
                    in: tableView,
                    id: "CRCCell",
                    text: item.crcHex,
                    alignment: .left,
                    monospaced: true,
                    secondary: true
                )
            case .method:
                return makeTextCell(
                    in: tableView,
                    id: "MethodCell",
                    text: item.method,
                    alignment: .left,
                    monospaced: false,
                    secondary: true
                )
            }
        }

        private func makeNameCell(in tableView: NSTableView, item: PaneRowItem) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier("NameCell")
            let container: NSTableCellView
            let iconView: NSImageView
            let label: NSTextField
            let badgeView: NSImageView

            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView,
               let iv = reused.imageView,
               let tf = reused.textField,
               let bv = reused.subviews.compactMap({ $0 as? NSImageView }).first(where: { $0 !== iv }) {
                container = reused
                iconView = iv
                label = tf
                badgeView = bv
            } else {
                container = NSTableCellView()
                container.identifier = cellID

                iconView = NSImageView()
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.imageScaling = .scaleProportionallyUpOrDown

                label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingMiddle
                label.font = .systemFont(ofSize: 12.5, weight: .regular)

                badgeView = NSImageView()
                badgeView.translatesAutoresizingMaskIntoConstraints = false
                badgeView.imageScaling = .scaleProportionallyDown

                container.addSubview(iconView)
                container.addSubview(label)
                container.addSubview(badgeView)
                container.imageView = iconView
                container.textField = label

                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                    iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: 16),
                    iconView.heightAnchor.constraint(equalToConstant: 16),

                    label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                    badgeView.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
                    badgeView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4),
                    badgeView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    badgeView.widthAnchor.constraint(equalToConstant: 12),
                    badgeView.heightAnchor.constraint(equalToConstant: 12)
                ])
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }

            iconView.image = item.icon
            label.stringValue = item.name
            label.font = .systemFont(
                ofSize: 12.5,
                weight: item.isArchiveFile ? .medium : .regular
            )
            label.textColor = item.isParentRow ? .secondaryLabelColor : .labelColor

            if item.isEncrypted {
                badgeView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Зашифрован")
                badgeView.contentTintColor = .systemOrange
                badgeView.isHidden = false
            } else if item.isSymlink {
                badgeView.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: "Символическая ссылка")
                badgeView.contentTintColor = .secondaryLabelColor
                badgeView.isHidden = false
            } else {
                badgeView.image = nil
                badgeView.isHidden = true
            }

            return container
        }

        private func makeTextCell(
            in tableView: NSTableView,
            id: String,
            text: String,
            alignment: NSTextAlignment,
            monospaced: Bool,
            secondary: Bool
        ) -> NSView {
            let cellID = NSUserInterfaceItemIdentifier(id)
            let container: NSTableCellView
            let label: NSTextField

            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView,
               let tf = reused.textField {
                container = reused
                label = tf
            } else {
                container = NSTableCellView()
                container.identifier = cellID
                label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                container.addSubview(label)
                container.textField = label

                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
            }

            label.stringValue = text
            label.alignment = alignment
            label.font = monospaced
                ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                : .systemFont(ofSize: 12, weight: .regular)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            return container
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticSelectionSync, let tableView else { return }
            markPaneActive()
            let selected = tableView.selectedRowIndexes.compactMap { idx -> String? in
                renderedRows.indices.contains(idx) ? renderedRows[idx].id : nil
            }
            let set = Set(selected)
            lastSyncedSelection = set
            pane.selectedIDs = set
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            markPaneActive()
            if let field = SortField(rawValue: tableColumn.identifier.rawValue) {
                pane.toggleSort(by: field)
            }
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            markPaneActive()
            let clicked = tableView.clickedRow
            guard renderedRows.indices.contains(clicked) else { return }
            appVM.activateRow(renderedRows[clicked], in: pane.side)
        }

        // MARK: - Keyboard Navigation (7zFM + macOS Pro shortcuts)

        func handleKeyDown(_ event: NSEvent) -> Bool {
            markPaneActive()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if flags == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    appVM.copySelectionToPasteboard()
                    return true
                case "v":
                    appVM.pasteFromPasteboard()
                    return true
                default:
                    break
                }
            }

            // Cmd+Up -> Go Up (..)
            if flags == .command && event.keyCode == 126 {
                pane.goUp()
                return true
            }
            // Cmd+Down -> Open / Enter
            if flags == .command && event.keyCode == 125 {
                activatePrimarySelection()
                return true
            }
            // Cmd+Backspace -> Delete
            if flags == .command && event.keyCode == 51 {
                appVM.deleteSelectedItems()
                return true
            }
            // Plain Return / Enter -> Open / Enter
            if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
                activatePrimarySelection()
                return true
            }
            // Plain Backspace -> Go Up (..)
            if flags.isEmpty && event.keyCode == 51 {
                pane.goUp()
                return true
            }
            // Space -> Quick Look
            if flags.isEmpty && event.keyCode == 49 {
                appVM.triggerQuickLook(in: pane.side)
                return true
            }
            // Tab -> Switch active pane in dual-pane mode
            if flags.isEmpty && event.keyCode == 48 && appVM.isDualPane {
                appVM.switchActivePane()
                return true
            }

            // Function keys matching classic 7zFM / Commander muscle memory
            if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
                switch Int(scalar.value) {
                case NSF2FunctionKey:
                    appVM.presentRenameDialog()
                    return true
                case NSF5FunctionKey:
                    appVM.copyOrMoveSelectionAcrossPanes(move: false)
                    return true
                case NSF6FunctionKey:
                    appVM.copyOrMoveSelectionAcrossPanes(move: true)
                    return true
                case NSF7FunctionKey:
                    appVM.presentNewFolderDialog()
                    return true
                case NSF9FunctionKey:
                    appVM.toggleDualPane()
                    return true
                case NSDeleteFunctionKey:
                    appVM.deleteSelectedItems()
                    return true
                default:
                    break
                }
            }

            return false
        }

        private func activatePrimarySelection() {
            guard let tableView else { return }
            let idx = tableView.selectedRow
            guard renderedRows.indices.contains(idx) else { return }
            appVM.activateRow(renderedRows[idx], in: pane.side)
        }

        // MARK: - Context Menu

        func buildContextMenu(clickedRow: Int) -> NSMenu? {
            let menu = NSMenu()

            if renderedRows.indices.contains(clickedRow) {
                let row = renderedRows[clickedRow]
                if row.isParentRow {
                    let upItem = NSMenuItem(title: "На уровень вверх", action: #selector(ctxGoUp), keyEquivalent: "")
                    upItem.target = self
                    menu.addItem(upItem)
                    return menu
                }

                let openItem = NSMenuItem(title: "Открыть", action: #selector(ctxOpen), keyEquivalent: "")
                openItem.target = self
                menu.addItem(openItem)

                if !row.isDirectory {
                    let qlItem = NSMenuItem(title: "Быстрый просмотр (Пробел)", action: #selector(ctxQuickLook), keyEquivalent: "")
                    qlItem.target = self
                    menu.addItem(qlItem)
                }

                menu.addItem(.separator())

                if pane.location.isInsideArchive {
                    let extItem = NSMenuItem(title: "Извлечь выбранное…", action: #selector(ctxExtract), keyEquivalent: "")
                    extItem.target = self
                    menu.addItem(extItem)
                } else {
                    let addItem = NSMenuItem(title: "Добавить в архив…", action: #selector(ctxCompress), keyEquivalent: "")
                    addItem.target = self
                    menu.addItem(addItem)

                    if row.isArchiveFile {
                        let extItem = NSMenuItem(title: "Извлечь архив…", action: #selector(ctxExtract), keyEquivalent: "")
                        extItem.target = self
                        menu.addItem(extItem)
                    }
                }

                if appVM.isDualPane {
                    let copyOther = NSMenuItem(title: "Копировать в соседнюю панель (F5)", action: #selector(ctxCopyAcross), keyEquivalent: "")
                    copyOther.target = self
                    menu.addItem(copyOther)
                }

                let clipboardCopy = NSMenuItem(title: "Копировать (⌘C)", action: #selector(ctxCopy), keyEquivalent: "")
                clipboardCopy.target = self
                menu.addItem(clipboardCopy)

                if !row.isDirectory {
                    let checksum = NSMenuItem(title: "Контрольные суммы…", action: #selector(ctxChecksum), keyEquivalent: "")
                    checksum.target = self
                    menu.addItem(checksum)
                }
                if pane.isShowingFlattenedPaths {
                    let containingFolder = NSMenuItem(title: "Открыть содержащую папку", action: #selector(ctxContainingFolder), keyEquivalent: "")
                    containingFolder.target = self
                    menu.addItem(containingFolder)
                }
                menu.addItem(.separator())

                let renameItem = NSMenuItem(title: "Переименовать (F2)…", action: #selector(ctxRename), keyEquivalent: "")
                renameItem.target = self
                menu.addItem(renameItem)

                let delItem = NSMenuItem(
                    title: pane.location.isInsideArchive ? "Удалить из архива…" : "Переместить в Корзину…",
                    action: #selector(ctxDelete),
                    keyEquivalent: ""
                )
                delItem.target = self
                menu.addItem(delItem)

                if case .disk(let d) = row {
                    menu.addItem(.separator())
                    let reveal = NSMenuItem(title: "Показать в Finder", action: #selector(ctxRevealInFinder(_:)), keyEquivalent: "")
                    reveal.representedObject = d.url
                    reveal.target = self
                    menu.addItem(reveal)
                }
            }

            menu.addItem(.separator())
            let mkdirItem = NSMenuItem(title: "Новая папка (F7)…", action: #selector(ctxNewFolder), keyEquivalent: "")
            mkdirItem.target = self
            menu.addItem(mkdirItem)

            let propsItem = NSMenuItem(title: "Свойства…", action: #selector(ctxProperties), keyEquivalent: "")
            propsItem.target = self
            menu.addItem(propsItem)

            return menu
        }

        @objc private func ctxCopy() { appVM.copySelectionToPasteboard() }
        @objc private func ctxChecksum() { appVM.computeChecksumsForSelection() }
        @objc private func ctxContainingFolder() {
            guard let row = pane.selectedActionableRows.first else { return }
            pane.revealContainingFolder(for: row)
        }
        @objc private func ctxGoUp() { pane.goUp() }
        @objc private func ctxOpen() { activatePrimarySelection() }
        @objc private func ctxQuickLook() { appVM.triggerQuickLook(in: pane.side) }
        @objc private func ctxExtract() { appVM.presentExtractDialog() }
        @objc private func ctxCompress() { appVM.presentAddCompressDialog() }
        @objc private func ctxCopyAcross() { appVM.copyOrMoveSelectionAcrossPanes(move: false) }
        @objc private func ctxRename() { appVM.presentRenameDialog() }
        @objc private func ctxDelete() { appVM.deleteSelectedItems() }
        @objc private func ctxNewFolder() { appVM.presentNewFolderDialog() }
        @objc private func ctxProperties() { appVM.presentProperties() }

        @objc private func ctxRevealInFinder(_ sender: NSMenuItem) {
            if let url = sender.representedObject as? URL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        // MARK: - Drag OUT to Finder (NSURL for Disk, NSFilePromiseProvider for Archive!)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard renderedRows.indices.contains(row) else { return nil }
            let item = renderedRows[row]

            switch item {
            case .parentDirectory:
                return nil
            case .disk(let d):
                return d.url as NSURL
            case .archive(let node):
                guard let arcURL = pane.location.activeArchiveLayer?.archiveFileURL else { return nil }
                let utType: UTType = node.isDirectory
                    ? .folder
                    : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
                let provider = NSFilePromiseProvider(fileType: utType.identifier, delegate: self)
                provider.userInfo = ArchivePromiseContext(
                    archiveURL: arcURL,
                    itemPath: node.path,
                    itemName: node.name,
                    stripPrefix: node.parentFolderPath,
                    password: pane.currentArchivePassword,
                    encoding: pane.archiveEncoding
                )
                return provider
            }
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            guard let ctx = filePromiseProvider.userInfo as? ArchivePromiseContext else {
                return "ExtractedItem"
            }
            return ctx.itemName
        }

        nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            MainActor.assumeIsolated { promiseQueue }
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            guard let ctx = filePromiseProvider.userInfo as? ArchivePromiseContext else {
                completionHandler(nil)
                return
            }

            do {
                let opened = try OpenArchive(url: ctx.archiveURL, password: ctx.password, encoding: ctx.encoding)
                defer { opened.close() }
                let tree = VirtualArchiveTree(entries: opened.entries)
                let indices = tree.extractionIndices(for: [ctx.itemPath])

                let tempSlot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("SevenZipMac-Promise-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempSlot, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempSlot) }

                try opened.extract(
                    indices: indices,
                    to: tempSlot,
                    stripPrefix: ctx.stripPrefix,
                    fullPaths: true,
                    overwrite: .overwriteAll,
                    password: ctx.password
                )

                let extractedCandidate = tempSlot.appendingPathComponent(ctx.itemName)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                if FileManager.default.fileExists(atPath: extractedCandidate.path) {
                    try FileManager.default.moveItem(at: extractedCandidate, to: url)
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        // MARK: - Drop IN from Finder

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            if info.draggingSource as? NSTableView === tableView {
                return []
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let pb = info.draggingPasteboard
            guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else {
                return false
            }
            appVM.handleDroppedURLs(urls, into: pane.side)
            return true
        }
    }
}
