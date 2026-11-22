#!/bin/bash
# Prints the notes for a GitHub release: how to install, and the SHA-256 of each file.
# Runs in GitHub Actions; needs GITHUB_REPOSITORY and GH_TOKEN.
#
#   scripts/release_notes.sh v1.0.0 MyOpenCleaner-1.0.0.dmg MyOpenCleaner-1.0.0.zip > notes.md
set -euo pipefail

TAG="${1:?usage: release_notes.sh <tag> <dmg> <zip>}"
DMG="${2:?usage: release_notes.sh <tag> <dmg> <zip>}"
ZIP="${3:?usage: release_notes.sh <tag> <dmg> <zip>}"
URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}"

cat <<EOF
## Download

**[$(basename "$DMG")]($URL/$(basename "$DMG"))** — one app for Apple silicon and Intel Macs, macOS 14 Sonoma or later. Also as a [zip]($URL/$(basename "$ZIP")).

1. Open the disk image and drag **MyOpenCleaner** onto **Applications**.
2. Open it. macOS will say it cannot check the app for malicious software, because the app is not notarized by Apple.
3. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to MyOpenCleaner. You only do this once.

Prefer Terminal? \`xattr -dr com.apple.quarantine /Applications/MyOpenCleaner.app\` does the same.

The app was built from this tag's source by GitHub Actions and is signed ad hoc. You can always build it yourself instead: \`./build.sh --install\`.

### SHA-256

\`\`\`
$(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")")
$(cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")")
\`\`\`

EOF
gh api "repos/${GITHUB_REPOSITORY}/releases/generate-notes" -f tag_name="$TAG" -q .body
