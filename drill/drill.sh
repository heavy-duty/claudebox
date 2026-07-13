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
# Four phases:
#   A. Incus semantics — the assumptions claudebox is built on, probed directly.
#      These were only ever verified against a stub.
#   B. The claudebox surface — the whole CLI, end to end, including the boundary.
#   C. Isolation baseline — does the trust boundary actually hold? (#15 section A)
#   D. Hardening rehearsal — #16's proposed changes, applied live and re-probed
#      (#15 section B). FAILs here are design vetoes, not code bugs.
#
# Exit 0 = every check passed. The summary ends with a block of audit answers
# to paste into heavy-duty/claudebox#15.
#
# The file is one long 'probe && ok "..." || no "..."'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
#
# NOT -e: a failing check is data, not a crash. NOT pipefail: half the checks
# are 'refusal 2>&1 | grep -q text' where the refusal exits 1/2 BY DESIGN, and
# 'grep -q' SIGPIPEs the left side on early match — pipefail turned both into
# false FAILs on the first live run. The pipeline verdict must be grep's alone.
set -u

REPO="${CLAUDEBOX_REPO:-heavy-duty/claudebox}"
REF="${CLAUDEBOX_REF:-main}"
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

pass=0; fail=0; findings=(); audit=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }
aud()  { audit+=("$*"); }                       # an answer for the #15 audit

wait_box() {   # poll until exec answers (the VM agent can take a while), ~2 min
  local b="$1" _i
  for _i in $(seq 1 60); do
    claudebox exec "$b" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

eth0_ip() {    # the box's address on claudenet — eth0 exactly; a box running
               # docker reports several addresses across quoted CSV lines.
               # Retries: the agent answers before DHCP hands out the address.
  local b="$1" ip _i
  for _i in $(seq 1 15); do
    ip="$(incus list "^$b\$" --format csv --columns 4 | tr -d '"' | tr ',' '\n' \
          | awk '/\(eth0\)$/ { print $1; exit }')"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
    sleep 2
  done
  return 1
}

box_listen() { # start a throwaway HTTP listener INSIDE a box, detached.
               # </dev/null is load-bearing: a child holding the exec pty makes
               # 'incus exec' wait forever (the first live run hung here).
  timeout 20 claudebox exec "$1" -- bash -c \
    "command -v python3 >/dev/null && { nohup python3 -m http.server $2 --bind 0.0.0.0 >/dev/null 2>&1 </dev/null & }" \
    >/dev/null 2>&1
  sleep 1
}

# --- stage 1: consent, install, then re-enter inside the incus-admin group ---
if [ "${IN_GROUP:-0}" != 1 ]; then
  if [ "$YES" -ne 1 ]; then
    cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · install Incus and a systemd unit
  · create a network (claudenet), an ACL, and a profile
  · rewrite firewall rules (nft or UFW, and Docker's DOCKER-USER chain)
  · create and destroy instances named: drill, clone, archive, peer, payroll, cbprobe, cbcopy
  · mutate the network and profile mid-run to rehearse the #16 hardening
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
  # setup-host.sh installs nftables itself when neither nft nor UFW exists
  # (fixed in this PR — a stock Debian 13 cloud image ships neither). This
  # guard stays as a tripwire: if it fires, that fix regressed.
  if ! command -v nft >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
    note "neither nft nor ufw present pre-setup — setup-host.sh must install nftables itself (it fixed this once; watch that it still does)"
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
incus delete -f drill clone archive peer payroll cbprobe cbcopy cbnotours >/dev/null 2>&1
incus network unset claudenet dns.mode 2>/dev/null
incus profile device unset claude-dev eth0 security.mac_filtering 2>/dev/null
incus profile device unset claude-dev eth0 security.ipv4_filtering 2>/dev/null

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

# A8 — unset config keys read as EMPTY with exit 0 (#15 B4). The '|| echo root'
# fallback #12 first proposed could never fire if so; #17's lookup depends on this.
u="$(incus config get cbprobe user.never-set 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$u" ]; then
  ok "config get on an unset key → empty string, exit 0"
  aud "B4 config-get unset key: empty + exit 0 — #17 fallbacks must use \${var:-}, never ||"
else
  note "config get on an unset key → rc=$rc out='$u' (not the documented empty+0 — #17's lookup adapts)"
  aud "B4 config-get unset key: rc=$rc out='$u'"
fi

# A9 — 'incus copy' preserves user.* keys (#15 B2). #17's whole metadata design:
# a clone must still know what it is without consulting the template.
incus config set cbprobe user.box.user claude 2>/dev/null
incus stop -f cbprobe >/dev/null 2>&1
incus copy cbprobe cbcopy >/dev/null 2>&1
c="$(incus config get cbcopy user.box.user 2>/dev/null)"
if [ "$c" = claude ]; then
  ok "incus copy preserves user.* keys (a clone knows what it is)"
  aud "B2 copy preserves user.*: YES — #17's metadata-stamp design holds"
else
  no "incus copy DROPPED user.* keys (got '$c') — #17's metadata design fails without them"
  aud "B2 copy preserves user.*: NO — #17 blocked as designed"
fi
incus delete -f cbcopy >/dev/null 2>&1

incus delete -f cbprobe cbnotours >/dev/null 2>&1

# ===========================================================================
phase "B. The claudebox surface"
# ===========================================================================
# Compare against the installed tree's VERSION file, not a hardcoded number —
# a pinned literal here would fail the drill on every release.
expected="$(cat "$HOME/.local/share/claudebox/VERSION" 2>/dev/null || echo '?')"
v="$(claudebox --version 2>&1)"
case "$v" in *"$expected"*) ok "claudebox --version → $v" ;; *) no "version mismatch: CLI says '$v', VERSION file says '$expected'" ;; esac

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

