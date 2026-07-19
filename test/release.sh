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
check "release.yml: fires on closed pull requests..." 0 "" \
  grep -qF 'types: [closed]' "$RY"
check "release.yml: ...into main" 0 "" \
  grep -qF 'branches: [main]' "$RY"
check "release.yml: the merge door gates on merged == true (closed-unmerged never fires)" 0 "" \
  grep -qF 'github.event.pull_request.merged == true' "$RY"
check "release.yml: ...AND on the release label, read from the event payload" 0 "" \
  grep -qF "contains(github.event.pull_request.labels.*.name, 'release')" "$RY"
check "release.yml: the tag door runs only on a push (a closed PR never reaches it)" 0 "" \
  grep -qF "github.event_name == 'push'" "$RY"
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
check "release.yml: decide gates every later merge-door step on ceremony=yes" 0 "3" \
  grep -cF "if: steps.decide.outputs.ceremony == 'yes'" "$RY"

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
