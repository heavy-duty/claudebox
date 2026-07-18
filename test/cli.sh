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
# Templates — #65 tmux. `box tmux` runs `tmux new-session` INSIDE the box, so a
# template that never installs tmux fails with "tmux: command not found". Every
# template must carry it in its cloud-init package list.
# ---------------------------------------------------------------------------
for t in blank claude codex grok; do
  check "template '$t': installs tmux (#65)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+tmux$' "$ROOT/templates/$t/user-data.yaml"
done

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
# to setup-host they cannot run).
check "new: pre-flights the box-net profile" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "incus profile show box-net"'
check "new: the restricted fix names box grant" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "box grant"'
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
  bash -c 'grep -A6 "Assert absence" "'"$ROOT"'/host/revoke-user.sh" | grep -q "config trust list"'
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
# The rehearsal itself stays runnable: syntax-checked here, run on real hosts.
check "multiuser.sh is valid bash" 0 "" bash -n "$ROOT/drill/multiuser.sh"
check "multiuser.sh refuses without the env gate" 2 "opt in" \
  bash "$ROOT/drill/multiuser.sh" --yes
check "grant-user.sh is valid bash"  0 "" bash -n "$ROOT/host/grant-user.sh"
check "revoke-user.sh is valid bash" 0 "" bash -n "$ROOT/host/revoke-user.sh"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR"
[ "$FAIL" -eq 0 ]