if claudebox exec drill -- claude --version >/dev/null 2>&1; then
  ok "Claude Code is installed in the box"
elif timeout 30 claudebox exec drill -- bash -lc 'claude --version' >/dev/null 2>&1; then
  no "'claude' is installed but NOT on exec's PATH — repo bug: the help promises 'claudebox exec work -- claude --version'"
  inf "PATH as exec sees it: $(timeout 30 claudebox exec drill -- printenv PATH 2>/dev/null)"
else
  no "'claude --version' failed inside the box"
  inf "cloud-init: $(timeout 30 claudebox incus drill -- exec {} -- cloud-init status 2>&1 | head -1)"
  inf "claude's ~/.local/bin holds: $(timeout 30 claudebox incus drill -- exec {} -- ls /home/claude/.local/bin 2>&1 | tr '\n' ' ' | cut -c1-120)"
fi
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
phase "C. Isolation baseline — does the boundary actually hold? (#15 section A)"
# ===========================================================================
claudebox start archive >/dev/null 2>&1
wait_box archive && ok "archive is back up (agent answering)" \
                 || no "archive did not come back within 2 min of start"

# Sibling isolation needs a sibling. Clone from the snapshot — fast, no cold mint.
printf '\n  cloning a peer for the sibling probes…\n'
if claudebox new --name peer --from archive/authed >/tmp/peer.log 2>&1 && wait_box peer; then
  ok "peer minted from archive/authed and answering"
else
  no "peer clone failed or never answered — tail: $(tail -3 /tmp/peer.log | tr '\n' ' ')"
fi

# C1 — public egress (#15 A1; resolving the hostname also proves A5, gateway DNS)
claudebox exec archive -- curl -sS -m 20 -o /dev/null -w '%{http_code}' https://api.github.com 2>/dev/null | grep -q 200 \
  && { ok "box reaches the public internet (and gateway DNS resolves public names)"; aud "A1/A5 egress + public DNS: PASS"; } \
  || { no "box cannot reach the internet (a box that can't is useless)"; aud "A1/A5 egress: FAIL"; }

# C2 — box → host (#15 A2): the host listens on the claudenet gateway
python3 -m http.server 8099 --bind 10.87.0.1 >/dev/null 2>&1 &
srv=$!
sleep 2
if claudebox exec archive -- curl -sS -m 5 -o /dev/null http://10.87.0.1:8099 2>/dev/null; then
  no "THE BOX REACHED THE HOST on 10.87.0.1:8099 — the firewall rules are not holding"
  aud "A2 box→host: FAIL — reached a gateway listener"
else
  ok "box → host is blocked (no path to the machine's sockets)"
  aud "A2 box→host: blocked"
fi
kill $srv 2>/dev/null

