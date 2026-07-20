#!/usr/bin/env bash
# The release flow (#83), proven offline. Run: bash test/release.sh
#
# Three surfaces: the changelog-section extraction release.yml publishes
# (.github/scripts/release-notes.sh, driven against fixtures AND the real
# CHANGELOG.md so the header format cannot drift under it), the
# latest-release tag resolution install.sh defaults to (the extracted
# function, driven against a shim curl serving canned redirects), and the
# three install channels — REAL install.sh runs against throwaway roots,
# with the shim curl standing in for GitHub. Nothing here touches the
# network; the same discipline as test/cli.sh. Deliberately no `set -e` —
# the harness asserts on failing commands.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

NOTES="$ROOT/.github/scripts/release-notes.sh"
WORK="$(mktemp -d)"

# ---------------------------------------------------------------------------
# release-notes.sh — the extraction, against a fixture changelog that carries
# every boundary: an Unreleased section that must never leak into a release,
# two adjacent versions, a version that prefixes another (0.7.0 vs
# 0.7.0-rc1), and a stamped-but-empty section that must refuse.
# ---------------------------------------------------------------------------
check "release-notes: runnable bash" 0 "" bash -n "$NOTES"

FIX="$WORK/CHANGELOG.md"
cat > "$FIX" <<'EOF'
# Changelog

Intro prose that belongs to no section.

## Unreleased

- **Not yet released** — must never appear in a release body.

## 0.7.0 — 2026-07-20

### Added

- **The seven-oh entry** — prose for 0.7.0, and only 0.7.0.

## 0.7.0-rc1 — 2026-07-19

- **The rc entry** — must not ride along with 0.7.0.

## 0.6.0 — 2026-07-18

- **The six-oh entry** — the previous release's prose.

## 0.5.0 — 2026-07-15

EOF

check "extract: prints the asked-for version's prose"   0 "The seven-oh entry" bash "$NOTES" 0.7.0 "$FIX"
check "extract: keeps the section's own subheaders"     0 "### Added"          bash "$NOTES" 0.7.0 "$FIX"
# shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
check "extract: stops at the NEXT section"              1 ""                    bash -c 'bash "$1" 0.7.0 "$2" | grep -q "rc entry"' _ "$NOTES" "$FIX"
# shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
check "extract: never leaks Unreleased into a release"  1 ""                    bash -c 'bash "$1" 0.7.0 "$2" | grep -q "Not yet released"' _ "$NOTES" "$FIX"
# shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
check "extract: never prints the header itself"         1 ""                    bash -c 'bash "$1" 0.7.0 "$2" | grep -q "^## "' _ "$NOTES" "$FIX"
check "extract: the version is matched WHOLE (rc1 is its own section)" \
                                                        0 "The rc entry"       bash "$NOTES" 0.7.0-rc1 "$FIX"
check "extract: an adjacent older version still resolves" 0 "six-oh"           bash "$NOTES" 0.6.0 "$FIX"
check "extract: a missing version refuses by name"      1 "no section for '9.9.9'" bash "$NOTES" 9.9.9 "$FIX"
check "extract: ...and names the ritual that was skipped" 1 "#83"              bash "$NOTES" 9.9.9 "$FIX"
check "extract: a stamped-but-EMPTY section refuses"    1 "no section for '0.5.0'" bash "$NOTES" 0.5.0 "$FIX"
check "extract: no version argument is a usage error"   2 "usage:"             bash "$NOTES"
check "extract: a missing changelog refuses by path"    1 "no such file"       bash "$NOTES" 1.0.0 "$WORK/nope.md"

# The REAL changelog: released sections must keep extracting, or release.yml
# breaks the day it runs — this is the guard against header-format drift.
check "extract: the real 0.6.0 section extracts"        0 "restricted tier"    bash "$NOTES" 0.6.0 "$ROOT/CHANGELOG.md"
check "extract: the real 0.5.0 section extracts"        0 ""                   bash "$NOTES" 0.5.0 "$ROOT/CHANGELOG.md"

# ---------------------------------------------------------------------------
# release.yml — a daemon-free run cannot push a tag, so the wiring is
# grepped, fail-closed (the house discipline): the VERSION assertion, the
# shared extraction script, and that the tag is verified before creation.
# ---------------------------------------------------------------------------
RY="$ROOT/.github/workflows/release.yml"
check "release.yml: exists" 0 "" test -f "$RY"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "release.yml: asserts tag == VERSION before creating anything" 0 "" \
  grep -qF 'GITHUB_REF_NAME" != "$ver"' "$RY"
check "release.yml: the mismatch creates NOTHING (exit 1)" 0 "" \
  grep -qF 'creating nothing' "$RY"
check "release.yml: the body comes from the shared extraction script" 0 "" \
  grep -qF '.github/scripts/release-notes.sh' "$RY"
check "release.yml: the release is bound to the pushed tag (--verify-tag)" 0 "" \
  grep -qF -- '--verify-tag' "$RY"

