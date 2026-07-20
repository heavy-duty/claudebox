#!/usr/bin/env bash
# Dependency-free CLI assertions for box. Run: bash test/cli.sh
#
# Runnable by a NON-root user with NO Incus installed — that is the whole point.
# Anything that needs a real incus daemon (every lifecycle command) is proven the
# way rig proves its root-only paths: source the pure function and drive it against
# a fixture, or grep the load-bearing line so a deleted guard cannot ship green.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
# BOX_YES is this family's documented automation switch, so an operator's CI
# wrapper may well export it. Checks that drive a destructive script for real
# would then take the CONSENT arm instead of the refusal they are asserting —
# turning this suite into `box uninstall --purge-host` on the host it runs on.
# Individual call sites use `env -u BOX_YES`; this is the belt to that braces,
# so the header's "runnable anywhere" promise cannot be broken by one export.
unset BOX_YES
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
    printf "IMAGE=%s USER=%s REQUIRE_VM=%s AUTOSTART=%s ROLE=%s\n" \
      "$T_IMAGE" "$T_USER" "$T_REQUIRE_VM" "$T_AUTOSTART" "$T_BOOTSTRAP_ROLE"
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
# The boot demands' green path, kept as a fixture even now that staging sets
# them in-tree: fixtures survive a template rename, and a deleted case arm
# must fail HERE, through the real parser, not at first use on a host.
mkdir -p "$EVILROOT/templates/server"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="ops"\nBOX_REQUIRE_VM="1"\nBOX_AUTOSTART="1"\n' \
  > "$EVILROOT/templates/server/box.env"
check "load_template: REQUIRE_VM and AUTOSTART round-trip (accepted + surfaced)" \
  0 "REQUIRE_VM=1 AUTOSTART=1" tpl "$EVILROOT" server
# BOX_BOOTSTRAP_ROLE (#81): accepted and surfaced through the real parser —
# and the value is a rig role NAME, nothing more. It is handed to
# 'incus exec … rig bootstrap <role>' at mint, so anything shell-shaped in
# it must die at parse time, on the host, before a guest exists.
mkdir -p "$EVILROOT/templates/tenant"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="claude"\nBOX_BOOTSTRAP_ROLE="claude"\n' \
  > "$EVILROOT/templates/tenant/box.env"
check "load_template: BOX_BOOTSTRAP_ROLE round-trips (accepted + surfaced)" \
  0 "ROLE=claude" tpl "$EVILROOT" tenant
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="claude"\nBOX_BOOTSTRAP_ROLE="claude; rm -rf /"\n' \
  > "$EVILROOT/templates/tenant/box.env"
check "load_template: a shell-shaped BOX_BOOTSTRAP_ROLE dies at the gate" \
  1 "not a sane role name" tpl "$EVILROOT" tenant
rm -rf "$EVILROOT"

# ---------------------------------------------------------------------------
# render_userdata (#81) — the seed's ONE substitution, driven for real: the
# rig pin point. Defaults resolve to heavy-duty/rig@main; RIG_REPO/RIG_REF
# override at mint (how a rig branch under review reaches a guest); and a
# hostile value — the tokens land inside a runcmd shell line — dies on the
# host before touching the YAML. bash's =~ anchors the WHOLE string, so a
# multi-line value cannot sneak one clean line past it (the line-oriented
# grep -q failure mode).
# ---------------------------------------------------------------------------
RUFN="$(mktemp)"
awk '/^render_userdata\(\) \{/,/^\}/' "$ROOT/bin/box" > "$RUFN"
check "render_userdata: extracted from bin/box (guards the awk)" 0 "RIG_REPO" cat "$RUFN"
check "render_userdata: the extracted function is valid bash"    0 "" bash -n "$RUFN"

SEED="$(mktemp)"
printf '#cloud-config\nruncmd:\n  - curl -fsSL https://raw.githubusercontent.com/@RIG_REPO@/@RIG_REF@/install.sh | RIG_REPO="@RIG_REPO@" RIG_REF="@RIG_REF@" bash\n' > "$SEED"
# shellcheck disable=SC2016  # $0/$1 expand in the child shell, by design
rud() { # rud [VAR=val ...] — render the fixture seed through the real function
  env "$@" bash -c 'die() { echo "box: $*" >&2; exit 1; }; . "$0"; render_userdata "$1"' "$RUFN" "$SEED"
}
check "render_userdata: defaults pin heavy-duty/rig" 0 "githubusercontent.com/heavy-duty/rig/main/install.sh" rud
check "render_userdata: defaults feed the installer's own env too" 0 'RIG_REPO="heavy-duty/rig" RIG_REF="main"' rud
check "render_userdata: RIG_REPO/RIG_REF override at mint" 0 "dan-claude-bot/rig/feat/bootstrap-roles/install.sh" \
  rud RIG_REPO=dan-claude-bot/rig RIG_REF=feat/bootstrap-roles
# shellcheck disable=SC2016  # $0/$1 expand in the child shells, by design
check "render_userdata: no token survives the render" 1 "" \
  bash -c 'env bash -c "die() { echo box: \$*; exit 1; }; . \"\$0\"; render_userdata \"\$1\"" "$1" "$2" | grep -q @RIG_' _ "$RUFN" "$SEED"
check "render_userdata: a shell-shaped RIG_REPO dies on the host" 1 "RIG_REPO" \
  rud 'RIG_REPO=evil"; rm -rf /; "/rig'
check "render_userdata: a spaced RIG_REF dies on the host" 1 "RIG_REF" \
  rud 'RIG_REF=main plus junk'
check "render_userdata: a newline-smuggled RIG_REPO dies (whole-string anchor)" 1 "RIG_REPO" \
  rud "RIG_REPO=$(printf 'a/b\nevil')"
rm -f "$RUFN" "$SEED"

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
  # cloud-init is passed to Incus verbatim (modulo the two rig pin tokens),
  # so it must exist, declare itself, and be well-formed — a mint is far too
  # late to learn about a typo.
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
  # BOX_USER is duplicated into the cloud-init by hand (the file reaches
  # Incus verbatim) — assert the two halves actually agree, per template.
  tuser="$(tpl "$ROOT" "$t" | sed -n 's/.*USER=\([^ ]*\).*/\1/p')"
  check "template '$t': user-data.yaml creates BOX_USER ('$tuser')" 0 "" \
    grep -qE "^[[:space:]]*-[[:space:]]+name:[[:space:]]+$tuser\$" "$d/user-data.yaml"

  # ------------------------------------------------------------------------
  # The thin-template contract (#81), both halves per template:
  #
  # THE SEED — a template that names a tenant role (BOX_BOOTSTRAP_ROLE) must
  # preinstall rig carrying BOTH pin tokens, on the installer URL and on the
  # installer's own env, or the pin is a half-truth: a mint would fetch one
  # ref's installer and install another ref's tree.
  # ------------------------------------------------------------------------
  trole="$(tpl "$ROOT" "$t" | sed -n 's/.*ROLE=\([^ ]*\).*/\1/p')"
  if [ -n "$trole" ]; then
    check "template '$t': the seed installs rig (role '$trole')" 0 "" \
      grep -q 'install.sh' "$d/user-data.yaml"
    # shellcheck disable=SC2016  # $1 expands in the child shell, by design
    check "template '$t': the rig install carries the @RIG_REPO@ pin token" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "@RIG_REPO@/@RIG_REF@"' _ "$d/user-data.yaml"
    # shellcheck disable=SC2016
    check "template '$t': the pin reaches the installer's env too" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "RIG_REPO=\"@RIG_REPO@\" RIG_REF=\"@RIG_REF@\""' _ "$d/user-data.yaml"
    # HOME=/root: a scar found live — cloud-init's runcmd has no $HOME and
    # rig's installer (set -u) dies on it (rig#39). The pin must survive
    # every seed rewrite.
    # shellcheck disable=SC2016
    check "template '$t': the rig install pins HOME=/root (runcmd has no \$HOME)" 0 "" \
      bash -c 'grep "install.sh" "$1" | grep -q "HOME=/root "' _ "$d/user-data.yaml"
  fi
  # ------------------------------------------------------------------------
  # THE ABSENCE — no tenant content in ANY template, ever again. Everything a
  # box becomes lives in rig's roles (rig#31); a template that grows an agent
  # CLI, docker, node, a tailnet join or a context-file heredoc is the
  # regression this suite exists to refuse. Greps run over EFFECTIVE
  # cloud-init lines (comments may name what they refuse — #69's idiom), and
  # they fail CLOSED: the want-exit is 1, so re-adding any of it goes red.
  # ------------------------------------------------------------------------
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': no agent CLI install (rig's job, rig#31)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "claude\.ai|x\.ai|@openai|npm|nodesource|nodejs"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no docker (rig's job, rig#31)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qi docker' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': nothing that joins or admits (no tailscale/authkey/ssh)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "tailscale|authkey|ssh"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no context-file heredoc (the #80 guard lives in rig's roles)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "write_files|CLAUDE\.md|AGENTS\.md"' _ "$d/user-data.yaml"
done

