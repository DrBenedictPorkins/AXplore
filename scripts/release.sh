#!/usr/bin/env bash
set -euo pipefail

VERSION_FILE="Sources/AXploreCore/Version.swift"

# ── Read current version ───────────────────────────────────────────────────────
CURRENT=$(grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$VERSION_FILE" | head -1 | tr -d '"')
if [[ -z "$CURRENT" ]]; then
    echo "error: could not find version string in $SERVER_FILE" >&2
    exit 1
fi

MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)

TAG="RELEASE-${MAJOR}.${MINOR}.${PATCH}"

echo "Current version : $CURRENT"
echo "Release tag     : $TAG"

# ── Guard: tag must not already exist ─────────────────────────────────────────
if git tag | grep -qx "$TAG"; then
    echo "error: tag $TAG already exists — bump the version first" >&2
    exit 1
fi

# ── Guard: working tree must be clean ─────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree has uncommitted changes — commit or stash first" >&2
    exit 1
fi

# ── Confirm ────────────────────────────────────────────────────────────────────
read -r -p "Tag $TAG on current HEAD and bump to next minor? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Create and push release tag ───────────────────────────────────────────────
echo ""
echo "Tagging $TAG..."
git tag "$TAG"
git push origin "$TAG"

# ── Bump minor version in source ──────────────────────────────────────────────
NEXT_MINOR=$((MINOR + 1))
NEXT="${MAJOR}.${NEXT_MINOR}.0"

echo "Bumping version $CURRENT → $NEXT..."
sed -i '' "s/axmcpVersion = \"${CURRENT}\"/axmcpVersion = \"${NEXT}\"/" "$VERSION_FILE"

git add "$VERSION_FILE"
git commit -m "Bump version to $NEXT after $TAG release"
git push origin main

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Released $TAG"
echo " Next version: $NEXT (working toward RELEASE-${MAJOR}.${NEXT_MINOR}.0)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
