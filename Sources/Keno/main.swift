import AppKit

// Keno has its own local dictation (Edit ▸ Start Dictation, ⌥⌘R); hide the system's menu item
// so there aren't two. The system shortcut (Fn Fn) keeps working.
UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