# ---------------------------------------------------------------------------
# release.yml, the merge door (#96) — merging the release-labeled PR IS the
# release. Same daemon-free discipline: the gate, the four asserts, and the
# same-job tag+publish are grep-pinned, fail-closed.
# ---------------------------------------------------------------------------
check "release.yml: the tag-push trigger is still present (manual fallback)" 0 "" \
  grep -qF 'tags: ["**"]' "$RY"
# The merge door rides pushes to MAIN, not pull_request events: a fork PR
# run gets a read-only GITHUB_TOKEN (permissions: cannot raise it), and
# every ceremony PR this org merges is cross-repo from the bot fork — the
# tag create would 403 after green asserts (#97 round 1). The label — the
# operator's intent — is read via the API off the merge commit's PR.
check "release.yml: the merge door rides pushes to main (fork-token-proof)" 0 "" \
  grep -qF 'branches: [main]' "$RY"
check "release.yml: the doors split on the ref — tags to the tag door..." 0 "" \
  grep -qF "startsWith(github.ref, 'refs/tags/')" "$RY"
check "release.yml: ...main to the merge door" 0 "" \
  grep -qF "github.ref == 'refs/heads/main'" "$RY"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "release.yml: the release label is read via the API off the merge commit" 0 "" \
  grep -qF 'commits/$GITHUB_SHA/pulls' "$RY"
check "release.yml: a transition without a labeled PR refuses" 0 "" \
  grep -qF "no merged, release-labeled PR is behind this commit" "$RY"
check "release.yml: assert — VERSION at the merge commit is non--dev" 0 "" \
  grep -qF '*-dev)' "$RY"
check "release.yml: assert — VERSION changed IN THIS PR (first parent vs merge)" 0 "" \
  grep -qF 'git show HEAD^1:VERSION' "$RY"
check "release.yml: assert — no existing tag for the version" 0 "" \
  grep -qF 'git/ref/tags/' "$RY"
check "release.yml: assert — no existing release for the version" 0 "" \
  grep -qF 'gh release view' "$RY"
check "release.yml: BOTH doors extract notes via the shared script" 0 "2" \
  grep -cF 'bash .github/scripts/release-notes.sh' "$RY"
check "release.yml: every failing assert creates NOTHING (both doors)" 0 "5" \
  grep -cF 'creating nothing' "$RY"
check "release.yml: the merge door creates the tag ref via the API..." 0 "" \
  grep -qF 'ref=refs/tags/' "$RY"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "release.yml: ...at the MERGE commit" 0 "" \
  grep -qF 'sha=$MERGE_SHA' "$RY"
check "release.yml: BOTH doors publish bound to an existing tag (--verify-tag)" 0 "2" \
  grep -cF -- '--verify-tag' "$RY"
check "release.yml: tag + publish share one job (the anti-recursion shape)" 0 "" \
  grep -qF 'anti-recursion' "$RY"
# The decide step tells the label's two meanings apart (LABELS.md gives
# `release` to release-flow WORK as well as to the ceremony PR — the PR
# that added the merge door included): work under the label no-ops GREEN —
# in the -dev steady state and in the post-release window (bare, unchanged,
# already released) — while every half-ceremony refuses. Pin each verdict
# and the gating output.
check "release.yml: decide — dev-tree work no-ops green (not a red run per infra PR)" 0 "" \
  grep -qF "release-flow work under the release label, not a ceremony" "$RY"
check "release.yml: decide — a -dev endstate is always work (the bump PR no-ops green)" 0 "" \
  grep -qF "a dev tree is by definition not a release" "$RY"
check "release.yml: decide — post-release-window work no-ops green" 0 "" \
  grep -qF "release-flow work merged in the post-release window" "$RY"
check "release.yml: decide — bare, unchanged, never released refuses to guess" 0 "" \
  grep -qF "Refusing to guess" "$RY"
check "release.yml: decide gates every later merge-door step on ceremony=yes" 0 "4" \
  grep -cF "if: steps.decide.outputs.ceremony == 'yes'" "$RY"
# The release re-arms main itself: the post-release -dev bump is arithmetic,
# not judgment, so it rides the same job — direct push, PR fallback.
check "release.yml: the release bumps main to the next -dev itself" 0 "" \
  grep -qF "bump main to the next -dev" "$RY"
check "release.yml: ...with a PR fallback when the direct push is refused" 0 "" \
  grep -qF "opening the bump PR instead" "$RY"

# ---------------------------------------------------------------------------
# changelog-armed.sh (#108) — the changelog has a heading for the NEXT entry.
#
# The drift this catches produces no conflict and no error: the ceremony
# stamps '## Unreleased' away, and a PR authored before the release merges its
# entry cleanly into the section that just shipped. box has no top-section
# guard at all today — the two checks above pin only that the 0.6.0 and 0.5.0
# sections still extract, which a disarmed main passes happily.
#
# BOTH states are constructed as real trees and the real script is run against
# them, because the failure mode of the naive fix is precisely a state
# mismatch: an unconditional '## Unreleased' requirement is green on main and
# false on the ceremony PR's own tree, which is why rig#44 and
# heavy-duty/cast#108 both had to revert one. A test that only drives the
# -dev state would have shipped that bug again.
# ---------------------------------------------------------------------------
ARMED="$ROOT/.github/scripts/changelog-armed.sh"
check "changelog-armed: runnable bash" 0 "" bash -n "$ARMED"

