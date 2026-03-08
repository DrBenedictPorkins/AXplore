import ApplicationServices
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
}
