#!/usr/bin/env bash
set -euo pipefail

# release-notes.sh <version> [<changelog>] — print exactly <version>'s
# section of the changelog: every line between its '## <version> — <date>'
# header and the next '## '. This is what release.yml hands to
# 'gh release create', so the release notes are the curated prose we wrote,
# not the PR list GitHub would generate (#83). Fails loudly when the section
# is missing or empty — a tag without its changelog section is a release
# ritual skipped, and an empty release body would paper over it.
#
# A file of its own (not inlined in release.yml) so test/release.sh drives
# the same extraction against fixtures and the real CHANGELOG.md.

ver="${1:-}"
changelog="${2:-CHANGELOG.md}"
[ -n "$ver" ] || { echo "usage: release-notes.sh <version> [<changelog>]" >&2; exit 2; }
[ -f "$changelog" ] || { echo "release-notes: no such file: $changelog" >&2; exit 1; }

# $2 of a section header ('## 0.6.0 — 2026-07-18') is the bare version —
# compared WHOLE, so 0.6.0 can never match a 0.6.0-rc1 section (or vice
# versa), and no regex-escaping of dots. sed drops the blank padding under
# the header; the command substitution eats the trailing blanks.
notes="$(awk -v ver="$ver" '
  /^## / { grab = ($2 == ver); next }
  grab   { print }
' "$changelog" | sed '/./,$!d')"

[ -n "$notes" ] || { echo "release-notes: $changelog has no section for '$ver' — the release PR stamps the Unreleased section with version + date BEFORE the tag (#83)" >&2; exit 1; }
printf '%s\n' "$notes"
