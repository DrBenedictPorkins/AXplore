import ApplicationServices
import AppKit

public enum FocusedContextReader {
    /// Capture what is currently focused: the app, its focused window, and focused UI element.
    public static func read(appElement: AXUIElement) -> FocusedContext {
        let focusedAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        let windowTitle = AXAttributeReader.element(appElement, kAXFocusedWindowAttribute)
            .flatMap { AXAttributeReader.string($0, kAXTitleAttribute) }

        var focusedRole: String?
        var focusedTitle: String?
        var focusedDesc: String?

        if let focused = AXAttributeReader.element(appElement, kAXFocusedUIElementAttribute) {
            focusedRole  = AXAttributeReader.string(focused, kAXRoleAttribute)
            focusedTitle = AXAttributeReader.string(focused, kAXTitleAttribute)
            focusedDesc  = AXAttributeReader.string(focused, kAXDescriptionAttribute)
        }

        return FocusedContext(
            focusedAppName:           focusedAppName,
            focusedWindowTitle:       windowTitle,
            focusedElementRole:       focusedRole,
            focusedElementTitle:      focusedTitle,
            focusedElementDescription: focusedDesc
        )
    }
}