# The staging seed's boot demands are part of its contract (#68/#69): the VM
# is its trust boundary (its guest runs docker, via rig) and a server returns
# from a host reboot without an operator. Pinned to the FILE so neither can
# quietly vanish in a rewrite.
check "staging-box: demands VM mode (BOX_REQUIRE_VM=1)" 0 "" \
  grep -qx 'BOX_REQUIRE_VM="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: demands autostart (BOX_AUTOSTART=1)" 0 "" \
  grep -qx 'BOX_AUTOSTART="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: the tenant role is 'staging-box'" 0 "ROLE=staging-box" tpl "$ROOT" staging-box
check "staging-box: the seed user is rig's default for the role ('ops')" 0 "USER=ops" tpl "$ROOT" staging-box
# The agent tenants. Two names, not one: the TEMPLATE is named for the rig role
# it converges — suffix and all, since rig's roles carry a family suffix
# ('-box' for box tenants, '-server' for fleet machines, rig#76) — while the
# seed USER stays the bare agent name, because that is the user rig's role
# converges and the one 'box shell' lands in. The pairing is the whole point of
# pinning it here: a rename that moves one and forgets the other mints a box
# whose role dies looking for a user that was never created.
for u in claude codex grok; do
  check "$u-box: role is '$u-box', seed user is '$u' (rig's tenant mapping)" \
    0 "USER=$u REQUIRE_VM= AUTOSTART= ROLE=$u-box" tpl "$ROOT" "$u-box"
done
# blank stays a box with NOBODY home: no rig, no role — same isolation, no
# tooling, and nothing auto-runs in it.
check "blank: names no bootstrap role" 1 "" \
  grep -q '^BOX_BOOTSTRAP_ROLE=' "$ROOT/templates/blank/box.env"
check "blank: does not preinstall rig" 1 "" grep -q 'install.sh' "$ROOT/templates/blank/user-data.yaml"

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

# The auto-run half of #81, grepped the same way (a daemon-free run cannot
# mint). The seed reaches Incus through render_userdata — the pin point — not
# through a raw cat; and the tenant convergence must order AFTER the
# cloud-init wait (rig is installed by the seed's runcmd, so exec'ing the
# role before cloud-init settles would race its own installer) and sit under
# the T_BOOTSTRAP_ROLE guard (blank must never auto-run anything).
check "new: cloud-init user-data goes through render_userdata (the rig pin)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "cloud-init.user-data" | grep -q "render_userdata"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the tenant auto-run orders after the cloud-init wait" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wait="$(printf "%s\n" "$fn" | grep -n "cloud-init status --wait" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "rig bootstrap" | head -1 | cut -d: -f1)"
  [ -n "$wait" ] && [ -n "$run" ] && [ "$wait" -lt "$run" ]'
check "new: the auto-run sits under the T_BOOTSTRAP_ROLE guard" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -B2 "incus exec .* rig bootstrap" | grep -q "T_BOOTSTRAP_ROLE"'
check "new: a failed tenant role names the re-run (the role converges)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -q "sudo rig bootstrap"'

# The launch phase, narrated and time-boxed (#93) — grepped the way the other
# mint-path guards are (a daemon-free run cannot mint). Twice in the
# 2026-07-19 release drill the child 'incus launch' wedged silently before
# the create was even accepted, once for 56 minutes. The narration must order
# BEFORE the launch call (a wedge after the line is visible at a glance; a
# wedge before it is the old silent hang), the call itself must sit under
# 'timeout -k' with the BOX_LAUNCH_TIMEOUT override and pinned stdin (RUNS.md
# trap 13: bare 'timeout N' cannot kill an incus call that owns a TTY), and
# the budget's failure must be LOUD — no server-side operation, the measured
# retry-succeeds hint, and the doctor as the next move.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the launch narration orders before incus launch (#93)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  say="$(printf "%s\n" "$fn" | grep -n "launching instance" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "timeout -k.*incus launch" | head -1 | cut -d: -f1)"
  [ -n "$say" ] && [ -n "$run" ] && [ "$say" -lt "$run" ]'
check "new: incus launch is time-boxed (timeout -k on the budget)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "timeout -k" | grep "budget" | grep -q "incus launch"'
check "new: the budget is BOX_LAUNCH_TIMEOUT, default 600s (the BOX_CPU knob shape)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "budget=" | grep -q "BOX_LAUNCH_TIMEOUT:-600"'
check "new: the launch pins stdin (RUNS.md trap 13)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "extra[@]" | grep -qF "</dev/null"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the wedge failure is loud — retry hint, the doctor, and #93" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  printf "%s\n" "$fn" | grep -A6 "WEDGED" | grep -q "observed to succeed" &&
  printf "%s\n" "$fn" | grep -q "box doctor" &&
  printf "%s\n" "$fn" | grep "did not finish inside" | grep -q "#93"'
# timeout proves only that the CLIENT overran the budget: launch is
# create-then-start, so a slow launch may have REGISTERED the instance and a
# blind "never created, retry" would send the operator into 'Instance already
# exists' (#94 round-1, all three reviewers). The timeout path must probe the
# instance, tell the two stories apart, and best-effort delete either way so
# the retry advice is safe in both worlds.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path probes before claiming never-created (#94 r1)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus info" | grep -q "\$instance"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path best-effort deletes, so retry is always clean" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus delete --force" | grep -q "|| true"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the overran-but-registered branch says so (not the wedge story)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "OVERRAN" | grep -q "budget"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: BOX_LAUNCH_TIMEOUT is documented in box help new" 0 "" bash -c '
  "'"$ROOT"'/bin/box" help new | grep "BOX_LAUNCH_TIMEOUT" | grep -q 600'
# staging-box's creds-holding join stays OPERATOR-run: cmd_new may print it as
# a next step, but no template and no code path auto-runs "rig bootstrap
# workload-server" — the one absence that keeps box creds-free end to end.
check "new: the workload join is printed, never exec'd" 1 "" bash -c '
  grep "rig bootstrap workload-server" "'"$ROOT"'/bin/box" | grep -q "incus exec"'
