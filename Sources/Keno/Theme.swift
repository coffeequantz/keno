import AppKit

enum Theme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let editorBackground = dynamic(light: .white, dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1))
    static let editorForeground = dynamic(light: NSColor(white: 0.1, alpha: 1), dark: NSColor(white: 0.83, alpha: 1))
    static let chromeBackground = dynamic(light: NSColor(white: 0.953, alpha: 1), dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.149, alpha: 1))
    static let sidebarBackground = dynamic(light: NSColor(white: 0.953, alpha: 1), dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.149, alpha: 1))
    static let hoverBackground = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
    static let separator = dynamic(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 0, alpha: 0.45))
    static let gutterForeground = dynamic(light: NSColor(white: 0.55, alpha: 1), dark: NSColor(white: 0.45, alpha: 1))
    static let currentLineBackground = dynamic(light: NSColor(white: 0, alpha: 0.04), dark: NSColor(white: 1, alpha: 0.04))

    // MARK: Font size (shared by editor and terminal, persisted)

    static let fontSizeDidChange = Notification.Name("KenoFontSizeDidChange")
    static let defaultFontSize: CGFloat = 13

    static var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "fontSize")
            return v > 0 ? CGFloat(v) : defaultFontSize
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 8), 32)), forKey: "fontSize")
            NotificationCenter.default.post(name: fontSizeDidChange, object: nil)
        }
    }

    static var editorFont: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    static var terminalFont: NSFont { .monospacedSystemFont(ofSize: max(fontSize - 1, 8), weight: .regular) }

    /// Resolves a dynamic color for a specific appearance (needed for CGColor-based consumers).
    static func resolve(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }
}
