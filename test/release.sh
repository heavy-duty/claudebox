#!/usr/bin/env bash
# Box-specific release-channel coverage. Shared release/guard machinery lives
# in heavy-duty/ceremony and is tested there; this file drives real install.sh.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

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

WORK="$(mktemp -d)"
SHIMDIR="$WORK/shim"; mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/curl" <<'SHIM'
#!/usr/bin/env bash
url="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -w|--write-out) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
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
check "latest_release_tag: extracted from install.sh" 0 "releases/latest" cat "$TAGFN"
check "latest_release_tag: extracted function is valid bash" 0 "" bash -n "$TAGFN"

ltag() {
  FAKE_REDIRECT="$1" FAKE_CURL_RC="${2:-0}" REPO=heavy-duty/box \
    PATH="$SHIMDIR:$PATH" bash -c ". '$TAGFN'; latest_release_tag"
}
check "resolve: reads the tag off the redirect" 0 "0.6.0" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.6.0"
check "resolve: a pre-release tag survives verbatim" 0 "0.7.0-rc1" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.7.0-rc1"
check "resolve: a repo with no releases fails" 1 "" \
  ltag "https://github.com/heavy-duty/box/releases"
check "resolve: no redirect fails" 1 "" ltag ""
check "resolve: a curl failure fails" 1 "" \
  ltag "https://github.com/heavy-duty/box/releases/tag/0.6.0" 6

FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
SRC="$WORK/box-9.9.9"; mkdir -p "$SRC/bin"
cp "$ROOT/bin/box" "$SRC/bin/box"; chmod +x "$SRC/bin/box"
printf '9.9.9\n' > "$SRC/VERSION"
tar -C "$WORK" -czf "$WORK/gh.tar.gz" box-9.9.9

ninst() {
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$SHIMDIR:$PATH" \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      FAKE_TARBALL="$WORK/gh.tar.gz" "$@" bash "$ROOT/install.sh"
}

H1="$WORK/h1"; B1="$WORK/b1"; L1="$WORK/c1.log"
check "default channel: installs the latest release" 0 "latest release: 9.9.9" \
  ninst "$H1" "$B1" FAKE_CURL_LOG="$L1" \
    FAKE_REDIRECT="https://github.com/heavy-duty/box/releases/tag/9.9.9" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/tags/9.9.9.tar.gz"
check "default channel: downloads the tag tarball" 0 "" \
  grep -qF "archive/refs/tags/9.9.9.tar.gz" "$L1"
check "default channel: never asks for a branch" 1 "" grep -q "refs/heads" "$L1"
check "default channel: records the resolved tag" 0 "heavy-duty/box@9.9.9" \
  cat "$H1/versions/9.9.9/INSTALLED_FROM"
check "default channel: installed binary answers" 0 "box 9.9.9" \
  env HOME="$FAKEHOME" "$B1/box" --version

H2="$WORK/h2"; B2="$WORK/b2"; L2="$WORK/c2.log"
check "pinned channel: installs the requested tag" 0 "done" \
  ninst "$H2" "$B2" BOX_REF=9.9.9 FAKE_CURL_LOG="$L2" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/tags/9.9.9.tar.gz"
check "pinned channel: skips latest-release resolution" 1 "" \
  grep -q "releases/latest" "$L2"

H3="$WORK/h3"; B3="$WORK/b3"; L3="$WORK/c3.log"
check "dev channel: falls back from tag to branch" 0 "trying it as a branch" \
  ninst "$H3" "$B3" BOX_REF=main FAKE_CURL_LOG="$L3" \
    FAKE_SERVE_URL="https://github.com/heavy-duty/box/archive/refs/heads/main.tar.gz"
check "dev channel: tries the tag first" 0 "refs/tags/main.tar.gz" head -1 "$L3"
check "dev channel: then downloads the branch" 0 "" \
  grep -qF "archive/refs/heads/main.tar.gz" "$L3"

H4="$WORK/h4"; B4="$WORK/b4"; L4="$WORK/c4.log"
check "resolution failure: names the latest-release probe" 1 "could not resolve the latest release" \
  ninst "$H4" "$B4" FAKE_CURL_RC=6 FAKE_CURL_LOG="$L4"
check "resolution failure: names BOX_REF as the override" 1 "BOX_REF" \
  ninst "$H4" "$B4" FAKE_CURL_RC=6
check "resolution failure: downloads nothing" 1 "" grep -q "archive/" "$L4"
check "resolution failure: installs nothing" 1 "" test -e "$H4/versions"
check "unknown ref names both attempted channels" 1 "neither a tag nor a branch" \
  ninst "$H4" "$B4" BOX_REF=no-such-ref

check "README documents the latest-release channel" 0 "" grep -qF 'latest release' "$ROOT/README.md"
check "README documents the pinned channel" 0 "" grep -qF 'BOX_REF=0.6.0' "$ROOT/README.md"
check "README documents the dev channel" 0 "" grep -qF 'BOX_REF=main' "$ROOT/README.md"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
