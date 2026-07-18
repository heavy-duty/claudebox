#!/usr/bin/env bash
# Dependency-free CLI assertions for box. Run: bash test/cli.sh
#
# Runnable by a NON-root user with NO Incus installed — that is the whole point.
# Anything that needs a real incus daemon (every lifecycle command) is proven the
# way rig proves its root-only paths: source the pure function and drive it against
# a fixture, or grep the load-bearing line so a deleted guard cannot ship green.
# Deliberately no `set -e` — the harness asserts on failing commands.
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

BOX="$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The CLI contract: dispatch, help, usage errors. No incus needed — these all
# resolve before any daemon call. Exit codes are box's own (0 ok / 1 wrong /
# 2 you-asked-wrong), read straight from bin/box and confirmed by running it.
# ---------------------------------------------------------------------------
# box with no args is 'help' (cmd="${1:-help}"), which prints the general usage
# and exits 0 — NOT rig's exit-2 bare-usage. Assert box's actual contract.
check "no args → general help, exit 0"        0 "USAGE"            "$BOX"
check "no args help names the command form"   0 "box <command>"   "$BOX"
check "--help exits 0"                         0 "USAGE"            "$BOX" --help
check "-h exits 0"                             0 "USAGE"            "$BOX" -h
check "help exits 0"                           0 "USAGE"            "$BOX" help
check "help <command> → that command's usage"  0 "usage: box new"  "$BOX" help new
check "--version exits 0"                       0 "box"             "$BOX" --version
# Unknown command is a usage error (2), and it says so — the suggester may add a
# 'did you mean', but the stem is stable.
check "unknown command exits 2"                2 "unknown command" "$BOX" frobnicate
check "unknown command points at help"         2 "box help"        "$BOX" zzzzzz
# Options before the command are the classic mistake; box names the fix.
check "option before command exits 2"          2 "options come after the command" "$BOX" --json list
# A missing required positional is a usage error carrying that command's synopsis.
check "new without --name exits 2"             2 "usage: box new"    "$BOX" new
check "shell without a box exits 2"            2 "usage: box shell"  "$BOX" shell
check "restore without arg2 needs a box first" 2 "usage: box restore" "$BOX" restore
# An unknown flag is refused, not swallowed as a positional (the --labl bug).
check "unknown flag on list exits 2"           2 "unknown option"   "$BOX" list --nope
# A flag that needs a value and gets none.
check "--name with no value exits 2"           2 "--name needs a value" "$BOX" new --name

# ---------------------------------------------------------------------------
# A shim `id` on PATH: lets us drive install.sh's DEST branch with a canned uid +
# group output, exactly the way rig drives assert_runner_repo against fixtures.
# ---------------------------------------------------------------------------
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/id" <<'SHIM'
#!/usr/bin/env bash
# Fake `id`: -u prints $FAKE_UID, -nG prints $FAKE_GROUPS. Just enough for
# install.sh's DEST branch, which only ever asks these two.
case "${1:-}" in
  -u)  printf '%s\n' "${FAKE_UID:-1000}" ;;
  -nG) printf '%s\n' "${FAKE_GROUPS:-}" ;;
  *)   exit 0 ;;
esac
SHIM
chmod +x "$SHIMDIR/id"

# ---------------------------------------------------------------------------
# install.sh — #71 global/root install. bash -n first, then drive the actual
# DEST/BINDIR branch with the shim id (the functional proof the contract asks
# for), then grep the root-only pieces that a daemon-free run cannot exercise.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
# Extract EXACTLY the DEST/BINDIR if/else/fi (the first `id -u -eq 0` block) and
# print what it resolved — the same "run the pure block in isolation" trick rig
# uses for its embedded dump script. Fail closed: a mangled extraction is caught
# by the /opt/box grep below before any resolution is trusted.
DBLOCK="$(mktemp)"
awk '/id -u.*-eq 0/{f=1} f{print} f&&/^fi$/{exit}' "$ROOT/install.sh" > "$DBLOCK"
# The $DEST/$BINDIR here are LITERAL text appended into the extracted block — they
# must expand when that block RUNS, not when this printf writes it. Hence single
# quotes; SC2016 is the intent.
# shellcheck disable=SC2016
printf '\nprintf "DEST=%%s BINDIR=%%s\\n" "$DEST" "$BINDIR"\n' >> "$DBLOCK"
check "install.sh: DEST block extracted (guards the awk)" 0 "/opt/box" cat "$DBLOCK"
check "install.sh: the extracted DEST block is valid bash" 0 "" bash -n "$DBLOCK"

dest() { # dest <uid> [extra env assignments...] — resolve DEST/BINDIR
  local uid="$1"; shift
  FAKE_UID="$uid" HOME=/home/tester PATH="$SHIMDIR:$PATH" env "$@" bash "$DBLOCK"
}
# Root: the global path — a system tree other users can read (#71).
check "install.sh: root → DEST=/opt/box"           0 "DEST=/opt/box"          dest 0
check "install.sh: root → BINDIR=/usr/local/bin"   0 "BINDIR=/usr/local/bin"  dest 0
# Non-root: unchanged, the solo path.
check "install.sh: non-root → DEST=\$HOME/.local"  0 "DEST=/home/tester/.local/share/box" dest 1000
check "install.sh: non-root → BINDIR=\$HOME/.local" 0 "BINDIR=/home/tester/.local/bin"    dest 1000
# BOX_HOME / BOX_BIN still win on BOTH branches — the scripting override.
check "install.sh: BOX_HOME overrides the root default" 0 "DEST=/srv/box"     dest 0    BOX_HOME=/srv/box
check "install.sh: BOX_BIN overrides the root default"  0 "BINDIR=/srv/bin"    dest 0    BOX_BIN=/srv/bin
check "install.sh: BOX_HOME overrides the non-root default" 0 "DEST=/srv/box"  dest 1000 BOX_HOME=/srv/box
rm -f "$DBLOCK"
# The root-only world-readable chmod (#71): the tree is EXECUTED by other users,
# so root must open read+traverse. Grep it, and that it is root-guarded so the
# per-user install stays byte-identical to before.
# $DEST is a LITERAL in the grep pattern (install.sh's own variable) — single
# quotes intended.
# shellcheck disable=SC2016
check "install.sh: root makes the tree world-readable (a+rX)" 0 "" \
  grep -qF 'chmod -R a+rX "$DEST"' "$ROOT/install.sh"
check "install.sh: the a+rX is root-guarded" 0 "" \
  bash -c 'grep -B2 "chmod -R a+rX" "'"$ROOT"'/install.sh" | grep -q "id -u.*-eq 0"'
# #66's flow, preserved: confirm-before-download, and no-op if already installed.
check "install.sh: still confirms before downloading (#66)" 0 "" \
  grep -qF 'confirm "Install box from' "$ROOT/install.sh"