# tree <dir> <version> <changelog-body...> — a two-file tree to run against
tree() {
  local d="$WORK/$1" v="$2"; shift 2
  mkdir -p "$d"
  printf '%s\n' "$v" > "$d/VERSION"
  { echo "# Changelog"; echo; printf '%s\n' "$@"; } > "$d/CHANGELOG.md"
  echo "$d"
}
armed() { bash "$ARMED" "$1/CHANGELOG.md" "$1/VERSION"; }

# --- the -dev steady state: armed is the only legal shape ------------------
T="$(tree dev-armed 0.7.1-dev '## Unreleased' '' '- **A pending entry**' '' '## 0.7.0 — 2026-07-19' '' '- **Shipped**')"
check "armed: a -dev tree with '## Unreleased' on top passes" 0 "agrees" armed "$T"
T="$(tree dev-disarmed 0.7.1-dev '## 0.7.0 — 2026-07-19' '' '- **Shipped**')"
check "armed: a -dev tree WITHOUT it fails — the #108 drift, caught" 1 "MUST carry" armed "$T"
check "armed: ...and the failure says how to fix it (re-arm)" 1 "re-arm" armed "$T"
check "armed: ...naming the issue and its origin" 1 "heavy-duty/rig#66" armed "$T"

# --- the ceremony PR: bare VERSION, BOTH arrangements legal ----------------
# This is the pair that the reverted guards got wrong. Neither may fail, or
# the release PR cannot go green and the ceremony is unshippable.
T="$(tree rel-stamped 0.7.1 '## 0.7.1 — 2026-07-19' '' '- **This release**')"
check "armed: a bare VERSION with its OWN stamped section on top passes" 0 "agrees" armed "$T"
T="$(tree rel-rearmed 0.7.1 '## Unreleased' '' '## 0.7.1 — 2026-07-19' '' '- **This release**')"
check "armed: ...and so does the RE-ARMED ceremony tree (the shape #108 asks for)" \
  0 "agrees" armed "$T"
# The one bare-VERSION arrangement that is wrong: a stamp naming another
# version. release.yml would publish a body that is not this release's.
T="$(tree rel-wrong 0.7.1 '## 0.7.0 — 2026-07-19' '' '- **Some other release**')"
check "armed: a bare VERSION under someone ELSE's stamped section fails" 1 "wrong number" armed "$T"

# --- the HALF-ceremony: the gap the two bare-VERSION clauses leave ---------
# VERSION bumped to the release, '## Unreleased' still populated on top, and
# the section for that version never stamped at all. The wrong-number test
# above is false on its FIRST clause here and short-circuits, so before
# heavy-duty/rig#67's rule this tree passed the guard and was refused instead
# by release.yml — at publish time, after the merge, on main, with the release
# already half-shipped. Caught here one step earlier, by running the same
# extraction release.yml runs.
T="$(tree rel-half 0.8.0 '## Unreleased' '' '- **A pending entry**' '' '## 0.7.0 — 2026-07-19' '' '- **Shipped**')"
check "armed: a bare VERSION whose section was never stamped fails (half-ceremony)" \
  1 "no non-empty section" armed "$T"
check "armed: ...and names the stamp as MISSING, not misnumbered" \
  1 "MISSING, not misnumbered" armed "$T"
# The wording is the whole point of the separate branch: an operator sent to
# fix a version number that is already correct will not find the real problem.
not_wrong_number() { ! armed "$1" 2>&1 | grep -qF 'wrong number'; }
check "armed: ...and not as the wrong-number case, which has a different fix" \
  0 "" not_wrong_number "$T"
# A section that exists but carries no prose is the same failure: release.yml
# would publish an empty body, which is what release-notes.sh already refuses.
T="$(tree rel-empty 0.7.1 '## 0.7.1 — 2026-07-19' '' '## 0.7.0 — 2026-07-19' '' '- **Shipped**')"
check "armed: a bare VERSION whose section is stamped but EMPTY fails" \
  1 "no non-empty section" armed "$T"

# --- degenerate trees refuse rather than pass by accident ------------------
T="$(tree no-sections 0.7.1-dev 'Prose and no headings at all.')"
check "armed: a changelog with no '## ' section at all fails" 1 "no '## ' section at all" armed "$T"
check "armed: a missing changelog refuses by path" 1 "no such file" \
  bash "$ARMED" "$WORK/nope.md" "$ROOT/VERSION"
check "armed: a missing VERSION refuses by path" 1 "no such file" \
  bash "$ARMED" "$ROOT/CHANGELOG.md" "$WORK/nope-version"
mkdir -p "$WORK/empty-ver"; : > "$WORK/empty-ver/VERSION"
check "armed: an empty VERSION refuses" 1 "is empty" \
  bash "$ARMED" "$ROOT/CHANGELOG.md" "$WORK/empty-ver/VERSION"

