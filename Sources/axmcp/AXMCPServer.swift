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

    // Tracks whether ax_get_instructions has been called this session.
    // Any tool call before this returns a gate message telling the client to load
    // the protocol first, then retry. Monotonic false→true; races are harmless.
    nonisolated(unsafe) private var instructionsLoaded = false

    func run() async throws {
        let server = Server(
            name: "axmcp",
            version: axmcpVersion,
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

        // Gate: require ax_get_instructions before any other tool.
        if params.name != "ax_get_instructions" && !instructionsLoaded {
            return [.text("Call ax_get_instructions first to load the usage protocol, then retry: \(params.name)")]
        }

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
        case "ax_key":         return try await pressKey(args)
        case "ax_type":        return try await typeString(args)
        case "ax_get_instructions": return getInstructions()
        case "ax_read_memory":   return try readMemory(args)
        case "ax_write_memory":  return try writeMemory(args)
        case "ax_get_applescript_dictionary": return try getAppleScriptDictionary(args)
        case "ax_run_applescript": return try runAppleScript(args)
        case "ax_clipboard_get":  return clipboardGet(args)
        case "ax_clipboard_set":  return try clipboardSet(args)
        case "ax_scroll":         return try await scroll(args)
        case "ax_wait_for":       return try await waitFor(args)
        case "ax_launch_app":     return try await launchApp(args)
        case "ax_quit_app":       return try quitApp(args)
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

    private func pressKey(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let key = args["key"]?.stringValue else {
            throw MCPError.invalidParams("key is required")
        }
        let (_, pid, appName) = try resolveApp(args)
        let modifiers: [String]
        if case .array(let arr) = args["modifiers"] {
            modifiers = arr.compactMap { $0.stringValue }
        } else {
            modifiers = []
        }
        try AXWriter.pressKey(pid: pid, key: key, modifiers: modifiers)
        let modStr = modifiers.isEmpty ? "" : " + modifiers: [\(modifiers.joined(separator: ", "))]"
        return [.text("Pressed key '\(key)'\(modStr) in \(appName) (PID \(pid))")]
    }

    private func typeString(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let text = args["text"]?.stringValue, !text.isEmpty else {
            throw MCPError.invalidParams("text is required")
        }
        let (_, pid, appName) = try resolveApp(args)
        let delayMs = args["delay_ms"]?.intValue.map { UInt32($0) } ?? 20
        try AXWriter.typeText(pid: pid, text: text, delayMs: delayMs)
        return [.text("Typed \(text.count) character(s) into \(appName) (PID \(pid))")]
    }

    // MARK: - Clipboard Tools

    private func clipboardGet(_ args: [String: Value]) -> [Tool.Content] {
        let pb = NSPasteboard.general
        if let text = pb.string(forType: .string) {
            return [.text("Clipboard (\(text.count) chars):\n\(text)")]
        }
        let types = pb.types?.map { $0.rawValue }.joined(separator: ", ") ?? "none"
        return [.text("Clipboard is empty or contains non-text content. Available types: \(types)")]
    }

    private func clipboardSet(_ args: [String: Value]) throws -> [Tool.Content] {
        guard let text = args["text"]?.stringValue else {
            throw MCPError.invalidParams("text is required")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return [.text("Clipboard set (\(text.count) chars).")]
    }

    // MARK: - Scroll Tool

    private func scroll(_ args: [String: Value]) async throws -> [Tool.Content] {
        let direction = args["direction"]?.stringValue ?? "down"
        let amount    = args["amount"]?.intValue ?? 3
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw MCPError.invalidParams("direction must be: up, down, left, right")
        }

        var point: CGPoint
        var desc: String

        if let elementId = args["element_id"]?.intValue {
            guard let ref = await ElementRegistry.shared.lookup(elementId) else {
                throw MCPError.invalidParams("element_id \(elementId) not found. Re-run ax_get_tree.")
            }
            guard let pos = ref.snapshot.position, let sz = ref.snapshot.size else {
                throw MCPError.invalidParams("Element id=\(elementId) has no position/size.")
            }
            point = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
            desc  = "element id=\(elementId)"
        } else {
            let (axApp, _, appName) = try resolveApp(args)
            let walker = AXTreeWalker(maxDepth: 1, maxNodes: 1)
            guard let win = walker.walkFocusedWindow(axApp).first,
                  let pos = win.position, let sz = win.size else {
                throw MCPError.invalidParams("Cannot determine scroll target for \(appName). Provide element_id or ensure the app has a focused window.")
            }
            point = CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
            desc  = "\(appName) window center (\(Int(point.x)), \(Int(point.y)))"
        }

        var wheel1: Int32 = 0
        var wheel2: Int32 = 0
        switch direction {
        case "up":    wheel1 =  Int32(amount)
        case "down":  wheel1 = -Int32(amount)
        case "left":  wheel2 =  Int32(amount)
        case "right": wheel2 = -Int32(amount)
        default:      break
        }

        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                   wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0) else {
            throw MCPError.invalidParams("Failed to create scroll event.")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return [.text("Scrolled \(direction) \(amount) lines at \(desc).")]
    }

    // MARK: - Wait Tool

    private func waitFor(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw MCPError.invalidParams("query is required")
        }
        let (axApp, pid, appName) = try resolveApp(args)
        let timeoutSec = args["timeout"]?.intValue ?? 10
        let deadline   = Date().addingTimeInterval(Double(timeoutSec))

        while Date() < deadline {
            let walker = AXTreeWalker(maxDepth: 8, maxNodes: 5000)
            walker.captureElements = true
            let roots    = walker.walkAppRoots(axApp)
            let allNodes = flatten(roots)
            let matches  = SearchFilter.search(allNodes, query: query)

            if !matches.isEmpty {
                var entries: [Int: AXElementRef] = [:]
                for (id, element) in walker.elementTable {
                    if let snap = allNodes.first(where: { $0.id == id }) {
                        entries[id] = AXElementRef(element: element, pid: pid, snapshot: snap)
                    }
                }
                await ElementRegistry.shared.store(entries)
                let m     = matches[0]
                let label = m.title ?? m.elementDescription ?? "(no label)"
                return [.text("Found '\(query)' in \(appName): id=\(m.id) [\(m.role ?? "?")] \"\(label)\"")]
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return [.text("Timed out after \(timeoutSec)s — '\(query)' did not appear in \(appName).")]
    }

    // MARK: - App Lifecycle Tools

    private func launchApp(_ args: [String: Value]) async throws -> [Tool.Content] {
        guard let bundleID = args["bundle_id"]?.stringValue, !bundleID.isEmpty else {
            throw MCPError.invalidParams("bundle_id is required")
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw MCPError.invalidParams("No application found for bundle ID '\(bundleID)'.")
        }
        let config = NSWorkspace.OpenConfiguration()
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let name = app?.localizedName ?? bundleID
                    continuation.resume(returning: [.text("Launched \(name) (\(bundleID)).")])
                }
            }
        }
    }

    private func quitApp(_ args: [String: Value]) throws -> [Tool.Content] {
        let (_, pid, appName) = try resolveApp(args)
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == pid }) else {
            throw MCPError.invalidParams("App \(appName) (PID \(pid)) not found in running applications.")
        }
        let ok = app.terminate()
        return [.text(ok
            ? "Sent quit signal to \(appName) (PID \(pid))."
            : "Could not quit \(appName) — app may not support graceful termination."
        )]
    }

    // MARK: - Memory + Instructions Tools

    private func getInstructions() -> [Tool.Content] {
        instructionsLoaded = true
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
        ax_key | Inject a keyboard event into the app (key + optional modifiers)
        ax_type | Type a string character by character into the focused field
        ax_get_instructions | Return this protocol (call at session start)
        ax_read_memory | Load persisted knowledge for an app (by bundle_id or app name)
        ax_write_memory | Save new knowledge for an app (overwrites file)
        ax_get_applescript_dictionary | Return the AppleScript dictionary for a scriptable app
        ax_run_applescript | Execute an AppleScript and return the result
        ax_clipboard_get | Read the current clipboard contents
        ax_clipboard_set | Write text to the clipboard
        ax_scroll | Scroll inside an app window or element (direction, amount, optional element_id)
        ax_wait_for | Poll until an element matching query appears (with timeout)
        ax_launch_app | Launch an app by bundle ID
        ax_quit_app | Quit a running app gracefully

        ## AppleScript vs AX — When to Use Which
        These are complementary tools. Use the right one for the job:

        | Situation | Use |
        |-----------|-----|
        | App has a scripting dictionary (Safari, Finder, Mail, Terminal, Pages, Numbers, Keynote, Music) | ax_run_applescript |
        | Need to access app data directly (get tab URLs, list windows, read document content) | ax_run_applescript |
        | Need to create things (new tab, new document, send mail) | ax_run_applescript |
        | Third-party app with no scripting support (PrusaSlicer, Filmora, etc.) | AX tools |
        | Clicking a specific button or filling a form field | AX tools |
        | App has a dictionary but the action isn't scriptable | AX tools as fallback |

        Call ax_get_applescript_dictionary for ANY app before reaching for AX automation — not just Apple apps.
        AppleScript accesses the app's data model directly — it's faster, more reliable, and doesn't depend on UI state.
        If the app has no scripting dictionary or the action isn't scriptable, fall back to AX tools.

        ## Efficiency Rules
        1. ALWAYS call ax_read_memory at session start for the target app — skip re-discovering what's already known.
        2. Call ax_get_applescript_dictionary for EVERY app before using AX tools — if the action is scriptable, ax_run_applescript is faster and more reliable than AX automation.
        3. Use ax_find_elements with a specific query rather than ax_get_tree when the target element is known.
        4. Use shallow mode first; switch to deep only if shallow didn't reveal the target.
        5. Opaque regions (many unlabeled AXGroups, zero children, large canvas areas) = do not waste calls on them; use menu bar instead.
        6. Element IDs are ephemeral — always re-scan before write operations if app state may have changed.
        7. Prefer ax_find_elements over ax_get_tree when you know what you're looking for.

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
        4. Call ax_get_applescript_dictionary for the app — even non-Apple apps may expose a scripting dictionary. Note which actions are scriptable; prefer ax_run_applescript for those.
        5. Call ax_get_tree(mode="shallow") for initial structural overview.
        6. Call ax_screenshot to correlate visual UI with AX tree elements.
        7. For regions of interest, drill with ax_find_elements(query=<role or label>).
        8. Produce structured report: accessible regions, opaque regions, scriptable AppleScript actions, proven element labels.
        9. Call ax_write_memory to save findings (include AppleScript findings) for future sessions.

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
        - wxWidgets apps (PrusaSlicer, etc.) often have fully flat AX trees — deep scan returns same nodes as shallow; tab bars and toolbars are entirely absent. Use ax_key for keyboard-based navigation (e.g. Ctrl+1/2/3 to switch tabs).

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

    /// Strips leading/trailing slashes from a bundle ID before using it as a filename.
    /// Some apps (e.g. PrusaSlicer) report a trailing "/" in their bundle ID via NSWorkspace.
    private func normalizedBundleID(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func memoryPath(bundleID: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safe = normalizedBundleID(bundleID)
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
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [.text("No memory found for \(bundleID). Run ax_get_tree and save findings with ax_write_memory.")]
        }

        // Verify the bundle ID stored in the file matches what we looked up,
        // to catch stale files or filename collisions after normalization.
        let requestedNormalized = normalizedBundleID(bundleID)
        let storedBundleID = content.components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("**Bundle ID:**") })
            .map { $0.replacingOccurrences(of: "**Bundle ID:**", with: "").trimmingCharacters(in: .whitespaces) }
        if let stored = storedBundleID, normalizedBundleID(stored) != requestedNormalized {
            return [.text("Warning: memory file bundle ID mismatch. File contains '\(stored)', requested '\(bundleID)'. Verify this is the correct app before using this memory.\n\n\(content)")]
        }

        return [.text(content)]
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

    // MARK: - AppleScript Tools

    private func getAppleScriptDictionary(_ args: [String: Value]) throws -> [Tool.Content] {
        let bundlePath: String
        let appName: String

        if let bid = args["bundle_id"]?.stringValue {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
               let url = app.bundleURL {
                (bundlePath, appName) = (url.path, app.localizedName ?? bid)
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                (bundlePath, appName) = (url.path, bid)
            } else {
                throw MCPError.invalidParams("No app found for bundle ID '\(bid)'.")
            }
        } else if let name = args["app"]?.stringValue {
            let lower = name.lowercased()
            guard let app = NSWorkspace.shared.runningApplications
                .filter({ $0.activationPolicy != .prohibited })
                .first(where: { $0.localizedName?.lowercased().contains(lower) == true }),
                  let url = app.bundleURL else {
                throw MCPError.invalidParams("App '\(name)' not found. Use ax_list_apps to see running apps.")
            }
            (bundlePath, appName) = (url.path, app.localizedName ?? name)
        } else {
            throw MCPError.invalidParams("Provide app or bundle_id.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [bundlePath]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, process.terminationStatus == 0 else {
            return [.text("\(appName) has no AppleScript dictionary (not scriptable).")]
        }

        let parser = SdefParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return [.text(parser.summary(appName: appName))]
    }

    private func runAppleScript(_ args: [String: Value]) throws -> [Tool.Content] {
        guard let script = args["script"]?.stringValue, !script.isEmpty else {
            throw MCPError.invalidParams("script is required")
        }
        guard let appleScript = NSAppleScript(source: script) else {
            throw MCPError.invalidParams("Failed to compile AppleScript.")
        }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let err = errorDict, let msg = err["NSAppleScriptErrorMessage"] as? String {
            return [.text("AppleScript error: \(msg)")]
        }
        let output = result.stringValue ?? "(no return value)"
        return [.text(output)]
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
            name: "ax_key",
            description: """
            Inject a keyboard event into a running app by PID, name, or bundle ID. \
            Useful for keyboard shortcuts and navigation in apps where AX elements are opaque \
            (e.g. wxWidgets tab bars, menu shortcuts, modal dismissal).

            key: single character ("a", "1", "/") or named key ("return", "tab", "space", \
            "escape", "delete", "up", "down", "left", "right", "f1"-"f12").
            modifiers: array of zero or more: "cmd", "shift", "ctrl", "alt".

            Examples:
              ax_key(app="PrusaSlicer", key="2", modifiers=["ctrl"])   → switch to tab 2
              ax_key(app="Safari", key="r", modifiers=["cmd"])          → reload
              ax_key(app="Finder", key="return")                        → rename selected item
            """,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("key")]),
                "properties": .object(appArgs.merging([
                    "key": .object(["type": .string("string"), "description": .string("Key to press: single char or named key (return, tab, space, escape, delete, up, down, left, right, f1-f12)")]),
                    "modifiers": .object(["type": .string("array"), "description": .string("Modifier keys: cmd, shift, ctrl, alt"), "items": .object(["type": .string("string")])]),
                ], uniquingKeysWith: { $1 }))
            ])
        ),

        Tool(
            name: "ax_type",
            description: """
            Type a string into the focused field of an app by injecting unicode keyboard events \
            for each character. Handles uppercase, symbols, and non-ASCII naturally — no key code \
            mapping required. Use ax_focus first to focus the target field, then ax_type to enter text.

            Prefer ax_type over ax_set_value when the app uses a custom text control that does \
            not respond to AXValue writes.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("text")]),
                "properties": .object(appArgs.merging([
                    "text":     .object(["type": .string("string"), "description": .string("The string to type into the app")]),
                    "delay_ms": .object(["type": .string("integer"), "description": .string("Delay in milliseconds between keystrokes (default: 20)")]),
                ], uniquingKeysWith: { $1 }))
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

        Tool(
            name: "ax_get_applescript_dictionary",
            description: """
            Return the AppleScript scripting dictionary for a macOS app — the full list of scriptable \
            classes (with properties) and commands (with parameters and return types). \
            Use this before ax_run_applescript to discover what the app supports. \
            Apps without a scripting dictionary (most third-party apps) return a not-scriptable message.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs)
            ])
        ),

        Tool(
            name: "ax_run_applescript",
            description: """
            Execute an AppleScript and return the result. Use ax_get_applescript_dictionary first \
            to discover available commands and classes for the target app. \
            Prefer AppleScript over AX automation for apps with rich scripting dictionaries \
            (Safari, Finder, Mail, Terminal, Pages, Numbers, Keynote, Music) — it accesses \
            the app's data model directly rather than simulating UI interactions.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("script")]),
                "properties": .object([
                    "script": .object(["type": .string("string"), "description": .string("The AppleScript source to execute")]),
                ])
            ])
        ),

        Tool(
            name: "ax_clipboard_get",
            description: "Read the current macOS clipboard contents. Returns text, or lists available data types if the clipboard contains non-text data.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])])
        ),

        Tool(
            name: "ax_clipboard_set",
            description: "Write text to the macOS clipboard. Combine with ax_key(key='v', modifiers=['cmd']) to paste into an app.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("text")]),
                "properties": .object([
                    "text": .object(["type": .string("string"), "description": .string("Text to place on the clipboard")]),
                ])
            ])
        ),

        Tool(
            name: "ax_scroll",
            description: """
            Scroll inside an app window or a specific element. \
            Provide element_id to target a specific scroll area (from ax_find_elements), \
            or provide app/bundle_id to scroll the focused window center.

            direction: up, down, left, right (default: down)
            amount: scroll lines (default: 3)
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs.merging([
                    "direction":  .object(["type": .string("string"),  "description": .string("Scroll direction: up, down, left, right (default: down)")]),
                    "amount":     .object(["type": .string("integer"), "description": .string("Number of scroll lines (default: 3)")]),
                    "element_id": .object(["type": .string("integer"), "description": .string("Element to scroll at (from ax_get_tree or ax_find_elements)")]),
                ], uniquingKeysWith: { $1 }))
            ])
        ),

        Tool(
            name: "ax_wait_for",
            description: """
            Poll an app's AX tree until an element matching query appears, or until timeout expires. \
            Use after ax_press to wait for a dialog or result element before continuing. \
            Returns the matched element ID ready for immediate use in write tools.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("query")]),
                "properties": .object(appArgs.merging([
                    "query":   .object(["type": .string("string"),  "description": .string("Text to wait for (role, label, title, or any searchable field)")]),
                    "timeout": .object(["type": .string("integer"), "description": .string("Max wait in seconds (default: 10)")]),
                ], uniquingKeysWith: { $1 }))
            ])
        ),

        Tool(
            name: "ax_launch_app",
            description: "Launch a macOS application by bundle ID. The app must be installed on the system. Use ax_list_apps after launching to confirm the app is running.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("bundle_id")]),
                "properties": .object([
                    "bundle_id": .object(["type": .string("string"), "description": .string("Bundle identifier of the app to launch, e.g. com.apple.Safari")]),
                ])
            ])
        ),

        Tool(
            name: "ax_quit_app",
            description: "Quit a running macOS application gracefully (equivalent to Cmd+Q). Provide app name, bundle_id, or pid.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(appArgs)
            ])
        ),
    ]
}

// MARK: - sdef XML parser

private final class SdefParser: NSObject, XMLParserDelegate {
    private struct SuiteDef {
        var name: String
        var classes: [ClassDef] = []
        var commands: [CommandDef] = []
    }
    private struct ClassDef {
        var name: String
        var description: String
        var properties: [(name: String, type: String, access: String)] = []
    }
    private struct CommandDef {
        var name: String
        var description: String
        var params: [(name: String, type: String)] = []
        var result: String?
    }

    private var suites: [SuiteDef] = []
    private var currentSuite: SuiteDef?
    private var currentClass: ClassDef?
    private var currentCommand: CommandDef?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch elementName {
        case "suite":
            currentSuite = SuiteDef(name: attributes["name"] ?? "?")
        case "class" where currentSuite != nil:
            currentClass = ClassDef(name: attributes["name"] ?? "?",
                                    description: attributes["description"] ?? "")
        case "property" where currentClass != nil:
            currentClass?.properties.append((
                name:   attributes["name"] ?? "?",
                type:   attributes["type"] ?? "any",
                access: attributes["access"] ?? "rw"
            ))
        case "command" where currentSuite != nil:
            currentCommand = CommandDef(name: attributes["name"] ?? "?",
                                        description: attributes["description"] ?? "")
        case "parameter" where currentCommand != nil:
            currentCommand?.params.append((
                name: attributes["name"] ?? "?",
                type: attributes["type"] ?? "any"
            ))
        case "direct-parameter" where currentCommand != nil:
            currentCommand?.params.append((name: "_", type: attributes["type"] ?? "any"))
        case "result" where currentCommand != nil:
            currentCommand?.result = attributes["type"]
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "suite":
            if let s = currentSuite { suites.append(s) }
            currentSuite = nil; currentClass = nil; currentCommand = nil
        case "class":
            if let c = currentClass { currentSuite?.classes.append(c) }
            currentClass = nil
        case "command":
            if let c = currentCommand { currentSuite?.commands.append(c) }
            currentCommand = nil
        default:
            break
        }
    }

    func summary(appName: String) -> String {
        if suites.isEmpty { return "\(appName) is not scriptable (empty dictionary)." }
        var lines = ["# AppleScript Dictionary: \(appName)", ""]
        for suite in suites {
            lines.append("## \(suite.name)")
            if !suite.classes.isEmpty {
                lines.append("### Classes")
                for cls in suite.classes {
                    let desc = cls.description.isEmpty ? "" : " — \(cls.description)"
                    lines.append("**\(cls.name)**\(desc)")
                    for p in cls.properties {
                        lines.append("  - \(p.name): \(p.type) [\(p.access)]")
                    }
                }
            }
            if !suite.commands.isEmpty {
                lines.append("### Commands")
                for cmd in suite.commands {
                    let params = cmd.params.isEmpty ? "" :
                        "(\(cmd.params.map { "\($0.name): \($0.type)" }.joined(separator: ", ")))"
                    let result = cmd.result.map { " → \($0)" } ?? ""
                    let desc   = cmd.description.isEmpty ? "" : " — \(cmd.description)"
                    lines.append("  **\(cmd.name)**\(params)\(result)\(desc)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
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