check "templates: no template names a creds-holding role" 1 "" bash -c '
  grep -h "^BOX_BOOTSTRAP_ROLE=" "'"$ROOT"'"/templates/*/box.env | grep -qE "workload|host|custom"'

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

# The help is the PRE-RUN CONTRACT: an operator reads it to decide whether to
# run the command at all, so it must not promise a mutation that will not
# happen (or deny one that will). Round 1 of #101 changed what grant/revoke
# mutate for an incus-admin member and left this prose describing the
# superseded design — these pins are why that cannot happen silently again.
# Both directions: the current sentence must be present, and the superseded
# one must be gone.
check "help grant: the admin member's group step is a real add, not a no-op" \
  0 "like anyone else" "$BOX" help grant
check "help revoke: a bare revoke of a granted admin member is 'partial:'" \
  0 "partial:" "$BOX" help revoke
check "help grant no longer calls the admin group step a no-op" 0 "" \
  bash -c '! "'"$BOX"'" help grant | grep -q "reported no-op"'
check "help revoke no longer claims there is no membership to drop" 0 "" \
  bash -c '! "'"$BOX"'" help revoke | grep -q "no membership to drop"'

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
check "grant: an incus-admin member is provisioned, not refused (#99)" 1 "" \
  grep -qF 'there is nothing tighter to grant' "$ROOT/host/grant-user.sh"
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
# Criterion o is the real-Incus half of #101: the shim cannot model an EACCES
# on the user socket, so the admin-only grant is measured where the socket has
# a real owning group. Pinned so it cannot quietly leave the rehearsal.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "rehearsal: grants an incus-admin-ONLY member on real Incus (criterion o)" 0 "" \
  grep -qF 'usermod -aG incus-admin "$U5"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # ditto
check "rehearsal: ...and opens the user socket as them, not just the daemon" 0 "" \
  grep -qF 'INCUS_SOCKET="$sockdir/unix.socket.user"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: purge deletes instances one at a time" 0 "" \
  grep -qF 'delete -f "$inst"' "$ROOT/host/revoke-user.sh"
check "revoke: purge removes the trust-store certificate" 0 "" \
  grep -qF 'config trust remove' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# #99: an incus-admin member is PROVISIONED, not refused. The distinction the
# old refusal missed is permission (the 'incus' group — theirs already, and
# stronger) versus provisioning (the user-<uid> project, the boxnet narrowing,
# snapshots, backups, the box-net profile — theirs not at all). Grepping the
# new prose would prove only that the prose exists, so both tier scripts are
# DRIVEN end to end under shims, the same seam setup-host is driven through:
# every incus and sudo call is logged, and the assertions are made against
# those logs — what the run did, not what the source says it would do.
# ---------------------------------------------------------------------------
GSHIM="$(mktemp -d)"; W99="$(mktemp -d)"
cat > "$GSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven grant/revoke: logs every call, answers the
# existence probes from FAKE_*, and models the two state changes the scripts
# depend on — the project appearing after the incus-user touch, and
# disappearing after a purge deletes it.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in *"profile edit"*) cat >/dev/null ;; esac
case "$*" in
  "network show boxnet")  [ -n "${FAKE_HAVE_BOXNET:-}" ] || exit 1 ;;
  "project show "*)
    [ -e "$FAKE_STATE/deleted" ] && exit 1
    if [ -n "${FAKE_PROJECT_LAZY:-}" ]; then
      # Lazy creation: absent on the first look, present afterwards — i.e.
      # the touch worked. n counts the looks this run has taken.
      n=0; [ -e "$FAKE_STATE/looks" ] && n="$(cat "$FAKE_STATE/looks")"
      printf '%s\n' "$((n + 1))" > "$FAKE_STATE/looks"
      [ "$n" -ge 1 ] || exit 1
    else
      [ -n "${FAKE_HAVE_PROJECT:-}" ] || exit 1
    fi ;;
  "project delete "*) : > "$FAKE_STATE/deleted" ;;
  *"restricted.networks.access"*)
    [ -z "${FAKE_FAIL_NARROW:-}" ] || { echo 'Instance "old" is on incusbr-1000' >&2; exit 1; } ;;
  *"network show "*) exit 1 ;;   # the private bridge: never there in these runs
esac
exit 0
SHIM
cat > "$GSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs and swallows — EXCEPT 'sudo test', which is run for real.
# Both scripts route filesystem probes through it on purpose (/var/lib/incus
# is not traversable by a non-root admin, so an unprivileged stat lies), and
# both directions matter here: revoke's absence assert must see incus-user's
# state directory as genuinely absent on a clean machine, and grant's socket
# check must see the shimmed unix.socket.user as genuinely present.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
case "${1:-}" in test) shift; test "$@"; exit $? ;; esac
exit 0
SHIM
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/getent"
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n'                > "$GSHIM/pgrep"
chmod +x "$GSHIM/incus" "$GSHIM/sudo" "$GSHIM/getent" "$GSHIM/systemctl" "$GSHIM/pgrep"

# The pinned incus-user socket. box grant resolves it through INCUS_DIR (the
# client's own first choice), so a directory here is the whole seam.
mkdir -p "$W99/incusdir"; : > "$W99/incusdir/unix.socket.user"

rungrant() { # rungrant <groups> <state-dir> [VAR=val ...] — the real grant, shimmed
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" \
      FAKE_HAVE_BOXNET=1 FAKE_PROJECT_LAZY=1 INCUS_DIR="$W99/incusdir" \
      FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/grant-user.sh" dev1
}

# --- the admin member: full convergence, no group change, honest caveat -----
A="$W99/admin"
check "grant: an incus-admin member CONVERGES (exit 0, no refusal)" 0 "granted:" \
  rungrant "users incus-admin" "$A"
check "grant: ...and the group step is a real convergence, named as one" 0 "added dev1 to 'incus'" \
  rungrant "users incus-admin" "$W99/a2"
check "grant: ...saying WHY (the socket is a file, group 'incus', not a privilege)" 0 "mode 0660" \
  rungrant "users incus-admin" "$W99/a2b"
check "grant: ...the caveat calls it a default placement, not a confinement" 0 "DEFAULT PLACEMENT" \
  rungrant "users incus-admin" "$W99/a3"
check "grant: ...and names the group that has to go for it to bind" 0 "gpasswd -d dev1 incus-admin" \
  rungrant "users incus-admin" "$W99/a4"
# The logs: what the run actually did to the machine.
# #101's decision, pinned at the seam that broke: an incus-admin member IS
# usermod'ed into 'incus'. It buys them no API privilege they lack — but
# incus-user's socket is a FILE, group 'incus' mode 0660, and without the
# membership the pinned touch below takes EACCES, the '|| true' eats it, and
# the grant dies blaming a healthy incus-user. The shim cannot model that
# EACCES (it ignores INCUS_SOCKET and permissions entirely), so the decision
# is pinned here and MEASURED on real Incus in drill/multiuser.sh criterion o.
check "grant: the admin member IS added to 'incus' — the user socket's group (#101)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$A/sudo.log"
check "grant: their project is still narrowed to boxnet" 0 "" \
  grep -qF 'project set user-1000 restricted.networks.access boxnet' "$A/incus.log"
check "grant: their project still gets snapshots" 0 "" \
  grep -qF 'project set user-1000 restricted.snapshots allow' "$A/incus.log"
check "grant: their project still gets backups" 0 "" \
  grep -qF 'project set user-1000 restricted.backups allow' "$A/incus.log"
check "grant: box-net is still installed INTO their project" 0 "" \
  grep -qF -- '--project user-1000 profile edit box-net' "$A/incus.log"
# The socket pin (#99's teeth): incus's client takes the DAEMON socket when it
# is writable, and only falls back to unix.socket.user when it is not — so for
# an incus-admin member an unpinned touch never reaches incus-user at all, and
# the project it was supposed to create never appears.
check "grant: the touch is pinned at incus-user's socket (the admin socket would win)" 0 "" \
  grep -qF "INCUS_SOCKET=$W99/incusdir/unix.socket.user" "$A/sudo.log"
check "grant: the user-side proof names their project (an unqualified show proves nothing)" 0 "" \
  grep -qF -- '--project user-1000 profile show box-net' "$A/sudo.log"
# The socket existence probe rides $SUDO, like revoke's: /var/lib/incus is not
# traversable by a non-root admin, and a bare [ -e ] there false-fails into an
# exit that blames incus-user for a socket that is present (#101 review).
check "grant: the socket probe goes through sudo, not a bare [ -e ]" 0 "" \
  grep -qF "test -e $W99/incusdir/unix.socket.user" "$A/sudo.log"

# --- the restricted user: unchanged, and unpinned ---------------------------
R="$W99/restricted"
check "grant: a plain user is still added to 'incus'" 0 "added dev1 to 'incus'" \
  rungrant "users" "$R"
check "grant: ...via usermod (the log, not the prose)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$R/sudo.log"
check "grant: ...and their client is left to its own socket fallback" 1 "" \
  grep -qF 'INCUS_SOCKET' "$R/sudo.log"

# --- the failure path: what this run added comes back, and says what didn't --
F="$W99/failed"
check "grant: a failed grant for an admin member exits 1" 1 "FAILED" \
  rungrant "users incus-admin" "$F" FAKE_FAIL_NARROW=1
check "grant: ...says their admin socket was neither granted nor removed here" 1 "neither granted nor removed" \
  rungrant "users incus-admin" "$W99/f2" FAKE_FAIL_NARROW=1
# The membership IS this run's now, so the backout IS its business (#101).
check "grant: ...and DOES roll the 'incus' membership back (this run added it)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$F/sudo.log"
check "grant: ...while refusing to call that rollback a lockout" 1 "closed incus-user's socket, NOT" \
  rungrant "users incus-admin" "$W99/f3" FAKE_FAIL_NARROW=1

# --- revoke, the mirror: it cannot take what it never gave ------------------
# BOX_YES=1 throughout: --purge is destructive and refuses without a terminal
# to confirm on, and this suite has none. It changes nothing for a bare revoke.
runrevoke() { # runrevoke <groups> <state-dir> [script args...]
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" BOX_YES=1 \
      FAKE_HAVE_PROJECT=1 FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" bash "$ROOT/host/revoke-user.sh" dev1 "$@"
}
# The granted admin member is in BOTH groups — that is what 'box grant' leaves
# behind now (#101) — so revoke has a real membership to take back. It takes
# it, and still refuses to call the result a lockout: 'incus-admin' holds the
# daemon and is not this script's to remove.
GRANTED="users incus incus-admin"
V="$W99/revoke"
check "revoke: a bare revoke of a granted admin member is 'partial', not 'revoked'" 0 "partial:" \
  runrevoke "$GRANTED" "$V"
check "revoke: ...and refuses to call it a lockout" 0 "is NOT locked out" \
  runrevoke "$GRANTED" "$W99/v2"
check "revoke: ...naming the group that would actually lock them out" 0 "gpasswd -d dev1 incus-admin" \
  runrevoke "$GRANTED" "$W99/v3"
# The mirror of grant's flip: there IS a privileged call now, and it is the
# membership grant added — asserted against the log, not the prose.
check "revoke: ...having actually dropped the 'incus' membership (the log)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$V/sudo.log"
check "revoke: ...calling that key incus-user's, not their daemon access" 0 "NOT their daemon access" \
  runrevoke "$GRANTED" "$W99/v4"
# An admin member who was never granted: nothing to take, and it still says so
# rather than reporting a revocation it did not perform.
N="$W99/revoke-ungranted"
check "revoke: an UNgranted admin member is still a named no-op" 0 "no-op:" \
  runrevoke "users incus-admin" "$N"
check "revoke: ...saying their access is incus-admin's, untouched here" 0 "which this does not touch" \
  runrevoke "users incus-admin" "$W99/n2"
# Absence of the LOG, not of a line in it: an ungranted admin member's bare
# revoke makes no privileged call whatsoever, so the file is never created.
check "revoke: ...having made NO privileged call at all (no membership to drop)" 1 "" \
  test -e "$N/sudo.log"
P="$W99/purge"
check "revoke --purge: still unmakes the provisioning" 0 "purged:" \
  runrevoke "$GRANTED" "$P" --purge
check "revoke --purge: ...and refuses to call an admin member 'out'" 0 "is NOT out" \
  runrevoke "$GRANTED" "$W99/p2" --purge
check "revoke --purge: ...the project really was deleted (the log, not the summary)" 0 "" \
  grep -qF 'project delete user-1000' "$P/incus.log"
rm -rf "$GSHIM" "$W99"
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
# The confirm gate (#105) — DRIVEN, not grepped.
#
# Until #105 the only coverage restore had was the two argument-validation
# checks above: neither ever reached dispatch, so the verb spent four releases
# handing a running box straight to 'incus snapshot restore' with no prompt
# and no --force, and nothing in this suite could have noticed. Both halves of
# the gate are now exercised against a fake incus that logs what it was asked
# to do — refusing must leave the log EMPTY (an assertion about an absence is
# the only way to prove a gate held), and --force must produce the restore.
#
# Stdin is closed on every run on purpose: confirm() branches on '[ -t 0 ]',
# and a suite run from a terminal would otherwise inherit one and sit there
# waiting for a human to type 'y'.
# ---------------------------------------------------------------------------
CSHIM="$(mktemp -d)"; CWORK="$(mktemp -d)"
cat > "$CSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the destructive-path drive. Logs every call, and answers the
# one probe resolve_box makes so a box called 'work' exists and is ours.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  "config get work user.box") echo 1 ;;
  "config get "*)             exit 1 ;;
esac
exit 0
SHIM
chmod +x "$CSHIM/incus"

runbox() {  # runbox <logfile> <args...> — the real box, shimmed, no TTY
  local log="$1" rc; shift
  : > "$log"
  # Output is kept in <log>.out as well as replayed, so a check can assert on
  # what the run PRINTED after the fact — check() swallows the output of a run
  # it passes, and the "the prompt does not say 'delete'" assertion is exactly
  # that: a claim about text from a run that already passed on its exit code.
  env FAKE_INCUS_LOG="$log" PATH="$CSHIM:$PATH" "$BOX" "$@" </dev/null >"$log.out" 2>&1
  rc=$?
  cat "$log.out"
  return "$rc"
}

# --- restore: the gate refuses, and nothing is destroyed --------------------
RLOG="$CWORK/restore.log"
check "restore: refuses without --force when there is no terminal (#105)" \
  2 "refusing to roll work back to snapshot 'authed'" \
  runbox "$RLOG" restore work authed
# The exact no-TTY wording, pinned. This is the regression test for the CI
# failure this PR produced: the multi-user rehearsal drives restore unattended
# on real Incus, took this refusal, and recorded '(b) restore failed' — a
# 40-minute job catching what a 15-second suite should have. box refuses
# rather than assuming consent, and it says which of the two ways out applies.
check "restore: ...and the refusal names the missing terminal, not a bad usage (#105)" \
  2 "no terminal to confirm on" \
  runbox "$CWORK/r-tty.log" restore work authed
# The load-bearing assertion: the refusal actually PREVENTED the rollback.
# 'grep -q' on an absence, so an empty log passes and a logged restore fails.
check "restore: ...and the refusal reached incus with no restore (#105)" 1 "" \
  grep -qF 'snapshot restore' "$RLOG"
# The prompt must name the SNAPSHOT and the loss, not rm's wording. This is
# the entire point of making the prompt row-driven: adding the 'confirm' token
# alone would have asked the operator to confirm deleting the box.
check "restore: the prompt names what is lost, not a deletion (#105)" \
  2 "discard everything in the box since it was taken" \
  runbox "$CWORK/r2.log" restore work authed
check "restore: the prompt does NOT offer to delete the box (#105)" 1 "" \
  grep -qF 'delete work' "$CWORK/r2.log.out"

# --- restore: --force is the way through, and it still restores -------------
FLOG="$CWORK/force.log"
check "restore --force: skips the prompt and restores (#105)" 0 "restored work to authed" \
  runbox "$FLOG" restore work authed --force
check "restore --force: ...and incus was really asked for the rollback (#105)" 0 "" \
  grep -qF 'incus snapshot restore work authed' "$FLOG"

# --- rm: its wording is unchanged, and its gate still holds -----------------
# #105 moved the prompt out of the dispatch line and into the rows. rm's text
# was the string that lived there, so it is pinned verbatim: a refactor that
# rewords the ONE verb that already asked correctly is a regression.
MLOG="$CWORK/rm.log"
check "rm: still refuses without --force, in its own words (#105 refactor)" \
  2 "refusing to delete work and all its snapshots" \
  runbox "$MLOG" rm work
check "rm: ...and nothing was deleted" 1 "" grep -qF 'delete' "$MLOG"
check "rm --force: still deletes" 0 "removed work" runbox "$CWORK/rmf.log" rm work --force
check "rm --force: ...via 'incus delete -f'" 0 "" \
  grep -qF 'incus delete -f work' "$CWORK/rmf.log"

# --- the table invariant: a confirm row must carry its own words ------------
# Fail-closed on the shape itself, so a future 'confirm' row cannot ship with
# an empty prompt field and inherit whatever the dispatch happens to say.
# shellcheck disable=SC2016  # $3/$7/$1 are awk's fields, not the shell's
check "table: every 'confirm' row supplies a prompt (#105)" 0 "" \
  awk -F'^' '
    /^CMDS=\(/ { in_t = 1; next }
    in_t && /^\)/ { exit }
    in_t && /^  "/ && $3 ~ /(^|,)confirm(,|$)/ {
      seen = 1
      if (NF < 7) { print "row for " $1 " is marked confirm with no prompt field"; bad = 1; next }
      p = $7; sub(/"$/, "", p)
      if (p == "") { print "row for " $1 " has an empty confirm prompt"; bad = 1 }
    }
    END { if (!seen) { print "no confirm rows found — the pin is not reading the table"; bad = 1 }
          exit (bad ? 1 : 0) }
  ' "$ROOT/bin/box"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "dispatch: the confirm prompt comes from the row, not a constant (#105)" 0 "" \
  grep -qF 'confirm "$(fill "$cnf" "$inst")"' "$ROOT/bin/box"
# The rehearsal drives restore unattended on real Incus, so it must consent
# EXPLICITLY — the gate is only real if the one automated caller had to change.
# Pinned here because the rehearsal itself needs a daemon and this suite has none.
check "rehearsal: the unattended restore passes --force (#105)" 0 "" \
  grep -qF 'box restore mine s1 --force' "$ROOT/drill/multiuser.sh"
# --- the three answers a human can give — DRIVEN ON A REAL PTY (#111) -------
# Everything above stops at the no-TTY refusal, because confirm() branches on
# '[ -t 0 ]' and this suite has no terminal. So the interactive half — 'y',
# 'n', and Ctrl-D — had never been executed here at all, which is precisely
# how #111 survived: an unguarded 'read' returns non-zero on EOF, 'set -e'
# ends the run before the 'case', and the abort happens in total silence.
#
# 'script' from util-linux gives the child a pty, so box takes the interactive
# branch for real and reads the answer we write to the master side. This does
# NOT hang a suite run from a terminal: script's own stdin is a file or
# /dev/null on every run below, never the developer's tty, so the answer (or
# the EOF) is always already waiting.
if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -q util-linux; then
  PWORK="$(mktemp -d)"; PLOG="$PWORK/pty.log"
  printf 'y\n' > "$PWORK/yes"; printf 'n\n' > "$PWORK/no"
  # Invoked through a file so 'script -c' needs no quoting of its own; the log
  # path and the shim PATH ride the environment script hands to the child.
  cat > "$PWORK/run" <<RUNNER
#!/usr/bin/env bash
exec env PATH="$CSHIM:\$PATH" "$BOX" rm work
RUNNER
  chmod +x "$PWORK/run"
  ptybox() {  # ptybox <answers-file> — 'box rm work' on a pty, answered
    : > "$PLOG"
    FAKE_INCUS_LOG="$PLOG" script -qec "$PWORK/run" /dev/null < "$1"
  }
  # The load-bearing assertion is the MESSAGE, not the exit code: before the
  # fix Ctrl-D also exited 1, just without ever saying why. Asserting on the
  # code alone would pass against the bug.
  check "rm: Ctrl-D at the prompt aborts OUT LOUD, not in silence (#111)" \
    1 "aborted." ptybox /dev/null
  check "rm: ...and the Ctrl-D abort really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  check "rm: 'n' at the prompt aborts (#111)" 1 "aborted." ptybox "$PWORK/no"
  check "rm: ...and 'n' really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  # The accept path, so the pty rig is proven to be able to reach the work —
  # three checks that can only ever refuse would pass against a box that
  # refuses everything.
  check "rm: 'y' at the prompt goes through (#111)" 0 "removed work" \
    ptybox "$PWORK/yes"
  check "rm: ...and 'y' really reached 'incus delete -f' (#111)" 0 "" \
    grep -qF 'incus delete -f work' "$PLOG"
  rm -rf "$PWORK"
else
  echo "skip: the interactive confirm answers (no util-linux 'script' here; CI has it)"
fi

# --- the sweep: no prompt-shaped 'read' under 'set -e' may go unguarded (#111)
# The pty checks above prove the two 'bin/box' gates. This proves the CLASS,
# repo-wide, and it exists because the class is exactly what the first pass at
# #111 missed: 'host/revoke-user.sh' and 'host/teardown-host.sh' carried the
# identical defect and survived, because nothing here was looking for the shape.
#
# The shape: a 'read' at the start of a statement, fed from the script's own
# stdin (so a human, or an EOF), inside a file that turns on errexit. On EOF
# 'read' returns non-zero and 'set -e' ends the run BEFORE the 'case' that was
# going to name the abort — the tool goes mute at the moment it asked.
#
# What is deliberately NOT flagged, because it is not the shape:
#   · 'while IFS= read -r' loops — fed by a redirect at 'done', and a non-zero
#     read is how the loop is supposed to end;
#   · '<<<' herestring reads — fed from a string, never from a human;
#   · files without errexit ('drill/wipe.sh', 'drill/drill.sh',
#     'drill/multiuser.sh' run under 'set -u' only, wipe.sh documents why), where
#     EOF simply falls through to the '*)' arm and aborts out loud on its own.
# A guard is any '||' on the read's own line: '|| die', '|| reply=""',
# '|| { echo …; exit 1; }' — the spelling is each script's to choose, the
# guard is not.
eof_guard_sweep() {
  local f n line bad=0 files
  # dotglob alongside globstar for the same reason CI's shellcheck step carries
  # it (#116): globstar descends, but a glob does not MATCH a dot-prefixed name,
  # so this sweep skipped '.github/scripts/*.sh' — the release path — exactly as
  # the linter did. Those three set errexit, so they are in scope for this class
  # by construction; today none of them reads at all, which is why widening the
  # set is a no-op on current code rather than a bug fix.
  files="$(cd "$ROOT" && shopt -s globstar dotglob && printf '%s\n' bin/* ./**/*.sh | sed 's|^\./||' | sort -u)"
  while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || continue
    grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$ROOT/$f" || continue
    while IFS=: read -r n line; do
      case "$line" in
        *'<<<'*) continue ;;   # herestring, not a prompt
        *'||'*)  continue ;;   # guarded — the whole point
      esac
      echo "$f:$n: prompt-shaped 'read' under 'set -e' with no '||' guard:$line"
      bad=1
    done < <(grep -nE '^[[:space:]]*(IFS=[^[:space:]]+[[:space:]]+)?read([[:space:]]|$)' "$ROOT/$f")
  done <<<"$files"
  return "$bad"
}
check "no prompt-shaped 'read' under 'set -e' goes unguarded, repo-wide (#111)" \
  0 "" eof_guard_sweep

