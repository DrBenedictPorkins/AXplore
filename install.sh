#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BINARY="$INSTALL_DIR/axmcp"
DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

cc_status="skipped"
cd_status="skipped"

confirm() {
    local prompt="$1"
    local reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "Building axmcp (release)..."
swift build -c release 2>&1 | tail -1

# ── 2. Install binary ─────────────────────────────────────────────────────────
echo "Installing binary to $BINARY..."
if [[ "$INSTALL_DIR" == /usr/local/bin ]]; then
    sudo cp .build/release/axmcp "$BINARY"
    sudo chmod +x "$BINARY"
else
    cp .build/release/axmcp "$BINARY"
    chmod +x "$BINARY"
fi

# ── 3. Claude Code ────────────────────────────────────────────────────────────
echo ""
if command -v claude &>/dev/null; then
    if confirm "Register axmcp with Claude Code?"; then
        claude mcp remove axmcp --scope user 2>/dev/null || true
        claude mcp add --scope user axmcp "$BINARY"
        cc_status="registered"
    else
        cc_status="skipped"
    fi
else
    cc_status="claude CLI not found"
fi

# ── 4. Claude Desktop ─────────────────────────────────────────────────────────
echo ""
if [[ -f "$DESKTOP_CONFIG" ]]; then
    if confirm "Register axmcp with Claude Desktop (modifies claude_desktop_config.json)?"; then
        if command -v jq &>/dev/null; then
            jq --arg bin "$BINARY" '.mcpServers.axmcp = {"command": $bin}' \
                "$DESKTOP_CONFIG" > "$DESKTOP_CONFIG.tmp" \
                && mv "$DESKTOP_CONFIG.tmp" "$DESKTOP_CONFIG"
            cd_status="registered — restart Claude Desktop to apply"
        else
            cd_status="skipped — jq not found (brew install jq, then re-run)"
        fi
    else
        cd_status="skipped"
    fi
else
    cd_status="skipped — config not found at: $DESKTOP_CONFIG"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Install summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Binary       : $BINARY"
echo " Claude Code  : $cc_status"
echo " Claude Desktop: $cd_status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Note: the axmcp server starts automatically — you never run it manually."
echo "Claude Desktop and Claude Code spawn it as a subprocess when they start."
echo ""
echo "Next steps:"
if [[ "$cc_status" == "registered" ]]; then
    echo "  Claude Code  : start a new session and run: claude mcp list"
    echo "                 axmcp tools appear automatically in the session"
elif [[ "$cc_status" == "skipped" ]]; then
    echo "  Claude Code  : to register manually:"
    echo "    claude mcp add axmcp $BINARY"
fi
if [[ "$cd_status" == registered* ]]; then
    echo "  Claude Desktop: restart the app, then click the tools (hammer) icon"
    echo "                  to confirm axmcp tools are listed"
elif [[ "$cd_status" == "skipped" ]]; then
    echo "  Claude Desktop: to register manually, add to:"
    echo "    $DESKTOP_CONFIG"
    echo '    "mcpServers": { "axmcp": { "command": "'"$BINARY"'" } }'
fi
echo ""
echo "Permissions required for the axmcp binary itself:"
echo "  System Settings > Privacy & Security > Accessibility  → add $BINARY"
echo "  System Settings > Privacy & Security > Screen Recording → add $BINARY"
echo "  (Claude.app and Terminal.app being allowed is not sufficient —"
echo "   macOS grants permissions per binary, not per parent process)"
