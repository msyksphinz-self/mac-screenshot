import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKeyManager?
    private let captureManager = CaptureManager()
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()

        // ⌘⇧2 : capture a region
        hotKey = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.startCapture()
        }
        if hotKey?.isRegistered != true {
            NSLog("QuickMark: failed to register ⌘⇧2 (already used by another app?)")
        }
    }

    // MARK: - Menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "QuickMark")

        let menu = NSMenu()
        let capture = NSMenuItem(title: "範囲を撮影して編集", action: #selector(captureFromMenu), keyEquivalent: "2")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)

        let clip = NSMenuItem(title: "クリップボードの画像を編集", action: #selector(editClipboard), keyEquivalent: "")
        clip.target = self
        menu.addItem(clip)

        let open = NSMenuItem(title: "画像ファイルを開く…", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "QuickMark を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// The main menu is invisible for an accessory app, but its key equivalents
    /// (⌘Z / ⇧⌘Z / ⌘C / ⌘W ...) still route through the responder chain.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "QuickMark を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(NSMenuItem(title: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: - Actions

    @objc private func captureFromMenu() { startCapture() }

    private func startCapture() {
        captureManager.captureInteractive { [weak self] image in
            self?.openEditor(with: image)
        }
    }

    @objc private func editClipboard() {
        guard let image = ImageLoader.load(pasteboard: .general) else {
            NSSound.beep()
            return
        }
        openEditor(with: image)
    }

    @objc private func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = ImageLoader.load(url: url) else { return }
        openEditor(with: image)
    }

    private func openEditor(with image: LoadedImage) {
        let editor = EditorWindowController(image: image) { [weak self] closed in
            guard let self else { return }
            self.editors.removeAll { $0 === closed }
            // Give focus back to the previous app so ⌘V works right away.
            if self.editors.isEmpty { NSApp.hide(nil) }
        }
        editors.append(editor)
        editor.show()
    }
}