rm -rf "$CSHIM" "$CWORK"

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

# --- choose_subnet: the four-case decision, driven case by case -------------
# 1 explicit pin: honored or refused, never overridden. 2 no pin + bridge:
# converge to the bridge (the bridge IS the pin) — the scan never runs with a
# bridge present. 3 no pin, no bridge, default free: default. 4 default
# claimed: scan 10.89…10.127, first free wins, loudly; refuse when all claimed.
PICKFN="$(mktemp)"
awk '/^(valid_subnet|subnet_claimant|choose_subnet)\(\) \{/,/^\}/' \
  "$ROOT/host/setup-host.sh" > "$PICKFN"
check "choose_subnet: extracted with its helpers (guards the awk)" 0 "auto-picked" cat "$PICKFN"
check "choose_subnet: subnet_claimant came along" 0 "DEFAULT GATEWAY" cat "$PICKFN"
check "choose_subnet: the extracted functions are valid bash" 0 "" bash -n "$PICKFN"
pick() { # pick <pin> <default-route> <addrs> [boxnet-addr]
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" FAKE_IP4_BOXNET="${4:-}" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$PICKFN'; choose_subnet \"\$1\"" _ "$1"
}
pickout()   { pick "$@" 2>/dev/null; }          # stdout only: the choice itself
pickquiet() { [ -z "$(pick "$@" 2>&1 >/dev/null)" ]; }  # stderr must be EMPTY
picknoscan(){ ! pick "$@" 2>&1 | grep -qF auto-picked; }