# --- and the tree under test, which is the assertion that actually fires ---
check "armed: THIS tree's VERSION and CHANGELOG.md agree" 0 "agrees" \
  bash "$ARMED" "$ROOT/CHANGELOG.md" "$ROOT/VERSION"

# The guard is only a guard if CI runs it, and the ceremony is only re-armed
# if the ceremony step says so. Fail-closed pins on both, since a guard nobody
# invokes and a step nobody wrote are the two ways this reverts silently.
check "ci.yml: runs the changelog-armed guard" 0 "" \
  grep -qF 'changelog-armed.sh' "$ROOT/.github/workflows/ci.yml"
check "CONTRIBUTING: the ceremony re-arms '## Unreleased' after stamping" 0 "" \
  grep -qF 'Stamping is two edits, not one' "$ROOT/CONTRIBUTING.md"
check "CONTRIBUTING: ...and names the guard that enforces it" 0 "" \
  grep -qF 'changelog-armed.sh' "$ROOT/CONTRIBUTING.md"

# ---------------------------------------------------------------------------
# changelog-monotonic.sh (#122) — no SHIPPED release heading may be DELETED.
#
# The complement of the guard above, and the reason it is a separate script:
# changelog-armed.sh asks about ONE tree ("does the top section agree with
# VERSION?"), which is exactly why it was green on #118's broken branch — the
# top section was still '## Unreleased'. "A heading disappeared" is not a
# property of a tree at all; it is a property of a DIFF. So these cases are
# driven against real, constructed GIT REPOS with a base commit and a branch
# commit, not the two-file trees above — a fixture without history cannot
# express the failure being guarded.
#
# The #118 shape is reconstructed verbatim as the first case: the line
# '## 0.8.0 — 2026-07-19' replaced by an entry written under '## Unreleased'.
# The ceremony's own stamp is driven right beside it, because a rule that
# fires on the stamp is unshippable for the same reason rig#44 and cast#108
# were — that pair, not the failing case alone, is what makes this a design.
# ---------------------------------------------------------------------------
MONO="$ROOT/.github/scripts/changelog-monotonic.sh"
check "changelog-monotonic: runnable bash" 0 "" bash -n "$MONO"

# grepo <name> <base-changelog-lines...> — a git repo whose `main` carries the
# given changelog, left checked out on a branch `pr` off it. Prints the dir.
grepo() {
  local d="$WORK/$1"; shift
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.invalid
  git -C "$d" config user.name test
  { echo "# Changelog"; echo; printf '%s\n' "$@"; } > "$d/CHANGELOG.md"
  git -C "$d" add CHANGELOG.md
  git -C "$d" commit -qm base
  git -C "$d" checkout -q -b pr
  echo "$d"
}
# head_changelog <dir> <lines...> — the PR branch's version of the file
head_changelog() {
  local d="$1"; shift
  { echo "# Changelog"; echo; printf '%s\n' "$@"; } > "$d/CHANGELOG.md"
  git -C "$d" commit -qam head
}
mono()        { local d="$1"; shift; ( cd "$d" && bash "$MONO" "$@" ); }
mono_strict() { local d="$1"; shift; ( cd "$d" && CHANGELOG_MONOTONIC_STRICT=1 bash "$MONO" "$@" ); }

# --- the #118 incident, reconstructed --------------------------------------
G="$(grepo mono-118 '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '### Added' '' '- **Shipped prose**')"
head_changelog "$G" '## Unreleased' '' '### Fixed' '' '- **An entry**' '' '### Added' '' '- **Shipped prose**'
check "monotonic: a DELETED release heading fails (the #118 near-miss)" 1 "DELETES release heading" mono "$G" main
check "monotonic: ...and names the heading that vanished" 1 "## 0.8.0" mono "$G" main
check "monotonic: ...and the shape of the mistake (replaced, not inserted)" 1 "instead of being" mono "$G" main
check "monotonic: ...and why nothing else says so (git merges it cleanly)" 1 "git merges that edit cleanly" mono "$G" main
# The whole point of the issue: the OTHER guard is green on this same tree.
# Pinned here so a future 'just widen changelog-armed.sh' cannot quietly
# delete the reason this script exists.
check "monotonic: ...on a tree changelog-armed.sh calls FINE (the #122 gap)" 0 "agrees" \
  bash "$ARMED" "$G/CHANGELOG.md" "$ROOT/VERSION"

# --- the #118 incident as it ACTUALLY happened: a DUPLICATED heading -------
# The deletion case above is the near-miss. What the bad rebase really produced
# was two '## 0.8.0 — 2026-07-19' headings with the incoming entry stranded
# between them. Containment cannot see this: the duplicate is head-side
# SURPLUS, and `comm -23` (base minus head) is blind to extras on the head side
# — with or without `sort -u`, and multiset comparison does not close it for
# the same reason. Uniqueness on HEAD is the assert that does.
G="$(grepo mono-dup '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '### Added' '' '- **Shipped prose**')"
head_changelog "$G" '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '### Fixed' '' '- **An entry**' '' '## 0.8.0 — 2026-07-19' '' '### Added' '' '- **Shipped prose**'
check "monotonic: a DUPLICATED release heading fails (the #118 shape)" 1 "DUPLICATE release heading" mono "$G" main
check "monotonic: ...and names the repeated heading" 1 "## 0.8.0" mono "$G" main
check "monotonic: ...and says what a repeat does to release-notes extraction" 1 "re-arms its extraction" mono "$G" main
# Containment alone is green on this exact tree — nothing was deleted. Pinned
# so a future simplification cannot collapse the two asserts into one.
# shellcheck disable=SC2016  # $1/$2 are the inner shell's positionals, not ours
check "monotonic: ...on a tree where NOTHING was deleted (containment is blind)" 1 "" \
  bash -c 'cd "$1" && bash "$2" main 2>&1 | grep -q "DELETES release heading"' _ "$G" "$MONO"
