import ApplicationServices
import CoreGraphics
import Foundation

/// Write-side AX operations: press, set value, focus.
///
/// All calls are synchronous IPC to the target process and may fail if:
///   - The element no longer exists (UI changed since the last tree walk)
///   - The action/attribute is not supported on this element
///   - The target app is unresponsive
///
/// Errors are surfaced as AXWriteError so callers can return them to the LLM.
public enum AXWriter {

    public enum AXWriteError: Error, CustomStringConvertible {
        case actionNotSupported(String)
        case actionFailed(String, AXError)
        case setValueFailed(String, AXError)
        case elementStale

        public var description: String {
            switch self {
            case .actionNotSupported(let a):    return "Action '\(a)' is not supported on this element."
            case .actionFailed(let a, let e):   return "Action '\(a)' failed: AXError \(e.rawValue)."
            case .setValueFailed(let attr, let e): return "Set '\(attr)' failed: AXError \(e.rawValue)."
            case .elementStale:                 return "Element is no longer valid (UI may have changed)."
            }
        }
    }

    /// Invoke AXPress on an element (equivalent to clicking it).
    public static func press(_ element: AXUIElement) throws {
        // Verify the action is listed before attempting it
        let actions = AXAttributeReader.actionNames(element)
        guard !actions.isEmpty else {
            // Empty action list is a sign the element is stale
            throw AXWriteError.elementStale
        }
        guard actions.contains(kAXPressAction) else {
            throw AXWriteError.actionNotSupported(kAXPressAction)
        }
        let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard err == .success else {
            throw AXWriteError.actionFailed(kAXPressAction, err)
        }
    }

    /// Set the AXValue attribute of an element (e.g., text field content, slider position).
    public static func setValue(_ element: AXUIElement, value: String) throws {
        let err = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else {
            throw AXWriteError.setValueFailed(kAXValueAttribute, err)
        }
    }

    /// Set a numeric value (for sliders, steppers, etc.)
    public static func setNumericValue(_ element: AXUIElement, value: Double) throws {
        let err = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard err == .success else {
            throw AXWriteError.setValueFailed(kAXValueAttribute, err)
        }
    }

    /// Focus an element by setting AXFocused = true.
    public static func focus(_ element: AXUIElement) throws {
        let err = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        guard err == .success else {
            throw AXWriteError.setValueFailed(kAXFocusedAttribute, err)
        }
    }

    /// Perform any named AX action (e.g., AXShowMenu, AXConfirm, AXDecrement).
    public static func performAction(_ element: AXUIElement, action: String) throws {
        let err = AXUIElementPerformAction(element, action as CFString)
        guard err == .success else {
            throw AXWriteError.actionFailed(action, err)
        }
    }

    /// Inject a keyboard event into a target process by PID.
    ///
    /// - Parameters:
    ///   - pid: Target process ID.
    ///   - key: Key name ("a"-"z", "0"-"9", "return", "tab", "space", "escape",
    ///          "delete", "up", "down", "left", "right", "f1"-"f12") or a single character.
    ///   - modifiers: Modifier names: "cmd", "shift", "ctrl", "alt".
    public static func pressKey(pid: pid_t, key: String, modifiers: [String]) throws {
        guard let keyCode = keyCode(for: key) else {
            throw AXWriteError.actionNotSupported("Unknown key: '\(key)'")
        }

        var flags = CGEventFlags()
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command":  flags.insert(.maskCommand)
            case "shift":           flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            default: break
            }
        }

        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw AXWriteError.actionFailed("pressKey", .failure)
        }
        guard
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else {
            throw AXWriteError.actionFailed("pressKey", .failure)
        }

        if !flags.isEmpty {
            keyDown.flags = flags
            keyUp.flags   = flags
        }

        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    /// Type a string into the target process by injecting unicode keyboard events
    /// for each character. Works regardless of keyboard layout or shift state.
    ///
    /// - Parameters:
    ///   - pid: Target process ID.
    ///   - text: String to type.
    ///   - delayMs: Milliseconds between keystrokes (default 20ms).
    public static func typeText(pid: pid_t, text: String, delayMs: UInt32 = 20) throws {
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            throw AXWriteError.actionFailed("typeText", .failure)
        }
        for char in text {
            var units = Array(String(char).utf16)
            guard
                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else {
                throw AXWriteError.actionFailed("typeText", .failure)
            }
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            if delayMs > 0 {
                usleep(delayMs * 1000)
            }
        }
    }

    // MARK: - Key code table

    private static func keyCode(for key: String) -> CGKeyCode? {
        // Named keys
        switch key.lowercased() {
        case "return", "enter":   return 36
        case "tab":               return 48
        case "space":             return 49
        case "delete", "backspace": return 51
        case "escape", "esc":     return 53
        case "up":                return 126
        case "down":              return 125
        case "left":              return 123
        case "right":             return 124
        case "home":              return 115
        case "end":               return 119
        case "pageup":            return 116
        case "pagedown":          return 121
        case "f1":  return 122; case "f2":  return 120
        case "f3":  return 99;  case "f4":  return 118
        case "f5":  return 96;  case "f6":  return 97
        case "f7":  return 98;  case "f8":  return 100
        case "f9":  return 101; case "f10": return 109
        case "f11": return 103; case "f12": return 111
        default: break
        }

        // Single character — ANSI key map
        let ansi: [Character: CGKeyCode] = [
            "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,
            "z": 6,  "x": 7,  "c": 8,  "v": 9,  "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18,
            "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
            "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
            "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        ]

        if key.count == 1, let ch = key.lowercased().first {
            return ansi[ch]
        }
        return nil
    }
}
