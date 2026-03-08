import Foundation

// Run the MCP server — blocks until stdin closes (client disconnects)
let server = AXMCPServer()
do {
    try await server.run()
} catch {
    fputs("axmcp fatal error: \(error)\n", stderr)
    exit(1)
}
