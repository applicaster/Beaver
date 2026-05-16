#!/usr/bin/env bash
# release.sh — build, sign, notarize, and staple a LoggerNext .pkg.
#
# Replaces the 12-step manual README from the old Logger project (D13).
# Designed to run locally or in CI.
#
# Required environment variables:
#   APPLE_ID                   Apple ID with notarization access
#   APPLE_APP_PASSWORD         App-specific password for APPLE_ID
#   APPLE_TEAM_ID              10-character team identifier
#   DEVELOPER_ID_INSTALLER     Common name of your Developer ID Installer cert
#                              (e.g., "Developer ID Installer: Acme Corp (ABCDE12345)")
#   DEVELOPER_ID_APPLICATION   Common name of your Developer ID Application cert
#   BUNDLE_ID                  e.g., com.applicaster.LoggerNext
#
# Optional:
#   CONFIGURATION              Defaults to Release
#   BUILD_DIR                  Defaults to ./build
#
# Usage:
#   ./scripts/release.sh
#
# Output:
#   build/LoggerNext-<version>-signed-notarized.pkg

set -euo pipefail

# -- TODO: fill in once Xcode project is scaffolded -------------------
# 1. xcodebuild archive  → LoggerNext.app
# 2. codesign            → sign .app with DEVELOPER_ID_APPLICATION
# 3. productbuild        → LoggerNext.pkg
# 4. productsign         → sign .pkg with DEVELOPER_ID_INSTALLER
# 5. notarytool submit   → wait for Apple's response
# 6. stapler staple      → attach the ticket
# 7. pkgutil --check-signature  → verify before publishing
# --------------------------------------------------------------------

echo "release.sh: not yet implemented — see TODO list above."
exit 1
