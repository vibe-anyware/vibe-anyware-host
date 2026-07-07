import Foundation

/// A key press with optional modifiers, identified by a layout-independent
/// key token from `KeyComboCatalog` (e.g. "a", "5", "f11", "return").
public struct KeyCombo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool

    public init(
        key: String,
        command: Bool = false,
        option: Bool = false,
        control: Bool = false,
        shift: Bool = false
    ) {
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    public var id: String {
        displayTitle
    }

    public var hasModifiers: Bool {
        command || option || control || shift
    }

    /// Compact glyph form, e.g. "⌃⌥⇧⌘T".
    public var displayTitle: String {
        var title = ""
        if control {
            title += "⌃"
        }
        if option {
            title += "⌥"
        }
        if shift {
            title += "⇧"
        }
        if command {
            title += "⌘"
        }
        title += KeyComboCatalog.displayName(for: key)
        return title
    }
}

/// The keys a combo (or the full-keyboard grid) can send, with their macOS
/// ANSI virtual key codes. Tokens are stable wire identifiers.
public enum KeyComboCatalog {
    public static let letterTokens: [String] = "abcdefghijklmnopqrstuvwxyz".map(String.init)
    public static let digitTokens: [String] = (0 ... 9).map(String.init)
    public static let functionTokens: [String] = (1 ... 12).map { "f\($0)" }
    public static let controlTokens: [String] = [
        "return", "delete", "escape", "tab", "space",
        "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
        "home", "end", "pageUp", "pageDown",
        "minus", "equal", "leftBracket", "rightBracket", "backslash",
        "semicolon", "quote", "comma", "period", "slash", "grave"
    ]

    public static var allTokens: [String] {
        letterTokens + digitTokens + functionTokens + controlTokens
    }

    public static func displayName(for token: String) -> String {
        switch token {
        case "return": return "Return"
        case "delete": return "Delete"
        case "escape": return "Esc"
        case "tab": return "Tab"
        case "space": return "Space"
        case "arrowUp": return "↑"
        case "arrowDown": return "↓"
        case "arrowLeft": return "←"
        case "arrowRight": return "→"
        case "home": return "Home"
        case "end": return "End"
        case "pageUp": return "PgUp"
        case "pageDown": return "PgDn"
        case "minus": return "-"
        case "equal": return "="
        case "leftBracket": return "["
        case "rightBracket": return "]"
        case "backslash": return "\\"
        case "semicolon": return ";"
        case "quote": return "'"
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "grave": return "`"
        default:
            if token.hasPrefix("f"), token.count > 1, Int(token.dropFirst()) != nil {
                return token.uppercased()
            }
            return token.uppercased()
        }
    }

    /// macOS ANSI virtual key code for a token; nil for unknown tokens.
    public static func virtualKeyCode(for token: String) -> UInt16? {
        keyCodes[token]
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "return": 36, "delete": 51, "escape": 53, "tab": 48, "space": 49,
        "arrowUp": 126, "arrowDown": 125, "arrowLeft": 123, "arrowRight": 124,
        "home": 115, "end": 119, "pageUp": 116, "pageDown": 121,
        "minus": 27, "equal": 24, "leftBracket": 33, "rightBracket": 30,
        "backslash": 42, "semicolon": 41, "quote": 39, "comma": 43,
        "period": 47, "slash": 44, "grave": 50
    ]
}
