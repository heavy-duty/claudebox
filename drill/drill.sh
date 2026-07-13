#!/usr/bin/env bash
# drill.sh — end-to-end drill for claudebox, against a real Incus.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY host you can format.
#     It installs Incus, rewrites the host's firewall rules, installs a systemd
#     unit, and creates and deletes instances. Never run it on a machine you care
#     about.
#
#   bash drill/drill.sh                  # asks first
#   bash drill/drill.sh --yes            # no prompt (CI, or you've read it)
#   bash drill/drill.sh --ref main       # drill a different branch of claudebox
#   bash drill/drill.sh --keep-boxes     # leave the boxes up to poke at
#
# Three phases:
#   A. Incus semantics — the assumptions claudebox is built on, probed directly.
#      These were only ever verified against a stub.
#   B. The claudebox surface — the whole CLI, end to end, including the boundary.
#   C. Isolation — does the trust boundary actually hold?
#
# Exit 0 = every check passed.
#
# The file is one long 'probe && ok "..." || no "..."'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
set -uo pipefail   # NOT -e: a failing check is data, not a crash

REPO="${CLAUDEBOX_REPO:-claude-hdb/claudebox}"
REF="${CLAUDEBOX_REF:-refactor/command-table}"
YES=0; KEEP=0
SELF="$(readlink -f "$0")"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --keep-boxes) KEEP=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --in-group) shift; break ;;                       # internal: see below
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "drill: unknown option: $1" >&2; exit 2 ;;
  esac
done

pass=0; fail=0; findings=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }

# --- stage 1: consent, install, then re-enter inside the incus-admin group ---
if [ "${IN_GROUP:-0}" != 1 ]; then
  if [ "$YES" -ne 1 ]; then
    cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · install Incus and a systemd unit
  · create a network (claudenet), an ACL, and a profile
  · rewrite firewall rules (nft or UFW, and Docker's DOCKER-USER chain)
  · create and destroy instances named: drill, clone, archive, payroll, cbprobe
Only do this on a machine you can format.
EOF
    [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
  fi

  phase "Installing claudebox ($REPO@$REF)"
  CLAUDEBOX_REPO="$REPO" CLAUDEBOX_REF="$REF" \
    bash -c "$(curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/install.sh")" \
    || { echo "install failed"; exit 1; }
  export PATH="$HOME/.local/bin:$PATH"

  phase "Host setup (Incus, claudenet, ACL, profile, firewall)"
  # setup-host.sh drives nft directly, but a stock Debian cloud image has no
  # nftables. If that's the case here, it is a real gap in the repo: record it.
  if ! command -v nft >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
    note "setup-host.sh needs 'nft' (no UFW here either) but nftables is NOT installed — installing it by hand to proceed. Repo gap: setup-host should install its own dependency."
    sudo apt-get install -y -qq nftables >/dev/null 2>&1
  fi
  sudo apt-get install -y -qq incus >/dev/null 2>&1   # so the group exists before we sg
  ~/.local/share/claudebox/host/setup-host.sh || true # first run may only add the group
  # The group we were just added to isn't in this shell's credentials yet.
  exec sg incus-admin -c "IN_GROUP=1 CLAUDEBOX_REPO='$REPO' CLAUDEBOX_REF='$REF' KEEP=$KEEP bash '$SELF' --in-group"
fi

export PATH="$HOME/.local/bin:$PATH"
KEEP="${KEEP:-0}"
~/.local/share/claudebox/host/setup-host.sh || { echo "setup-host failed inside the group"; exit 1; }

# Re-runnable: clear anything a previous drill left behind.
incus delete -f drill clone archive payroll cbprobe cbnotours >/dev/null 2>&1

# A real server has room for the production profile (8GiB/4cpu), and drilling the
# real profile is worth more than drilling a shrunken one. Only shrink if we must.
ram="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
if [ "$ram" -lt 20 ]; then
  incus profile set claude-dev limits.memory=3GiB limits.cpu=2
  note "host has ${ram}GiB RAM — lowered claude-dev to 3GiB/2cpu for the drill (production profile is 8GiB/4cpu, and that is what was NOT drilled)"
else
  inf "host has ${ram}GiB RAM — drilling the production profile (8GiB/4cpu) unchanged"
fi

KVM=0; [ -e /dev/kvm ] && KVM=1
[ "$KVM" = 1 ] && inf "/dev/kvm present — boxes will be VMs (the real trust boundary)" \
               || note "NO /dev/kvm on this host — claudebox will fall back to CONTAINER mode, so this run does NOT validate the VM trust boundary"

# ===========================================================================
phase "A. Incus semantics — the assumptions claudebox is built on"
# ===========================================================================
incus launch images:debian/13 cbprobe --config user.claudebox=1 >/dev/null 2>&1
incus launch images:debian/13 cbnotours >/dev/null 2>&1      # untagged: not ours
sleep 3

# A1 — the tag read. #13 puts this on the path of EVERY box command.
t="$(incus config get cbprobe user.claudebox 2>&1)"
[ "$t" = "1" ] && ok "config get user.claudebox → '1'" \
               || no "config get user.claudebox → '$t' (expected '1'; every box command would fail closed)"

# A2 — the list filter, and that it EXCLUDES an instance we didn't mint
f="$(incus list user.claudebox=1 --format csv --columns nstS 2>&1)"
if echo "$f" | grep -q '^cbprobe,' && ! echo "$f" | grep -q '^cbnotours,'; then
  ok "list filter user.claudebox=1 selects ours, excludes theirs"
else
  no "list filter user.claudebox=1 is wrong — got: $(echo "$f" | tr '\n' ' ')"
fi

# A3 — four fields, no commas/newlines to mangle the awk table
n="$(echo "$f" | grep '^cbprobe,' | awk -F, '{print NF}')"
[ "$n" = 4 ] && ok "--columns nstS → 4 clean CSV fields" || no "--columns nstS → $n fields (the list table would garble)"

# A4 — the state string require_stopped compares against
s="$(incus list cbprobe --format csv --columns s 2>&1 | head -1)"
[ "$s" = RUNNING ] && ok "state column → 'RUNNING'" || no "state column → '$s' (require_stopped compares against RUNNING/STOPPED)"

# A5 — does rename REFUSE a running instance? #13's precondition bets it does.
if r="$(incus rename cbprobe cbprobe2 2>&1)"; then
  no "incus renamed a RUNNING instance — #13's 'stopped' precondition is unnecessary (merely conservative)"
  incus rename cbprobe2 cbprobe >/dev/null 2>&1
else
  ok "incus refuses to rename a running instance → $(echo "$r" | head -1 | cut -c1-60)"
fi

# A6 — snapshot list CSV: 'info' reads field 1 as the label
incus snapshot create cbprobe authed >/dev/null 2>&1
s1="$(incus snapshot list cbprobe --format csv 2>&1 | head -1)"
[ "$(echo "$s1" | cut -d, -f1)" = authed ] && ok "snapshot list csv → field 1 is the label" \
                                           || no "snapshot list csv field 1 ≠ label — got: $s1"

# A7 — the IPv4 column. #9 assumes it can be quoted/multi-line, hence fetching it apart.
inf "ipv4 column raw: $(incus list cbprobe --format csv --columns 4 2>&1 | tr '\n' '|')"

incus delete -f cbprobe cbnotours >/dev/null 2>&1

# ===========================================================================
phase "B. The claudebox surface"
# ===========================================================================
v="$(claudebox --version 2>&1)"
case "$v" in *0.3.0*) ok "claudebox --version → $v" ;; *) no "unexpected version: $v" ;; esac

