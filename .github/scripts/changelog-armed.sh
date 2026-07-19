#!/usr/bin/env bash
set -euo pipefail

# changelog-armed.sh [<changelog>] [<version-file>] — assert that
# CHANGELOG.md is ARMED: that there is a heading for the next PR's entry to
# land under, and that it is the right one for the state this tree is in.
#
# The failure it exists to catch (#108, heavy-duty/rig#66) leaves no trace:
# the ceremony PR stamps '## Unreleased' into '## X.Y.Z — DATE' by hand, and
# nothing puts the heading back. A PR authored BEFORE the release wrote its
# entry under '## Unreleased'; that heading is gone by the time it merges, so
# git lands the entry under whatever heading now occupies that position — the
# just-shipped section — CLEANLY, with no conflict. The one signal an author
# would trust ("git told me to look") is absent exactly when the result is
# wrong, and the drift is only ever discovered by reading the file.
#
# The rule, keyed on VERSION, because the two states are genuinely different:
#
#   VERSION ends in -dev  ->  the top section MUST be '## Unreleased'
#   VERSION is bare       ->  the top section may be '## Unreleased' (armed,
#                             the ceremony's own re-arm) or the stamped
#                             section for exactly that VERSION — AND the
#                             section for that VERSION must exist and carry
#                             prose, because it is the one about to ship
#
# Keying on VERSION is the whole design, and the reason this is not simply
# "require '## Unreleased'". That unconditional form is what rig#44 and
# heavy-duty/cast#108 had to REVERT: it is false by construction on the
# ceremony PR's own tree, which makes the release unshippable through a green
# CI. Anyone tempted to simplify this back should read those two first.
#
# The consequence worth stating plainly: a ceremony PR that stamps and forgets
# to re-arm still passes here — its VERSION is bare, and a bare tree is
# allowed to be stamped. It goes red the moment the '-dev' bump lands on main,
# which release.yml does automatically in the same job as the publish. So the
# guard does not block the release; it refuses to let main SIT disarmed, which
# is the window a late PR can fall into.
#
# A file of its own (not inlined in ci.yml) so test/release.sh can drive it
# against constructed trees for both states — the same discipline as
# release-notes.sh.

changelog="${1:-CHANGELOG.md}"
version_file="${2:-VERSION}"

# release-notes.sh lives beside this script; the bare-VERSION branch runs it
# rather than re-implementing the extraction, so the guard and the publisher
# cannot disagree about what a section is or when one counts as empty.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$changelog" ]    || { echo "changelog-armed: no such file: $changelog" >&2; exit 1; }
[ -f "$version_file" ] || { echo "changelog-armed: no such file: $version_file" >&2; exit 1; }

ver="$(tr -d '[:space:]' < "$version_file")"
[ -n "$ver" ] || { echo "changelog-armed: $version_file is empty" >&2; exit 1; }

# The TOP section: the first '## ' heading in the file. Everything above it is
# the changelog's own preamble and belongs to no section.
top="$(grep -m1 '^## ' "$changelog" || true)"
[ -n "$top" ] || {
  echo "changelog-armed: $changelog has no '## ' section at all — nothing for a PR entry to land under" >&2
  exit 1
}

# '## 0.7.0 — 2026-07-19' -> '0.7.0'. Split on whitespace, same shape
# release-notes.sh matches on, so the two cannot disagree about what a
# section header is.
top_ver="$(printf '%s\n' "$top" | awk '{ print $2 }')"

case "$ver" in
  *-dev)
    if [ "$top_ver" != "Unreleased" ]; then
      cat >&2 <<EOF
changelog-armed: VERSION is '$ver' (a development tree) but the top section of
  $changelog is:

    $top

  A -dev tree MUST carry '## Unreleased' at the top. Without it, a PR that
  wrote its entry under '## Unreleased' before the release merges CLEANLY into
  the section above — the one that already shipped — and the changelog quietly
  misattributes it (#108, heavy-duty/rig#66).

  The fix is to re-arm: add an empty '## Unreleased' immediately above
  '$top'. The release ceremony is supposed to do this in the same edit that
  stamps the version — see CONTRIBUTING.md, "Releases".
EOF
      exit 1
    fi
    ;;
  *)
    # A bare VERSION is the ceremony tree and the merge commit that publishes
    # it. Both arrangements are legal there: re-armed ('## Unreleased' back on
    # top, above the section just stamped) or not yet re-armed (the stamped
    # section still on top). What is NOT legal is a stamped top section naming
    # some OTHER version — that is a ceremony that stamped the wrong number,
    # and release.yml would publish a body that is not this release's.
    if [ "$top_ver" != "Unreleased" ] && [ "$top_ver" != "$ver" ]; then
      cat >&2 <<EOF
changelog-armed: VERSION is '$ver' but the top section of $changelog is:

    $top

  A bare VERSION means this tree is a release. Its top section must be either
  '## Unreleased' (re-armed after stamping) or the stamped section for '$ver'
  itself. A stamped section naming a different version means the ceremony
  stamped the wrong number, and the published release body would come from
  the wrong section.
EOF
      exit 1
    fi
    # The top heading is deliberately left UNCONSTRAINED above — both ceremony
    # shapes must stay legal, which is the #44 / cast#108 lesson and is not
    # negotiable. That asymmetry leaves a gap of its own, the HALF-ceremony
    # tree: VERSION bumped to the release, a populated '## Unreleased' still on
    # top, and no stamped section for the version anywhere. The test above is
    # false on its first clause, short-circuits, and passes. Nothing else
    # refuses until release.yml extracts the notes — which happens AFTER the
    # merge, on main, and publishes a release with an empty body, the worst
    # place for this to land. So make the same assert one step earlier by
    # running the very script release.yml runs (heavy-duty/rig#67).
    if ! bash "$here/release-notes.sh" "$ver" "$changelog" >/dev/null 2>&1; then
      cat >&2 <<EOF
changelog-armed: VERSION is '$ver' but $changelog has no non-empty section for
  '$ver'. The top section is:

    $top

  This is a HALF-DONE ceremony: the version was bumped but its section was
  never stamped — the stamp is MISSING, not misnumbered. A bare VERSION means
  this tree is a release, and the section it is about to publish has to exist
  and have prose in it. Left alone, this passes CI, merges, and only then does
  release.yml refuse to extract the notes — on main, after the fact, with the
  release already half-shipped.

  The fix is the ceremony's first edit (CONTRIBUTING.md, "Releases"): stamp
  '## Unreleased' into '## $ver — DATE', then put an empty '## Unreleased'
  back above it.
EOF
      exit 1
    fi
    ;;
esac

echo "changelog-armed: VERSION '$ver' agrees with the top section ($top_ver)"
