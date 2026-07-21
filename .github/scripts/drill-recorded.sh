#!/usr/bin/env bash
set -euo pipefail

# drill-recorded.sh [<drills-dir>] [<version-file>] — assert that a RELEASE
# tree carries a drill record: that the full real-hardware drill this repo
# says a release rests on was actually run for this version, and written
# down as drills/<version>.md.
#
# CONTRIBUTING.md has said since #96 that "this PR is where the release
# ritual hangs: the full drill on real hardware, recorded". No release ever
# did it. #95, #114 and #148 all shipped as a VERSION bump plus a
# CHANGELOG.md stamp and nothing else. That is three releases through the
# same gap, because the gate was a sentence in a document and the only thing
# standing on it was a reviewer remembering to ask. A reviewer finally did —
# which is the point: the ONE time it was caught is the time somebody
# happened to look, and that is not a gate, it is luck with good manners.
#
# So the rule moves into CI, where it fires on every release PR whether or
# not anyone is paying attention. It is keyed on VERSION for the same reason
# changelog-armed.sh is — the two states are genuinely different:
#
#   VERSION ends in -dev  ->  PASS. A development tree ships nothing, so
#                             there is nothing for it to have proven. Almost
#                             every PR in this repo is this case, and a guard
#                             that nagged all of them would be turned off.
#   VERSION is bare       ->  the ceremony tree, the one about to ship.
#                             <drills-dir>/<version>.md MUST exist and carry
#                             at least one non-whitespace character.
#
# ONE FILE PER VERSION, and that is the whole design. Records used to be
# sections sharing drill/RUNS.md, and every hard edge this script used to
# have existed only because of that sharing: em-dash field matching, an
# optional ' — DATE' tail, whole-version comparison so '0.9.0-rc1' could not
# satisfy '0.9.0', avoiding '\x' escapes because CI runs mawk not gawk, and a
# non-blank body rule to tell an empty section from a filled one. Two
# separate defects were found in review because of that complexity — a
# `sed '/./,$!d'` whitespace bypass, and heading-grammar drift from the
# sibling repos. Splitting the file makes almost all of it UNREPRESENTABLE:
# '0.9.0.md' and '0.9.0-rc1.md' are simply different files, so whole-version
# matching is free rather than a trap, and there is no grammar left to drift.
#
# The directory is plain 'drills', NOT '.drills'. A dot-directory is
# invisible to a glob without dotglob, which is exactly what caused #116 and
# #118 in this repo; evidence a sweep cannot see is evidence that goes
# missing quietly.
#
# drills/ is RELEASE EVIDENCE, one file per shipped version. It is NOT
# drill/RUNS.md, which stays exactly as it is: the harness's own run log,
# traps table and lore, a different artifact with a different purpose. This
# guard reads drills/ and never looks at drill/RUNS.md.
#
# What this guard asserts is a RECORD, deliberately — not a passing drill.
# CI cannot run the drill: it wants real hardware, a real Incus, and the
# better part of an hour (see ci.yml, which says exactly this about the
# rehearsal job it runs instead). What CI can do is refuse to let a release
# claim a ritual it left no evidence of. That also leaves the maintainer
# waiver intact and honest: a release that must ship without a full drill
# records WHY in its own file, which is a deliberate, reviewable commit in
# the diff — rather than the silent skip that got us here.
#
# A file of its own (not inlined in ci.yml) so test/release.sh can drive it
# against constructed trees for both states — the same discipline as
# changelog-armed.sh and release-notes.sh.

drills="${1:-drills}"
version_file="${2:-VERSION}"

# A missing or empty version file is an ERROR, never a silent pass. A guard
# that cannot read the version cannot know whether this tree is its business,
# and "could not tell" must not resolve to "allowed".
[ -f "$version_file" ] || { echo "drill-recorded: no such file: $version_file" >&2; exit 1; }

ver="$(tr -d '[:space:]' < "$version_file")"
[ -n "$ver" ] || { echo "drill-recorded: $version_file is empty" >&2; exit 1; }

case "$ver" in
  *-dev)
    # Nothing to assert, and saying so is the point: the operator reading a
    # green log should be able to tell "the guard passed" from "the guard
    # decided this tree was not its business".
    echo "drill-recorded: VERSION '$ver' is a development tree — nothing to assert; only ceremony trees ship"
    exit 0
    ;;
esac

record="$drills/$ver.md"

# The one rule that survives the rewrite, and it survives because it was
# never really about heading parsing: a file of only spaces, tabs and
# newlines is NOT a record. The first cut of the old guard extracted with
# `sed '/./,$!d'`, where `.` matches a space — so a record whose body was one
# tab satisfied a guard that promised "at least one non-blank line". An
# evidence-free release for the price of an invisible character, on the one
# check whose entire job is to demand evidence. Existence alone is a weaker
# claim than `touch` can defeat, so existence alone is not the test.
if [ ! -f "$record" ] || ! grep -q '[^[:space:]]' "$record"; then
  cat >&2 <<EOF
drill-recorded: VERSION is '$ver' — a release — and there is no drill record
  for it. The file this looks for is:

    $record

  ...with something written in it. Either the file is absent entirely, or it
  is present and blank; both mean the same thing, which is that this release
  is asserting a ritual it has left no evidence of.

  The unblock is to RUN THE DRILL (drill/drill.sh, on real hardware) and
  record it at that path — what it measured, what it found, what it cost.
  See $drills/README.md for what a record should contain. CI cannot run the
  drill for you; it can only refuse a release that never ran one.

  (drill/RUNS.md is a different artifact — the harness's own run log and
  traps. Appending there does not satisfy this guard, and is not meant to.)

  If this release must ship without a full drill, that is a maintainer's call
  to make and it is still recorded: create the same file and say plainly that
  the drill was WAIVED and why. The guard requires a record, not a passing
  result — so a skip is a visible, reviewable file in the diff rather than
  the silent gap that let #95, #114 and #148 all ship unproven. See
  CONTRIBUTING.md, "Releases".
EOF
  exit 1
fi

echo "drill-recorded: VERSION '$ver' has a drill record at $record"
