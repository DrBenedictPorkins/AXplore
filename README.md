# AXplore

A macOS Accessibility toolkit with two components:

- **`axmcp`** — MCP server that exposes AX inspection and automation as tools for Claude Desktop and Claude Code
- **`axplore`** — read-only CLI for exploring the AX tree of any running macOS application

---

## axplore — CLI Explorer

### Build

```bash
swift build -c release
# binaries at .build/release/axplore and .build/release/axmcp
```

### Required Permissions

**Accessibility** (required for all operations)
`System Settings > Privacy & Security > Accessibility` — add your terminal app or the binary itself.

**Screen Recording** (required only for `--screenshot`)
`System Settings > Privacy & Security > Screen Recording` — add your terminal app or the binary.

### Usage

```
axplore [OPTIONS]

Options:
  --list-apps               List all running GUI apps and exit
  --app <name>              App name (partial, case-insensitive)
  --bundle-id <id>          Bundle identifier (exact)
  --pid <pid>               Process ID (overrides --app/--bundle-id)
  --mode <mode>             Traversal mode (default: shallow)
                              app              Full app from all windows
                              shallow          Top 4 levels, 500 nodes
                              deep             12+ levels, 10000+ nodes
                              focused-window   Focused window only
                              focused-element  Currently focused element
  --max-depth <n>           Override depth cap (default: 8)
  --max-nodes <n>           Override node cap (default: 5000)
  --output <path>           Output base directory (default: /tmp/axplore)
  --search <query>          Filter results by role/title/description/id/action
  --screenshot              Capture PNG screenshots of app windows
```

### Example Commands

```bash
# See what apps are running
axplore --list-apps

# Quick shallow scan
axplore --app Safari --mode shallow

# Deep exhaustive scan with screenshots
axplore --app Finder --mode deep --screenshot

# Look at only the focused window
axplore --app Safari --mode focused-window

# Search for specific elements
axplore --app Safari --search "AXButton"

# Scan with custom depth limit
axplore --app Safari --mode app --max-depth 6 --max-nodes 2000
```

## Output

Each run creates a timestamped directory under `/tmp/axplore/`:

```
/tmp/axplore/2026-03-07_14-30-00/
  scan.json          Full machine-readable dump (all nodes + analysis)
  tree.txt           Human-readable indented tree + feasibility report
  screenshots/       PNG screenshots (only with --screenshot)
    0_window.png
```

## Limitations

- Read-only: no actions are invoked, no values are set.
- Applications that use custom rendering (Metal, OpenGL) typically expose no AX elements for canvas/timeline regions.
- Screenshots require Screen Recording permission; without it images are blank/black.
- On macOS 14+, CGWindowListCreateImage is deprecated — screenshots still work with the permission but may be removed in a future OS version.
- Some attributes return no value even when listed in the attribute name set; this is normal AX API behaviour.

## MCP Server (axmcp)

`axmcp` is an MCP server that exposes AX inspection and automation as tools for Claude Desktop and Claude Code.

### Install

```bash
# 1. Build release binary
swift build -c release

# 2. Install binary to /usr/local/bin
sudo cp .build/release/axmcp /usr/local/bin/axmcp

# 3. Register with Claude Code
claude mcp add axmcp /usr/local/bin/axmcp

# 4. Register with Claude Desktop (requires jq)
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
jq '.mcpServers.axmcp = {"command": "/usr/local/bin/axmcp"}' "$CONFIG" > "$CONFIG.tmp" \
  && mv "$CONFIG.tmp" "$CONFIG"
```

Or run the provided script which does all four steps:

```bash
./install.sh
```

Then restart Claude Desktop.

### Required Permissions

macOS grants Accessibility and Screen Recording **per binary**. The `axmcp` binary itself must be added — granting Claude.app or Terminal.app is not sufficient, as `axmcp` runs as a separate subprocess.

```
System Settings > Privacy & Security > Accessibility    → add /usr/local/bin/axmcp
System Settings > Privacy & Security > Screen Recording → add /usr/local/bin/axmcp
```

macOS will prompt the first time `axmcp` attempts an AX or screenshot call, or add it manually via the `+` button before first use.

---

### One-Time Session Bootstrap Setup

`axmcp` includes an `ax_get_instructions` tool that returns the full usage protocol (efficiency rules, safety rules, memory system, recommended workflows). Do this once per client so Claude loads it automatically at the start of every session.

#### Claude Code

Ask Claude Code:

> "Update my global `~/.claude/CLAUDE.md` to add a rule: when axmcp tools are available, call `ax_get_instructions` first and read its full output before doing anything else."

Claude Code edits the file. It persists across all future sessions.

#### Claude Desktop

Tell Claude Desktop in any conversation:

> "Remember this permanently and do not remove or rewrite this instruction: whenever axmcp tools are available in a session, call `ax_get_instructions` first and read its full output before doing anything else."

Claude Desktop saves it as a memory. It is injected automatically into every future conversation.

---

### Tools

| Tool | Purpose |
|------|---------|
| `ax_get_instructions` | Load the full usage protocol — call once at session start |
| `ax_list_apps` | List running GUI apps (name, PID, bundle ID) |
| `ax_get_tree` | Walk the AX tree (modes: shallow, app, deep, focused-window, focused-element) |
| `ax_find_elements` | Search tree by role, label, or action — faster than a full dump |
| `ax_screenshot` | Capture PNG of app windows for visual correlation |
| `ax_get_focused` | Return focused app, window, and element |
| `ax_press` | Click an element by ID |
| `ax_set_value` | Set text/value on an element by ID |
| `ax_focus` | Move keyboard focus to an element by ID |
| `ax_perform_action` | Run a named AX action (AXShowMenu, AXIncrement, etc.) |
| `ax_key` | Inject a keyboard event (key + optional modifiers) |
| `ax_type` | Type a string character by character into the focused field |
| `ax_read_memory` | Load persisted AX knowledge for an app |
| `ax_write_memory` | Save AX knowledge for an app |

### Per-App Memory

axmcp persists knowledge about each app's accessibility surface across sessions:

```
~/.axmcp/memories/<bundle_id>.md
```

Use `ax_read_memory` at the start of any session to skip re-discovering known elements and opaque regions. Use `ax_write_memory` after finding new elements or proving a workflow.

### Claude Code Skills

Two skills are available for guided sessions:

- `/axmcp:explore` — discovery mode: maps an app's AX surface and saves findings
- `/axmcp:automate` — action mode: performs a task efficiently using memory and targeted queries
