import AppKit

/// Builds the menu bar in code (no nib). Shortcuts follow VS Code on macOS.
enum MainMenu {
    static func build(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        let W = MainWindowController.self

        // App
        let app = submenu(main, "Keno")
        app.addItem(withTitle: "About Keno", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Keno", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Keno", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "File")
        file.addItem(item("New File", #selector(W.newFile(_:)), "n"))
        file.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Open…", #selector(W.openAnything(_:)), "o"))
        file.addItem(item("Open Folder…", #selector(W.openFolder(_:)), "o", [.command, .shift]))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDelegate
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        file.addItem(item("Save", #selector(W.saveFile(_:)), "s"))
        file.addItem(item("Save As…", #selector(W.saveFileAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Save All", #selector(W.saveAllFiles(_:)), "s", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Close Editor", #selector(W.closeEditorTab(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))

        // Edit
        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        find.addItem(finder("Find…", .showFindInterface, "f"))
        find.addItem(finder("Find and Replace…", .showReplaceInterface, "f", [.command, .option]))
        find.addItem(finder("Find Next", .nextMatch, "g"))
        find.addItem(finder("Find Previous", .previousMatch, "g", [.command, .shift]))
        find.addItem(finder("Use Selection for Find", .setSearchString, "e"))
        edit.addItem(.separator())
        edit.addItem(item("Format Document", #selector(W.formatDocument(_:)), "f", [.shift, .option]))
        edit.addItem(item("Toggle Line Comment", #selector(EditorTextView.toggleComment(_:)), "/"))
        edit.addItem(item("Indent Lines", #selector(EditorTextView.indentLines(_:)), "]"))
        edit.addItem(item("Outdent Lines", #selector(EditorTextView.outdentLines(_:)), "["))

        // View
        let view = submenu(main, "View")
        view.addItem(item("Hide Explorer", #selector(W.toggleExplorer(_:)), "b"))
        view.addItem(item("Toggle Terminal", #selector(W.toggleTerminal(_:)), "`", [.control]))
        view.addItem(hidden(item("Toggle Terminal", #selector(W.toggleTerminal(_:)), "j"))) // VS Code's ⌘J
        view.addItem(item("Move Terminal to Right", #selector(W.toggleTerminalPosition(_:)), ""))
        view.addItem(item("Toggle Word Wrap", #selector(W.toggleWordWrap(_:)), "z", [.option]))
        view.addItem(.separator())
        view.addItem(item("Focus Editor", #selector(W.focusEditor(_:)), "1"))
        view.addItem(item("Focus Explorer", #selector(W.focusExplorer(_:)), "e", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(W.zoomIn(_:)), "="))
        view.addItem(hidden(item("Zoom In", #selector(W.zoomIn(_:)), "+"))) // for layouts with a + key
        view.addItem(item("Zoom Out", #selector(W.zoomOut(_:)), "-"))
        view.addItem(item("Reset Zoom", #selector(W.resetZoom(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Terminal
        let term = submenu(main, "Terminal")
        term.addItem(item("New Terminal", #selector(W.newTerminal(_:)), "`", [.control, .shift]))
        term.addItem(item("Kill Terminal", #selector(W.killTerminal(_:)), ""))
        term.addItem(.separator())
        term.addItem(item("Start Voice Prompt", #selector(W.toggleVoicePrompt(_:)), "r", [.command, .option]))
        term.addItem(item("Cancel Voice Prompt", #selector(W.cancelVoicePrompt(_:)), ""))
        let langs = NSMenu(title: "Voice Language")
        for (title, code) in [("Detect Automatically", "auto"), ("English", "en"), ("German", "de"),
                              ("French", "fr"), ("Spanish", "es"), ("Italian", "it")] {
            let i = item(title, #selector(W.setVoiceLanguage(_:)), "")
            i.representedObject = code
            langs.addItem(i)
        }
        term.addItem(withTitle: "Voice Language", action: nil, keyEquivalent: "").submenu = langs

        // Window
        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        window.addItem(item("Next Tab", #selector(W.nextTab(_:)), right, [.command, .option]))
        window.addItem(item("Previous Tab", #selector(W.previousTab(_:)), left, [.command, .option]))
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let m = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
        return m
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func hidden(_ i: NSMenuItem) -> NSMenuItem {
        i.isHidden = true
        i.allowsKeyEquivalentWhenHidden = true
        return i
    }

    private static func finder(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                               _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = item(title, #selector(NSResponder.performTextFinderAction(_:)), key, mods)
        i.tag = action.rawValue
        return i
    }
}
