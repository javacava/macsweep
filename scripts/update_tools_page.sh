#!/bin/bash
# Regenerates the list in docs/tools/index.html from the app's own catalog
# (`MyOpenCleaner --list-tools --html`). A test fails when the page and the app disagree.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -q
BIN="$(swift build --show-bin-path)/MyOpenCleaner"
PAGE=docs/tools/index.html

FRAGMENT="$(mktemp)"
trap 'rm -f "$FRAGMENT"' EXIT
"$BIN" --list-tools --html > "$FRAGMENT"

FRAGMENT="$FRAGMENT" perl -0pi -e '
    BEGIN { local $/; open my $f, "<", $ENV{FRAGMENT} or die; $new = <$f>; close $f }
    s/(<!-- tools:start -->\n).*?(<!-- tools:end -->)/$1$new$2/s or die "markers not found\n";
' "$PAGE"
echo "Updated $PAGE"
