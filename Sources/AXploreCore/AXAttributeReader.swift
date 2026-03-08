import ApplicationServices
import CoreGraphics
import Foundation

/// Safe, non-crashing wrappers around the macOS Accessibility API.
///
/// Every function returns an Optional and swallows AXErrors such as:
///   .attributeUnsupported  — element doesn't have this attribute
///   .noValue               — attribute exists but is currently nil
///   .apiDisabled           — process-level AX is off
///   .cannotComplete        — transient failure (e.g. app is busy)
///
/// We never invoke actions here — this file is strictly read-only.
public enum AXAttributeReader {

    // MARK: - Basic types

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return ref as? String
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        // AX booleans come back as CFBoolean
        if CFGetTypeID(ref) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((ref as! CFBoolean))
        }
        return ref as? Bool
    }

    // MARK: - AXValue geometry types (CGPoint / CGSize / CGRect)

    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let axVal = axValue(element, attribute) else { return nil }
        guard AXValueGetType(axVal) == .cgPoint else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(axVal, .cgPoint, &pt)
        return pt
    }

    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let axVal = axValue(element, attribute) else { return nil }
        guard AXValueGetType(axVal) == .cgSize else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(axVal, .cgSize, &sz)
        return sz
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        guard CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        // Safe forced cast: we've verified the CF type ID above
        return (ref as! AXValue)
    }

    // MARK: - Element arrays (children, windows, etc.)

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        return elements(element, kAXChildrenAttribute)
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return [] }

        // Swift's CF bridging usually handles [AXUIElement] directly
        if let arr = ref as? [AXUIElement] { return arr }

        // Fallback: manually walk the CFArray
        guard CFGetTypeID(ref) == CFArrayGetTypeID() else { return [] }
        let cfArr = ref as! CFArray
        let count = CFArrayGetCount(cfArr)
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let elem = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            result.append(elem)
        }
        return result
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    // MARK: - Attribute / action name lists

    public static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
              let names = names as? [String] else { return [] }
        return names
    }

    public static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else { return [] }
        return names
    }

    // MARK: - Value stringifier

    /// Returns a human-readable string for any AX attribute value, or nil if unreadable.
    public static func valueString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }

        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }

        let typeID = CFGetTypeID(ref)

        if typeID == AXValueGetTypeID() {
            let axVal = ref as! AXValue
            switch AXValueGetType(axVal) {
            case .cgPoint:
                var pt = CGPoint.zero
                AXValueGetValue(axVal, .cgPoint, &pt)
                return "(\(Int(pt.x)), \(Int(pt.y)))"
            case .cgSize:
                var sz = CGSize.zero
                AXValueGetValue(axVal, .cgSize, &sz)
                return "\(Int(sz.width))x\(Int(sz.height))"
            case .cgRect:
                var rect = CGRect.zero
                AXValueGetValue(axVal, .cgRect, &rect)
                return "(\(Int(rect.origin.x)),\(Int(rect.origin.y))) \(Int(rect.size.width))x\(Int(rect.size.height))"
            default:
                return nil
            }
        }

        if typeID == CFBooleanGetTypeID() {
            // Safe: type ID verified above
            let b = unsafeDowncast(ref, to: CFBoolean.self)
            return CFBooleanGetValue(b) ? "true" : "false"
        }

        if typeID == CFArrayGetTypeID() {
            let cfArr = unsafeDowncast(ref, to: CFArray.self)
            return "[array:\(CFArrayGetCount(cfArr))]"
        }

        // Unknown CF type — skip rather than crash
        return nil
    }
}