check "install.sh: still no-ops on an existing install (#66)" 0 "" \
  grep -qF 'already installed' "$ROOT/install.sh"

# ---------------------------------------------------------------------------
# Templates — DYNAMIC over templates/*/ (#68): the loop discovers every
# template directory, so a new template cannot ship without passing these (the
# old hardcoded blank/claude/codex/grok list let exactly that happen). The
# box.env parse is proven against the REAL allowlist: load_template is
# extracted from bin/box and DRIVEN against each template — the same
# source-the-pure-function trick install.sh's DEST block and box_tier get
# below — so an unknown key, a missing BOX_IMAGE/BOX_USER, or a line that is
# not KEY="value" fails HERE, not at mint time on a host.
# ---------------------------------------------------------------------------
TPLFN="$(mktemp)"
awk '/^load_template\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TPLFN"
check "load_template: extracted from bin/box (guards the awk)" 0 "unknown key" cat "$TPLFN"
check "load_template: the extracted function is valid bash"    0 "" bash -n "$TPLFN"

# tpl <root> <template> — run the real parser against <root>/templates/, print
# what it resolved. $0 carries the extracted-function file into the subshell.
tpl() {
  root="$1" bash -c '
    die() { echo "box: $*" >&2; exit 1; }
    . "$0"; load_template "$1"
    printf "IMAGE=%s USER=%s REQUIRE_VM=%s AUTOSTART=%s\n" \
      "$T_IMAGE" "$T_USER" "$T_REQUIRE_VM" "$T_AUTOSTART"
  ' "$TPLFN" "$2"
}

# The allowlist itself is load-bearing: a template must not be able to grow a
# network key, and the required keys must still be required. Fixture-driven,
# against a throwaway root — exactly the dies a green parse cannot prove.
EVILROOT="$(mktemp -d)"; mkdir -p "$EVILROOT/templates/evil"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="dev"\nBOX_NETWORK="lan"\n' \
  > "$EVILROOT/templates/evil/box.env"
check "load_template: an unknown key dies (no template grows a network)" 1 "unknown key" \
  tpl "$EVILROOT" evil
printf 'BOX_USER="dev"\n' > "$EVILROOT/templates/evil/box.env"
check "load_template: a missing BOX_IMAGE dies" 1 "required" tpl "$EVILROOT" evil
# The green path the two new keys exist for: no in-tree template sets them yet
# (the seed lands after rig#31), so without this fixture the case arms could be
# deleted and the suite would stay green while the keys silently died as
# "unknown key" at first use. Accepted AND surfaced, through the real parser.
mkdir -p "$EVILROOT/templates/server"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="ops"\nBOX_REQUIRE_VM="1"\nBOX_AUTOSTART="1"\n' \
  > "$EVILROOT/templates/server/box.env"
check "load_template: REQUIRE_VM and AUTOSTART round-trip (accepted + surfaced)" \
  0 "REQUIRE_VM=1 AUTOSTART=1" tpl "$EVILROOT" server
rm -rf "$EVILROOT"

# YAML well-formedness needs python3 + pyyaml; the CI runner has both. Skip
# gracefully (never silently) where they are missing.
HAVE_YAML=0
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=1

