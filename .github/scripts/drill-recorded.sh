#!/usr/bin/env bash
set -euo pipefail

# drill-recorded.sh [<runs-file>] [<version-file>] — assert that a RELEASE
# tree carries a drill record: that the full real-hardware drill this repo
# says a release rests on was actually run for this version, and written
# down in drill/RUNS.md.
#
# CONTRIBUTING.md has said since #96 that "this PR is where the release
# ritual hangs: the full drill on real hardware, recorded in drill/RUNS.md".
# No release has ever done it. #95, #114 and #148 all shipped as a VERSION
# bump plus a CHANGELOG.md stamp and nothing else, and the file they were
# supposed to append to has no '## Release drill' section anywhere in it.
# That is three releases through the same gap, because the gate was a
# sentence in a document and the only thing standing on it was a reviewer
# remembering to ask. A reviewer finally did — which is the point: the ONE
# time it was caught is the time somebody happened to look, and that is not a
# gate, it is luck with good manners.
#
# So the rule moves into CI, where it fires on every release PR whether or
# not anyone is paying attention. The rule, keyed on VERSION for the same
# reason changelog-armed.sh is — the two states are genuinely different:
#
#   VERSION ends in -dev  ->  PASS. A development tree ships nothing, so
#                             there is nothing for it to have proven. Almost
#                             every PR in this repo is this case, and a guard
#                             that nagged all of them would be turned off.
#   VERSION is bare       ->  the ceremony tree, the one about to ship.
#                             drill/RUNS.md MUST carry a section headed
#                             '## Release drill — <version>' (optionally with
#                             ' — <date>' after it), and that section must
#                             have prose in it.
#
# What this guard asserts is a RECORD, deliberately — not a passing drill.
# CI cannot run the drill: it wants real hardware, a real Incus, and the
# better part of an hour (see ci.yml, which says exactly this about the
# rehearsal job it runs instead). What CI can do is refuse to let a release
# claim a ritual it left no evidence of. That also leaves the maintainer
# waiver intact and honest: a release that must ship without a full drill
# records WHY under its own heading, which is a deliberate, reviewable commit
# in the diff — rather than the silent skip that got us here.
#
# A file of its own (not inlined in ci.yml) so test/release.sh can drive it
# against constructed trees for both states — the same discipline as
# changelog-armed.sh and release-notes.sh.

runs="${1:-drill/RUNS.md}"
version_file="${2:-VERSION}"

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

[ -f "$runs" ] || { echo "drill-recorded: no such file: $runs" >&2; exit 1; }

# The section for this version: everything between its own heading and the
# next '## '. The version is compared WHOLE — as a field, never as a
# substring or a regex — so '0.9.0' can never be satisfied by a
# '0.9.0-rc1' section (or vice versa), and there are no dots to escape.
# release-notes.sh solves the identical trap the identical way; the two
# scripts must not disagree about what "the section for X" means.
#
# The heading shape is '## Release drill — <ver>' with an OPTIONAL
# ' — <date>' tail, i.e. fields: '##' 'Release' 'drill' '—' '<ver>' ['—' ...].
# Pinning the leading fields as well as the version keeps some other '## '
# heading that merely mentions the number from counting as a record.
#
# The em dash is passed IN as a variable rather than written into the awk
# program, because '\x' escapes in an awk string are a gawk extension and CI
# runs on ubuntu-latest, where awk is mawk.
record="$(awk -v ver="$ver" -v dash="—" '
  /^## / {
    grab = ($2 == "Release" && $3 == "drill" && $4 == dash && $5 == ver \
            && (NF == 5 || $6 == dash))
    next
  }
  grab { print }
' "$runs" | sed '/./,$!d')"

if [ -z "$record" ]; then
  cat >&2 <<EOF
drill-recorded: VERSION is '$ver' — a release — and $runs has no drill record
  for it. The heading this looks for is:

    ## Release drill — $ver — DATE

  ...with at least one non-blank line under it. Either the section is absent
  entirely, or it is present and empty; both mean the same thing, which is
  that this release is asserting a ritual it has left no evidence of.

  The unblock is to RUN THE DRILL (drill/drill.sh, on real hardware) and
  record it in $runs under that heading — what it measured, what it found,
  what it cost. CI cannot run the drill for you; it can only refuse a release
  that never ran one.

  If this release must ship without a full drill, that is a maintainer's call
  to make and it is still recorded: write the section under the same heading
  and say plainly that the drill was WAIVED and why. The guard requires a
  record, not a passing result — so a skip is a visible, reviewable line in
  the diff rather than the silent gap that let #95, #114 and #148 all ship
  unproven. See CONTRIBUTING.md, "Releases".
EOF
  exit 1
fi

echo "drill-recorded: VERSION '$ver' has a drill record in $runs"