# C3 — RFC1918 (#15 A2)
claudebox exec archive -- curl -sS -m 5 -o /dev/null http://192.168.1.1 2>/dev/null \
  && { no "box reached a private-range address — the ACL is not dropping RFC1918"; aud "A2 RFC1918: FAIL"; } \
  || { ok "box → RFC1918 is dropped by the ACL"; aud "A2 RFC1918: dropped"; }

# C4 — SIBLING isolation (#15 A3): the central claim of #12, never reproduced
# live. A listener runs on peer so the curl exit code is unambiguous:
#   0 = connected (isolation broken) · 7 = refused (the packet ARRIVED — the
#   egress drop is not covering siblings) · timeout = dropped, as designed.
PEER_IP="$(eth0_ip peer)"
if [ -n "$PEER_IP" ]; then
  box_listen peer 8088
  claudebox exec archive -- curl -sS -m 5 -o /dev/null "http://$PEER_IP:8088" 2>/dev/null
  rc=$?
  case "$rc" in
    0) no "BOX A CONNECTED TO BOX B ($PEER_IP:8088) — sibling isolation does not hold"
       aud "A3 sibling: FAIL — connected. #16 is a FIX, not a formalization" ;;
    7) no "box A's packets ARRIVE at box B (connection refused, not dropped)"
       aud "A3 sibling: FAIL — refused means the packet arrived. #16 is a FIX" ;;
    *) ok "box A cannot reach box B (drop — curl exit $rc)"
       aud "A3 sibling: blocked (the incidental 10.0.0.0/8 drop covers it, as #12 read)" ;;
  esac
else
  no "could not read peer's eth0 address — the sibling probe never ran"
  aud "A3 sibling: NOT PROBED (no eth0 address on peer)"
fi

# C5 — DNS enumeration (#15 A4): #12 predicts this LEAKS today. Either way it
# is audit data, not a code failure — #16's dns.mode=none is the fix.
e1="$(claudebox exec archive -- getent hosts peer 2>/dev/null)"
e2="$(claudebox exec archive -- getent hosts peer.incus 2>/dev/null)"
if [ -n "$e1$e2" ]; then
  note "DNS enumeration leaks, as #12 predicted: a box resolves its sibling ($(printf '%s' "$e1$e2" | head -1 | cut -c1-50))"
  aud "A4 dns enumeration: LEAKS (bare='${e1:+yes}' fqdn='${e2:+yes}') — #16's dns.mode=none earns its place"
else
  note "DNS enumeration did NOT leak — #16's dns.mode item shrinks to an assertion"
  aud "A4 dns enumeration: no leak observed"
fi

# C6 — IPv6 off (#15 A6): every ACL rule is IPv4-only; off is the only cover.
[ "$(incus network get claudenet ipv6.address 2>/dev/null)" = none ] \
  && { ok "claudenet ipv6.address = none (the IPv4-only ACLs have no uncovered path)"; aud "A6 ipv6: none, as contract requires"; } \
  || { no "claudenet has IPv6 enabled — and not one ACL rule covers IPv6"; aud "A6 ipv6: ENABLED and uncovered"; }

# C7 — inbound, host → box (#15 A7): the ACL's default ingress drop
ARCH_IP="$(eth0_ip archive)"
box_listen archive 8087
if [ -n "$ARCH_IP" ] && curl -sS -m 5 -o /dev/null "http://$ARCH_IP:8087" 2>/dev/null; then
  no "the HOST connected to a listener inside the box — the default ingress drop is not holding"
  aud "A7 inbound host→box: FAIL — reached a box listener"
else
  ok "host → box is dropped (entry is 'incus exec' only, as designed)"
  aud "A7 inbound host→box: dropped"
fi

# ===========================================================================
phase "D. Hardening rehearsal — #16's changes, applied live (#15 section B)"
# ===========================================================================
# The host is disposable, so rehearse the exact changes #16 proposes and watch
# what breaks. A FAIL here vetoes a piece of #16's design before it is written.

