import ApplicationServices
import Foundation

/// Wraps AXUIElement for safe cross-concurrency-boundary use.
///
/// AXUIElement is a CF reference type. We mark it @unchecked Sendable because:
///   1. CF types are reference-counted (not thread-unsafe in the way classes can be)
///   2. All AX API calls are process-to-process IPC, safe from any thread
///   3. We never mutate the AXUIElement pointer itself, only call AX functions on it
public struct AXElementRef: @unchecked Sendable {
    public let element: AXUIElement
    public let pid: pid_t
    public let snapshot: AXElementSnapshot

    public init(element: AXUIElement, pid: pid_t, snapshot: AXElementSnapshot) {
        self.element  = element
        self.pid      = pid
        self.snapshot = snapshot
    }
}

/// Thread-safe registry that maps integer node IDs to live AXUIElement references.
///
/// Populated by AXTreeWalker after each tree scan. Used by the MCP server to
/// execute write operations (press, setValue, focus) on previously-discovered elements.
///
/// Elements can become stale if the UI changes after the scan — callers should
/// handle errors from AX operations gracefully and re-scan if needed.
public actor ElementRegistry {
    public static let shared = ElementRegistry()

    private var table: [Int: AXElementRef] = [:]

    private init() {}

    /// Store a batch of elements from a tree walk.
    public func store(_ entries: [Int: AXElementRef]) {
        for (id, ref) in entries {
            table[id] = ref
        }
    }

    /// Look up a single element by its snapshot ID.
    public func lookup(_ id: Int) -> AXElementRef? {
        table[id]
    }

    /// Remove all entries (call before a new scan to avoid stale references accumulating).
    public func clear() {
        table.removeAll()
    }

    /// Number of registered elements.
    public var count: Int { table.count }
}
