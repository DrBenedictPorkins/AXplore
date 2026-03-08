import Foundation

public enum TextTreeRenderer {

    public static func export(
        roots: [AXElementSnapshot],
        analysis: AXAnalysis,
        focusedContext: FocusedContext?,
        to dir: String
    ) throws {
        var lines: [String] = []

        lines.append("AXplore Tree Dump")
        lines.append("=================")
        lines.append("")

        // Focused context header
        if let fc = focusedContext {
            lines.append("Focused context:")
            lines.append("  App     : \(fc.focusedAppName ?? "?")")
            lines.append("  Window  : \(fc.focusedWindowTitle ?? "?")")
            if let role = fc.focusedElementRole {
                let label = fc.focusedElementTitle ?? fc.focusedElementDescription ?? "(no label)"
                lines.append("  Element : [\(role)] \(label)")
            }
            lines.append("")
        }

        // Tree
        lines.append("Element tree:")
        for root in roots {
            renderNode(root, indent: 0, lines: &lines)
        }

        // Summary
        lines.append("")
        lines.append("Summary:")
        lines.append("  Total nodes : \(analysis.totalNodes)")
        lines.append("  Windows     : \(analysis.windowCount)")
        lines.append("  With labels : \(analysis.elementsWithLabels)")
        lines.append("  With actions: \(analysis.elementsWithActions)")

        lines.append("")
        lines.append("Feasibility:")
        for fn in analysis.feasibilityNotes {
            let marker: String
            switch fn.verdict {
            case "accessible":        marker = "[YES   ]"
            case "likely-accessible": marker = "[LIKELY]"
            case "opaque":            marker = "[OPAQUE]"
            default:                  marker = "[?     ]"
            }
            lines.append("  \(marker) \(fn.area): \(fn.observation)")
        }

        let text = lines.joined(separator: "\n")
        let path = (dir as NSString).appendingPathComponent("tree.txt")
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("[export] Tree  -> \(path)")
    }

    // MARK: - Private

    private static func renderNode(_ node: AXElementSnapshot, indent: Int, lines: inout [String]) {
        let prefix = String(repeating: "  ", count: indent)
        var parts: [String] = []

        // Role + subrole
        var roleStr = node.role ?? "?"
        if let sr = node.subrole { roleStr += "(\(sr))" }
        parts.append("[\(roleStr)]")

        // Label: prefer title, then description
        if let label = node.title ?? node.elementDescription {
            parts.append("\"\(label)\"")
        } else if !node.notes.filter({ $0.hasPrefix("unlabeled") || $0.hasPrefix("large") }).isEmpty {
            parts.append("*\(node.notes.first { $0.hasPrefix("unlabeled") || $0.hasPrefix("large") } ?? "")*")
        }

        // Value
        if let val = node.value { parts.append("value=\(val)") }

        // Geometry
        if let pos = node.position, let sz = node.size {
            parts.append("\(Int(sz.width))x\(Int(sz.height))@(\(Int(pos.x)),\(Int(pos.y)))")
        }

        // State flags
        var flags: [String] = []
        if node.enabled == false { flags.append("disabled") }
        if node.focused == true  { flags.append("focused") }
        if node.selected == true { flags.append("selected") }
        if !flags.isEmpty { parts.append("[\(flags.joined(separator: ","))]") }

        // Actions
        if !node.actions.isEmpty {
            parts.append("actions={\(node.actions.joined(separator: ","))}")
        }

        // Children truncation note
        if node.childCount > node.children.count {
            parts.append("(\(node.children.count)/\(node.childCount) children shown)")
        }

        lines.append(prefix + parts.joined(separator: " "))

        for child in node.children {
            renderNode(child, indent: indent + 1, lines: &lines)
        }
    }
}