# The bridge lines and the both-claimed / all-claimed address tables.
B_88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
B_89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'
A_TWOCLAIM="$A_GUEST
3: virbr7    inet 10.89.0.7/24 brd 10.89.0.255 scope global virbr7"
A_ALLCLAIM="$(for b in $(seq 88 127); do
  printf '%d: virbr%d    inet 10.%d.0.7/24 brd 10.%d.0.255 scope global virbr%d\n' \
    "$((b - 85))" "$((b - 87))" "$b" "$b" "$((b - 87))"
done)"

# Case 1 — the pin. Refusals identical in spirit to the pre-autopick gate.
check "pick: pinned + gw-in-subnet REFUSES, names issue #80" \
  1 "issue #80" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned + foreign interface REFUSES, names it" \
  1 "virbr7" pick 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "pick: a pinned refusal still names BOX_SUBNET" \
  1 "BOX_SUBNET" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned against a disagreeing bridge REFUSES (never re-addresses)" \
  1 "never re-addresses" pick 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK" "$B_89"
check "pick: a garbage pin is refused by name" \
  1 "not a sane subnet" pick banana "$D_LAN" "$A_HOSTSTACK"
check "pick: a pin that clears the gate is used verbatim" \
  0 "10.89.0.0/24" pickout 10.89.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: ...silently — a pin is the operator talking, not us" \
  0 "" pickquiet 10.89.0.0/24 "$D_INBOX" "$A_GUEST"

# Case 2 — no pin, a bridge: converge to ITS subnet. No refusal, no scan —
# even when the default is claimed (THIS machine: nested stack, uplink on
# 10.88, bridge remapped to 10.89 — the #80 workaround host, bare re-run).
check "pick: bridge present converges to the bridge's own subnet" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...announcing the convergence (an off-default bridge is worth a line)" \
  0 "converging" pick "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...and the scan never ran (case 2 precedes case 4)" \
  0 "" picknoscan "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: bridge on the DEFAULT subnet converges silently (plain re-run)" \
  0 "" pickquiet "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
