import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let documents = MarkdownDocumentController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        documents.autosavingDelay = 3
        buildMenus()
        if documents.documents.isEmpty { documents.newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.newDocument(nil) }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            documents.openDocument(withContentsOf: URL(fileURLWithPath: filename), display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func buildMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        func menu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            bar.addItem(item)
            let menu = NSMenu(title: name)
            item.submenu = menu
            return menu
        }
        let app = menu("清墨")
        add(app, "关于清墨", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "隐藏清墨", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp)
        add(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "退出清墨", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        let file = menu("文件")
        add(file, "新建窗口", #selector(NSDocumentController.newDocument(_:)), key: "n", target: documents)
        add(file, "在新窗口打开…", #selector(NSDocumentController.openDocument(_:)), key: "o", target: documents)
        let recentItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "最近打开")
        recent.delegate = self
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        add(file, "保存", #selector(NSDocument.save(_:)), key: "s")
        add(file, "另存为…", #selector(NSDocument.saveAs(_:)), key: "s", modifiers: [.command, .shift])
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), key: "w")

        let edit = menu("编辑")
        add(edit, "撤销", Selector(("undo:")), key: "z")
        add(edit, "重做", Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), key: "x")
        add(edit, "复制", #selector(NSText.copy(_:)), key: "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), key: "v")
        add(edit, "全选", #selector(NSText.selectAll(_:)), key: "a")
        edit.addItem(.separator())
        let find = add(edit, "查找…", #selector(NSTextView.performFindPanelAction(_:)), key: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let replace = add(edit, "查找与替换…", #selector(NSTextView.performFindPanelAction(_:)), key: "f", modifiers: [.command, .option])
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue

        let format = menu("格式")
        add(format, "粗体", #selector(EditorWindowController.bold(_:)), key: "b")
        add(format, "斜体", #selector(EditorWindowController.italic(_:)), key: "i")
        add(format, "行内代码", #selector(EditorWindowController.inlineCode(_:)), key: "e")
        add(format, "链接", #selector(EditorWindowController.insertLink(_:)), key: "k")

        add(format, "插入图片…", #selector(EditorWindowController.insertImage(_:)), key: "i", modifiers: [.command, .shift])

        let view = menu("显示")
        add(view, "显示 / 隐藏大纲", #selector(EditorWindowController.toggleOutline(_:)), key: "\\", modifiers: [.command])
        view.addItem(.separator())
        add(view, "放大文字", #selector(EditorWindowController.increaseFont(_:)), key: "=")
        add(view, "缩小文字", #selector(EditorWindowController.decreaseFont(_:)), key: "-")
        add(view, "恢复文字大小", #selector(EditorWindowController.resetFont(_:)), key: "0")
        view.addItem(.separator())
        add(view, "进入 / 退出全屏", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.control, .command])

        let window = menu("窗口")
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(window, "缩放", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "全部置于前端", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window

        let help = menu("帮助")
        add(help, "清墨使用指南", #selector(openGuide), target: self)
        NSApp.helpMenu = help
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in documents.recentDocumentURLs {
            let item = add(menu, url.lastPathComponent, #selector(openRecent(_:)), target: self)
            item.representedObject = url
            item.toolTip = url.path
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "还没有最近打开的文件", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "清除最近记录", #selector(NSDocumentController.clearRecentDocuments(_:)), target: documents)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        documents.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    @objc private func openGuide(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "使用指南", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        do {
            let document = try documents.openUntitledDocumentAndDisplay(true) as! MarkdownDocument
            document.source = text
            document.displayName = "清墨使用指南（副本）"
            for case let controller as EditorWindowController in document.windowControllers {
                controller.loadSource()
            }
        } catch { NSApp.presentError(error) }
    }
}