for d in "$ROOT"/templates/*/; do
  t="$(basename "$d")"
  # The parse itself asserts the allowlist AND the required keys (the driven
  # function dies without BOX_IMAGE/BOX_USER); the greps pin both keys to the
  # FILE, so neither can quietly become an inherited default.
  check "template '$t': box.env parses against the real allowlist" 0 "USER=" tpl "$ROOT" "$t"
  check "template '$t': box.env sets BOX_IMAGE" 0 "" grep -q '^BOX_IMAGE=' "$d/box.env"
  check "template '$t': box.env sets BOX_USER"  0 "" grep -q '^BOX_USER='  "$d/box.env"
  # cloud-init is passed to Incus verbatim, so it must exist, declare itself,
  # and be well-formed — a mint is far too late to learn about a typo.
  check "template '$t': user-data.yaml exists" 0 "" test -f "$d/user-data.yaml"
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': user-data.yaml begins with #cloud-config" 0 "" \
    bash -c 'head -1 "$1" | grep -qx "#cloud-config"' _ "$d/user-data.yaml"
  if [ "$HAVE_YAML" = 1 ]; then
    check "template '$t': user-data.yaml is well-formed YAML" 0 "" \
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$d/user-data.yaml"
  else
    echo "skip: template '$t' YAML well-formedness (no python3+pyyaml here; CI has both)"
  fi
  # #65: 'box tmux' runs 'tmux new-session' INSIDE the box, so every
  # template's package list must carry tmux or the verb dies inside.
  check "template '$t': installs tmux (#65)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+tmux$' "$d/user-data.yaml"
done

rm -f "$TPLFN"

# The keys' cmd_new half, grepped the way the expose guard is (line order —
# a daemon-free run cannot mint). The REQUIRE_VM refusal must read the
# EFFECTIVE mode, i.e. come after pick_mode: refusing on the template key
# alone would refuse valid VM mints, and a guard deleted in a refactor must
# not ship green.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the REQUIRE_VM refusal orders after pick_mode" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  pick="$(printf "%s\n" "$fn" | grep -n "pick_mode"    | head -1 | cut -d: -f1)"
  guard="$(printf "%s\n" "$fn" | grep -n "T_REQUIRE_VM" | head -1 | cut -d: -f1)"
  [ -n "$pick" ] && [ -n "$guard" ] && [ "$pick" -lt "$guard" ]'
# Order is necessary, not sufficient: a regression to the RAW flag
# ([ "$mode" != vm ]) would still sit after pick_mode — and would refuse every
# auto mint on a valid VM host. Pin the guard to the EFFECTIVE operand: the
# T_REQUIRE_VM line itself must compare $m, the pick_mode result.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the REQUIRE_VM guard compares the effective mode (\$m)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "T_REQUIRE_VM" | grep -qF "\"\$m\" != vm"'
check "new: boot.autostart is stamped under the T_AUTOSTART guard" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "boot.autostart=true" | grep -q "T_AUTOSTART"'

# ---------------------------------------------------------------------------
# The restricted tier (#74). box_tier() is the decision the whole tier hangs
# on, so it is DRIVEN, not grepped: extracted from bin/box, sourced, and run
# against a shim id for every case — including the one that bites (a user in
# BOTH groups is admin: membership wins at the socket, and the function must
# not substring-match 'incus' inside 'incus-admin').
# ---------------------------------------------------------------------------
TIERFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TIERFN"
check "box_tier: extracted from bin/box (guards the awk)" 0 "incus-admin" cat "$TIERFN"
check "box_tier: the extracted function is valid bash"    0 "" bash -n "$TIERFN"

tier() { # tier <uid> <groups...>
  local uid="$1"; shift
  FAKE_UID="$uid" FAKE_GROUPS="$*" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$TIERFN'; box_tier"
}
check "box_tier: uid 0 → admin"                    0 "admin"      tier 0
check "box_tier: incus-admin → admin"              0 "admin"      tier 1000 "users incus-admin"
check "box_tier: incus only → restricted"          0 "restricted" tier 1000 "users incus"
check "box_tier: both groups → admin (membership wins at the socket)" \
                                                    0 "admin"      tier 1000 "users incus incus-admin"
check "box_tier: neither → none"                   0 "none"       tier 1000 "users dialout"
rm -f "$TIERFN"

# setup-host.sh must decide the tier BEFORE any install tree exists, so it
# carries its own copy — and a drifted copy is two tiers pretending to be one.
# Byte-identical, asserted.
BINFN="$(mktemp)"; HOSTFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box"            > "$BINFN"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$HOSTFN"
check "box_tier: bin/box and setup-host.sh copies are byte-identical" 0 "" \
  diff "$BINFN" "$HOSTFN"
rm -f "$BINFN" "$HOSTFN"

# The tier scripts parse and refuse bad usage without a daemon — drive them.
check "grant: no argument is a usage error"      2 "usage: box grant"  bash "$ROOT/host/grant-user.sh"
check "grant: a flag is not a user"              2 "usage: box grant"  bash "$ROOT/host/grant-user.sh" --frob
check "revoke: no argument is a usage error"     2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh"
check "revoke: two users is a usage error"       2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh" a b
check "box grant with no user exits 2 (via the CLI table)"  2 "usage: box grant"  "$BOX" grant
check "box revoke with no user exits 2 (via the CLI table)" 2 "usage: box revoke" "$BOX" revoke
check "help grant names the hardened network" 0 "boxnet" "$BOX" help grant
check "help revoke names --purge"             0 "purge"  "$BOX" help revoke

# Load-bearing lines a daemon-free run cannot exercise — grepped so a deleted
# guard cannot ship green (the house test discipline).
# The expose guard must fire before ANY incus call in cmd_expose: line order.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "expose: the restricted guard precedes the first incus call" 0 "" bash -c '
  fn="$(awk "/^cmd_expose\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "box_tier" | head -1 | cut -d: -f1)"
  first="$(printf "%s\n" "$fn" | grep -n "incus config" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$first" ] && [ "$guard" -lt "$first" ]'
# cmd_new refuses before minting when the placement contract is absent, and
# the message is tier-aware (a restricted user is sent to 'box grant', not
# to setup-host they cannot run). The pre-flight lives in require_stack()
# since #70 gave it a second caller (import lands on the same contract), so
# assert both halves: the helper holds the probe, and cmd_new calls it.
check "require_stack: probes the box-net profile" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "incus profile show box-net"'
check "require_stack: the restricted fix names box grant" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "box grant"'
check "new: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# grant converges to boxnet and ONLY boxnet — "boxnet,incusbr" would keep the
# unhardened private bridge one --network flag away (the #74 measured hole).
check "grant: narrows access to boxnet alone" 0 "" \
  grep -qE 'restricted\.networks\.access boxnet($| )' "$ROOT/host/grant-user.sh"
check "grant: never grants the private bridge" 1 "" \
  grep -qE 'networks\.access[^#]*incusbr' "$ROOT/host/grant-user.sh"
check "grant: allows snapshots (the clone workflow)" 0 "" \
  grep -qF 'restricted.snapshots allow' "$ROOT/host/grant-user.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "grant: installs the SHIPPED profile into the project" 0 "" \
  grep -qF 'profile edit box-net < "$here/profiles/box-net.yaml"' "$ROOT/host/grant-user.sh"
check "grant: unpins the private-bridge eth0 from the default profile" 0 "" \
  grep -qF 'profile device remove default eth0' "$ROOT/host/grant-user.sh"
check "grant: refuses an incus-admin member (nothing tighter to grant)" 0 "" \
  grep -qF 'incus-admin' "$ROOT/host/grant-user.sh"
check "revoke: group removal is the lockout" 0 "" \
  grep -qF 'gpasswd -d' "$ROOT/host/revoke-user.sh"
# Group membership is read at login: purge must terminate live sessions (a
# stale-group process could recreate the project unhardened AFTER the purge),
# and a bare revoke must say the socket survives in held sessions.
check "revoke: purge terminates live sessions first" 0 "" \
  grep -qF 'loginctl terminate-user' "$ROOT/host/revoke-user.sh"
check "revoke: purge refuses under unkillable sessions" 0 "" \
  grep -qF 'refusing to purge under them' "$ROOT/host/revoke-user.sh"
check "revoke: bare revoke warns about held sessions" 0 "" \
  grep -qF 'live sessions' "$ROOT/host/revoke-user.sh"
check "revoke: the purge asserts the certificate's absence too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "config trust list"'
# A failed grant must not leave a half-granted user: if THIS run added the
# group, the exit path takes it back (and the trap disarms only on success).
check "grant: backs out its own group-add on failure" 0 "" \
  grep -qF 'trap backout EXIT' "$ROOT/host/grant-user.sh"
check "grant: the back-out disarms on success" 0 "" \
  grep -qF 'trap - EXIT' "$ROOT/host/grant-user.sh"
# The backout must VERIFY the removal and scream when it cannot — an
# unverified rollback printing a security guarantee is the review's A2.
check "grant: the backout verifies against the group database" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "id -nG"'
check "grant: an unverifiable rollback screams" 0 "" \
  grep -qF 'ROLLBACK INCOMPLETE' "$ROOT/host/grant-user.sh"
check "grant: a failed re-grant warns the pre-existing member is untouched" 0 "" \
  grep -qF 'still holding socket access' "$ROOT/host/grant-user.sh"
check "grant: the mid-grant login window is named" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "loginctl terminate-user"'
# The scoped guarantee (raw --network boxnet) is measured, not prose:
check "rehearsal: measures the raw boxnet attach (criterion m)" 0 "" \
  grep -qF -- '--network boxnet' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "rehearsal: injects grant failures (criterion n)" 0 "" \
  grep -qF 'grant-user.sh" "$U3"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: purge deletes instances one at a time" 0 "" \
  grep -qF 'delete -f "$inst"' "$ROOT/host/revoke-user.sh"
check "revoke: purge removes the trust-store certificate" 0 "" \
  grep -qF 'config trust remove' "$ROOT/host/revoke-user.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the restricted gate precedes the sudo resolution" 0 "" bash -c '
  gate="$(grep -n "restricted tier" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  sudo="$(grep -n "^elif command -v sudo" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$gate" ] && [ -n "$sudo" ] && [ "$gate" -lt "$sudo" ]'
check "setup-host: enables incus-user.socket for the tier" 0 "" \
  grep -qF 'incus-user.socket' "$ROOT/host/setup-host.sh"
check "doctor: honors BOX_TIER" 0 "" \
  grep -qF 'BOX_TIER' "$ROOT/drill/doctor.sh"
check "box exports BOX_TIER to the doctor" 0 "" \
  grep -qF 'export BOX_TIER' "$ROOT/bin/box"
# 'box restore' must speak incus 6 ('snapshot restore'); bare 'incus restore'
# does not exist and the verb was broken for everyone until #74's rehearsal hit it.
check "restore: dispatches 'incus snapshot restore'" 0 "" \
  grep -qF '^incus:snapshot restore^' "$ROOT/bin/box"
# ---------------------------------------------------------------------------
# export / import (#70) — a box's state that survives the box and the host.
# Usage errors and the pure pre-incus refusals are DRIVEN; every daemon-gated
# invariant is grep-guarded or line-order-asserted (fail-closed: an empty
# grep is a FAIL, so a deleted guard cannot ship green).
# ---------------------------------------------------------------------------
check "export without a box exits 2"           2 "usage: box export" "$BOX" export
check "export of an unknown box exits 1"       1 "no such box"       "$BOX" export nosuchbox
check "import without a file exits 2"          2 "usage: box import" "$BOX" import
check "import of a missing file exits 1"       1 "no such file"      "$BOX" import /nope/nothing.tar.gz
check "import --name with no value exits 2"    2 "--name needs a value" "$BOX" import x.tar.gz --name
# A file that is not an export artifact is named as such, before any incus
# call — pure (tar + awk), so it is driven, not grepped.
NOTATARBALL="$(mktemp)"; echo "not a tarball" > "$NOTATARBALL"
check "import: a non-artifact file is refused" 1 "not an incus/box export" "$BOX" import "$NOTATARBALL"
rm -f "$NOTATARBALL"
check "help export names the credential risk"  0 "CREDENTIAL"        "$BOX" help export
check "help import names the re-stamping"      0 "user.box=1"        "$BOX" help import
# Export refuses a running box — require_stopped fires BEFORE incus export
# (line order inside cmd_export, fail-closed on either grep missing).
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "export: requires the box stopped, before exporting" 0 "" bash -c '
  fn="$(awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "require_stopped" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus export" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Snapshots ride along by default; --instance-only is the explicit opt-out.
check "export: snapshots included unless --instance-only" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q -- "--instance-only"'
# The credential SHOUT (#70's scrub-or-shout decision: box shouts).
check "export: shouts that the file is a credential" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "treat the file itself as a credential"'
# Import re-stamps the boundary tag onto the current stack.
check "import: re-stamps user.box=1" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "user.box=1"'
# The name-collision guard fires BEFORE incus import — the resolve_box
# boundary from the other side: never occupy an existing instance's name.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: the collision guard precedes the import" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "already exists" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus import" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Import lands on the placement contract: same pre-flight as a mint.
check "import: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# The artifact's MAC comes back verbatim, and a re-import beside a sibling
# collides at start (measured live: "MAC address already defined on another
# NIC") — the hwaddr unset must precede the start. Line order, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: regenerates the NIC MAC before the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  mac="$(printf "%s\n" "$fn" | grep -n "hwaddr" | head -1 | cut -d: -f1)"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  [ -n "$mac" ] && [ -n "$start" ] && [ "$mac" -lt "$start" ]'
# reset_identity runs AFTER the imported box is started — the clone trust
# boundary (machine-id → DHCP lease), line-order-asserted, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: reset_identity follows the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  reset="$(printf "%s\n" "$fn" | grep -n "reset_identity" | head -1 | cut -d: -f1)"
  [ -n "$start" ] && [ -n "$reset" ] && [ "$start" -lt "$reset" ]'
# The restricted tier can export: grant converges restricted.backups (the
# backup API is what 'incus export' rides; blocked by default — #70).
check "grant: allows backups (the export workflow)" 0 "" \
  grep -qF 'restricted.backups allow' "$ROOT/host/grant-user.sh"

# The rehearsal itself stays runnable: syntax-checked here, run on real hosts.
check "multiuser.sh is valid bash" 0 "" bash -n "$ROOT/drill/multiuser.sh"
check "multiuser.sh refuses without the env gate" 2 "opt in" \
  bash "$ROOT/drill/multiuser.sh" --yes
check "grant-user.sh is valid bash"  0 "" bash -n "$ROOT/host/grant-user.sh"
check "revoke-user.sh is valid bash" 0 "" bash -n "$ROOT/host/revoke-user.sh"
check "teardown-host.sh is valid bash" 0 "" bash -n "$ROOT/host/teardown-host.sh"

# ---------------------------------------------------------------------------
# Revoke leaves NOTHING (the grant/revoke cleanliness pass). The gap this
# closes: --purge removed /var/lib/incus/users/<uid> but never RE-CHECKED it —
# the one path its own absence assert did not cover. And the stat must ride
# $SUDO: /var/lib/incus is not traversable by a non-root admin, so a bare
# [ -d ] answers "absent" for a directory that is very much there.
# ---------------------------------------------------------------------------
check "revoke: purge removes the incus-user state directory" 0 "" \
  grep -qF '/var/lib/incus/users/' "$ROOT/host/revoke-user.sh"
check "revoke: the absence assert covers the incus-user state too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "/var/lib/incus/users/"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: the state checks go through \$SUDO test (an unprivileged stat lies)" 0 "" \
  grep -qF '$SUDO test -d "/var/lib/incus/users/$uid"' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# The #80 guard and BOX_SUBNET. setup-host run inside a box used to build a
# nested boxnet on the guest's own uplink subnet — captured gateway, duplicate
# routes, intermittent egress blackouts. The guard's two pure functions are
# extracted and DRIVEN (a shim ip serves canned route tables, the same seam as
# the shim id), and then the WHOLE script is driven end to end under shims:
# the refusal paths must exit 1 having touched nothing (the incus/sudo shims
# log every call, and the log must not exist), the converge path must still
# run, and BOX_SUBNET must plumb through to every derived value.
# ---------------------------------------------------------------------------
cat > "$SHIMDIR/ip" <<'SHIM'
#!/usr/bin/env bash
# Fake `ip`: canned tables for the #80 guard and signature — just the reads
# setup-host and doctor make. Specific patterns first: case takes the first hit.
case "$*" in
  "-4 -o addr show dev boxnet") printf '%s\n' "${FAKE_IP4_BOXNET:-}" ;;
  "-4 route show default")      printf '%s\n' "${FAKE_IP4_DEFAULT:-}" ;;
  "-4 route show")              printf '%s\n' "${FAKE_IP4_ROUTES:-}" ;;
  "-4 -o addr show")            printf '%s\n' "${FAKE_IP4_ADDRS:-}" ;;
esac
exit 0
SHIM
chmod +x "$SHIMDIR/ip"

# The route tables, verbatim from issue #80's capture (the poisoned guest) and
# from the states around it.
D_INBOX='default via 10.88.0.1 dev enp5s0 proto dhcp src 10.88.0.202 metric 1024'
D_LAN='default via 192.168.1.1 dev eno1 proto dhcp metric 100'
A_GUEST='2: enp5s0    inet 10.88.0.202/24 metric 1024 brd 10.88.0.255 scope global dynamic enp5s0'
A_HOSTSTACK='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
5: boxnet    inet 10.88.0.1/24 scope global boxnet'
A_FOREIGN='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
3: virbr7    inet 10.88.0.7/24 brd 10.88.0.255 scope global virbr7'

SUBFN="$(mktemp)"
awk '/^valid_subnet\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$SUBFN"
check "valid_subnet: extracted from setup-host.sh (guards the awk)" 0 "return 1" cat "$SUBFN"
check "valid_subnet: the extracted function is valid bash" 0 "" bash -n "$SUBFN"
vsub() { bash -c ". '$SUBFN'; valid_subnet \"\$1\"" _ "$1"; }
check "valid_subnet: the default is valid"                 0 "" vsub 10.88.0.0/24
check "valid_subnet: the documented escape hatch is valid" 0 "" vsub 10.89.0.0/24
check "valid_subnet: any a.b.c.0/24 is valid"              0 "" vsub 192.168.7.0/24
check "valid_subnet: not-a-/24 is refused"                 1 "" vsub 10.88.0.0/16
check "valid_subnet: a nonzero host octet is refused"      1 "" vsub 10.88.0.5/24
check "valid_subnet: an octet past 255 is refused"         1 "" vsub 300.88.0.0/24
check "valid_subnet: a bare address is refused"            1 "" vsub 10.88.0.0
check "valid_subnet: garbage is refused"                   1 "" vsub banana
check "valid_subnet: an empty value is refused"            1 "" vsub ""
rm -f "$SUBFN"

CLMFN="$(mktemp)"
awk '/^subnet_claimant\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$CLMFN"
check "subnet_claimant: extracted from setup-host.sh (guards the awk)" 0 "DEFAULT GATEWAY" cat "$CLMFN"
check "subnet_claimant: the extracted function is valid bash" 0 "" bash -n "$CLMFN"
claim() { # claim <subnet> <default-route> <addrs>
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$CLMFN'; subnet_claimant \"\$1\"" _ "$1"
}
check "claimant: the default gateway inside the target is the smoking gun" \
  0 "DEFAULT GATEWAY" claim 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "claimant: a foreign interface inside the target is named" \
  0 "virbr7" claim 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "claimant: boxnet's own prior claim is the converge path — CLEAN" \
  1 "" claim 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: a free subnet is clean" \
  1 "" claim 10.89.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: 10.8.0.0/24 does not prefix-match 10.88.x (the dot terminates)" \
  1 "" claim 10.8.0.0/24 "$D_INBOX" "$A_GUEST"
rm -f "$CLMFN"

# --- the whole script, driven: refuse-before-mutation, converge, plumb-through
SETUPSHIM="$(mktemp -d)"
cat > "$SETUPSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven setup-host: records every call (and, for the
# stdin verbs, the stdin) to $FAKE_INCUS_LOG, answers the existence probes
# from FAKE_HAVE_*, and never goes near a daemon.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  *"admin init --preseed"*|*"acl edit"*|*"profile edit"*)
    if [ -n "${FAKE_INCUS_LOG:-}" ]; then sed 's/^/  | /' >> "$FAKE_INCUS_LOG"; else cat >/dev/null; fi ;;
esac
case "$*" in
  "storage show default")         [ -n "${FAKE_HAVE_STORAGE:-}" ] || exit 1 ;;
  "network show boxnet")          [ -n "${FAKE_HAVE_BOXNET:-}" ]  || exit 1 ;;
  "network acl show box-isolate") [ -n "${FAKE_HAVE_ACL:-}" ]     || exit 1 ;;
  "profile show box-net")         [ -n "${FAKE_HAVE_PROFILE:-}" ] || exit 1 ;;
esac
exit 0
SHIM
cat > "$SETUPSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs to $FAKE_SUDO_LOG and swallows everything — the driven
# setup-host must never mutate the machine running this suite.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
exit 0
SHIM
chmod +x "$SETUPSHIM/incus" "$SETUPSHIM/sudo"

runsetup() { # runsetup [VAR=val ...] — the real setup-host, under shims
  env FAKE_UID=1000 FAKE_GROUPS="users incus-admin" \
      PATH="$SETUPSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/setup-host.sh"
}

W80="$(mktemp -d)"
# Refusal 1: the default gateway sits inside the target — the inside of a box.
check "setup-host: gw-in-subnet REFUSES and names issue #80" 1 "issue #80" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g1.log" FAKE_SUDO_LOG="$W80/s1.log"
check "setup-host: ...naming BOX_SUBNET as the way out" 1 "BOX_SUBNET" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: the refusal made NO incus call (refuse precedes mutation)" 1 "" \
  test -e "$W80/g1.log"
check "setup-host: the refusal made NO sudo call either" 1 "" \
  test -e "$W80/s1.log"
# Refusal 2: a foreign interface owns an address inside the target.
check "setup-host: a foreign interface in the subnet REFUSES" 1 "virbr7" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_FOREIGN"
# Refusal 3: garbage BOX_SUBNET dies at the gate.
check "setup-host: a garbage BOX_SUBNET is refused by name" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=banana
check "setup-host: a /16 BOX_SUBNET is refused" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=10.88.0.0/16
# Refusal 4: an existing bridge on ANOTHER subnet is never re-addressed.
check "setup-host: a bridge on another subnet refuses (converge, don't re-address)" \
  1 "never re-addresses" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.89.0.1/24 scope global boxnet' \
           BOX_SUBNET=10.88.0.0/24
# The legitimate re-run: boxnet itself owns the subnet — setup-host converges.
check "setup-host: a prior boxnet claiming the subnet CONVERGES (no false positive)" \
  0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.88.0.1/24 scope global boxnet' \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1
# BOX_SUBNET plumbs through: a fresh build on 10.89.0.0/24 must derive EVERY
# value from it — the bridge address and the ACL's gateway carve-out.
check "setup-host: BOX_SUBNET drives a fresh build to completion" 0 "Host ready" \
  runsetup BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g2.log" FAKE_SUDO_LOG="$W80/s2.log"
check "setup-host: ...the bridge derives from BOX_SUBNET" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g2.log"
check "setup-host: ...and so does the ACL's gateway carve-out" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g2.log"
# ...which also proves the guard scans the TARGET subnet: the same tables that
# refused the default (gw 10.88.0.1) pass once BOX_SUBNET moves off it — the
# issue's workaround host, sanctioned.
rm -rf "$W80" "$SETUPSHIM"

# The guard must be the FIRST effective act — before the incus install, the
# usermod, every apt call. Line order, fail-closed on either grep missing.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the subnet guard precedes the first mutation" 0 "" bash -c '
  guard="$(grep -n "subnet_claimant \"\$BOX_SUBNET\"" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  mut="$(grep -n "^if ! command -v incus" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$mut" ] && [ "$guard" -lt "$mut" ]'
# box-firewall follows the bridge, wherever BOX_SUBNET put it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "box-firewall: the gateway is read off the live bridge, not hardcoded" 0 "" \
  grep -qF 'addr show dev "$NET"' "$ROOT/host/box-firewall.sh"
# The drill and migrate probes derive the prefix from the network — a
# BOX_SUBNET host must not fail its own rehearsals.
check "drill: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/drill.sh"
check "multiuser: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/multiuser.sh"
check "migrate-host: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/host/migrate-host.sh"

# ---------------------------------------------------------------------------
# The doctor's #80 signature. gw_squat_signature is pure text → findings, so
# it is extracted and driven against synthetic route tables — including the
# EXACT poisoned state from the issue, the workaround state (bridge remapped:
# clean), and a healthy host running the stack (clean).
# ---------------------------------------------------------------------------
SIGFN="$(mktemp)"
awk '/^gw_squat_signature\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$SIGFN"
check "gw_squat_signature: extracted from doctor.sh (guards the awk)" 0 "default" cat "$SIGFN"
check "gw_squat_signature: the extracted function is valid bash" 0 "" bash -n "$SIGFN"
sig()   { bash -c ". '$SIGFN'; gw_squat_signature \"\$1\" \"\$2\"" _ "$1" "$2"; }
nosig() { [ -z "$(sig "$1" "$2")" ]; }

# The poisoned guest, verbatim from #80: gateway held locally AND duplicated
# connected routes for the uplink subnet.
R_POISON="$D_INBOX
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1 linkdown
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024"
A_POISON="$A_GUEST
17: boxnet    inet 10.88.0.1/24 scope global boxnet"
check "signature: poisoned guest — the gateway is held as a LOCAL address" \
  0 "held as a LOCAL address" sig "$R_POISON" "$A_POISON"
check "signature: poisoned guest — duplicate connected routes for the uplink" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_POISON"
# The workaround state (#80's fix: bridge remapped off the uplink subnet) —
# both signature lines must be ABSENT.
R_REMAP="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024
10.89.0.0/24 dev boxnet proto kernel scope link src 10.89.0.1 linkdown"
A_REMAP="$A_GUEST
17: boxnet    inet 10.89.0.1/24 scope global boxnet"
check "signature: the remapped-bridge workaround is CLEAN" 0 "" nosig "$R_REMAP" "$A_REMAP"
# A healthy HOST running the stack: boxnet legitimately owns its subnet, and
# the uplink is elsewhere — clean, or every host would cry wolf.
R_HOST="$D_LAN
192.168.1.0/24 dev eno1 proto kernel scope link src 192.168.1.50
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1"
check "signature: a healthy host running the stack is CLEAN" 0 "" nosig "$R_HOST" "$A_HOSTSTACK"
check "signature: no default route → nothing to judge (clean)" 0 "" \
  nosig "10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1" "$A_HOSTSTACK"
# Each line fires on its own: a captured gateway without duplicate routes...
R_GWONLY="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024"
check "signature: a captured gateway alone still fires" \
  0 "held as a LOCAL address" sig "$R_GWONLY" "$A_POISON"
# ...and duplicate routes without the gateway captured (nested bridge on .5).
A_DUPONLY="$A_GUEST
17: boxnet    inet 10.88.0.5/24 scope global boxnet"
check "signature: duplicate routes alone still fire" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_DUPONLY"
rm -f "$SIGFN"

# The wiring: the signature is judged on THIS machine before any daemon call
# (the daemon answering could be the nested impostor), probed INSIDE boxes on
# both tiers, and the egress-broken-DNS-fine split names the fingerprint.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "doctor: this machine's signature precedes the daemon checks" 0 "" bash -c '
  sig="$(grep -n "is a nested box stack squatting" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  daemon="$(grep -n "timeout 10 incus list" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  [ -n "$sig" ] && [ -n "$daemon" ] && [ "$sig" -lt "$daemon" ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the signature is probed inside boxes on BOTH tiers" 0 "" bash -c '
  [ "$(grep -c "probe_sig \"\$probe\"" "'"$ROOT"'/drill/doctor.sh")" -eq 2 ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the egress-broken-DNS-fine fingerprint is named on both tiers" 0 "" bash -c '
  [ "$(grep -c "fingerprint" "'"$ROOT"'/drill/doctor.sh")" -ge 2 ]'
check "doctor: the ACL carve-out is checked against the live gateway" 0 "" \
  grep -qF "does NOT match boxnet's gateway" "$ROOT/drill/doctor.sh"

# The docs keep the new promises.
check "help setup-host names BOX_SUBNET" 0 "BOX_SUBNET" "$BOX" help setup-host
check "help setup-host names the refusal" 0 "REFUSES" "$BOX" help setup-host
check "help doctor names the #80 signature" 0 "#80" "$BOX" help doctor
check "README documents BOX_SUBNET" 0 "" grep -qF 'BOX_SUBNET' "$ROOT/README.md"

# ---------------------------------------------------------------------------
# The versioned install (#66 → 0.7.0). BOX_INSTALL_SOURCE bypasses the network,
# so these are REAL runs of install.sh against throwaway BOX_HOME/BOX_BIN
# roots — layout, symlink chain, flat-tree migration, symlink healing, use and
# uninstall are all DRIVEN, not grepped. A fake `incus` on PATH answers the
# existing-boxes gate ($FAKE_BOXES names them), so the #66 refusals — refuse
# to flip, refuse to switch, refuse to uninstall under boxes — run for real
# too, with no daemon anywhere near this suite.
# ---------------------------------------------------------------------------
VER="$(cat "$ROOT/VERSION")"
WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

ISHIM="$WORK/ishim"; mkdir -p "$ISHIM"
cat > "$ISHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus: 'list' prints $FAKE_BOXES (whitespace-separated names, one per
# line); everything else succeeds silently. Just enough for the existing-boxes
# gate that guards version flips.
case " $* " in
  *" list "*) for b in ${FAKE_BOXES:-}; do printf '%s\n' "$b"; done ;;
esac
exit 0
SHIM
chmod +x "$ISHIM/incus"

# A fabricated "newer release": the same CLI, a different VERSION — what an
# upgrade actually is, from the installer's point of view.
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin"
cp "$ROOT/bin/box" "$SRC9/bin/box"; chmod +x "$SRC9/bin/box"
echo "9.9.9-drill" > "$SRC9/VERSION"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/box" "$SRC8/bin/box"; chmod +x "$SRC8/bin/box"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <box_home> <box_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
ibox() {  # ibox [VAR=val ...] <cmd...> — run an installed box under the shim
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= "$@"
}

# --- fresh install: the layout and the chain --------------------------------
H1="$WORK/h1"; B1="$WORK/b1"
check "install: a fresh install runs clean" 0 "done" inst "$H1" "$B1"
check "install: the tree lands in versions/<v>" 0 "" test -x "$H1/versions/$VER/bin/box"
check "install: 'current' points at versions/<v>" 0 "versions/$VER" readlink "$H1/current"
check "install: the PATH symlink rides the chain" 0 "$H1/current/bin/box" readlink "$B1/box"
check "install: box --version answers through the whole chain" 0 "box $VER" ibox "$B1/box" --version
check "install: INSTALLED_FROM records the local source" 0 "local:" cat "$H1/versions/$VER/INSTALLED_FROM"

# --- converge, don't clobber ------------------------------------------------
touch "$H1/versions/$VER/CANARY"
check "install: a same-version re-run is a no-op that says so (#66)" 0 "already installed" inst "$H1" "$B1"
check "install: the no-op left the tree untouched" 0 "" test -e "$H1/versions/$VER/CANARY"
check "install: BOX_REINSTALL=1 replaces that version's tree" 0 "reinstalled" inst "$H1" "$B1" BOX_REINSTALL=1
check "install: the reinstall really replaced it (canary gone)" 1 "" test -e "$H1/versions/$VER/CANARY"

# --- a second version: side-by-side, and the no-boxes flip ------------------
check "install: a second version installs side-by-side" 0 "" inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...into its own versions dir" 0 "" test -x "$H1/versions/9.9.9-drill/bin/box"
check "install: ...and the old version stays" 0 "" test -d "$H1/versions/$VER"
check "install: with no boxes, the default flips to the new version" 0 "box 9.9.9-drill" ibox "$B1/box" --version

# --- box versions -----------------------------------------------------------
check "versions: lists the installed versions" 0 "$VER" ibox "$B1/box" versions
check "versions: marks the current default" 0 "(current)" ibox "$B1/box" versions
check "versions: marks the running one" 0 "(running)" ibox "$B1/box" versions

# --- box use ----------------------------------------------------------------
check "use: no argument is a usage error" 2 "usage: box use" ibox "$B1/box" use
check "use: an unknown version is refused by name" 1 "no such version" ibox "$B1/box" use 1.2.3
# A version is a directory NAME — a crafted one must die at the gate, never
# reach the ln (current pointing outside the root) or an rm -rf.
check "use: a path-traversal version dies at the gate" 1 "not a sane version name" \
  ibox "$B1/box" use '../../tmp/evil'
check "use: refuses under existing boxes, naming them (#66)" 1 "wedged" \
  ibox FAKE_BOXES="wedged stuck" "$B1/box" use "$VER"
check "use: the refusal points at the remedy (box rm, then re-run)" 1 "box rm" \
  ibox FAKE_BOXES=wedged "$B1/box" use "$VER"
check "use: with no boxes, flips the default" 0 "switched to $VER" ibox "$B1/box" use "$VER"
check "use: the flip is effective through the PATH chain" 0 "box $VER" ibox "$B1/box" --version
check "install: an installed-but-not-current version is a no-op too" 0 "already installed" \
  inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...and does not move the default" 0 "box $VER" ibox "$B1/box" --version

# --- the upgrade-under-boxes refusal, driven end to end ---------------------
H2="$WORK/h2"; B2="$WORK/b2"
check "refusal drill: baseline install" 0 "done" inst "$H2" "$B2"
check "upgrade under boxes: REFUSES the default flip (#66)" 0 "refusing to change the default box version" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "upgrade under boxes: the new version IS installed side-by-side" 0 "" \
  test -d "$H2/versions/9.9.9-drill"
check "upgrade under boxes: the default stayed put" 0 "box $VER" ibox "$B2/box" --version
check "upgrade under boxes: the blocking boxes are NAMED" 0 "· work" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC8" FAKE_BOXES=work
check "upgrade under boxes: the refusal names the deliberate flip" 0 "" \
  bash -c 'grep -q "then flip the default:  box use" "'"$ROOT"'/install.sh"'

# --- migration: a 0.6.0 flat tree becomes a versioned one -------------------
H3="$WORK/h3"; B3="$WORK/b3"; mkdir -p "$H3/bin" "$B3"
cp "$ROOT/bin/box" "$H3/bin/box"; chmod +x "$H3/bin/box"
cp "$ROOT/VERSION" "$H3/VERSION"
echo "test@flat" > "$H3/INSTALLED_FROM"
ln -s "$H3/bin/box" "$B3/box"
check "migrate: a pre-0.7.0 flat tree is moved into versions/" 0 "migrating" inst "$H3" "$B3"
check "migrate: the OPERATOR'S tree moved (not a fresh copy)" 0 "test@flat" \
  cat "$H3/versions/$VER/INSTALLED_FROM"
check "migrate: nothing flat remains at the root" 1 "" test -e "$H3/bin"
check "migrate: current points at the migrated version" 0 "versions/$VER" readlink "$H3/current"
check "migrate: the PATH symlink was re-pointed through current" 0 "$H3/current/bin/box" readlink "$B3/box"
check "migrate: the migrated install answers --version" 0 "box $VER" ibox "$B3/box" --version

# ...and the seamless 0.6.0 → 0.7.0 upgrade: flat tree in, new version beside it.
H4="$WORK/h4"; B4="$WORK/b4"; mkdir -p "$H4/bin" "$B4"
cp "$ROOT/bin/box" "$H4/bin/box"; chmod +x "$H4/bin/box"
cp "$ROOT/VERSION" "$H4/VERSION"
ln -s "$H4/bin/box" "$B4/box"
check "migrate+upgrade: flat 0.6.0 in, new version installed beside it" 0 "" \
  inst "$H4" "$B4" BOX_INSTALL_SOURCE="$SRC9"
check "migrate+upgrade: both versions present" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
check "migrate+upgrade: no boxes → the new version is the default" 0 "box 9.9.9-drill" \
  ibox "$B4/box" --version

# A broken current must halt the single-version path BEFORE any decision: the
# CURRENT guard keys off what current resolves to, and a dangling link makes
# that answer a lie. Drive the version tree's own binary — the current chain
# is exactly what is broken. H4 has two versions; heal current afterwards.
ln -sfn "versions/gone" "$H4/current"
check "uninstall: refuses while current is dangling (heal before delete)" 1 "dangling" \
  ibox "$H4/versions/$VER/bin/box" uninstall 9.9.9-drill --force
check "uninstall: ...and both version trees survived the refusal" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
ln -sfn "versions/9.9.9-drill" "$H4/current"

# The migration reads VERSION off the old tree — disk data, not installer
# data. A hostile value must refuse BEFORE the tree moves anywhere.
H9="$WORK/h9"; B9="$WORK/b9"; mkdir -p "$H9/bin" "$B9"
cp "$ROOT/bin/box" "$H9/bin/box"; chmod +x "$H9/bin/box"
printf '%s\n' '../pwn' > "$H9/VERSION"
check "migrate: a hostile flat VERSION refuses to migrate" 1 "not a sane directory name" \
  inst "$H9" "$B9"
check "migrate: ...with the flat tree untouched where it was" 0 "" test -x "$H9/bin/box"

# --- healing: a wedged \$BINDIR/box must never block an install -------------
H5="$WORK/h5"; B5="$WORK/b5"; mkdir -p "$B5"
ln -s "$WORK/nowhere/box" "$B5/box"                    # dangling
check "heal: a DANGLING \$BINDIR/box does not wedge the install" 0 "done" inst "$H5" "$B5"
check "heal: ...and got repointed" 0 "box $VER" ibox "$B5/box" --version
H6="$WORK/h6"; B6="$WORK/b6"; mkdir -p "$B6"
ln -s /bin/true "$B6/box"                              # stale, but resolvable
check "heal: a STALE \$BINDIR/box with no tree does not fake 'installed'" 0 "installing $VER" \
  inst "$H6" "$B6"
check "heal: ...the install is real and answers" 0 "box $VER" ibox "$B6/box" --version

# --- box uninstall: one version ---------------------------------------------
check "uninstall: refuses to remove the CURRENT version" 1 "CURRENT" \
  ibox "$B1/box" uninstall "$VER" --force
check "uninstall: an unknown version is refused by name" 1 "no such version" \
  ibox "$B1/box" uninstall 5.5.5 --force
check "uninstall: a path-traversal version dies at the gate (never an rm -rf)" 1 "not a sane version name" \
  ibox "$B1/box" uninstall '../../../../etc' --force
check "uninstall: a version plus --all is ambiguous (usage error)" 2 "" \
  ibox "$B1/box" uninstall 9.9.9-drill --all --force
check "uninstall: removes a non-current version" 0 "removed version" \
  ibox "$B1/box" uninstall 9.9.9-drill --force
check "uninstall: that version dir is gone" 1 "" test -e "$H1/versions/9.9.9-drill"
check "uninstall: the current version still answers" 0 "box $VER" ibox "$B1/box" --version

# --- box uninstall: everything, in the safe order ---------------------------
check "uninstall: refuses while boxes exist, naming them" 1 "wedged" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: the refusal offers --purge-host" 1 "purge-host" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: refuses without --force when no terminal" 2 "refusing" \
  ibox bash -c "'$B1/box' uninstall --all </dev/null"
# Plant legacy crumbs: a real uninstall leaves neither name generation behind.
mkdir -p "$FAKEHOME/.local/share/claudebox"
ln -s "$WORK/gone" "$B1/claudebox"
check "uninstall --all: removes the whole install" 0 "uninstalled" \
  ibox "$B1/box" uninstall --all --force
check "uninstall --all: ZERO residue — root, symlinks, legacy names" 0 "" bash -c "
  [ ! -e '$H1' ] && [ ! -L '$H1' ] &&
  [ ! -e '$B1/box' ] && [ ! -L '$B1/box' ] &&
  [ ! -e '$B1/claudebox' ] && [ ! -L '$B1/claudebox' ] &&
  [ ! -e '$FAKEHOME/.local/share/claudebox' ]"
# The last word is a re-check: a survivor must turn into a loud INCOMPLETE,
# never a cheerful "uninstalled". (Root ignores file modes, so this drill is
# meaningful — and runnable — for a non-root runner only.)
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/h7"; B7="$WORK/b7"
  inst "$H7" "$B7" >/dev/null 2>&1
  mkdir -p "$H7/versions/$VER/stuck"; touch "$H7/versions/$VER/stuck/pin"
  chmod 555 "$H7/versions/$VER/stuck"
  check "uninstall: a survivor makes it scream INCOMPLETE (exit 1)" 1 "INCOMPLETE" \
    ibox "$B7/box" uninstall --all --force
  chmod -R u+w "$H7" 2>/dev/null
fi

# --- the versioned verbs from a working tree: refuse, don't guess -----------
check "uninstall: refuses from a working tree" 1 "not a versioned install" "$BOX" uninstall --all --force
check "versions: refuses from a working tree" 1 "not a versioned install" "$BOX" versions
check "use: refuses from a working tree" 1 "not a versioned install" "$BOX" use 1.0.0

# The existing-boxes gate must be ONE decision: install.sh and bin/box carry
# byte-identical copies (the installer runs before any tree exists), and a
# drifted copy is two #66 stances pretending to be one.
EBBIN="$(mktemp)"; EBINST="$(mktemp)"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$EBBIN"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$EBINST"
check "existing_boxes: extracted from bin/box (guards the awk)" 0 "user.box=1" cat "$EBBIN"
check "existing_boxes: bin/box and install.sh copies are byte-identical" 0 "" diff "$EBBIN" "$EBINST"
rm -f "$EBBIN" "$EBINST"

# Same discipline for the version-name gate: one policy, two copies, no drift
# — a version that install.sh would refuse must not be one 'box use' accepts.
VVBIN="$(mktemp)"; VVINST="$(mktemp)"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$VVBIN"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$VVINST"
check "valid_version: extracted from bin/box (guards the awk)" 0 "A-Za-z0-9" cat "$VVBIN"
check "valid_version: bin/box and install.sh copies are byte-identical" 0 "" diff "$VVBIN" "$VVINST"
rm -f "$VVBIN" "$VVINST"

# --purge-host must FORWARD installer-family consent: under --force/BOX_YES
# the teardown call carries --yes, or a non-interactive combined uninstall
# dies at teardown's own prompt with the flag's promise broken.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "uninstall: --purge-host forwards consent to teardown-host (--yes)" 0 "" \
  grep -qF -- 'bash "$root/host/teardown-host.sh" --yes' "$ROOT/bin/box"

# --- the help keeps its promises --------------------------------------------
check "help: the table lists 'versions'"                0 "versions"   "$BOX" help
check "help use: names the #66 stance"                  0 "boxes"      "$BOX" help use
check "help uninstall: names --purge-host"              0 "purge-host" "$BOX" help uninstall
check "help uninstall: promises the absence re-check"   0 "absence"    "$BOX" help uninstall

# --- automation hooks the CI uninstall drill rides ---------------------------
check "teardown-host: honors --yes/BOX_YES (CI runs it unattended)" 0 "" \
  grep -qF 'BOX_YES' "$ROOT/host/teardown-host.sh"
check "teardown-host: points at box uninstall when done" 0 "" \
  grep -qF "box uninstall" "$ROOT/host/teardown-host.sh"
check "drill: reads the installed tree through current/" 0 "" \
  grep -qF '.local/share/box/current/VERSION' "$ROOT/drill/drill.sh"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR" "$WORK"
[ "$FAIL" -eq 0 ]
