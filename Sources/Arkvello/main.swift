import AppKit
import ArchiveCore
import Carbon
import SwiftUI

@MainActor
final class ArkvelloAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appVM = AppViewModel()
    private var mainWindow: NSWindow?
    private lazy var finderServicesHandler = FinderServicesHandler(appVM: appVM)
    private var serviceOnlyLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        serviceOnlyLaunch = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsServiceItem))?.booleanValue == true
        NSApp.servicesProvider = finderServicesHandler
        appVM.onFinderServiceRequested = { [weak self] in self?.showServiceWindowIfNeeded() }
        appVM.onFinderServiceFinished = { [weak self] in
            guard let self, self.appVM.isFinderOperationWindow else { return }
            self.mainWindow?.close()
        }
    }

    private func showServiceWindowIfNeeded() {
        guard mainWindow == nil else { return }
        appVM.isFinderOperationWindow = true
        createWindow(operationOnly: true)
    }

    private func showBrowser() {
        serviceOnlyLaunch = false
        appVM.isFinderOperationWindow = false
        if let window = mainWindow {
            // Keep the same sheet host: a pending overwrite reply must not end up
            // attached to a hidden, abandoned operation window.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.subtitle = SevenZipEngine.version
            window.toolbarStyle = .unifiedCompact
            window.minSize = NSSize(width: 720, height: 440)
            window.setContentSize(NSSize(width: 1060, height: 660))
            window.makeKeyAndOrderFront(nil)
        } else {
            createWindow(operationOnly: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if appVM.isFinderOperationWindow || mainWindow == nil { showBrowser() }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if appVM.operations.isRunning {
            appVM.cancelRunningOperation()
            return false
        }
        return sender.attachedSheet == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = finderServicesHandler
        NSUpdateDynamicServices()
        // AppKit also identifies non-default launches when no launch Apple event was
        // available yet in applicationWillFinishLaunching. File-open events create
        // their browser explicitly in application(_:open:).
        let defaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        if !serviceOnlyLaunch && defaultLaunch != false && mainWindow == nil {
            createWindow(operationOnly: false)
        }

        // Check CLI file argument (e.g. `Arkvello /path/to/archive.7z`)
        let cliPaths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let firstPath = cliPaths.first {
            let url = URL(fileURLWithPath: firstPath)
            if FileManager.default.fileExists(atPath: url.path) {
                if mainWindow == nil { showBrowser() }
                appVM.openExternalURLs([url])
            }
        }
    }

    private func createWindow(operationOnly: Bool) {
        let contentView = MainWindowView(appVM: appVM)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: operationOnly ? 520 : 1060, height: operationOnly ? 210 : 660),
            styleMask: operationOnly ? [.titled, .closable] : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Arkvello"
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !operationOnly {
            window.subtitle = SevenZipEngine.version
            window.toolbarStyle = .unifiedCompact
            window.minSize = NSSize(width: 720, height: 440)
        }
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window

        NSApp.activate(ignoringOtherApps: true)

    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appVM.refreshModifiedEditSessions()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if mainWindow == nil || appVM.isFinderOperationWindow { showBrowser() }
        appVM.openExternalURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appVM.persistSessionState()
    }

    @objc func menuNewTab(_ sender: Any?) { appVM.openNewTabInActivePane() }
    @objc func menuCloseTabOrWindow(_ sender: Any?) {
        // Sheets own their cancellation so pending callbacks always receive a response.
        guard mainWindow?.attachedSheet == nil else { return }
        if appVM.isFinderOperationWindow {
            mainWindow?.performClose(sender)
            return
        }
        guard NSApp.keyWindow === mainWindow else {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        if !appVM.closeActiveTabOrAllowWindowClose() {
            mainWindow?.performClose(sender)
        }
    }
    @objc func menuSettings(_ sender: Any?) {
        guard !appVM.operations.isRunning else { NSSound.beep(); return }
        appVM.showSettingsSheet = true
    }
    @objc func menuChecksums(_ sender: Any?) { appVM.computeChecksumsForSelection() }
    @objc func menuFind(_ sender: Any?) { appVM.activePane.focusSearch(enableDeepSearch: true) }

    @objc func menuOpen(_ sender: Any?) { appVM.promptOpenArchiveDialog() }
    @objc func menuCompress(_ sender: Any?) { appVM.presentAddCompressDialog() }
    @objc func menuExtract(_ sender: Any?) { appVM.presentExtractDialog() }
    @objc func menuTestArchive(_ sender: Any?) { appVM.testCurrentArchive() }
    @objc func menuProperties(_ sender: Any?) { appVM.presentProperties() }
    @objc func menuToggleDualPane(_ sender: Any?) { appVM.toggleDualPane() }
    @objc func menuNewFolder(_ sender: Any?) { appVM.presentNewFolderDialog() }
    @objc func menuRename(_ sender: Any?) { appVM.presentRenameDialog() }

    @objc func menuAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Arkvello"
        alert.informativeText = """
        Версия: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
        Независимый архиватор с собственным интерфейсом для macOS.
        Arkvello не является официальной версией 7-Zip, не связан с его авторами и не одобрен ими.

        Код приложения: MIT, Copyright © 2026 IzusX.
        Движок: \(SevenZipEngine.version) (встроенная библиотека libsevenzip.dylib)

        7-Zip Copyright © 1999–2026 Igor Pavlov.
        Основной код движка распространяется на условиях GNU LGPL v2.1+, компоненты декодирования LZFSE/ZSTD — BSD 3-Clause, XXH64 — BSD 2-Clause.
        Код распаковки RAR используется с ограничением лицензии unRAR (Alexander Roshal): запрещено использование для воссоздания проприетарного алгоритма сжатия RAR.
        """
        alert.addButton(withTitle: "ОК")
        alert.addButton(withTitle: "Лицензии…")
        alert.addButton(withTitle: "Сайт проекта")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let resources = Bundle.main.resourceURL {
                NSWorkspace.shared.open(resources.appendingPathComponent("Licenses", isDirectory: true))
            }
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://github.com/IzusX/arkvello") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}

@MainActor
private func buildMainMenu(delegate: ArkvelloAppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    // App menu
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu

    let aboutItem = NSMenuItem(title: "О программе Arkvello", action: #selector(ArkvelloAppDelegate.menuAbout(_:)), keyEquivalent: "")
    aboutItem.target = delegate
    appMenu.addItem(aboutItem)
    appMenu.addItem(.separator())
    let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(ArkvelloAppDelegate.menuSettings(_:)), keyEquivalent: ",")
    settingsItem.target = delegate
    appMenu.addItem(settingsItem)
    appMenu.addItem(.separator())
    let servicesItem = NSMenuItem(title: "Службы", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Службы")
    servicesItem.submenu = servicesMenu
    appMenu.addItem(servicesItem)
    NSApp.servicesMenu = servicesMenu
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Скрыть Arkvello", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Завершить Arkvello", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    // File menu
    let fileMenuItem = NSMenuItem()
    mainMenu.addItem(fileMenuItem)
    let fileMenu = NSMenu(title: "Файл")
    fileMenuItem.submenu = fileMenu

    let openItem = NSMenuItem(title: "Открыть архив или папку…", action: #selector(ArkvelloAppDelegate.menuOpen(_:)), keyEquivalent: "o")
    openItem.target = delegate
    fileMenu.addItem(openItem)

    let addItem = NSMenuItem(title: "Добавить к архиву…", action: #selector(ArkvelloAppDelegate.menuCompress(_:)), keyEquivalent: "n")
    addItem.target = delegate
    fileMenu.addItem(addItem)

    let extractItem = NSMenuItem(title: "Извлечь…", action: #selector(ArkvelloAppDelegate.menuExtract(_:)), keyEquivalent: "e")
    extractItem.target = delegate
    fileMenu.addItem(extractItem)

    let tabItem = NSMenuItem(title: "Новая вкладка", action: #selector(ArkvelloAppDelegate.menuNewTab(_:)), keyEquivalent: "t")
    tabItem.target = delegate
    fileMenu.addItem(tabItem)

    let testItem = NSMenuItem(title: "Проверить целостность", action: #selector(ArkvelloAppDelegate.menuTestArchive(_:)), keyEquivalent: "t")
    testItem.keyEquivalentModifierMask = [.command, .shift]
    testItem.target = delegate
    fileMenu.addItem(testItem)

    fileMenu.addItem(.separator())

    let mkdirItem = NSMenuItem(title: "Новая папка…", action: #selector(ArkvelloAppDelegate.menuNewFolder(_:)), keyEquivalent: "N")
    mkdirItem.target = delegate
    fileMenu.addItem(mkdirItem)

    let renameItem = NSMenuItem(title: "Переименовать…", action: #selector(ArkvelloAppDelegate.menuRename(_:)), keyEquivalent: "r")
    renameItem.target = delegate
    fileMenu.addItem(renameItem)

    let propsItem = NSMenuItem(title: "Свойства", action: #selector(ArkvelloAppDelegate.menuProperties(_:)), keyEquivalent: "i")
    propsItem.target = delegate
    fileMenu.addItem(propsItem)

    let checksumItem = NSMenuItem(title: "Контрольные суммы…", action: #selector(ArkvelloAppDelegate.menuChecksums(_:)), keyEquivalent: "")
    checksumItem.target = delegate
    fileMenu.addItem(checksumItem)

    fileMenu.addItem(.separator())
    let closeItem = NSMenuItem(title: "Закрыть вкладку или окно", action: #selector(ArkvelloAppDelegate.menuCloseTabOrWindow(_:)), keyEquivalent: "w")
    closeItem.target = delegate
    fileMenu.addItem(closeItem)

    // Edit menu (needed so Cmd+C / Cmd+V / Cmd+A work inside text fields & sheets!)
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Правка")
    editMenuItem.submenu = editMenu
    editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSStandardKeyBindingResponding.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    let findItem = NSMenuItem(title: "Поиск…", action: #selector(ArkvelloAppDelegate.menuFind(_:)), keyEquivalent: "f")
    findItem.target = delegate
    editMenu.addItem(findItem)

    // View menu
    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "Вид")
    viewMenuItem.submenu = viewMenu

    let dualItem = NSMenuItem(title: "Двухпанельный режим (F9)", action: #selector(ArkvelloAppDelegate.menuToggleDualPane(_:)), keyEquivalent: "2")
    dualItem.target = delegate
    viewMenu.addItem(dualItem)

    // Window menu
    let winMenuItem = NSMenuItem()
    mainMenu.addItem(winMenuItem)
    let winMenu = NSMenu(title: "Окно")
    winMenuItem.submenu = winMenu
    winMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    winMenu.addItem(withTitle: "Изменить масштаб", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

    return mainMenu
}

@main
enum ArkvelloLauncher {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = ArkvelloAppDelegate()
            app.delegate = delegate
            app.mainMenu = buildMainMenu(delegate: delegate)
            app.run()
        }
    }
}
