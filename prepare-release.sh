#!/usr/bin/env bash
# =============================================================================
#  RADS_WEB — prepare-release.sh
#  Packages the RADS_WEB application bundle for deployment / GitHub release.
#  Run from the repo root.  Produces: rads-web-<version>.tar.gz
# =============================================================================
set -euo pipefail

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")}"
TARBALL="rads-web-${VERSION}.tar.gz"
STAGING="rads-web-${VERSION}"

echo "==> Preparing RADS_WEB release: ${VERSION}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ -f "RADS_WEBInstall.sh" ]] || { echo "ERROR: Run from the RADS_WEB repo root"; exit 1; }

# ── Clean up old builds ───────────────────────────────────────────────────────
rm -rf "${STAGING}" "${TARBALL}"
mkdir -p "${STAGING}"

# ── Copy app files ────────────────────────────────────────────────────────────
echo "==> Copying application files..."
cp -r api            "${STAGING}/api"
cp -r ui             "${STAGING}/ui"
cp requirements.txt  "${STAGING}/"

# Installer scripts
cp RADS_WEB-Installer.sh  "${STAGING}/"
cp RADS_WEBInstall.sh     "${STAGING}/"
cp EASY_INSTALL           "${STAGING}/"

# Optional extras if present
for f in README.md LICENSE CHANGELOG.md; do
    [[ -f "$f" ]] && cp "$f" "${STAGING}/" && echo "   + $f"
done

# ── Set permissions ───────────────────────────────────────────────────────────
echo "==> Setting permissions..."
chmod 755 "${STAGING}/RADS_WEB-Installer.sh"
chmod 755 "${STAGING}/RADS_WEBInstall.sh"
chmod 755 "${STAGING}/EASY_INSTALL"
chmod -R 644 "${STAGING}/api/"
chmod -R 644 "${STAGING}/ui/"
find "${STAGING}/api" -name "*.py" -exec chmod 644 {} \;

# ── Create tarball ────────────────────────────────────────────────────────────
echo "==> Creating tarball..."
tar -czf "${TARBALL}" "${STAGING}/"
rm -rf "${STAGING}"

# ── Checksum ──────────────────────────────────────────────────────────────────
sha256sum "${TARBALL}" > "${TARBALL}.sha256"

echo ""
echo "==> Release ready:"
echo "    ${TARBALL}"
echo "    ${TARBALL}.sha256"
ls -lh "${TARBALL}"
