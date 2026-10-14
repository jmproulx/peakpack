import AppKit
import Combine
import PeakModdedCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let options: LaunchOptions
    private var env: AppEnvironment?
    private var model: AppModel?
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        NSApp.mainMenu = MainMenu.build(target: self)
        let env: AppEnvironment
        do { env = try AppEnvironment(options: options) } catch {
            let a = NSAlert()
            a.messageText = "PEAK (Modded) can't start"
            a.informativeText = (error as? FriendError)?.advice ?? "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        self.env = env
        AppLog.shared.configure(directory: env.paths.logs)
        AppLog.shared.info("PEAK (Modded) \(AppInfo.version) (\(AppInfo.build)) starting; macOS \(SystemProbe.macOSVersion); data \(env.paths.dataRoot.path)")
        let model = AppModel(env: env)
        self.model = model
        makeWindow(model: model)
        let note = model.markStarted()
        model.start(showOptions: optionHeld || options.showOptions, autoplay: !options.noAutoplay, afterUpdateNote: note)

        // Tuck the window away while PEAK runs; bring it back when something needs the friend.
        model.$screen.receive(on: RunLoop.main).sink { [weak self] s in self?.screenChanged(s) }.store(in: &cancellables)
        model.$problem.receive(on: RunLoop.main).sink { [weak self] p in if p != nil { self?.showWindow() } }.store(in: &cancellables)
        model.$waiting.receive(on: RunLoop.main).sink { [weak self] w in
            if let w, w != .welcome { self?.showWindow() }
        }.store(in: &cancellables)
    }

    private func makeWindow(model: AppModel) {
        let root = RootView().environmentObject(model)
        let host = NSHostingView(rootView: root)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = AppInfo.displayName
        w.isMovableByWindowBackground = true
        w.contentView = host
        w.center()
        w.setFrameAutosaveName("PEAKModdedMain")
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var lastScreen: AppModel.Screen = .loading

    private func screenChanged(_ s: AppModel.Screen) {
        defer { lastScreen = s }
        // PEAK ended but the app stays (opened for options): bring the window back.
        if lastScreen == .playing && s != .playing && s != .launching { showWindow() }
        hideTask?.cancel()
        if s == .playing {
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self, self.model?.screen == .playing, self.model?.problem == nil else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    func showWindow() {
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dock click while running: show the window (options), and don't quit when the game ends.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showHome()
        showWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window while PEAK runs just hides it; otherwise closing quits (one-window app).
        if let m = model, m.screen == .playing || m.screen == .launching && m.isBusy {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let m = model else { return true }
        return !(m.screen == .playing || m.isBusy)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = model, m.isBusy, m.screen != .playing, m.screen != .message else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Setup is still working"
        a.informativeText = "If you quit now, PEAK (Modded) continues where it stopped next time you open it."
        a.addButton(withTitle: "Keep Working")
        a.addButton(withTitle: "Quit")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Dock menu (right-click / Option-click the Dock icon)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        m.addItem(item("Play with Mods", #selector(playModded)))
        m.addItem(item("Play Normal PEAK", #selector(playNormal)))
        let fps = item("Show FPS", #selector(toggleFPS))
        fps.state = model?.showFPS == true ? .on : .off
        m.addItem(fps)
        m.addItem(.separator())
        m.addItem(item("Show Logs", #selector(openLogs)))
        m.addItem(item("Repair…", #selector(repair)))
        m.addItem(item("Uninstall…", #selector(uninstall)))
        return m
    }

    private func item(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    // MARK: actions (menus)

    @objc func playModded() { model?.quitWhenGameEnds = false; model?.play() }
    @objc func playNormal() { model?.quitWhenGameEnds = false; model?.play(vanilla: true) }
    @objc func toggleFPS() { model?.toggleFPS() }
    @objc func openLogs() { model?.openLogs() }
    @objc func copyDiagnostics() { model?.copyDiagnostics() }
    @objc func checkForUpdates() { showWindow(); model?.showHome(); model?.checkForAppUpdate(userInitiated: true) }
    @objc func repair() {
        showWindow()
        let a = NSAlert()
        a.messageText = "Repair PEAK (Modded)?"
        a.informativeText = "This checks the game engine, PEAK's Windows settings, PEAK's files and the mods, and fixes what's broken. Your settings and saves are kept."
        a.addButton(withTitle: "Repair")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { model?.repair() }
    }
    @objc func uninstall() {
        showWindow()
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Uninstall PEAK (Modded)?"
        a.informativeText = "This moves the app, its game engine, PEAK's Windows files (about 2 GB) and the mods to the Trash. Steam and your Steam library are not touched."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { model?.uninstall() }
    }
    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: """
        Plays PEAK with \(env?.kit.hostName ?? "Joshua")'s mods on a Mac, using your own Steam account and copy of PEAK.

        Built on Wine (LGPL), DXMT, DXVK and MoltenVK, BepInEx, and PeakPack. Licences and source links are in the app's Resources/LICENSES folder.

        Not made by or affiliated with Landfall, Aggro Crab, Valve or Apple.
        """, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.displayName,
            .applicationVersion: AppInfo.version,
            .version: AppInfo.build,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showHelp() {
        if let u = URL(string: "https://github.com/jmproulx/peakpack/tree/master/mac/app#for-friends") { NSWorkspace.shared.open(u) }
    }
    @objc func showMainWindow() { model?.showHome(); showWindow() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleFPS) { menuItem.state = model?.showFPS == true ? .on : .off }
        let busy = model?.isBusy ?? true
        switch menuItem.action {
        case #selector(playModded), #selector(playNormal), #selector(repair), #selector(uninstall):
            return !busy && (env?.state.setupComplete ?? false) || menuItem.action == #selector(uninstall) && !busy
        default: return true
        }
    }
}

@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        // Items with target nil go up the responder chain (standard AppKit actions); ours target the delegate.
        func item(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags, _ t: AnyObject?) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = t
            menu.addItem(i)
        }
        func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) {
            item(menu, title, sel, key, mods, target)
        }
        func sys(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) {
            item(menu, title, sel, key, mods, nil)
        }
        let name = AppInfo.displayName

        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(title: name); appItem.submenu = app
        add(app, "About \(name)", #selector(AppDelegate.showAbout))
        add(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates))
        app.addItem(.separator())
        sys(app, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
        sys(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        sys(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
        app.addItem(.separator())
        sys(app, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        sys(edit, "Copy", #selector(NSText.copy(_:)), "c")
        sys(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let gameItem = NSMenuItem(); main.addItem(gameItem)
        let game = NSMenu(title: "PEAK"); gameItem.submenu = game
        add(game, "Play with Mods", #selector(AppDelegate.playModded), "p")
        add(game, "Play Normal PEAK", #selector(AppDelegate.playNormal), "p", [.command, .option])
        add(game, "Show FPS", #selector(AppDelegate.toggleFPS), "f", [.command, .option])
        game.addItem(.separator())
        add(game, "Show Logs", #selector(AppDelegate.openLogs), "l", [.command, .option])
        add(game, "Copy Diagnostics", #selector(AppDelegate.copyDiagnostics))
        add(game, "Repair…", #selector(AppDelegate.repair))
        game.addItem(.separator())
        add(game, "Uninstall…", #selector(AppDelegate.uninstall))

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window"); winItem.submenu = win
        sys(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(win, name, #selector(AppDelegate.showMainWindow), "0")
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let help = NSMenu(title: "Help"); helpItem.submenu = help
        add(help, "\(name) Help", #selector(AppDelegate.showHelp), "?")
        NSApp.helpMenu = help
        return main
    }
}
