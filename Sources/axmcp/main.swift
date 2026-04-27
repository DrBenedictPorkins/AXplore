import Foundation
import AXploreCore

let args = CommandLine.arguments.dropFirst()

if args.contains("--version") {
    print("axmcp \(axmcpVersion)")
    exit(0)
}

if args.contains("--help") || args.contains("-h") {
    print("""
    axmcp \(axmcpVersion)
    MCP server for macOS Accessibility automation.

    axmcp is launched automatically by Claude Code and Claude Desktop.
    Do not run it manually — it communicates over stdin/stdout (MCP protocol).

    Options:
      --version    Print version and exit
      --help       Print this message and exit
    """)
    exit(0)
}

// Run the MCP server — blocks until stdin closes (client disconnects)
let server = AXMCPServer()
do {
    try await server.run()
} catch {
    fputs("axmcp fatal error: \(error)\n", stderr)
    exit(1)
}