# And, as with the deletion case, the other guard calls this tree fine.
check "monotonic: ...on a tree changelog-armed.sh calls FINE" 0 "agrees" \
  bash "$ARMED" "$G/CHANGELOG.md" "$ROOT/VERSION"

# --- the release ceremony's stamp: an ADD, never a removal -----------------
# '## Unreleased' -> '## 0.8.1 — DATE' adds 0.8.1 and removes no X.Y.Z
# heading, because 'Unreleased' is not one. A false positive here would make
# every release unshippable — the rig#44 / cast#108 failure, one guard over.
G="$(grepo mono-stamp '## Unreleased' '' '- **Pending**' '' '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
head_changelog "$G" '## Unreleased' '' '## 0.8.1 — 2026-07-20' '' '- **Pending**' '' '## 0.8.0 — 2026-07-19' '' '- **Shipped**'
check "monotonic: the ceremony stamp passes (adds a heading, removes none)" 0 "still present" mono "$G" main

# --- the ordinary entry, done right ----------------------------------------
G="$(grepo mono-ok '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
head_changelog "$G" '## Unreleased' '' '### Fixed' '' '- **An entry**' '' '## 0.8.0 — 2026-07-19' '' '- **Shipped**'
check "monotonic: an entry INSERTED above the top section passes" 0 "still present" mono "$G" main
check "monotonic: ...and counts what it actually checked" 0 "all 1 release heading" mono "$G" main

# --- deletion is caught anywhere in the file, not just at the top ----------
G="$(grepo mono-mid '## 0.8.0 — 2026-07-19' '' '- **a**' '' '## 0.7.0 — 2026-07-18' '' '- **b**' '' '## 0.6.0 — 2026-07-17' '' '- **c**')"
head_changelog "$G" '## 0.8.0 — 2026-07-19' '' '- **a**' '' '- **b**' '' '## 0.6.0 — 2026-07-17' '' '- **c**'
check "monotonic: a heading deleted MID-FILE is caught too" 1 "## 0.7.0" mono "$G" main
# ...and only the deleted one is named, so the message points at the edit.
notes_only_070() { ! mono "$1" main 2>&1 | grep -qE '^    ## 0\.(6|8)\.0$'; }
check "monotonic: ...naming only the heading that went missing" 0 "" notes_only_070 "$G"

# --- a rewritten Unreleased is NOT a violation (changelog-armed owns it) ---
G="$(grepo mono-unrel '## Unreleased' '' '- **Pending**' '' '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
head_changelog "$G" '## 0.8.0 — 2026-07-19' '' '- **Shipped**'
check "monotonic: a deleted '## Unreleased' is NOT this guard's business" 0 "still present" mono "$G" main

# --- a changelog that did not exist at the base ----------------------------
G="$(grepo mono-new 'No sections yet.')"
head_changelog "$G" '## 0.1.0 — 2026-07-20' '' '- **First**'
check "monotonic: a base with no release headings passes (nothing to delete)" 0 "all 0 release heading" mono "$G" main

# --- degradation: no base to compare against -------------------------------
# A local run may genuinely have no base ref. That must SKIP loudly, not fail
# spuriously (which would make the script un-runnable off CI) and not pass
# silently (which is the failure shape this repo keeps refusing). CI closes
# the hole from the other side with STRICT.
G="$(grepo mono-nobase '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
check "monotonic: an unresolvable base ref SKIPS containment" 0 "containment SKIPPED" mono "$G" no-such-ref
check "monotonic: ...and says uniqueness already ran, not that nothing did" 0 "already ran" mono "$G" no-such-ref
check "monotonic: ...naming the base ref it could not resolve" 0 "no-such-ref" mono "$G" no-such-ref
check "monotonic: ...and warning that CI treats it as a failure" 0 "hard failure" mono "$G" no-such-ref
check "monotonic: STRICT turns that skip into a red run" 1 "is a FAILURE, not a skip" mono_strict "$G" no-such-ref
check "monotonic: ...and points at the checkout, not the script" 1 "fetch-depth: 0" mono_strict "$G" no-such-ref
# Outside a work tree at all (a tarball, an unpacked release).
mkdir -p "$WORK/mono-nogit"
printf '%s\n' '# Changelog' '' '## 0.8.0 — 2026-07-19' > "$WORK/mono-nogit/CHANGELOG.md"
check "monotonic: outside a git work tree it skips containment, not everything" 0 "containment SKIPPED" \
  mono "$WORK/mono-nogit" main
