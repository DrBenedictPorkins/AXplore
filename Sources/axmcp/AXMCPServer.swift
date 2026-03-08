import MCP
import AXploreCore
import AppKit
import Foundation

/// MCP server exposing AX inspection and automation tools.
///
/// Designed for use with Claude Desktop and Claude Code.
/// Tools are split into read-only (ax_list_apps, ax_get_tree, ax_find_elements,
/// ax_screenshot, ax_get_focused) and write (ax_press, ax_set_value, ax_focus,
/// ax_perform_action).
///
/// Write tools operate on element IDs produced by ax_get_tree / ax_find_elements.
/// The registry is refreshed on every tree scan; stale IDs return an error.
final class AXMCPServer: Sendable {

    func run() async throws {
        let server = Server(
            name: "axmcp",
            version: "1.0.0",
            capabilities: .init(tools: .init())
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.toolDefinitions)
        }

        await server.withMethodHandler(CallTool.self) { [self] params in
            await self.dispatch(params)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Block until the client disconnects (stdin EOF)
        try await Task.sleep(nanoseconds: .max)
    }

    // MARK: - Dispatch

    private func dispatch(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let content = try await handle(params)
            return .init(content: content, isError: false)
        } catch {
            return .init(content: [.text("Error: \(error)")], isError: true)
        }
    }

    private func handle(_ params: CallTool.Parameters) async throws -> [Tool.Content] {
        let args = params.arguments ?? [:]
        switch params.name {
        case "ax_list_apps":   return try listApps()
        case "ax_get_tree":    return try await getTree(args)
        case "ax_find_elements": return try await findElements(args)
        case "ax_screenshot":  return try screenshot(args)
        case "ax_get_focused": return try getFocused(args)
        case "ax_press":       return try await press(args)
        case "ax_set_value":   return try await setValue(args)
        case "ax_focus":       return try await focusElement(args)
        case "ax_perform_action": return try await performAction(args)
        case "ax_get_instructions": return getInstructions()
        case "ax_read_memory":   return try readMemory(args)
        case "ax_write_memory":  return try writeMemory(args)
        default:
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }
    }

    // MARK: - Read Tools

    private func listApps() throws -> [Tool.Content] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { app -> [String: String] in
                var d: [String: String] = [
                    "name": app.localizedName ?? "?",
                    "pid":  "\(app.processIdentifier)",
                ]
                if let bid = app.bundleIdentifier { d["bundleId"] = bid }
                return d
            }

        let json = try jsonString(apps)
        return [.text(json)]
    }

    private func getTree(_ args: [String: Value]) async throws -> [Tool.Content] {
        let (axApp, pid, appName) = try resolveApp(args)
        let mode      = args["mode"]?.stringValue ?? "shallow"
        let maxDepth  = args["max_depth"]?.intValue  ?? 8
        let maxNodes  = args["max_nodes"]?.intValue  ?? 5000

        let (depth, nodes) = effectiveLimits(mode: mode, maxDepth: maxDepth, maxNodes: maxNodes)
        let walker = AXTreeWalker(maxDepth: depth, maxNodes: nodes)
        walker.captureElements = true

        let roots: [AXElementSnapshot]
        switch mode {
        case "focused-window": roots = walker.walkFocusedWindow(axApp)
        case "focused-element": roots = walker.walkFocusedElement(axApp)
        default: roots = walker.walkAppRoots(axApp)
        }

        // Populate element registry for subsequent write calls
        let allNodes = flatten(roots)
        var entries: [Int: AXElementRef] = [:]
        for (id, element) in walker.elementTable {
            if let snap = allNodes.first(where: { $0.id == id }) {
                entries[id] = AXElementRef(element: element, pid: pid, snapshot: snap)
            }
        }
        await ElementRegistry.shared.clear()
        await ElementRegistry.shared.store(entries)

        // Build text summary
        let analysis = AXSummaryAnalyzer(nodes: allNodes).analyze()

        var lines: [String] = []
        lines.append("App: \(appName) (PID \(pid)) | nodes: \(allNodes.count) | mode: \(mode)")
        lines.append("")
        appendTree(roots, indent: 0, to: &lines, maxLines: 300)

        lines.append("")
        lines.append("--- Summary ---")
        lines.append("Windows: \(analysis.windowCount)")
        lines.append("With labels: \(analysis.elementsWithLabels)/\(analysis.totalNodes)")
        lines.append("With actions: \(analysis.elementsWithActions)")
        lines.append("")
        lines.append("Top roles:")
        for rc in analysis.roleHistogram.prefix(10) {
            lines.append("  \(rc.role): \(rc.count)")
        }
        lines.append("")
        lines.append("Feasibility:")
        for fn in analysis.feasibilityNotes {
            let m = fn.verdict == "accessible" ? "YES" : fn.verdict == "opaque" ? "OPAQUE" : "LIKELY"
            lines.append("  [\(m)] \(fn.area): \(fn.observation)")
        }
        lines.append("")
        lines.append("Element IDs are valid for ax_press, ax_set_value, ax_focus until the next ax_get_tree call.")

        return [.text(lines.joined(separator: "\n"))]
    }

    private func findElements(_ args: [String: Value]) async throws -> [Tool.Content] {
        let (axApp, pid, appName) = try resolveApp(args)
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw MCPError.invalidParams("query is required")
        }
        let maxDepth = args["max_depth"]?.intValue ?? 8
        let maxNodes = args["max_nodes"]?.intValue ?? 5000

        let walker = AXTreeWalker(maxDepth: maxDepth, maxNodes: maxNodes)
        walker.captureElements = true
        let roots    = walker.walkAppRoots(axApp)
        let allNodes = flatten(roots)

        // Merge new captures into registry (additive — keeps IDs from previous scans)
        var entries: [Int: AXElementRef] = [:]
        for (id, element) in walker.elementTable {
            if let snap = allNodes.first(where: { $0.id == id }) {
                entries[id] = AXElementRef(element: element, pid: pid, snapshot: snap)
            }
        }
        await ElementRegistry.shared.store(entries)

        let matches = SearchFilter.search(allNodes, query: query)

        if matches.isEmpty {
            return [.text("No elements matched '\(query)' in \(appName).")]
        }

        var lines: [String] = ["Found \(matches.count) element(s) matching '\(query)' in \(appName):", ""]
        for node in matches.prefix(100) {
            let label = node.title ?? node.elementDescription ?? "(no label)"
            let pos   = node.position.map { "@(\(Int($0.x)),\(Int($0.y)))" } ?? ""
            let sz    = node.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? ""
            let acts  = node.actions.isEmpty ? "" : " actions=[\(node.actions.joined(separator: ","))]"
            lines.append("  id=\(node.id)  [\(node.role ?? "?")]  \"\(label)\"  \(pos) \(sz)\(acts)")
        }
        if matches.count > 100 { lines.append("  ... \(matches.count - 100) more matches.") }

        return [.text(lines.joined(separator: "\n"))]
    }

    private func screenshot(_ args: [String: Value]) throws -> [Tool.Content] {
        let (_, pid, appName) = try resolveApp(args)

        let tmpDir = "/tmp/axmcp_screenshots"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let (paths, diagnostic) = ScreenshotCapture.captureWindows(for: pid, outputDir: tmpDir)

        if paths.isEmpty {
            let reason = diagnostic.isEmpty ? "Unknown failure." : diagnostic
            return [.text("No screenshots captured for \(appName). \(reason)")]
        }

        var content: [Tool.Content] = [.text("Captured \(paths.count) screenshot(s) for \(appName):")]
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            // MCP image content requires base64-encoded string, not raw Data
            let b64 = data.base64EncodedString()
            content.append(Tool.Content.image(data: b64, mimeType: "image/png", metadata: nil))
        }
        return content
    }

    private func getFocused(_ args: [String: Value]) throws -> [Tool.Content] {
        let (axApp, _, appName) = try resolveApp(args)
        let ctx = FocusedContextReader.read(appElement: axApp)

        var lines = ["Focused context for \(appName):"]
        lines.append("  Focused app    : \(ctx.focusedAppName ?? "?")")
        lines.append("  Focused window : \(ctx.focusedWindowTitle ?? "(none)")")
        if let role = ctx.focusedElementRole {
            let label = ctx.focusedElementTitle ?? ctx.focusedElementDescription ?? "(no label)"
            lines.append("  Focused element: [\(role)] \"\(label)\"")
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    // MARK: - Write Tools

    private func press(_ args: [String: Value]) async throws -> [Tool.Content] {
        let (element, snap) = try await lookupElement(args)
        try AXWriter.press(element)
        let label = snap.title ?? snap.elementDescription ?? "(no label)"
        return [.text("Pressed [\(snap.role ?? "?")] \"\(label)\" (id=\(snap.id))")]
    }

    private func setValue(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let value = args["value"]?.stringValue else {
            throw MCPError.invalidParams("value is required")
        }
        let (element, snap) = try await lookupElement(args)
        try AXWriter.setValue(element, value: value)
        let label = snap.title ?? snap.elementDescription ?? "(no label)"
        return [.text("Set value of [\(snap.role ?? "?")] \"\(label)\" (id=\(snap.id)) to \"\(value)\"")]
    }

    private func focusElement(_ args: [String: Value]) async throws -> [Tool.Content] {
        let (element, snap) = try await lookupElement(args)
        try AXWriter.focus(element)
        let label = snap.title ?? snap.elementDescription ?? "(no label)"
        return [.text("Focused [\(snap.role ?? "?")] \"\(label)\" (id=\(snap.id))")]
    }

    private func performAction(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let action = args["action"]?.stringValue else {
            throw MCPError.invalidParams("action is required")
        }
        let (element, snap) = try await lookupElement(args)
        try AXWriter.performAction(element, action: action)
        let label = snap.title ?? snap.elementDescription ?? "(no label)"
        return [.text("Performed \(action) on [\(snap.role ?? "?")] \"\(label)\" (id=\(snap.id))")]
    }

    // MARK: - Memory + Instructions Tools

    private func getInstructions() -> [Tool.Content] {
        let text = """
        # axmcp Usage Protocol

        Call this once at session start to load the full protocol. All rules below apply for the duration of the session.

        ## Tool Cheatsheet
        | Tool | Purpose |
        |------|---------|
        ax_list_apps | List running GUI apps (name, PID, bundle ID)
        ax_get_tree | Walk AX tree; modes: shallow (default), app, deep, focused-window, focused-element
        ax_find_elements | Search tree by role/title/label/action — targeted, faster than full dump
        ax_screenshot | Capture PNG of app windows for visual correlation
        ax_get_focused | Return focused app/window/element state
        ax_press | Click element by ID (must expose AXPress action)
        ax_set_value | Set text/value on element by ID
        ax_focus | Move keyboard focus to element by ID
        ax_perform_action | Run named AX action (AXShowMenu, AXIncrement, etc.)
        ax_get_instructions | Return this protocol (call at session start)
        ax_read_memory | Load persisted knowledge for an app (by bundle_id or app name)
        ax_write_memory | Save new knowledge for an app (overwrites file)

        ## Efficiency Rules
        1. ALWAYS call ax_read_memory at session start for the target app — skip re-discovering what's already known.
        2. Use ax_find_elements with a specific query rather than ax_get_tree when the target element is known.
        3. Use shallow mode first; switch to deep only if shallow didn't reveal the target.
        4. Opaque regions (many unlabeled AXGroups, zero children, large canvas areas) = do not waste calls on them; use menu bar instead.
        5. Element IDs are ephemeral — always re-scan before write operations if app state may have changed.
        6. Prefer ax_find_elements over ax_get_tree when you know what you're looking for.

        ## Safety Rules
        1. Call ax_screenshot BEFORE and AFTER every write operation (ax_press, ax_set_value).
        2. After ax_set_value, always call ax_perform_action(element_id, "AXConfirm") to commit the value — without this, the field reverts when focus changes.
        3. If ax_press returns an error, call ax_find_elements to refresh IDs, then retry once.
        3. Never assume a dialog or panel is open — call ax_get_focused to confirm current focus state.
        4. If multiple elements match a query, call ax_screenshot first to confirm which one is visible.
        5. Never perform write operations on stale element IDs (from a previous ax_get_tree call after state changes).

        ## Memory Rules
        1. Call ax_read_memory at the start of every session for the target app.
        2. Call ax_write_memory after any new element is confirmed or workflow is proven.
        3. Memory format: sections for Accessible Regions, Opaque Regions, Known Elements (table), Proven Workflows, Notes.
        4. Include date and approximate node count in Notes so staleness can be assessed.
        5. Memory files live at: ~/.axmcp/memories/<bundle_id>.md

        ## Recommended Workflow — Explore Mode
        1. Identify target app (ask user if unclear).
        2. Call ax_read_memory — if memory exists, use it to skip known-opaque regions.
        3. Call ax_list_apps to confirm app is running and get PID.
        4. Call ax_get_tree(mode="shallow") for initial structural overview.
        5. Call ax_screenshot to correlate visual UI with AX tree elements.
        6. For regions of interest, drill with ax_find_elements(query=<role or label>).
        7. Produce structured report: accessible regions, opaque regions, proven element labels.
        8. Call ax_write_memory to save findings for future sessions.

        ## Recommended Workflow — Automate Mode
        1. Call ax_read_memory — use prior knowledge to skip scanning known regions.
        2. Call ax_screenshot to confirm current app state.
        3. Use ax_find_elements with targeted queries (never full-tree dump unless necessary).
        4. Call ax_press / ax_set_value on identified elements. After ax_set_value, call ax_perform_action(element_id, "AXConfirm") to commit the value.
        5. Call ax_screenshot after each action to verify the result.
        6. If an action fails, call ax_get_tree(mode="focused-window") and retry with fresh IDs.
        7. Update ax_write_memory if a new workflow was proven.

        ## Common Pitfalls
        - Canvas/timeline areas in creative apps (video editors, DAWs, drawing tools) are almost always opaque — zero accessible children despite being large UI regions.
        - Electron apps expose minimal AX structure; use menu bar traversal as fallback.
        - AXGroup clusters with no labels = opaque container, do not recurse further.
        - Element IDs reset on every ax_get_tree call — never cache IDs across tool calls if state changed.
        - wxWidgets apps (PrusaSlicer, etc.) often have fully flat AX trees — deep scan returns same nodes as shallow; tab bars and toolbars are entirely absent.

        ## Automation Assessment Report (required output of every explore session)
        After exploring an app, always deliver this report to the user before ending the session:

        ```
        ## Automation Assessment: <App Name>

        ### Claude can do this autonomously
        - <specific action>: <element label, field name, query>

        ### You need to do this (then Claude continues)
        - <interaction>: <why — opaque region, custom control, no AX path>
          Hint: <keyboard shortcut or click target if known>

        ### Unreachable — no AX path exists
        - <region or feature>: <reason>

        ### Automation coverage: <Low | Partial | Good | High>
        <One sentence summary.>
        ```

        Coverage levels:
        - High    — most interactions automatable, user rarely needed
        - Good    — core workflows automatable, user needed for navigation only
        - Partial — key actions accessible, significant opaque areas require user
        - Low     — mostly opaque; axmcp useful for reading state and a few actions only

        This report is what makes axmcp useful as a co-pilot: the user knows exactly when
        to expect Claude to act, and when they need to click something themselves.
        """
        return [.text(text)]
    }

    private func memoryPath(bundleID: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safe = bundleID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(home)/.axmcp/memories/\(safe).md"
    }

    private func readMemory(_ args: [String: Value]) throws -> [Tool.Content] {
        let bundleID: String
        if let bid = args["bundle_id"]?.stringValue {
            bundleID = bid
        } else if let name = args["app"]?.stringValue {
            let locator = ProcessLocator()
            guard let app = locator.findByName(name).first else {
                throw MCPError.invalidParams("App '\(name)' not found. Use ax_list_apps to see running apps.")
            }
            guard let bid = NSWorkspace.shared.runningApplications
                .first(where: { $0.processIdentifier == app.pid })?
                .bundleIdentifier else {
                throw MCPError.invalidParams("Could not resolve bundle ID for '\(name)'. Provide bundle_id directly.")
            }
            bundleID = bid
        } else {
            throw MCPError.invalidParams("Provide bundle_id or app.")
        }

        let path = memoryPath(bundleID: bundleID)
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return [.text(content)]
        }
        return [.text("No memory found for \(bundleID). Run ax_get_tree and save findings with ax_write_memory.")]
    }

    private func writeMemory(_ args: [String: Value]) throws -> [Tool.Content] {
        guard let bundleID = args["bundle_id"]?.stringValue, !bundleID.isEmpty else {
            throw MCPError.invalidParams("bundle_id is required")
        }
        guard let content = args["content"]?.stringValue else {
            throw MCPError.invalidParams("content is required")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.axmcp/memories"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let path = memoryPath(bundleID: bundleID)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return [.text("Memory saved to \(path)")]
    }

    // MARK: - Helpers

    private func resolveApp(_ args: [String: Value]) throws -> (AXUIElement, pid_t, String) {
        let locator = ProcessLocator()
        let candidates: [AppProcess]

        if let pidVal = args["pid"]?.intValue {
            candidates = locator.findByPID(Int32(pidVal))
        } else if let bid = args["bundle_id"]?.stringValue {
            candidates = locator.findByBundleID(bid)
        } else if let name = args["app"]?.stringValue {
            candidates = locator.findByName(name)
        } else {
            throw MCPError.invalidParams("Provide app, bundle_id, or pid.")
        }

        guard let target = candidates.first else {
            let id = args["app"]?.stringValue ?? args["bundle_id"]?.stringValue ?? "?"
            throw MCPError.invalidParams("App '\(id)' not found. Use ax_list_apps to see running apps.")
        }

        return (AXUIElementCreateApplication(target.pid), target.pid, target.name)
    }

    private func lookupElement(_ args: [String: Value]) async throws -> (AXUIElement, AXElementSnapshot) {
        guard let elementId = args["element_id"]?.intValue else {
            throw MCPError.invalidParams("element_id is required. Run ax_get_tree or ax_find_elements first.")
        }
        guard let ref = await ElementRegistry.shared.lookup(elementId) else {
            throw MCPError.invalidParams("element_id \(elementId) not found in registry. Re-run ax_get_tree to refresh element IDs.")
        }
        return (ref.element, ref.snapshot)
    }

    private func effectiveLimits(mode: String, maxDepth: Int, maxNodes: Int) -> (Int, Int) {
        switch mode {
        case "shallow": return (min(maxDepth, 4),  min(maxNodes, 500))
        case "deep":    return (max(maxDepth, 12), max(maxNodes, 10_000))
        default:        return (maxDepth, maxNodes)
        }
    }

    private func flatten(_ nodes: [AXElementSnapshot]) -> [AXElementSnapshot] {
        var result: [AXElementSnapshot] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }

    private func appendTree(_ nodes: [AXElementSnapshot], indent: Int, to lines: inout [String], maxLines: Int) {
        guard lines.count < maxLines else {
            if lines.count == maxLines { lines.append("... (tree truncated, use ax_find_elements to search)") }
            return
        }
        let prefix = String(repeating: "  ", count: indent)
        for node in nodes {
            let role  = node.role ?? "?"
            let label = node.title ?? node.elementDescription ?? ""
            let labelStr = label.isEmpty ? "" : " \"\(label)\""
            let pos   = node.position.map { " @(\(Int($0.x)),\(Int($0.y)))" } ?? ""
            let sz    = node.size.map { " \(Int($0.width))x\(Int($0.height))" } ?? ""
            let acts  = node.actions.isEmpty ? "" : " [\(node.actions.joined(separator: ","))]"
            lines.append("\(prefix)id=\(node.id) [\(role)]\(labelStr)\(sz)\(pos)\(acts)")
            appendTree(node.children, indent: indent + 1, to: &lines, maxLines: maxLines)
        }
    }

    private func jsonString(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Tool Definitions

    private static let appArgs: [String: Value] = [
        "app":       .object(["type": .string("string"), "description": .string("App name (partial, case-insensitive)")]),
        "bundle_id": .object(["type": .string("string"), "description": .string("Bundle identifier (exact)")]),
        "pid":       .object(["type": .string("integer"), "description": .string("Process ID")]),
    ]

    static let toolDefinitions: [Tool] = [

        Tool(
            name: "ax_list_apps",
            description: "List all running macOS GUI applications with their name, PID, and bundle ID.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),

        Tool(
            name: "ax_get_tree",
            description: """
            Walk the Accessibility tree of a running macOS app. Returns a text tree with element IDs, roles, labels, sizes, positions, and actions. Also returns a summary and feasibility report.

            Element IDs returned here are valid for ax_press, ax_set_value, ax_focus, and ax_perform_action until the next ax_get_tree call.

            Modes:
              shallow (default) — top 4 levels, fast
              app               — full app from all windows
              deep              — exhaustive, up to 12 levels
              focused-window    — only the focused window
              focused-element   — only the focused element
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs.merging([
                    "mode":      .object(["type": .string("string"), "description": .string("shallow | app | deep | focused-window | focused-element")]),
                    "max_depth": .object(["type": .string("integer"), "description": .string("Max tree depth (default 8)")]),
                    "max_nodes": .object(["type": .string("integer"), "description": .string("Max nodes (default 5000)")]),
                ], uniquingKeysWith: { $1 }))
            ])
        ),

        Tool(
            name: "ax_find_elements",
            description: "Search the Accessibility tree of an app for elements matching a query string. Matches role, title, description, identifier, value, or action name. Returns matching elements with IDs usable in write tools.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object(appArgs.merging([
                    "query":     .object(["type": .string("string"), "description": .string("Search string: role, title, description, identifier, action name, or value substring")]),
                    "max_depth": .object(["type": .string("integer"), "description": .string("Max depth to search (default 8)")]),
                    "max_nodes": .object(["type": .string("integer"), "description": .string("Max nodes to scan (default 5000)")]),
                ], uniquingKeysWith: { $1 }))
            ])
        ),

        Tool(
            name: "ax_screenshot",
            description: "Capture a PNG screenshot of the app's on-screen windows. Returns image content for visual inspection. Requires Screen Recording permission.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs)
            ])
        ),

        Tool(
            name: "ax_get_focused",
            description: "Return the currently focused app, window, and UI element for a given app.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs)
            ])
        ),

        Tool(
            name: "ax_press",
            description: "Press (click) an element by its element ID. Use ax_get_tree or ax_find_elements first to discover element IDs. Only works on elements that expose the AXPress action.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("element_id")]),
                "properties": .object([
                    "element_id": .object(["type": .string("integer"), "description": .string("Element ID from ax_get_tree or ax_find_elements")]),
                ])
            ])
        ),

        Tool(
            name: "ax_set_value",
            description: "Set the value of an element (e.g., type text into a text field, move a slider). Use ax_find_elements with query 'AXTextField' to find editable fields. IMPORTANT: Always follow ax_set_value with ax_perform_action(element_id, AXConfirm) to commit the value — without it the field reverts when focus changes.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("element_id"), .string("value")]),
                "properties": .object([
                    "element_id": .object(["type": .string("integer"), "description": .string("Element ID from ax_get_tree or ax_find_elements")]),
                    "value":      .object(["type": .string("string"),  "description": .string("New value to set")]),
                ])
            ])
        ),

        Tool(
            name: "ax_focus",
            description: "Focus an element (bring keyboard focus to it).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("element_id")]),
                "properties": .object([
                    "element_id": .object(["type": .string("integer"), "description": .string("Element ID from ax_get_tree or ax_find_elements")]),
                ])
            ])
        ),

        Tool(
            name: "ax_perform_action",
            description: "Perform a named AX action on an element (e.g., AXShowMenu, AXConfirm, AXDecrement, AXIncrement). Use ax_get_tree to see available actions per element.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("element_id"), .string("action")]),
                "properties": .object([
                    "element_id": .object(["type": .string("integer"), "description": .string("Element ID from ax_get_tree or ax_find_elements")]),
                    "action":     .object(["type": .string("string"),  "description": .string("AX action name, e.g. AXPress, AXShowMenu, AXDecrement, AXIncrement, AXConfirm")]),
                ])
            ])
        ),

        Tool(
            name: "ax_get_instructions",
            description: "Return the full axmcp usage protocol: efficiency rules, safety rules, memory rules, tool cheatsheet, and recommended workflows for explore and automate modes. Call this once at the start of every session.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),

        Tool(
            name: "ax_read_memory",
            description: "Load persisted AX knowledge for an app from ~/.axmcp/memories/<bundle_id>.md. Returns file content, or a prompt to scan and save if no memory exists yet.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundle_id": .object(["type": .string("string"), "description": .string("Bundle identifier (exact), e.g. com.apple.Safari")]),
                    "app":       .object(["type": .string("string"), "description": .string("App name (resolved to bundle ID via running processes)")]),
                ])
            ])
        ),

        Tool(
            name: "ax_write_memory",
            description: "Save AX knowledge for an app to ~/.axmcp/memories/<bundle_id>.md. Overwrites existing content. Use after discovering new elements or proving a workflow.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("bundle_id"), .string("content")]),
                "properties": .object([
                    "bundle_id": .object(["type": .string("string"), "description": .string("Bundle identifier, e.g. com.apple.Safari")]),
                    "content":   .object(["type": .string("string"), "description": .string("Full markdown content to write (replaces existing file)")]),
                ])
            ])
        ),
    ]
}

// MARK: - Value helpers

extension Value {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
}