# D1 — dns.mode=none (#15 B3): must kill sibling resolution, must NOT kill egress
if incus network set claudenet dns.mode=none 2>/dev/null; then
  sleep 2
  claudebox exec archive -- getent hosts peer.incus >/dev/null 2>&1 \
    && { no "dns.mode=none did not stop sibling resolution"; aud "B3 dns.mode=none: does NOT close the leak"; } \
    || { ok "dns.mode=none: sibling names no longer resolve"; aud "B3 dns.mode=none: closes the enumeration leak"; }
  claudebox exec archive -- curl -sS -m 20 -o /dev/null https://api.github.com 2>/dev/null \
    && { ok "dns.mode=none: public egress still works"; aud "B3 egress under dns.mode=none: intact — safe to ship"; } \
    || { no "dns.mode=none BROKE public DNS — #16 cannot ship it as-is"; aud "B3 egress under dns.mode=none: BROKEN — design veto"; }
else
  no "incus rejected dns.mode=none on claudenet"
  aud "B3 dns.mode=none: REJECTED by incus — #16 needs another mechanism"
fi

# D2 — L2 filtering (#15 B5): the box must keep working with it on.
# Filtering binds at NIC attach, so the boxes restart here.
if incus profile device set claude-dev eth0 security.mac_filtering=true security.ipv4_filtering=true 2>/dev/null; then
  incus restart -f archive peer >/dev/null 2>&1
  wait_box archive || note "archive slow to return after the filtering restart"
  claudebox exec archive -- curl -sS -m 20 -o /dev/null https://api.github.com 2>/dev/null \
    && { ok "mac+ipv4 filtering on: the box still reaches the internet"; aud "B5 L2 filtering: box networking intact — safe for the claude workload"; } \
    || { no "mac+ipv4 filtering BROKE the box's networking"; aud "B5 L2 filtering: BREAKS the box — design veto"; }
  claudebox exec archive -- docker info >/dev/null 2>&1 \
    && { ok "…and in-box Docker still works under ipv4_filtering"; aud "B5 in-box docker under filtering: fine (NAT hides behind eth0, as #12 argued)"; } \
    || { note "in-box docker not confirmed under filtering ('docker info' failed — may be container-mode)"; aud "B5 in-box docker under filtering: UNVERIFIED here"; }
else
  no "incus rejected security filtering on the profile NIC"
  aud "B5 L2 filtering: REJECTED on a profile NIC"
fi

# D3 — @internal as an ACL destination on a bridge network (#15 B1). If it
# holds AND egress survives (the gateway carve-out must win the ordering),
# #16's sibling drop is renumber-proof by construction.
if incus network acl rule add claude-isolate egress action=drop destination=@internal 2>/tmp/ai.err; then
  ok "@internal accepted as an ACL destination on a bridge network"
  claudebox exec archive -- curl -sS -m 20 -o /dev/null https://api.github.com 2>/dev/null \
    && { ok "…and public egress survives the @internal drop (the carve-out wins)"; aud "B1 @internal: accepted, egress survives ⇒ #16 uses @internal"; } \
    || { no "the @internal drop killed egress/DNS — ordering does not protect the carve-out"; aud "B1 @internal: accepted but kills DNS ⇒ #16 derives the subnet instead"; }
  incus network acl rule remove claude-isolate egress action=drop destination=@internal >/dev/null 2>&1
else
  note "@internal rejected on a bridge ACL ($(head -1 /tmp/ai.err 2>/dev/null | cut -c1-60))"
  aud "B1 @internal: rejected ⇒ #16 derives the subnet in setup-host.sh (mask the gateway CIDR)"
fi

# ===========================================================================
if [ "$KEEP" = 1 ]; then
  phase "Boxes left up (--keep-boxes)"
  claudebox list
  inf "note: the D-phase mutations (dns.mode=none, NIC filtering) are still applied"
else
  claudebox rm peer --force >/dev/null 2>&1
  claudebox rm archive --force >/dev/null 2>&1
  claudebox list 2>&1 | grep -q 'no boxes yet' && ok "teardown: no boxes left" || no "a box survived teardown"
fi

phase "Summary"
printf '  %s passed, %s failed\n' "$pass" "$fail"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi

if [ "${#audit[@]}" -gt 0 ]; then
  phase "#15 audit answers — paste this block into heavy-duty/claudebox#15"
  printf '  %s\n' "${audit[@]}"
fi

echo
inf "this host still has Incus, claudenet, the ACL, the profile and the firewall rules"
inf "(plus, unless re-run: dns.mode=none and NIC filtering from the D phase)."
inf "to undo:  ~/.local/share/claudebox/host/teardown-host.sh [--purge-incus]"
[ "$fail" -eq 0 ]