check "monotonic: a missing changelog refuses by path (never a skip)" 1 "no such file" \
  bash "$MONO" main "$WORK/nope.md"

# --- #143: uniqueness is a property of HEAD, so nothing base-side may gate it -
# Containment needs the merge base. Uniqueness needs only the file in front of
# it. Before #143 the duplicate check sat downstream of the base-ref, merge-base
# and base-blob conditions, so each of the three degradation paths below exited
# 0 on a tree with a duplicate in plain sight — the base-blob one not even via
# skip(), but a bare `exit 0` that STRICT could not reach. These cases pin the
# ORDER, which is the actual invariant; asserting the exit code alone is what
# let the original ship (the base-absent case below was green before and after).
grepo_nocl() { # a repo whose main has NO changelog at all
  local d="$WORK/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.invalid
  git -C "$d" config user.name test
  echo seed > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -qm base
  git -C "$d" checkout -q -b pr
  echo "$d"
}
add_changelog() { # <dir> <lines...> — the PR introduces the file
  local d="$1"; shift
  { echo "# Changelog"; echo; printf '%s\n' "$@"; } > "$d/CHANGELOG.md"
  git -C "$d" add CHANGELOG.md
  git -C "$d" commit -qm head
}

# The changelog is absent at the merge base AND the PR introduces a duplicate.
G="$(grepo_nocl mono-143-newdup)"
add_changelog "$G" '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '- **a**' '' '## 0.8.0 — 2026-07-19' '' '- **stranded**'
check "monotonic: a duplicate introduced where the base had no changelog is CAUGHT (#143)" 1 "DUPLICATE release heading" mono "$G" main
check "monotonic: ...and STRICT does not change that (it was never a skip)" 1 "DUPLICATE release heading" mono_strict "$G" main
# ...and the clean counterpart still exits 0, now saying uniqueness did run.
G="$(grepo_nocl mono-143-newok)"
add_changelog "$G" '## Unreleased' '' '## 0.8.0 — 2026-07-19' '' '- **a**'
check "monotonic: ...while a CLEAN introduced changelog still passes" 0 "nothing could have been deleted" mono "$G" main
check "monotonic: ...saying uniqueness was checked, not that nothing was" 0 "uniqueness on HEAD already passed" mono "$G" main

# No git at all: uniqueness still has everything it needs.
mkdir -p "$WORK/mono-143-nogit"
printf '%s\n' '# Changelog' '' '## 0.8.0 — 2026-07-19' '' '## 0.8.0 — 2026-07-19' > "$WORK/mono-143-nogit/CHANGELOG.md"
check "monotonic: a duplicate OUTSIDE a git work tree is caught (#143)" 1 "DUPLICATE release heading" \
  mono "$WORK/mono-143-nogit" main

# Unresolvable base ref: same — the skip is containment's, not the script's.
G="$(grepo mono-143-nobase '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
head_changelog "$G" '## 0.8.0 — 2026-07-19' '' '- **a**' '' '## 0.8.0 — 2026-07-19' '' '- **b**'
check "monotonic: a duplicate is caught even when the base ref will not resolve (#143)" 1 "DUPLICATE release heading" mono "$G" no-such-ref

# --- the push-to-main shape: containment vacuous, uniqueness real ----------
# With the pull_request gate gone (#143), merge_base == HEAD is a ROUTINE path,
# not a degradation. Containment compares the file against itself and asserts
# nothing, so a line reading "all N still present" would claim a check that did
# no work — the same dishonesty the skip messages were fixed for. The success
# line therefore has two forms, and this pins which one each event gets.
G="$(grepo mono-vacuous '## 0.8.0 — 2026-07-19' '' '- **Shipped**')"
check "monotonic: HEAD as its own base reports containment VACUOUS, not verified" 0 "containment vacuous" mono "$G" HEAD
check "monotonic: ...and names uniqueness as the half that actually ran" 0 "uniqueness on HEAD checked" mono "$G" HEAD
# shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
check "monotonic: ...and does NOT claim headings were still present" 1 "" \
  bash -c 'cd "$1" && bash "$2" HEAD | grep -q "are still present"' _ "$G" "$MONO"
# The PR shape keeps the containment wording — the two must not collapse.
head_changelog "$G" '## 0.8.0 — 2026-07-19' '' '- **Shipped**' '' '## 0.9.0 — 2026-07-20' '' '- **New**'
check "monotonic: a real base still reports containment, naming the count" 0 "still present" mono "$G" main

# --- and the real tree, through the real script ----------------------------
# HEAD as its own base: the merge base is HEAD, so the sets are identical by
# construction. Proves the script runs against the actual CHANGELOG.md and
# parses its real headings, without depending on an `origin/main` that a
# fresh clone or a detached CI checkout may not have.
# HEAD as its own base is now the VACUOUS-containment path (#143), so the
# assertion moved to uniqueness's count — which is the stronger proof of the
# original intent anyway: it says the parser read the REAL CHANGELOG.md and
# found real headings in it, rather than that a self-comparison came out equal.
check "monotonic: THIS tree passes against itself (the parser meets reality)" 0 "uniqueness on HEAD checked" \
  mono "$ROOT" HEAD