claudebox list >/dev/null 2>&1 && claudebox list 2>&1 | grep -q 'no boxes yet' \
  && ok "empty host: 'no boxes yet', exit 0" || no "empty-host message wrong"

printf '\n  minting a box (cold, ~10 min)…\n'
t0=$SECONDS
if claudebox new --name drill >/tmp/new.log 2>&1; then
  ok "claudebox new --name drill  ($((SECONDS - t0))s)"
else
  no "claudebox new FAILED — tail: $(tail -3 /tmp/new.log | tr '\n' ' ')"
  echo; echo "── cannot continue without a box"; printf '  %s\n' "${findings[@]}"; exit 1
fi

typ="$(claudebox list | awk '$1 == "drill" { print $3 }')"
if [ "$KVM" = 1 ]; then
  [ "$typ" = VM ] && ok "the box is a VM — the trust boundary is real" \
                  || no "the box is '$typ' but /dev/kvm exists — it should have been a VM"
else
  note "the box is '$typ' (no /dev/kvm on this host)"
fi

claudebox info drill | grep -q '^IPV4' && ok "info shows an IPv4" || no "info has no IPV4 row"
claudebox info drill | grep -q 'SNAPSHOTS  (none)' && ok "info: no snapshots yet, offers to take one" || no "info snapshot-empty state wrong"

claudebox exec drill -- claude --version >/dev/null 2>&1 \
  && ok "Claude Code is installed in the box" || no "'claude --version' failed inside the box"
claudebox exec drill -- gh --version >/dev/null 2>&1 \
  && ok "the GitHub CLI is installed in the box (PR #5)" || no "'gh --version' failed inside the box"

# --- the snapshot → clone workflow, which is the whole point of the tool ---
claudebox snapshot drill authed 2>&1 | grep -q authed && ok "snapshot drill authed" || no "snapshot failed"
claudebox info drill | grep -q 'authed' && ok "info lists the snapshot label" || no "info does not show the label"
claudebox info drill | grep -q -- '--from drill/authed' && ok "info prints the --from line to clone it" || no "info lacks the --from hint"

