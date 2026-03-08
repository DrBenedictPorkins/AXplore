import Foundation

public enum SearchFilter {

    /// Search a flat list of nodes using a simple query string.
    /// Matches against: role, title, elementDescription, identifier, action names, value.
    public static func search(_ nodes: [AXElementSnapshot], query: String) -> [AXElementSnapshot] {
        let q = query.lowercased()
        return nodes.filter { matches($0, query: q) }
    }

    private static func matches(_ node: AXElementSnapshot, query: String) -> Bool {
        if let role = node.role,               role.lowercased().contains(query) { return true }
        if let title = node.title,             title.lowercased().contains(query) { return true }
        if let desc = node.elementDescription, desc.lowercased().contains(query) { return true }
        if let id = node.identifier,           id.lowercased().contains(query) { return true }
        if let val = node.value,               val.lowercased().contains(query) { return true }
        if node.actions.contains(where: { $0.lowercased().contains(query) }) { return true }
        return false
    }
}