check "pick: ...to the default" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
# The poisoned state (#80 verbatim: bridge AND uplink both on 10.88) must not
# converge — rebuilding there re-arms the blackouts. Refuse, name the fix.
check "pick: a bridge on a FOREIGN-claimed subnet refuses (the poisoned state)" \
  1 "poisoned" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"
check "pick: ...naming the bridge move as the fix" \
  1 "ipv4.address" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"

# Case 3 — no pin, no bridge, default free: the default, silently.
check "pick: a free default host gets 10.88.0.0/24" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" ""
check "pick: ...with no announcement" 0 "" pickquiet "" "$D_LAN" ""

# Case 4 — no pin, no bridge, default claimed: the nested case. First free
# candidate wins, the announcement names the claimant and the pin.
check "pick: default claimed by the gateway auto-picks 10.89.0.0/24" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST"
check "pick: ...saying so loudly" \
  0 "auto-picked 10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...naming WHY (the machine's own gateway = inside a box)" \
  0 "DEFAULT GATEWAY" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...and how to pin it for scripts" \
  0 "BOX_SUBNET=10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: default AND 10.89 claimed skips to 10.90.0.0/24" \
  0 "10.90.0.0/24" pickout "" "$D_INBOX" "$A_TWOCLAIM"
check "pick: every candidate claimed → the old refusal" \
  1 "refusing to build boxnet" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...naming the end of the scan range" \
  1 "10.127.0.0/24" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...and BOX_SUBNET as the way out" \
  1 "BOX_SUBNET" pick "" "$D_LAN" "$A_ALLCLAIM"
rm -f "$PICKFN"

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
# Refusal 1: an EXPLICIT pin on the subnet the default gateway sits inside —
# the inside of a box, and the operator said 10.88 out loud. A pin is never
# silently overridden, so this refuses exactly as it did pre-autopick.
check "setup-host: a pinned gw-claimed subnet REFUSES and names issue #80" 1 "issue #80" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g1.log" FAKE_SUDO_LOG="$W80/s1.log"
check "setup-host: ...naming BOX_SUBNET as the way out" 1 "BOX_SUBNET" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: the refusal made NO incus call (refuse precedes mutation)" 1 "" \
  test -e "$W80/g1.log"
check "setup-host: the refusal made NO sudo call either" 1 "" \
  test -e "$W80/s1.log"
# Refusal 2: a pin on a subnet a foreign interface owns an address inside.
check "setup-host: a pinned foreign-claimed subnet REFUSES" 1 "virbr7" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_FOREIGN"
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
# The nested case with ZERO flags — #80's tables, no pin, no bridge: the
# auto-pick must land the whole build on 10.89, announced, and every derived
# value must follow the pick, not the default.
check "setup-host: nested with no flags auto-picks and completes" 0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g3.log" FAKE_SUDO_LOG="$W80/s3.log"
check "setup-host: ...announcing the auto-pick" 0 "auto-picked 10.89.0.0/24" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...the bridge follows the pick" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g3.log"
check "setup-host: ...the ACL carve-out follows the pick" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g3.log"
rm -rf "$W80" "$SETUPSHIM"

# The decision must be the FIRST effective act — before the incus install, the
# usermod, every apt call. Line order, fail-closed on either grep missing.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the subnet decision precedes the first mutation" 0 "" bash -c '
  guard="$(grep -n "^BOX_SUBNET=\"\$(choose_subnet " "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
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

# ---------------------------------------------------------------------------
# box-firewall's UFW converge and the fail-closed boot window (#86 review,
# items 1–2). The whole script is DRIVEN under shims (the setup-host seam):
# a fake ufw serves canned `ufw status` tables and logs every mutation, fake
# nft/sysctl/iptables swallow the rest, and the shim ip answers the
# live-bridge read. Stale gateway allows must converge to the live gateway,
# a fresh UFW host must get exactly the rule set it always did, a no-UFW
# host must keep its nft path, and the no-bridge-address boot window must
# mutate NOTHING — the old GW=10.88.0.1 fallback built the carve-out for
# the wrong gateway on every BOX_SUBNET host that hit it.
# ---------------------------------------------------------------------------
FWSHIM="$(mktemp -d)"; UFWSHIM="$(mktemp -d)"; WFW="$(mktemp -d)"
cat > "$UFWSHIM/ufw" <<'SHIM'
#!/usr/bin/env bash
# Fake ufw: 'status' prints $FAKE_UFW_STATUS; every call is logged to
# $FAKE_UFW_LOG. Mutations mutate nothing, of course.
[ -n "${FAKE_UFW_LOG:-}" ] && printf 'ufw %s\n' "$*" >> "$FAKE_UFW_LOG"
case "${1:-}" in status) printf '%s\n' "${FAKE_UFW_STATUS:-Status: inactive}" ;; esac
exit 0
SHIM
cat > "$FWSHIM/nft" <<'SHIM'
#!/usr/bin/env bash
# Fake nft: logs to $FAKE_NFT_LOG. The bridge-table probe answers "absent"
# so the creation path runs (and is logged) instead of being skipped.
[ -n "${FAKE_NFT_LOG:-}" ] && printf 'nft %s\n' "$*" >> "$FAKE_NFT_LOG"
case "$*" in "list table bridge box") exit 1 ;; esac
exit 0
SHIM
cat > "$FWSHIM/sysctl" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat > "$FWSHIM/iptables" <<'SHIM'
#!/usr/bin/env bash
# Fake iptables: the DOCKER-USER probe answers "no such chain", so the
# docker block is deterministically skipped whether or not this runner
# happens to have docker.
exit 1
SHIM
chmod +x "$UFWSHIM/ufw" "$FWSHIM/nft" "$FWSHIM/sysctl" "$FWSHIM/iptables"

runfw() { # runfw <ufw|noufw> [VAR=val ...] — the real box-firewall, under shims
  local mode="$1" p rc=0; shift
  p="$FWSHIM:$SHIMDIR:$PATH"
  [ "$mode" = ufw ] && p="$UFWSHIM:$p"
  # Stderr is captured to a file AND re-emitted, rather than only passed
  # through. The driving `check` swallows the output of a run that passes, so
  # when a later grep over the log fails there is nothing left to read — which
  # is precisely the hole #102 fell into. Keeping a copy on disk lets
  # fwlog_ready below show what the run actually said. Overwritten per call by
  # design: every fwlog_ready sits immediately after its own runfw, so "the
  # last run" is always the run being diagnosed.
  env PATH="$p" "$@" bash "$ROOT/host/box-firewall.sh" 2>"$WFW/last-run.err" || rc=$?
  cat "$WFW/last-run.err" >&2
  return "$rc"
}

# fwlog_ready <log> — the shimmed ufw actually logged mutations to <log>.
#
# Why this exists (#102): every grep in the blocks below reads a log written by
# the shimmed ufw during the driving `runfw` check. When something stops the
# UFW branch of box-firewall.sh from running at all, that log is missing — or,
# as it turned out, present but holding nothing except the `ufw status` probe.
# The greps then fail four-at-a-time with empty output: a signature that looks
# alarmingly specific and carries no information whatsoever. #102 was filed
# reading it as "the log is not written", which was a reasonable inference from
# four blank failures and was also wrong; the file was there, the mutations
# were not, and that distinction is the entire diagnosis. So assert the
# precondition explicitly, before the content greps, and on failure print what
# IS in $WFW, what the log itself holds, and what the run wrote to stderr. The
# fix below should mean this never fires — it is here for the next cause, not
# this one, and its whole job is to hand over the evidence instead of making
# the next person re-derive it from a re-run loop.
fwlog_ready() {
  local log="$1" muts
  if [ -f "$log" ]; then
    muts="$(grep -vc "^ufw status" "$log")"
    [ "$muts" -gt 0 ] && return 0
    echo "DIAGNOSIS: $log exists but logs no ufw MUTATION (only 'ufw status')."
    echo "  => box-firewall.sh took its no-UFW branch; the UFW carve-out never ran."
  else
    echo "DIAGNOSIS: $log does not exist — the shimmed ufw was never invoked."
  fi
  echo "  \$WFW ($WFW) holds:"
  # shellcheck disable=SC2012  # a human-read diagnostic dump, not parsed: `ls -la`
  # shows sizes and mtimes, which is the whole point here (a zero-byte log and a
  # log that was never created are different failures). $WFW is our own mktemp -d.
  ls -la "$WFW" 2>&1 | sed 's/^/    /'
  echo "  contents of $(basename "$log"):"
  { [ -f "$log" ] && cat "$log" || echo "(absent)"; } 2>&1 | sed 's/^/    /'
  echo "  stderr of the run that should have written it:"
  { [ -s "$WFW/last-run.err" ] && cat "$WFW/last-run.err" || echo "(empty)"; } 2>&1 | sed 's/^/    /'
  return 1
}