# --- the boundary: an instance claudebox did NOT mint ----------------------
incus launch images:debian/13 payroll >/dev/null 2>&1   # somebody else's instance
sleep 2
claudebox down payroll 2>&1 | grep -q 'no such box' && ok "boundary: 'down' refuses an untagged instance" || no "boundary: 'down' touched an instance claudebox didn't mint!"
claudebox rm payroll --force 2>&1 | grep -q 'no such box' && ok "boundary: 'rm' refuses an untagged instance" || no "boundary: 'rm' would DELETE a foreign instance!"
claudebox incus payroll -- config show 2>&1 | grep -q 'no such box' && ok "boundary: the escape hatch refuses it too" || no "boundary: the hatch reached a foreign instance!"
incus list payroll --format csv --columns ns | grep -q '^payroll,RUNNING' && ok "…and payroll is still running, untouched" || no "payroll was harmed — the boundary leaked"
incus delete -f payroll >/dev/null 2>&1

# --- rename, and its precondition -----------------------------------------
claudebox rename drill archive 2>&1 | grep -qi 'RUNNING' && ok "rename refuses a running box, and says how to fix it" || no "rename did not refuse a running box"
claudebox down drill >/dev/null 2>&1 && ok "down drill" || no "down failed"
claudebox rename drill archive 2>&1 | grep -q 'renamed drill to archive' && ok "rename drill → archive (stopped)" || no "rename failed on a stopped box"
claudebox list | grep -q '^archive' && ok "list shows the new name" || no "list still shows the old name"
claudebox info archive | grep -q authed && ok "the snapshot followed the rename" || no "snapshot lost across the rename"

# --- clone from a snapshot of a renamed box --------------------------------
printf '\n  cloning from the snapshot…\n'
if claudebox new --name clone --from archive/authed >/tmp/clone.log 2>&1; then
  ok "new --from archive/authed (clone of a snapshot of a renamed box)"
  claudebox exec clone -- true >/dev/null 2>&1 && ok "the clone is alive and enterable" || no "the clone is not enterable"
else
  no "clone FAILED — tail: $(tail -3 /tmp/clone.log | tr '\n' ' ')"
fi

# --- the escape hatch ------------------------------------------------------
claudebox incus archive -- config show 2>/dev/null | grep -q 'user.claudebox' && ok "hatch: 'incus archive -- config show', instance appended" || no "hatch passthrough failed"
h="$(claudebox incus archive -- config device add {} scratch disk source=/tmp path=/mnt/scratch 2>&1)"
echo "$h" | grep -q 'isolation stack' && ok "hatch warns when a command can break isolation" || no "hatch did not warn on a device add"
claudebox incus archive -- config device remove {} scratch >/dev/null 2>&1

# --- rm, and the guard that did not used to exist --------------------------
claudebox rm clone </dev/null 2>&1 | grep -q 'refusing' && ok "rm with no TTY and no --force refuses (exit 2)" || no "rm destroyed a box with no confirmation!"
claudebox rm clone --force 2>&1 | grep -q 'removed' && ok "rm --force removes the clone" || no "rm --force failed"

# --- the CLI contract ------------------------------------------------------
claudebox lst 2>&1 | grep -q "did you mean 'list'" && ok "typo → did-you-mean, exit 2" || no "unknown command not suggested"
claudebox list archive 2>&1 | grep -q 'claudebox info archive' && ok "'list <box>' points at info" || no "'list <box>' does not point at info"
claudebox snapshot archive --labl x 2>&1 | grep -q 'unknown option' && ok "typo'd flag rejected (not swallowed as a label)" || no "unknown flag was swallowed"

# ===========================================================================
phase "C. Isolation — does the boundary actually hold?"
# ===========================================================================
claudebox start archive >/dev/null 2>&1
sleep 10

claudebox exec archive -- curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com 2>/dev/null | grep -q 200 \
  && ok "box reaches the public internet" || no "box cannot reach the internet (a box that can't is useless)"

# The host listens on the claudenet gateway; the box must NOT be able to reach it.
python3 -m http.server 8099 --bind 10.87.0.1 >/dev/null 2>&1 &
srv=$!
sleep 2
if claudebox exec archive -- curl -sS -m 5 -o /dev/null http://10.87.0.1:8099 2>/dev/null; then
  no "THE BOX REACHED THE HOST on 10.87.0.1:8099 — the firewall rules are not holding"
else
  ok "box → host is blocked (no inbound path to the machine)"
fi
kill $srv 2>/dev/null

claudebox exec archive -- curl -sS -m 5 -o /dev/null http://192.168.1.1 2>/dev/null \
  && no "box reached a private-range address — the ACL is not dropping RFC1918" \
  || ok "box → RFC1918 is dropped by the ACL"

# ===========================================================================
if [ "$KEEP" = 1 ]; then
  phase "Boxes left up (--keep-boxes)"
  claudebox list
else
  claudebox rm archive --force >/dev/null 2>&1
  claudebox list 2>&1 | grep -q 'no boxes yet' && ok "teardown: no boxes left" || no "a box survived teardown"
fi

phase "Summary"
printf '  %s passed, %s failed\n' "$pass" "$fail"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi
echo
inf "this host still has Incus, claudenet, the ACL, the profile and the firewall rules."
inf "to undo:  ~/.local/share/claudebox/host/teardown-host.sh [--purge-incus]"
[ "$fail" -eq 0 ]