# The guard is only a guard if CI runs it — and only if CI runs it with the
# history it needs. Fail-closed pins on all three, since a depth-1 checkout
# would silently downgrade every run to the SKIP path.
check "ci.yml: runs the changelog-monotonic guard" 0 "" \
  grep -qF 'changelog-monotonic.sh' "$ROOT/.github/workflows/ci.yml"
check "ci.yml: ...with full history, or the merge base is unreachable" 0 "" \
  grep -qF 'fetch-depth: 0' "$ROOT/.github/workflows/ci.yml"
check "ci.yml: ...and STRICT, so a skip is a red run and not a green one" 0 "" \
  grep -qF 'CHANGELOG_MONOTONIC_STRICT' "$ROOT/.github/workflows/ci.yml"
# #143: the step must NOT be pull-request-only — duplication is vacuous on no
# tree — and dropping that gate is only safe with the base-ref fallback, since
# `github.base_ref` is empty on a push and a bare `origin/` under STRICT is a
# hard failure on every push to main.
# Scoped to the step's OWN block, deliberately. A file-wide negative would
# forbid any FUTURE step in ci.yml from being pull_request-gated and would fail
# citing #143 when one legitimately is — #143 constrains this step, not the file.
mono_step_block() {
  awk '/^      - name: no shipped changelog heading/ {f=1; print; next}
       f && /^      - name: / {exit}
       f {print}' "$ROOT/.github/workflows/ci.yml"
}
mono_step_gated() { mono_step_block | grep -q 'if:'; }
check "ci.yml: the monotonic step itself is not pull_request-gated (#143)" 1 "" mono_step_gated
check "ci.yml: ...and the block was actually found (guards the awk above)" 0 "changelog-monotonic" mono_step_block
check "ci.yml: ...and falls back to ref_name, so a push has a base to resolve" 0 "" \
  grep -qF 'github.base_ref || github.ref_name' "$ROOT/.github/workflows/ci.yml"
check "CONTRIBUTING: names the append-only rule for release headings" 0 "" \
  grep -qF 'changelog-monotonic.sh' "$ROOT/CONTRIBUTING.md"

# ---------------------------------------------------------------------------
# latest_release_tag — extracted from install.sh (the source-the-pure-function
# trick) and driven against a shim curl. The shim serves the ONE seam the
# function uses: -w '%{redirect_url}' on the releases/latest probe.
# ---------------------------------------------------------------------------
SHIMDIR="$WORK/shim"; mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/curl" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for the release drills: answers the releases/latest probe with
# $FAKE_REDIRECT on stdout (the -w '%{redirect_url}' seam) — or fails with
# $FAKE_CURL_RC (network down) — and serves downloads (-o <file>) by copying
# $FAKE_TARBALL when the URL is $FAKE_SERVE_URL, else exit 22 (curl's own
# 404-under--f code). Every URL is appended to $FAKE_CURL_LOG so a test can
# assert exactly what was asked for, and in what order.
url="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)    out="$2"; shift 2 ;;
    -w|--write-out) shift 2 ;;
    -*)             shift ;;
    *)              url="$1"; shift ;;
  esac
done
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
case "$url" in
  */releases/latest)
    [ "${FAKE_CURL_RC:-0}" -eq 0 ] || exit "${FAKE_CURL_RC}"
    printf '%s' "${FAKE_REDIRECT:-}"; exit 0 ;;
  *)
    if [ -n "${FAKE_SERVE_URL:-}" ] && [ "$url" = "$FAKE_SERVE_URL" ]; then
      cp "${FAKE_TARBALL:?}" "${out:?}"; exit 0
    fi
    exit 22 ;;
esac
SHIM
chmod +x "$SHIMDIR/curl"

TAGFN="$(mktemp)"
awk '/^latest_release_tag\(\) \{/,/^\}/' "$ROOT/install.sh" > "$TAGFN"
check "latest_release_tag: extracted from install.sh (guards the awk)" 0 "releases/latest" cat "$TAGFN"
check "latest_release_tag: the extracted function is valid bash" 0 "" bash -n "$TAGFN"

ltag() { # ltag <redirect_url> [curl_rc]
  FAKE_REDIRECT="$1" FAKE_CURL_RC="${2:-0}" REPO=heavy-duty/box \
    PATH="$SHIMDIR:$PATH" bash -c ". '$TAGFN'; latest_release_tag"
}
check "resolve: reads the tag off the redirect" 0 "0.6.0" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.6.0"
check "resolve: a -dev-style tag survives verbatim" 0 "0.7.0-rc1" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.7.0-rc1"
check "resolve: a repo with NO releases (redirect to /releases) fails" 1 "" \
  ltag "https://github.com/heavy-duty/box/releases"
check "resolve: no redirect at all fails" 1 "" ltag ""
check "resolve: a curl failure (network down) fails, never hangs on prose" 1 "" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.6.0" 6
rm -f "$TAGFN"