# Canned `ufw status` tables, modeled on the real output shape.
U_HDR='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere'
U_FRESH="$U_HDR"
U_OLDGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere
10.88.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
U_LIVEGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.89.0.1 53/tcp on boxnet ALLOW       Anywhere
10.89.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
BX88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
BX89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'

# The remapped host (#80's escape hatch): bridge on 10.89, UFW still carrying
# 10.88's carve-out — the stale allows go, the live gateway's land.
check "box-firewall: a remapped bridge CONVERGES the UFW carve-out" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/remap.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/remap.log"
check "box-firewall: ...the stale tcp allow is deleted" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and the stale udp allow" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway gains its tcp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and its udp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway's rules are never deleted" 1 "" \
  grep -qF 'delete allow in on boxnet to 10.89.0.1' "$WFW/remap.log"

# The agreeing host: rules already match the live gateway — nothing deleted
# (ufw itself skips the re-adds as existing rules).
check "box-firewall: an agreeing UFW host deletes nothing" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_LIVEGW" FAKE_UFW_LOG="$WFW/agree.log"
# This one matters more than it looks: "no delete was issued" is an ASSERT-ABSENT
# check, so a run that issued nothing at all passes it for the wrong reason.
# fwlog_ready is what keeps the absence meaningful.
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/agree.log"
check "box-firewall: ...no delete was issued" 1 "" grep -qF ' delete ' "$WFW/agree.log"

# The fresh host: no boxnet rules yet — exactly the five historical commands,
# aimed at the live gateway, and nothing else (unchanged behavior).
check "box-firewall: a fresh UFW host runs clean" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX88" FAKE_UFW_STATUS="$U_FRESH" FAKE_UFW_LOG="$WFW/fresh.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/fresh.log"
check "box-firewall: ...the deny lands" 0 "" \
  grep -qF 'ufw insert 1 deny in on boxnet' "$WFW/fresh.log"
check "box-firewall: ...the DNS allows aim at the live gateway" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...DHCP and the route allow land too" 0 "" bash -c '
  grep -qF "ufw insert 1 allow in on boxnet to any port 67 proto udp" "$1" &&
  grep -qF "ufw route allow in on boxnet" "$1"' _ "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...exactly the five historical mutations, no more" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 5 ]' _ "$WFW/fresh.log"

# The boot window (#86 review item 2): bridge not yet addressed → NO guessed
# gateway, NO mutation at all — the persisted rules are left exactly as they
# are, and the skip says so. (The old fallback built 10.88.0.1 rules on a
# BOX_SUBNET host here — a latent DNS drop.)
check "box-firewall: an unaddressed bridge FAILS CLOSED on a UFW host" 0 "left as-is" \
  runfw ufw FAKE_IP4_BOXNET= FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/boot.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...not one ufw mutation was issued" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 0 ]' _ "$WFW/boot.log"
check "box-firewall: the hardcoded gateway fallback is GONE (comments aside)" 1 "" \
  grep -qE '^[^#]*GW=10' "$ROOT/host/box-firewall.sh"

# The no-UFW host: untouched semantics — the nft input carve-out is
# interface-scoped, so it needs no gateway and applies even in the boot
# window where the UFW path now declines to guess.
check "box-firewall: a no-UFW host keeps its nft path" 0 "" \
  runfw noufw FAKE_IP4_BOXNET="$BX89" FAKE_NFT_LOG="$WFW/nft.log"
check "box-firewall: ...the DNS/DHCP accept is interface-scoped" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nft.log"
check "box-firewall: ...and the input drop lands" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet drop' "$WFW/nft.log"
check "box-firewall: the nft path survives the boot window too" 0 "" \
  runfw noufw FAKE_IP4_BOXNET= FAKE_NFT_LOG="$WFW/nftboot.log"
check "box-firewall: ...with the same interface-scoped carve-out" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nftboot.log"

# ---------------------------------------------------------------------------
# The doctor's UFW blind spot (#86 review item 1, second half): the ACL
# check alone gave a remapped UFW host a clean bill while the stale UFW
# allow dropped box DNS. ufw_dns_findings is pure text → findings, the
# gw_squat_signature seam: extracted and driven against canned tables.
# ---------------------------------------------------------------------------
UFWFN="$(mktemp)"
awk '/^ufw_dns_findings\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$UFWFN"
check "ufw_dns_findings: extracted from doctor.sh (guards the awk)" 0 "DNS allow" cat "$UFWFN"
check "ufw_dns_findings: the extracted function is valid bash" 0 "" bash -n "$UFWFN"
ufwsig()   { bash -c ". '$UFWFN'; ufw_dns_findings \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"; }
noufwsig() { [ -z "$(ufwsig "$1" "$2" "$3")" ]; }

check "ufw findings: agreement is SILENT" 0 "" noufwsig "$U_LIVEGW" boxnet 10.89.0.1
check "ufw findings: a stale carve-out is flagged as NOT the live gateway" \
  0 "NOT boxnet's live gateway" ufwsig "$U_OLDGW" boxnet 10.89.0.1
check "ufw findings: ...naming the address it points at" \
  0 "10.88.0.1" ufwsig "$U_OLDGW" boxnet 10.89.0.1
# Our deny with no DNS allow at all is a drop — say so.
U_DENYONLY="$U_HDR
Anywhere on boxnet         DENY        Anywhere"
check "ufw findings: a deny with NO DNS allow is a drop" \
  0 "NO DNS allow" ufwsig "$U_DENYONLY" boxnet 10.89.0.1
# A UFW host box-firewall never touched has nothing to judge — clean.
check "ufw findings: an untouched UFW host is CLEAN" 0 "" noufwsig "$U_FRESH" boxnet 10.89.0.1
# A stale allow left BESIDE the live one still gets named (residue, not a drop).
U_BOTH="$U_LIVEGW
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere"
check "ufw findings: a stale allow beside the live one is named" \
  0 "stale UFW DNS allow" ufwsig "$U_BOTH" boxnet 10.89.0.1
# Rules on OTHER interfaces are not boxnet's problem.
U_OTHERIF="$U_LIVEGW
10.88.0.1 53/tcp on eth0   ALLOW       Anywhere"
check "ufw findings: another interface's DNS allow is ignored" 0 "" \
  noufwsig "$U_OTHERIF" boxnet 10.89.0.1

# The wiring: doctor judges UFW's own table where UFW is active, and the fix
# points at the converging box-firewall.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: reads UFW's table through ufw_dns_findings" 0 "" \
  grep -qF 'ufw_dns_findings "$ufw_out"' "$ROOT/drill/doctor.sh"
check "doctor: the UFW fix names the converge" 0 "" \
  grep -qF 'converges the UFW allows' "$ROOT/drill/doctor.sh"
