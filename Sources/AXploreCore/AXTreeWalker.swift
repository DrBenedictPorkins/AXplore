import ApplicationServices
import Foundation

/// Walks an AX element tree recursively, building AXElementSnapshot nodes.
///
/// Safety mechanisms:
///   - Hard depth cap (maxDepth)
///   - Hard node count cap (maxNodes) across the entire walk
///   - Notes added to each node for downstream analysis
///
/// When `captureElements = true`, the walker also maintains `elementTable` — a map
/// from node ID to live AXUIElement. This is used by the MCP server to execute
/// write operations on elements found during a tree scan.
public final class AXTreeWalker {

    public let maxDepth: Int
    public let maxNodes: Int

    /// When true, every visited AXUIElement is stored in `elementTable` keyed by node ID.
    public var captureElements: Bool = false

    /// Populated after a walk when `captureElements = true`.
    /// Maps snapshot ID → raw AXUIElement (for use with AXWriter).
    public private(set) var elementTable: [Int: AXUIElement] = [:]

    private var nodeCounter = 0   // auto-increment ID assigned to each node
    private var nodeCount   = 0   // running total; walk stops when >= maxNodes

    public init(maxDepth: Int, maxNodes: Int) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }

    // MARK: - Entry Points

    /// Walk all windows (or the app element itself if no windows are exposed).
    public func walkAppRoots(_ appElement: AXUIElement) -> [AXElementSnapshot] {
        reset()
        let windows = AXAttributeReader.elements(appElement, kAXWindowsAttribute)
        if windows.isEmpty {
            return snapshot(appElement, depth: 0).map { [$0] } ?? []
        }
        return windows.compactMap { snapshot($0, depth: 0) }
    }

    /// Walk only the currently focused window.
    public func walkFocusedWindow(_ appElement: AXUIElement) -> [AXElementSnapshot] {
        reset()
        if let win = AXAttributeReader.element(appElement, kAXFocusedWindowAttribute) {
            return snapshot(win, depth: 0).map { [$0] } ?? []
        }
        let windows = AXAttributeReader.elements(appElement, kAXWindowsAttribute)
        if let first = windows.first {
            return snapshot(first, depth: 0).map { [$0] } ?? []
        }
        return []
    }

    /// Walk from the currently focused UI element.
    public func walkFocusedElement(_ appElement: AXUIElement) -> [AXElementSnapshot] {
        reset()
        if let focused = AXAttributeReader.element(appElement, kAXFocusedUIElementAttribute) {
            return snapshot(focused, depth: 0).map { [$0] } ?? []
        }
        return walkFocusedWindow(appElement)
    }

    // MARK: - Private

    private func reset() {
        nodeCounter  = 0
        nodeCount    = 0
        elementTable = [:]
    }

    private func snapshot(_ element: AXUIElement, depth: Int) -> AXElementSnapshot? {
        guard depth <= maxDepth, nodeCount < maxNodes else { return nil }

        let myID = nodeCounter
        nodeCounter += 1
        nodeCount   += 1

        // Optionally store the live element reference for later write operations
        if captureElements {
            elementTable[myID] = element
        }

        let attrNames   = AXAttributeReader.attributeNames(element)
        let actionNames = AXAttributeReader.actionNames(element)

        let role        = AXAttributeReader.string(element, kAXRoleAttribute)
        let subrole     = AXAttributeReader.string(element, kAXSubroleAttribute)
        let title       = AXAttributeReader.string(element, kAXTitleAttribute)
        let desc        = AXAttributeReader.string(element, kAXDescriptionAttribute)
        let help        = AXAttributeReader.string(element, kAXHelpAttribute)
        let identifier  = AXAttributeReader.string(element, "AXIdentifier")
        let placeholder = AXAttributeReader.string(element, "AXPlaceholderValue")

        let enabled  = AXAttributeReader.bool(element, kAXEnabledAttribute)
        let focused  = AXAttributeReader.bool(element, kAXFocusedAttribute)
        let selected = AXAttributeReader.bool(element, kAXSelectedAttribute)

        let position = AXAttributeReader.point(element, kAXPositionAttribute)
        let sz       = AXAttributeReader.size(element, kAXSizeAttribute)
        let valueStr = AXAttributeReader.valueString(element, kAXValueAttribute)

        let childElements = AXAttributeReader.children(element)
        let childCount    = childElements.count

        var notes: [String] = []
        if role == kAXGroupRole, title == nil, desc == nil {
            notes.append("unlabeled-group")
        }
        if let s = sz, s.width > 400, s.height > 150, title == nil, desc == nil {
            notes.append("large-unnamed-container")
        }
        if !actionNames.isEmpty {
            notes.append("actions:\(actionNames.joined(separator: ","))")
        }
        if role == nil || role == "AXUnknown" {
            notes.append("no-role")
        }

        var childSnapshots: [AXElementSnapshot] = []
        if depth < maxDepth {
            for child in childElements {
                guard nodeCount < maxNodes else { break }
                if let snap = snapshot(child, depth: depth + 1) {
                    childSnapshots.append(snap)
                }
            }
        }

        return AXElementSnapshot(
            id:                 myID,
            depth:              depth,
            role:               role,
            subrole:            subrole,
            title:              title,
            elementDescription: desc,
            help:               help,
            value:              valueStr,
            placeholderValue:   placeholder,
            identifier:         identifier,
            enabled:            enabled,
            focused:            focused,
            selected:           selected,
            position:           position.map { PointSnap($0) },
            size:               sz.map       { SizeSnap($0)  },
            actions:            actionNames,
            attributeNames:     attrNames,
            childCount:         childCount,
            children:           childSnapshots,
            notes:              notes,
            axErrors:           [:]
        )
    }
}
