import ArgumentParser
import Foundation
import AppKit
import AXploreCore

// TraversalMode.rawValue is String so ArgumentParser can synthesize this automatically
extension TraversalMode: ExpressibleByArgument {}

public struct AXploreCommand: ParsableCommand {

    public static let configuration = CommandConfiguration(
        commandName: "axplore",
        abstract: "Inspect the Accessibility tree of any running macOS application.",
        discussion: """
        AXplore is a read-only Accessibility explorer. It discovers AX elements,
        attributes, and actions exposed by macOS applications.

        Examples:
          axplore --list-apps
          axplore --app Filmora --mode shallow
          axplore --bundle-id com.wondershare.filmoramacos --mode deep --max-depth 10
          axplore --app Safari --mode focused-window --screenshot
          axplore --app Filmora --search "Export"
        """,
        version: axmcpVersion
    )

    // MARK: - Options

    @Option(name: .long, help: "App name (partial, case-insensitive match)")
    var app: String?

    @Option(name: .customLong("bundle-id"), help: "Bundle identifier (exact match)")
    var bundleId: String?

    @Option(name: .long, help: "Process ID (overrides --app and --bundle-id)")
    var pid: Int32?

    @Option(name: .long, help: "Traversal mode: app | shallow | deep | focused-window | focused-element  (default: shallow)")
    var mode: TraversalMode = .shallow

    @Option(name: .customLong("max-depth"), help: "Maximum traversal depth (default: 8)")
    var maxDepth: Int = 8

    @Option(name: .customLong("max-nodes"), help: "Maximum total nodes to collect (default: 5000)")
    var maxNodes: Int = 5000

    @Option(name: .long, help: "Output directory for JSON/text files (default: /tmp/axplore)")
    var output: String = "/tmp/axplore"

    @Option(name: .long, help: "Search query: filter tree by role, title, description, identifier, or action name")
    var search: String?

    @Flag(name: .customLong("screenshot"), help: "Capture PNG screenshots of the app's windows (requires Screen Recording permission)")
    var captureScreenshots: Bool = false

    @Flag(name: .customLong("list-apps"), help: "List all running GUI applications and exit")
    var listApps: Bool = false

    public init() {}

    // MARK: - Entry Point

    public mutating func run() throws {

        if listApps {
            ProcessLocator.printAllRunningApps()
            return
        }

        let permission = PermissionChecker.check()
        permission.printStatus()
        guard permission.isGranted else {
            print("\nCannot proceed without Accessibility permission.")
            throw ExitCode.failure
        }

        let locator = ProcessLocator()
        let candidates: [AppProcess]

        if let pid {
            candidates = locator.findByPID(pid)
        } else if let bundleId {
            candidates = locator.findByBundleID(bundleId)
        } else if let app {
            candidates = locator.findByName(app)
        } else {
            print("Error: provide --app, --bundle-id, --pid, or --list-apps")
            throw ExitCode.failure
        }

        guard !candidates.isEmpty else {
            print("No matching application found. Use --list-apps to see what is running.")
            throw ExitCode.failure
        }

        if candidates.count > 1 {
            print("Multiple candidates found — using first. Use --pid for precision:")
            for c in candidates { c.printSummary(); print("") }
        }

        let target = candidates[0]
        print("\nTarget:")
        target.printSummary()

        if !target.isAccessible {
            print("\nWarning: \(target.name) did not respond to the AX probe.")
            print("It may require AX access or be slow to start. Continuing anyway.")
        }

        let (effectiveDepth, effectiveNodes) = adjustedLimits(for: mode)

        print("\nWalking AX tree [mode=\(mode.rawValue) maxDepth=\(effectiveDepth) maxNodes=\(effectiveNodes)]...")
        let axApp  = AXUIElementCreateApplication(target.pid)
        let walker = AXTreeWalker(maxDepth: effectiveDepth, maxNodes: effectiveNodes)

        let roots: [AXElementSnapshot]
        switch mode {
        case .app, .shallow, .deep:
            roots = walker.walkAppRoots(axApp)
        case .focusedWindow:
            roots = walker.walkFocusedWindow(axApp)
        case .focusedElement:
            roots = walker.walkFocusedElement(axApp)
        }

        let allNodes = flatten(roots)
        print("Nodes collected: \(allNodes.count)")

        var searchResults: [AXElementSnapshot]? = nil
        if let query = search {
            searchResults = SearchFilter.search(allNodes, query: query)
            print("Search '\(query)': \(searchResults!.count) match(es)")
        }

        let analysis    = AXSummaryAnalyzer(nodes: allNodes).analyze()
        let focusedCtx  = FocusedContextReader.read(appElement: axApp)
        let outDir      = makeOutputDir(base: output)

        var screenshotPaths: [String] = []
        if captureScreenshots {
            screenshotPaths = ScreenshotCapture.captureWindows(for: target.pid, outputDir: outDir).paths
        }

        let scanResult = AXScanResult.build(
            processInfo:      target,
            permissionStatus: permission,
            traversalMode:    mode.rawValue,
            maxDepth:         effectiveDepth,
            maxNodes:         effectiveNodes,
            timestamp:        ISO8601DateFormatter().string(from: Date()),
            totalNodeCount:   allNodes.count,
            focusedContext:   focusedCtx,
            analysis:         analysis,
            screenshotPaths:  screenshotPaths,
            searchQuery:      search,
            searchResults:    searchResults,
            roots:            roots
        )

        try JSONExporter.export(scanResult, to: outDir)
        try TextTreeRenderer.export(roots: roots, analysis: analysis, focusedContext: focusedCtx, to: outDir)

        analysis.printConsole()

        if let results = searchResults {
            print("\n--- Search results for '\(search!)' (\(results.count) matches) ---")
            for node in results.prefix(50) {
                let label = node.title ?? node.elementDescription ?? "(no label)"
                let pos   = node.position.map { " @(\(Int($0.x)),\(Int($0.y)))" } ?? ""
                print("  id=\(node.id) depth=\(node.depth) [\(node.role ?? "?")] \"\(label)\"\(pos)")
            }
            if results.count > 50 { print("  ... and \(results.count - 50) more (see scan.json)") }
        }

        print("\nOutput directory: \(outDir)")
    }

    // MARK: - Helpers

    private func adjustedLimits(for mode: TraversalMode) -> (depth: Int, nodes: Int) {
        switch mode {
        case .shallow:
            return (min(maxDepth, 4), min(maxNodes, 500))
        case .deep:
            return (max(maxDepth, 12), max(maxNodes, 10_000))
        case .app, .focusedWindow, .focusedElement:
            return (maxDepth, maxNodes)
        }
    }

    private func makeOutputDir(base: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts  = formatter.string(from: Date())
        let dir = (base as NSString).appendingPathComponent(ts)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func flatten(_ nodes: [AXElementSnapshot]) -> [AXElementSnapshot] {
        var result: [AXElementSnapshot] = []
        for node in nodes {
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
        return result
    }
}