rm -f "$UFWFN"; rm -rf "$FWSHIM" "$UFWSHIM" "$WFW"

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
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin" "$SRC9/host"
cp "$ROOT/bin/box" "$SRC9/bin/box"; chmod +x "$SRC9/bin/box"
echo "9.9.9-drill" > "$SRC9/VERSION"
# A stub host/setup-host.sh that only announces itself: enough to prove WHETHER
# the installer ran host setup, and from WHICH version's tree, with no Incus and
# no root. The real script builds the isolation stack; this one echoes (#115).
cat > "$SRC9/host/setup-host.sh" <<'STUB'
#!/usr/bin/env bash
echo "SETUP-HOST-RAN-FROM 9.9.9-drill"
STUB
chmod +x "$SRC9/host/setup-host.sh"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/box" "$SRC8/bin/box"; chmod +x "$SRC8/bin/box"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <box_home> <box_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
inst_setup() {  # like inst, but WITHOUT BOX_SKIP_SETUP_HOST — host setup is the
  # thing under test, so the switch that suppresses it has to come off. Safe
  # offline: the only setup-host on these fabricated sources is the echo stub
  # above, and BOX_YES=1 answers its prompt.
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 \
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

# #117: the migration is not silent about the entry it manufactured. The old
# tree is now a first-class 'box versions' row the operator never installed —
# so the output has to name the way back out (uninstall) and the reason to
# keep it (rollback), at the migration AND again in the closing summary, which
# is the half an operator scrolling ~250 lines of install output actually sees.
H3B="$WORK/h3b"; B3B="$WORK/b3b"; mkdir -p "$H3B/bin" "$B3B"
cp "$ROOT/bin/box" "$H3B/bin/box"; chmod +x "$H3B/bin/box"
cp "$ROOT/VERSION" "$H3B/VERSION"
ln -s "$H3B/bin/box" "$B3B/box"
mig_out="$WORK/mig-out.txt"
inst "$H3B" "$B3B" BOX_INSTALL_SOURCE="$SRC9" >"$mig_out" 2>&1 || true
check "migrate: the output points at the reap command (#117)" 0 "box uninstall $VER" \
  cat "$mig_out"
check "migrate: ...and names keeping it as a rollback target (#117)" 0 "keep it to roll back" \
  cat "$mig_out"
check "migrate: ...and the closing summary re-states it (#117)" 0 "was migrated to versions/$VER" \
  cat "$mig_out"
# ...and the note is conditional: an install with nothing to migrate must not
# mention a migration at all. grep exits 1 when the string is absent, which is
# the pass here.
nomig_out="$WORK/nomig-out.txt"
H3C="$WORK/h3c"; B3C="$WORK/b3c"
inst "$H3C" "$B3C" >"$nomig_out" 2>&1 || true
check "migrate: a NON-migrating install stays silent about migration (#117)" 1 "" \
  grep -qF "was migrated to versions/" "$nomig_out"

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

# #115, end to end and fully offline: a flat pre-0.7.0 tree must still count as
# "no install yet" and RUN host setup. The migration converts the flat tree into
# versions/<v>, which is precisely what used to make had_install read 1 — the
# host then skipped setup-host while 'box --version' reported the new release,
# leaving every host-side artifact (box-firewall, #102) at the old one. The stub
# setup-host echoes a marker, so the marker IS the proof it ran.
H4B="$WORK/h4b"; B4B="$WORK/b4b"; mkdir -p "$H4B/bin" "$B4B"
cp "$ROOT/bin/box" "$H4B/bin/box"; chmod +x "$H4B/bin/box"
cp "$ROOT/VERSION" "$H4B/VERSION"
ln -s "$H4B/bin/box" "$B4B/box"
check "flat upgrade: host setup RUNS over a migrated flat tree (#115)" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC9"

# The converse, so the gate is proven to still GATE: H4B is now a genuinely
# versioned tree, which HAS already made the host-setup decision — a re-run must
# not redo it. Without this, "fix" and "run setup-host unconditionally" would be
# indistinguishable.
vers_out="$WORK/versioned-upgrade-out.txt"
inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC8" >"$vers_out" 2>&1 || true
check "versioned upgrade: an existing versioned install still SKIPS host setup" 0 "already had a box install" \
  cat "$vers_out"
check "versioned upgrade: ...and the stub did NOT run" 1 "" \
  grep -qF "SETUP-HOST-RAN-FROM" "$vers_out"

# 'current' does not always flip: the #66 guard holds the default under existing
# boxes. Host setup must still come from the version just installed, or the
# upgrade converges the host with the OLD release's host scripts — reinstating
# the very staleness #115 is about. The flat fixture carries no host/ dir at all,
# so going through 'current' could not even find a script to run.
H10="$WORK/h10"; B10="$WORK/b10"; mkdir -p "$H10/bin" "$B10"
cp "$ROOT/bin/box" "$H10/bin/box"; chmod +x "$H10/bin/box"
cp "$ROOT/VERSION" "$H10/VERSION"
ln -s "$H10/bin/box" "$B10/box"
check "flat upgrade under boxes: setup-host runs the NEW version's script" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H10" "$B10" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "flat upgrade under boxes: ...while the default correctly stayed put (#66)" 0 "box $VER" \
  ibox "$B10/box" --version

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
# ...and the other side of that contract (#113): consent NOT given and no
# terminal to ask on is a usage error, not a mute 'aborted'. Driven for real —
# the gate sits above the first 'incus' call, so a daemon-free run reaches it.
check "teardown-host: refuses without a TTY and names the override (#113)" 2 \
  "--yes (or BOX_YES=1) means yes" env -u BOX_YES bash "$ROOT/host/teardown-host.sh" </dev/null

# #102's race, pinned as a CLASS rather than at the one site that had it
# (#107). A daemon-free run cannot exercise a UFW teardown, so the shape is
# pinned instead: nowhere under host/ or drill/ may a known multi-line writer
# be piped into a line reader. `Status: active` is ufw's FIRST line, so the
# reader matches, closes the pipe, ufw takes SIGPIPE, and the pipeline
# yields 141 — under pipefail the branch silently reads false and the whole
# firewall block is skipped on a host the operator was told is clean.
#
# Swept, not per-file, because absence of pipefail is what made drill/wipe.sh
# survive the same shape: a file is only ever one `set -o pipefail` — the kind
# of robustness tweak that sails through review — from being #102 again. The
# sweep closes the class, so a new host/ or drill/ script inherits the pin for
# free instead of being one more site someone has to remember.
# Comment lines are stripped before matching: each fix's own commentary quotes
# the racing shape to explain it, and a pin that cannot tell prose from code
# would fail on the very comment documenting why it exists.
#
# BOTH halves of the matcher are alternations, and both were widened in #124:
#
#   · READERS. Pinning `| grep` guarded the instance spelling, not the class.
#     `head -n1`, `sed -n '1p;q'` and `awk '/x/ {print; exit}'` all close the
#     pipe early and produce the identical wrong answer under pipefail. The
#     alternation is deliberately NOT restricted to the early-exit spellings
#     (`grep -q` but not `grep -c`, `sed …q` but not `sed s///`): telling
#     those apart by regex is exactly the kind of precision that rots, and
#     the house idiom is to capture first anyway — all six `ufw status` sites
#     in the tree already do. Banning the pipe outright costs nothing real
#     and cannot be defeated by a spelling nobody enumerated.
#
#   · WRITERS. Enumerated, not generalised. `incus config trust list` joins
#     `ufw status` because host/revoke-user.sh used it as a leftover-detection
#     condition under `set -euo pipefail` (#124). A generic "no multi-line
#     writer feeds a reader" matcher is unwritable here: ~150 legitimate
#     `| grep` sites exist across host/ and drill/, nearly all reading an
#     already-captured string back out of `printf '%s\n' "$var"`. So the
#     sweep claims exactly what it can check — THESE writers are never piped
#     — and grows one named writer at a time.
# shellcheck disable=SC2016  # "$1" is the subshell's positional, passed below
check "no multi-line writer is piped into a line reader under host/ or drill/" 0 "" \
  bash -c 'bad=""
    for f in "$1"/host/*.sh "$1"/drill/*.sh; do
      grep -vE "^[[:space:]]*#" "$f" \
        | grep -qE "(ufw status|incus config trust list)[^|]*\| *(grep|head|sed|awk|read)" \
        && bad="$bad ${f#"$1"/}"
    done
    [ -z "$bad" ] || { printf "racing reads in:%s\n" "$bad"; exit 1; }' \
    _ "$ROOT"

# The other direction, per file that removes UFW rules: the capture present and
# the delete loop breaking on absence, so the sweep above cannot be satisfied by
# deleting the block instead of fixing it.
for f in host/teardown-host.sh drill/wipe.sh; do
  # shellcheck disable=SC2016  # the $-strings are literals in the target files
  check "$f: the UFW branch reads a captured snapshot" 0 "" \
    grep -qF 'if [[ "$ufw_status" == *"Status: active"* ]]; then' "$ROOT/$f"
  # shellcheck disable=SC2016  # ditto
  check "$f: the numbered-delete loop breaks on absence, not on a pipe" 0 "" \
    grep -qF '[ -n "$line" ] || break' "$ROOT/$f"
done

# Same other-direction pin for the non-ufw writer the sweep now names: the
# --purge leftover assert must match a captured trust store, so the sweep
# cannot be satisfied by deleting the assert instead of fixing it. That assert
# is the last thing standing between "purge INCOMPLETE" and a silent claim of
# success on a host that still trusts the revoked user's certificate.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke-user: the purge leftover assert reads a captured trust store" 0 "" \
  grep -qF 'trust_csv="$(incus config trust list' "$ROOT/host/revoke-user.sh"
# shellcheck disable=SC2016  # ditto
check "revoke-user: the cert leftover check matches the capture, not a pipe" 0 "" \
  grep -qF '"$trust_csv" == *$' "$ROOT/host/revoke-user.sh"
check "drill: reads the installed tree through current/" 0 "" \
  grep -qF '.local/share/box/current/VERSION' "$ROOT/drill/drill.sh"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR" "$WORK"
[ "$FAIL" -eq 0 ]