# ---------------------------------------------------------------------------
# The three channels, driven through REAL install.sh runs (#83): default =
# latest release, BOX_REF=<tag> = pinned, BOX_REF=<branch> = dev. The shim
# curl serves a fabricated release tarball shaped exactly like GitHub's (one
# top-level directory), and its log proves WHICH URLs the installer asked
# for. FAKE_TARBALL carries VERSION 9.9.9 so nothing collides with the tree
# under test.
# ---------------------------------------------------------------------------
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
SRC="$WORK/box-9.9.9"; mkdir -p "$SRC/bin"
cp "$ROOT/bin/box" "$SRC/bin/box"; chmod +x "$SRC/bin/box"
echo "9.9.9" > "$SRC/VERSION"
tar -C "$WORK" -czf "$WORK/gh.tar.gz" box-9.9.9

ninst() { # ninst <box_home> <box_bin> [VAR=val ...] — install.sh, shim network
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$SHIMDIR:$PATH" \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      FAKE_TARBALL="$WORK/gh.tar.gz" "$@" bash "$ROOT/install.sh"
}

# --- channel 1: the default is the latest RELEASE ---------------------------
H1="$WORK/h1"; B1="$WORK/b1"; L1="$WORK/c1.log"
check "default channel: resolves and installs the latest release" 0 "latest release: 9.9.9" \
  ninst "$H1" "$B1" FAKE_CURL_LOG="$L1" \
    FAKE_REDIRECT="https://github.com/heavy-duty/box/releases/tag/9.9.9" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/tags/9.9.9.tar.gz"
check "default channel: the download is the TAG tarball" 0 "" \
  grep -qF "archive/refs/tags/9.9.9.tar.gz" "$L1"
check "default channel: it never asked for a branch" 1 "" \
  grep -q "refs/heads" "$L1"
check "default channel: INSTALLED_FROM records the RESOLVED tag" 0 "heavy-duty/box@9.9.9" \
  cat "$H1/versions/9.9.9/INSTALLED_FROM"
check "default channel: the install answers through the chain" 0 "box 9.9.9" \
  env HOME="$FAKEHOME" "$B1/box" --version

# --- channel 2: BOX_REF=<tag> pins a release --------------------------------
H2="$WORK/h2"; B2="$WORK/b2"; L2="$WORK/c2.log"
check "pinned channel: BOX_REF=<tag> installs that tag" 0 "done" \
  ninst "$H2" "$B2" BOX_REF=9.9.9 FAKE_CURL_LOG="$L2" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/tags/9.9.9.tar.gz"
check "pinned channel: no releases/latest probe (a pin resolves nothing)" 1 "" \
  grep -q "releases/latest" "$L2"

# --- channel 3: BOX_REF=<branch> is the dev channel -------------------------
H3="$WORK/h3"; B3="$WORK/b3"; L3="$WORK/c3.log"
check "dev channel: BOX_REF=main falls back tag -> branch" 0 "trying it as a branch" \
  ninst "$H3" "$B3" BOX_REF=main FAKE_CURL_LOG="$L3" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/heads/main.tar.gz"
check "dev channel: the tag was tried FIRST" 0 "refs/tags/main.tar.gz" \
  head -1 "$L3"
check "dev channel: then the branch" 0 "" \
  grep -qF "archive/refs/heads/main.tar.gz" "$L3"

# --- the failure is LOUD, never a silent fall-through to main ---------------
H4="$WORK/h4"; B4="$WORK/b4"; L4="$WORK/c4.log"
check "resolution failure: REFUSES, naming the probe URL" 1 "could not resolve the latest release" \
  ninst "$H4" "$B4" FAKE_CURL_RC=6 FAKE_CURL_LOG="$L4"
check "resolution failure: ...and the way out (BOX_REF)" 1 "BOX_REF" \
  ninst "$H4" "$B4" FAKE_CURL_RC=6
check "resolution failure: downloaded NOTHING (no silent main)" 1 "" \
  grep -q "archive/" "$L4"
check "resolution failure: nothing was installed" 1 "" test -e "$H4/versions"
check "a ref that is neither tag nor branch dies naming both" 1 "neither a tag nor a branch" \
  ninst "$H4" "$B4" BOX_REF=no-such-ref

# ---------------------------------------------------------------------------
# The -dev convention (#83): main's VERSION carries -dev between releases, so
# a dev install lands beside releases in versions/ instead of impersonating
# one — and the docs keep the promises this PR makes.
# ---------------------------------------------------------------------------
check "CONTRIBUTING documents the post-release -dev bump" 0 "" \
  grep -q -- '-dev' "$ROOT/CONTRIBUTING.md"
check "CONTRIBUTING documents the release ritual (tag == VERSION)" 0 "" \
  grep -qi 'release' "$ROOT/CONTRIBUTING.md"
check "README documents the default (latest release) channel" 0 "" \
  grep -qF 'latest release' "$ROOT/README.md"
check "README documents the pinned channel" 0 "" \
  grep -qF 'BOX_REF=0.6.0' "$ROOT/README.md"
check "README documents the dev channel" 0 "" \
  grep -qF 'BOX_REF=main' "$ROOT/README.md"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
