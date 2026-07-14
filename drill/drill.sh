#!/usr/bin/env bash
# drill.sh — end-to-end drill for box (the claudebox repo), against a real Incus.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY host you can format.
#     It installs Incus, rewrites the host's firewall rules, installs a systemd
#     unit, and creates and deletes instances. Never run it on a machine you care
#     about.
#
#   bash drill/drill.sh                  # asks first
#   bash drill/drill.sh --yes            # no prompt (CI, or you've read it)
#   bash drill/drill.sh --ref main       # drill a different branch of the repo
#   bash drill/drill.sh --keep-boxes     # leave the boxes up to poke at
#
# Four phases:
#   A. Incus semantics — the assumptions box is built on, probed directly.
#      These were only ever verified against a stub.
#   B. The box surface — the whole CLI, end to end, including the boundary.
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
    box exec "$b" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Read from inside a box WITHOUT ever hanging the drill.
#
# Two traps, both hit for real:
#   · 'box exec' becomes 'sudo -u <template user> -i' — a LOGIN zsh (oh-my-zsh and
#     all). Fine for a person, needless machinery for a probe.
#   · $( ) waits for stdout to CLOSE, not for the command to exit. A grandchild
#     inheriting the exec session's stdout keeps the substitution open forever,
#     and 'timeout' does not save you: it kills the wrapper, not the holder of
#     the pipe. Run 4 hung 10+ minutes on exactly this.
# So: talk to 'incus exec' directly, pin stdin to /dev/null, land the output in
# a file (never a pipe), and hard-kill on timeout.
in_box() {
  local b="$1"; shift
  local out; out="$(mktemp)"
  timeout -k 5 20 incus exec "$b" -- "$@" >"$out" 2>/dev/null </dev/null
  local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

# The box's address ON BOXNET. Three ways to get this wrong, all of them hit:
#   · 'incus list' name filters are NOT regexes ("^b$" silently matches nothing)
#   · its CSV quotes a multi-address box across lines
#   · and the interface is NOT called eth0. The PROFILE names the device eth0,
#     but inside a VM guest predictable naming renames it enp5s0. Six runs of
#     A3 "not probed" were this, not the network.
# So: read it from inside the box, and select by SUBNET (10.88.x, what boxnet
# hands out) rather than by interface name — docker0 (172.17.x) is the decoy,
# and the NIC's name is the guest's business, not ours.
boxnet_ip() {
  local b="$1" ip _i
  for _i in $(seq 1 15); do
    ip="$(in_box "$b" ip -4 -o addr show scope global \
          | awk '{ for (i = 1; i < NF; i++) if ($i == "inet" && $(i+1) ~ /^10\.88\./) { split($(i+1), a, "/"); print a[1]; exit } }')"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
    sleep 2
  done
  return 1
}

# The probe. Its verdict comes from curl's MESSAGE, never from its exit code.
#
# curl exit 7 is "failed to connect" — and it covers BOTH of these:
#   · "Connection refused"  → a RST came back. The packet ARRIVED. Reachable.
#   · "Could not connect to server" / "No route to host" → nothing came back at
#     all. The frame went nowhere. ISOLATED.
# Opposite conclusions, one exit code. The drill mapped 7 → "it arrived" and so
# reported a WORKING boundary as a broken one, run after run, while the kernel
# had 'isolated on' the bridge ports the whole time. A refusal is instant; an
# unreachable host burns the timeout. The words say which; the number cannot.
#
# Never hangs: incus exec directly (no login shell), stdin pinned, output landed
# in a file rather than a pipe, hard kill on timeout.
box_probe() {   # box_probe <box> <url> [timeout] → reachable | refused | dropped
  local b="$1" url="$2" t="${3:-5}" out rc msg
  out="$(mktemp)"
  timeout -k 5 $((t + 15)) incus exec "$b" -- curl -sS -m "$t" -o /dev/null "$url" \
    >/dev/null 2>"$out" </dev/null
  rc=$?
  msg="$(cat "$out")"; rm -f "$out"
  if [ "$rc" -eq 0 ]; then echo reachable; return; fi
  case "$msg" in
    *"Connection refused"*) echo refused ;;   # it ARRIVED, and was rejected
    *)                      echo dropped ;;   # nothing came back
  esac
}

box_pings() {   # box_pings <box> <ip> → 0 if it answers ICMP
  timeout -k 5 20 incus exec "$1" -- ping -c1 -W2 "$2" >/dev/null 2>&1 </dev/null
}

# --- stage 1: consent, install, then re-enter inside the incus-admin group ---
if [ "${IN_GROUP:-0}" != 1 ]; then
  if [ "$YES" -ne 1 ]; then
    cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · install Incus and a systemd unit
  · create a network (boxnet), an ACL, and a profile
  · rewrite firewall rules (nft or UFW, and Docker's DOCKER-USER chain)
  · create and destroy instances named: drill, clone, archive, peer, payroll, cbprobe, cbcopy, tpl
  · mutate the network and profile mid-run to rehearse the #16 hardening
Only do this on a machine you can format.
EOF
    [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
  fi

  phase "Installing box ($REPO@$REF)"
  CLAUDEBOX_REPO="$REPO" CLAUDEBOX_REF="$REF" \
    bash -c "$(curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/install.sh")" \
    || { echo "install failed"; exit 1; }
  export PATH="$HOME/.local/bin:$PATH"

  phase "Host setup (Incus, boxnet, ACL, profile, firewall)"
  # setup-host.sh installs nftables itself when neither nft nor UFW exists
  # (a stock Debian 13 cloud image ships neither). This guard is a tripwire:
  # if it fires, that fix regressed.
  if ! command -v nft >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
    note "neither nft nor ufw present pre-setup — setup-host.sh must install nftables itself (it fixed this once; watch that it still does)"
  fi

  # Sudo, up front and out loud. Later calls run unattended, and a password
  # prompt swallowed by a '-qq' redirect looks exactly like a hang.
  sudo -v || { echo "drill: need sudo (the host setup installs packages and firewall rules)"; exit 1; }

  # apt's lock is held by apt-daily / unattended-upgrades on a fresh cloud
  # image, and 'apt-get -qq >/dev/null' waits for it in COMPLETE SILENCE —
  # which is how run 5 looked stuck for minutes right after this header.
  # Say what we are waiting for, and give up rather than hang forever.
  if ! command -v incus >/dev/null 2>&1; then
    inf "installing incus (waiting for the apt lock if a background upgrade holds it)…"
    if ! sudo DEBIAN_FRONTEND=noninteractive timeout 600 \
           apt-get -o DPkg::Lock::Timeout=300 install -y incus; then
      echo "drill: 'apt-get install incus' failed or timed out." >&2
      echo "  a background apt job usually holds the lock. check with:" >&2
      echo "    sudo fuser -v /var/lib/dpkg/lock-frontend" >&2
      echo "    systemctl status unattended-upgrades apt-daily.service" >&2
      exit 1
    fi
  else
    inf "incus already installed — skipping apt"
  fi

  inf "running setup-host.sh (first pass: may only add you to incus-admin)…"
  ~/.local/share/claudebox/host/setup-host.sh || true
  # The group we were just added to isn't in this shell's credentials yet.
  inf "re-entering inside the incus-admin group…"
  exec sg incus-admin -c "IN_GROUP=1 CLAUDEBOX_REPO='$REPO' CLAUDEBOX_REF='$REF' KEEP=$KEEP bash '$SELF' --in-group"
fi

export PATH="$HOME/.local/bin:$PATH"
KEEP="${KEEP:-0}"

# CLEAN BEFORE SETUP, not after. setup-host.sh reconfigures the network's ACLs,
# and a previous run's boxes are still ATTACHED to that network — 'incus network
# set' then has to push the change onto every live NIC, which is how run 6
# stalled. An aborted run also leaves the D-phase mutations (dns.mode=none, NIC
# filtering) in place, so setup would be converging against a moving target.
# Take the boxes down and revert the mutations FIRST; then the host is a
# clean-ish slate and setup-host is the no-op it should be.
# A host still carrying a previous run's phase-D mutations mints boxes with no
# DNS, and then reports the resulting breakage as a finding. Refuse to run.
# NOTE: dns.mode=none is now part of the SHIPPED stack (it closes the sibling
# DNS-enumeration leak), so it is no longer "dirt" from a rehearsal — do not
# revert it. Only the vetoed NIC filtering counts as leftover.
dirty=""
for p in box-net claude-dev; do
  [ -n "$(incus profile device get "$p" eth0 security.ipv4_filtering 2>/dev/null)" ] && dirty="$dirty $p:ipv4_filtering"
  [ -n "$(incus profile device get "$p" eth0 security.mac_filtering 2>/dev/null)" ] && dirty="$dirty $p:mac_filtering"
done
if [ -n "$dirty" ]; then
  note "this host carries the VETOED NIC filtering from an old rehearsal:$dirty — reverting"
  for p in box-net claude-dev; do
    incus profile device unset "$p" eth0 security.mac_filtering >/dev/null 2>&1
    incus profile device unset "$p" eth0 security.ipv4_filtering >/dev/null 2>&1
  done
fi

inf "clearing anything a previous run left behind…"
# One name at a time — 'incus delete -f a b c' aborts at the first MISSING name,
# which is how run 2 inherited run 1's boxes and cascaded five false FAILs.
for n in drill clone archive peer payroll cbprobe cbcopy cbnotours tpl; do
  timeout -k 5 60 incus delete -f "$n" >/dev/null 2>&1
done
if incus network show boxnet >/dev/null 2>&1; then
  timeout -k 5 30 incus network unset boxnet dns.mode >/dev/null 2>&1
fi
for p in box-net claude-dev; do
  if incus profile show "$p" >/dev/null 2>&1; then
    timeout -k 5 30 incus profile device unset "$p" eth0 security.mac_filtering >/dev/null 2>&1
    timeout -k 5 30 incus profile device unset "$p" eth0 security.ipv4_filtering >/dev/null 2>&1
  fi
done
left="$(incus list --format csv --columns n 2>/dev/null | tr '\n' ' ')"
[ -n "$left" ] && inf "instances still on this host (not ours, left alone): $left"

inf "running setup-host.sh (in-group pass: network, ACL, profile, firewall)…"
if ! timeout -k 10 300 ~/.local/share/claudebox/host/setup-host.sh; then
  echo "drill: setup-host.sh failed or timed out (>5 min)." >&2
  echo "  it should take seconds on a host that already has incus. usual causes:" >&2
  echo "    · instances still attached to boxnet while its ACLs are reconfigured" >&2
  echo "        incus list" >&2
  echo "    · the firewall unit not completing" >&2
  echo "        systemctl status box-firewall.service --no-pager" >&2
  echo "    · the incus daemon wedged by an earlier aborted run" >&2
  echo "        systemctl status incus --no-pager; journalctl -u incus -n 30 --no-pager" >&2
  exit 1
fi
inf "host setup complete"

# A real server has room for the claude template's resources (8GiB/4cpu), and
# drilling the real numbers is worth more than drilling shrunken ones. Only
# shrink if we must. Since 0.4.0 resources are per-box, stamped from the
# template at mint — a profile edit no longer reaches them; the supported
# override is the BOX_* environment, which every 'box new' below inherits.
ram="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
if [ "$ram" -lt 20 ]; then
  export BOX_MEMORY=3GiB BOX_CPU=2
  note "host has ${ram}GiB RAM — minting at 3GiB/2cpu via BOX_MEMORY/BOX_CPU (the claude template's 8GiB/4cpu is what was NOT drilled)"
else
  inf "host has ${ram}GiB RAM — drilling the claude template's resources (8GiB/4cpu) unchanged"
fi

KVM=0; [ -e /dev/kvm ] && KVM=1
[ "$KVM" = 1 ] && inf "/dev/kvm present — boxes will be VMs (the real trust boundary)" \
               || note "NO /dev/kvm on this host — box will fall back to CONTAINER mode, so this run does NOT validate the VM trust boundary"

# ===========================================================================
phase "A. Incus semantics — the assumptions box is built on"
# ===========================================================================
incus launch images:debian/13 cbprobe --config user.box=1 >/dev/null 2>&1
incus launch images:debian/13 cbnotours >/dev/null 2>&1      # untagged: not ours
sleep 3

# A1 — the tag read. #13 puts this on the path of EVERY box command.
t="$(incus config get cbprobe user.box 2>&1)"
[ "$t" = "1" ] && ok "config get user.box → '1'" \
               || no "config get user.box → '$t' (expected '1'; every box command would fail closed)"

# A2 — the list filter, and that it EXCLUDES an instance we didn't mint
f="$(incus list user.box=1 --format csv --columns nstS 2>&1)"
if echo "$f" | grep -q '^cbprobe,' && ! echo "$f" | grep -q '^cbnotours,'; then
  ok "list filter user.box=1 selects ours, excludes theirs"
else
  no "list filter user.box=1 is wrong — got: $(echo "$f" | tr '\n' ' ')"
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
phase "B. The box surface"
# ===========================================================================
# Compare against the installed tree's VERSION file, not a hardcoded number —
# a pinned literal here would fail the drill on every release.
expected="$(cat "$HOME/.local/share/claudebox/VERSION" 2>/dev/null || echo '?')"
v="$(box --version 2>&1)"
case "$v" in *"$expected"*) ok "box --version → $v" ;; *) no "version mismatch: CLI says '$v', VERSION file says '$expected'" ;; esac

# The drill must not require an empty host: operator boxes tagged
# user.box=1 (or the legacy tag) are legitimate tenants, and the teardown below deliberately
# refuses to touch them. The empty-host message is only TESTABLE when the host
# is actually empty — on a shared host, skip it instead of failing it.
tenants="$({ incus list user.box=1 --format csv --columns n 2>/dev/null
             incus list user.claudebox=1 --format csv --columns n 2>/dev/null; } | sort -u | tr '\n' ' ')"
if [ -n "${tenants% }" ]; then
  inf "host already has boxes (${tenants% }) — the empty-host message cannot be tested this run"
else
  box list >/dev/null 2>&1 && box list 2>&1 | grep -q 'no boxes yet' \
    && ok "empty host: 'no boxes yet', exit 0" || no "empty-host message wrong"
fi

# --- templates: the mint surface is itself a surface to test ----------------
box templates 2>/dev/null | grep -q '^  blank' && box templates 2>/dev/null | grep -q '^  claude' \
  && ok "templates: lists blank and claude" || no "templates listing is missing a shipped template"
box new --name tpl --template nosuch 2>&1 | grep -q 'no such template' \
  && ok "unknown template refused, points at 'box templates'" || no "an unknown template was not refused"
# The one rule that keeps templates honest: no key can name a network. Plant a
# bad template in the installed tree (the drill owns this host), expect the
# parser to reject it BY NAME, remove it.
badt="$HOME/.local/share/claudebox/templates/cbdrill-bad"
mkdir -p "$badt" && printf 'BOX_IMAGE="x"\nBOX_USER="y"\nBOX_NETWORK="lan"\n' >"$badt/box.env" && : >"$badt/user-data.yaml"
box new --name tpl --template cbdrill-bad 2>&1 | grep -q "unknown key 'BOX_NETWORK'" \
  && ok "a template cannot name a network — BOX_NETWORK rejected by name" \
  || no "a box.env key outside the allowlist was ACCEPTED — a template could weaken isolation"
rm -rf "$badt"

printf '\n  minting a blank box (the DEFAULT template — no tooling, fast)…\n'
t0=$SECONDS
if box new --name tpl >/tmp/tpl.log 2>&1; then
  ok "box new --name tpl, no --template  ($((SECONDS - t0))s)"
  tt="$(incus config get tpl user.box.template 2>/dev/null)"
  [ "$tt" = blank ] && ok "the default template is blank (user.box.template=blank)" \
                    || no "default template is '${tt:-<unset>}' — expected blank"
  [ "$(incus config get tpl user.box.user 2>/dev/null)" = dev ] \
    && ok "template user stamped on the instance (user.box.user=dev)" || no "user.box.user not stamped"
  incus config show tpl 2>/dev/null | grep -q '^- box-net' \
    && ok "blank box launched with the box-net profile — same placement contract" \
    || no "blank box is NOT on box-net — a template picked its own placement?!"
  u="$(timeout -k 5 30 box exec tpl -- whoami </dev/null 2>/dev/null | tr -d '[:space:]')"
  [ "$u" = dev ] && ok "exec lands in the template's user ($u) — nothing hardcodes claude" \
                 || no "exec landed in '${u:-<nothing>}', expected dev"
  timeout -k 5 30 box exec tpl -- sh -lc 'command -v claude' </dev/null >/dev/null 2>&1 \
    && no "the blank box has claude installed — 'blank' is not blank" \
    || ok "blank box has no claude — nobody home, as designed"
  box_pings tpl 1.1.1.1 && ok "blank box reaches the internet (same egress as any template)" \
                        || no "blank box has NO egress — isolation parity broken"
  in_box tpl getent hosts deb.debian.org >/dev/null 2>&1 \
    && ok "blank box resolves public names (pinned resolver serves every template)" \
    || no "blank box cannot resolve — DNS parity broken"
  box rm tpl --force >/dev/null 2>&1 && ok "blank box removed" || no "could not remove the blank box"
else
  no "blank mint FAILED — tail: $(tail -3 /tmp/tpl.log | tr '\n' ' ')"
fi

printf '\n  minting a claude box (cold, ~10 min)…\n'
t0=$SECONDS
if box new --name drill --template claude >/tmp/new.log 2>&1; then
  ok "box new --name drill --template claude  ($((SECONDS - t0))s)"
else
  no "box new FAILED — tail: $(tail -3 /tmp/new.log | tr '\n' ' ')"
  echo; echo "── cannot continue without a box"; printf '  %s\n' "${findings[@]}"; exit 1
fi

typ="$(box list | awk '$1 == "drill" { print $3 }')"
if [ "$KVM" = 1 ]; then
  [ "$typ" = VM ] && ok "the box is a VM — the trust boundary is real" \
                  || no "the box is '$typ' but /dev/kvm exists — it should have been a VM"
else
  note "the box is '$typ' (no /dev/kvm on this host)"
fi

box info drill | grep -q '^IPV4' && ok "info shows an IPv4" || no "info has no IPV4 row"
box info drill | grep -q 'SNAPSHOTS  (none)' && ok "info: no snapshots yet, offers to take one" || no "info snapshot-empty state wrong"

if box exec drill -- claude --version >/dev/null 2>&1; then
  ok "Claude Code is installed in the box"
elif timeout 30 box exec drill -- bash -lc 'claude --version' >/dev/null 2>&1; then
  no "'claude' is installed but NOT on exec's PATH — repo bug: the help promises 'box exec work -- claude --version'"
  inf "PATH as exec sees it: $(timeout 30 box exec drill -- printenv PATH 2>/dev/null)"
else
  no "'claude --version' failed inside the box"
  # diag output must skip the hatch's own 'box: incus exec …' announce lines
  hatch_out() { timeout 30 box incus drill -- exec {} -- "$@" 2>&1 | grep -v '^box:' | tail -1 | cut -c1-120; }
  inf "cloud-init:   $(hatch_out cloud-init status)"
  inf "binary runs?  $(hatch_out sudo -u claude /home/claude/.local/bin/claude --version)"
  inf "exec PATH:    $(timeout 30 box exec drill -- printenv PATH 2>/dev/null | tail -1)"
fi
box exec drill -- gh --version >/dev/null 2>&1 \
  && ok "the GitHub CLI is installed in the box (PR #5)" || no "'gh --version' failed inside the box"

# --- the snapshot → clone workflow, which is the whole point of the tool ---
box snapshot drill authed 2>&1 | grep -q authed && ok "snapshot drill authed" || no "snapshot failed"
box info drill | grep -q 'authed' && ok "info lists the snapshot label" || no "info does not show the label"
box info drill | grep -q -- '--from drill/authed' && ok "info prints the --from line to clone it" || no "info lacks the --from hint"

# --- the boundary: an instance box did NOT mint ----------------------
incus launch images:debian/13 payroll >/dev/null 2>&1   # somebody else's instance
sleep 2
box down payroll 2>&1 | grep -q 'no such box' && ok "boundary: 'down' refuses an untagged instance" || no "boundary: 'down' touched an instance box didn't mint!"
box rm payroll --force 2>&1 | grep -q 'no such box' && ok "boundary: 'rm' refuses an untagged instance" || no "boundary: 'rm' would DELETE a foreign instance!"
box incus payroll -- config show 2>&1 | grep -q 'no such box' && ok "boundary: the escape hatch refuses it too" || no "boundary: the hatch reached a foreign instance!"
incus list payroll --format csv --columns ns | grep -q '^payroll,RUNNING' && ok "…and payroll is still running, untouched" || no "payroll was harmed — the boundary leaked"
incus delete -f payroll >/dev/null 2>&1

# --- rename, and its precondition -----------------------------------------
box rename drill archive 2>&1 | grep -qi 'RUNNING' && ok "rename refuses a running box, and says how to fix it" || no "rename did not refuse a running box"
box down drill >/dev/null 2>&1 && ok "down drill" || no "down failed"
box rename drill archive 2>&1 | grep -q 'renamed drill to archive' && ok "rename drill → archive (stopped)" || no "rename failed on a stopped box"
box list | grep -q '^archive' && ok "list shows the new name" || no "list still shows the old name"
box info archive | grep -q authed && ok "the snapshot followed the rename" || no "snapshot lost across the rename"

# --- clone from a snapshot of a renamed box --------------------------------
printf '\n  cloning from the snapshot…\n'
if box new --name clone --from archive/authed >/tmp/clone.log 2>&1; then
  ok "new --from archive/authed (clone of a snapshot of a renamed box)"
  box exec clone -- true >/dev/null 2>&1 && ok "the clone is alive and enterable" || no "the clone is not enterable"
else
  no "clone FAILED — tail: $(tail -3 /tmp/clone.log | tr '\n' ' ')"
fi

# --- the escape hatch ------------------------------------------------------
box incus archive -- config show 2>/dev/null | grep -q 'user.box' && ok "hatch: 'incus archive -- config show', instance appended" || no "hatch passthrough failed"
h="$(box incus archive -- config device add {} scratch disk source=/tmp path=/mnt/scratch 2>&1)"
echo "$h" | grep -q 'isolation stack' && ok "hatch warns when a command can break isolation" || no "hatch did not warn on a device add"
box incus archive -- config device remove {} scratch >/dev/null 2>&1

# --- rm, and the guard that did not used to exist --------------------------
box rm clone </dev/null 2>&1 | grep -q 'refusing' && ok "rm with no TTY and no --force refuses (exit 2)" || no "rm destroyed a box with no confirmation!"
box rm clone --force 2>&1 | grep -q 'removed' && ok "rm --force removes the clone" || no "rm --force failed"

# --- the CLI contract ------------------------------------------------------
box lst 2>&1 | grep -q "did you mean 'list'" && ok "typo → did-you-mean, exit 2" || no "unknown command not suggested"
box list archive 2>&1 | grep -q 'box info archive' && ok "'list <box>' points at info" || no "'list <box>' does not point at info"
box snapshot archive --labl x 2>&1 | grep -q 'unknown option' && ok "typo'd flag rejected (not swallowed as a label)" || no "unknown flag was swallowed"

# ===========================================================================
phase "C. Isolation baseline — does the boundary actually hold? (#15 section A)"
# ===========================================================================
box start archive >/dev/null 2>&1
wait_box archive && ok "archive is back up (agent answering)" \
                 || no "archive did not come back within 2 min of start"

# Sibling isolation needs a sibling. Clone from the snapshot — fast, no cold mint.
printf '\n  cloning a peer for the sibling probes…\n'
if box new --name peer --from archive/authed >/tmp/peer.log 2>&1 && wait_box peer; then
  ok "peer minted from archive/authed and answering"
else
  no "peer clone failed or never answered — tail: $(tail -3 /tmp/peer.log | tr '\n' ' ')"
fi

# C1 — public egress (#15 A1; resolving the hostname also proves A5, gateway DNS)
BASELINE_OK=1
if [ "$(box_probe archive https://api.github.com 20)" = reachable ]; then
  ok "box reaches the public internet (and gateway DNS resolves public names)"
  aud "A1/A5 egress + public DNS: PASS"
else
  BASELINE_OK=0
  no "box cannot reach the internet (a box that can't is useless)"
  aud "A1/A5 egress: FAIL"
fi

# C2 — box → host (#15 A2). The host DOES listen on the gateway: dnsmasq is on
# :53 by design (that carve-out is what makes egress DNS work). So probe a port
# nothing serves and read refused-vs-dropped — refused would mean the box's
# packet reached the host's stack, which is the thing the firewall must prevent.
# (No background listener: one less process to leak, one less way to wedge.)
hv="$(box_probe archive http://10.88.0.1:8099)"
case "$hv" in
  reachable|refused)
    no "THE BOX'S PACKETS REACH THE HOST on 10.88.0.1:8099 [$hv] — the firewall rules are not holding"
    aud "A2 box→host: FAIL — $hv (the packet reached the host's stack)" ;;
  dropped)
    ok "box → host is blocked (no path to the machine's sockets)"
    aud "A2 box→host: dropped" ;;
  *)
    note "box→host probe inconclusive ($hv)"
    aud "A2 box→host: INCONCLUSIVE ($hv)" ;;
esac

# C3 — RFC1918 (#15 A2)
case "$(box_probe archive http://192.168.1.1)" in
  reachable|refused)
    no "box REACHED a private-range address — the ACL is not dropping RFC1918"
    aud "A2 RFC1918: FAIL" ;;
  *)
    ok "box → RFC1918 is dropped by the ACL"
    aud "A2 RFC1918: dropped" ;;
esac

# C4 — SIBLING isolation (#15 A3): the central claim of #12, and the one probe
# three runs failed to fire. NO listener on the peer, deliberately — a closed
# port answers the question just as well (refused = the packet arrived), and
# the listener was what kept wedging the run. Ping corroborates: if the two
# disagree, say so rather than pick one.
PEER_IP="$(boxnet_ip peer)"
ARCH_IP_PRE="$(boxnet_ip archive)"
if [ -n "$PEER_IP" ] && [ "$PEER_IP" = "$ARCH_IP_PRE" ]; then
  # Guard, because this actually happened: a clone inherited its source's
  # machine-id, hence its DHCP lease, hence its ADDRESS. Probing "archive →
  # peer" was archive probing itself, and would have reported a cheerful
  # "reachable" as a sibling-isolation failure. Never let A3 answer this.
  no "archive and peer hold the SAME address ($PEER_IP) — the clone did not get its own identity; A3 cannot be probed"
  aud "A3 sibling: NOT PROBED — clone/source IP collision (see the clone-identity fix)"
elif [ -n "$PEER_IP" ]; then
  inf "probing archive ($ARCH_IP_PRE) → peer ($PEER_IP): a REFUSAL means it arrived; silence means it was dropped"
  v="$(box_probe archive "http://$PEER_IP:8088")"
  box_pings archive "$PEER_IP"; png=$?

  if [ "$v" = reachable ] || [ "$v" = refused ]; then
    no "BOX A REACHES BOX B ($PEER_IP) — sibling isolation does NOT hold [tcp: $v]"
    aud "A3 sibling: FAIL — tcp $v (the packet arrived)"
  elif [ "$png" -eq 0 ]; then
    no "TCP to box B goes nowhere, but it ANSWERS ICMP — sibling isolation is only partial"
    aud "A3 sibling: PARTIAL — tcp dropped, ping replies"
  else
    ok "box A cannot reach box B: TCP goes nowhere, ICMP unanswered"
    aud "A3 sibling: BLOCKED — tcp dropped + no icmp reply (security.port_isolation)"
  fi
else
  no "could not read peer's boxnet address — the sibling probe never ran"
  aud "A3 sibling: NOT PROBED (no 10.88.x address on peer)"
fi

# C5 — DNS enumeration (#15 A4). Now a CONTRACT, not an observation: setup-host
# sets dns.mode=none precisely so a box cannot enumerate its siblings.
e1="$(in_box archive getent hosts peer)"
e2="$(in_box archive getent hosts peer.incus)"
if [ -n "$e1$e2" ]; then
  no "a box can still RESOLVE its sibling ($(printf '%s' "$e1$e2" | head -1 | cut -c1-40)) — dns.mode=none is not holding"
  aud "A4 dns enumeration: LEAKS — the fix is not in effect"
else
  ok "a box cannot resolve its sibling's name (no DNS enumeration)"
  aud "A4 dns enumeration: blocked (dns.mode=none)"
fi

# C6 — IPv6 off (#15 A6): every ACL rule is IPv4-only; off is the only cover.
[ "$(incus network get boxnet ipv6.address 2>/dev/null)" = none ] \
  && { ok "boxnet ipv6.address = none (the IPv4-only ACLs have no uncovered path)"; aud "A6 ipv6: none, as contract requires"; } \
  || { no "boxnet has IPv6 enabled — and not one ACL rule covers IPv6"; aud "A6 ipv6: ENABLED and uncovered"; }

# C7 — inbound, host → box (#15 A7): the ACL's default ingress drop. Same
# listener-free logic, run from the host this time.
ARCH_IP="$(boxnet_ip archive)"
if [ -n "$ARCH_IP" ]; then
  hmsg="$(curl -sS -m 5 -o /dev/null "http://$ARCH_IP:8087" 2>&1)"; hrc=$?
  if [ "$hrc" -eq 0 ]; then hv=reachable
  elif printf '%s' "$hmsg" | grep -q 'Connection refused'; then hv=refused
  else hv=dropped
  fi
  case "$hv" in
    reachable|refused)
      no "the HOST's packets REACH the box ($ARCH_IP) — the default ingress drop is not holding [$hv]"
      aud "A7 inbound host→box: FAIL — $hv (the packet arrived)" ;;
    dropped)
      ok "host → box is dropped (entry is 'incus exec' only, as designed)"
      aud "A7 inbound host→box: dropped" ;;
    *)
      note "inbound probe inconclusive ($hv)"
      aud "A7 inbound host→box: INCONCLUSIVE ($hv)" ;;
  esac
else
  no "could not read archive's boxnet address — the inbound probe never ran"
  aud "A7 inbound host→box: NOT PROBED"
fi

# ===========================================================================
phase "D. The isolation contract, stated"
# ===========================================================================
# Phase D used to REHEARSE the hardening on a throwaway host, because nobody
# knew whether it would work. That question is settled: the hardening now ships
# in setup-host.sh and box-firewall.sh, so phase C tests the real thing
# and there is nothing left to rehearse. What the rehearsal established, kept
# here so it is not re-litigated:
#
#   · @internal is REJECTED as an ACL destination on a bridge network
#     ("Unsupported nftables subject") — so the sibling drop is an nftables
#     bridge-family rule, not an ACL rule. It has to be: an L3 ACL never sees
#     frames switched between two ports of one bridge, which is why box→box was
#     wide open while the ACL looked airtight.
#   · dns.mode=none closes the enumeration leak and public egress survives it.
#   · security.ipv4_filtering BREAKS the box's networking (dockerd comes up but
#     cannot pull or run a container). VETOED — it is not in the shipped stack.
#
inf "@internal: unsupported on bridge ACLs ⇒ the sibling drop is an nft bridge rule"
inf "dns.mode=none: shipped (closes DNS enumeration, egress unaffected)"
inf "security.ipv4_filtering: VETOED — it breaks the box. Not shipped."
inf "the contract is now tested in phase C against the real stack, not rehearsed"

# The lesson that cost the most: a verdict measured on a broken box is not a
# verdict. Run 7 reported "L2 filtering BREAKS the box" from a box whose network
# was already dead, and #16 was nearly redesigned around it. If the baseline
# failed, say plainly that phase C's isolation results cannot be trusted.
if [ "$BASELINE_OK" -ne 1 ]; then
  no "the box could not reach the internet AT ALL — every isolation result above is suspect, not a pass"
  inf "a boundary that 'holds' on a box with no network holds nothing. fix the baseline, re-run."
  inf "start with:  bash drill/doctor.sh"
fi

# ===========================================================================
if [ "$KEEP" = 1 ]; then
  phase "Boxes left up (--keep-boxes)"
  box list
  inf "note: the D-phase mutations (dns.mode=none, NIC filtering) are still applied"
else
  # every name the drill can have left, whatever branch a partial run took
  for n in drill clone archive peer tpl; do box rm "$n" --force >/dev/null 2>&1; done
  # Assert OUR boxes are gone — not that the host is empty. The rm loop above
  # already embodies the discipline (only names the drill minted); demanding
  # 'no boxes yet' here would flag any pre-existing operator box as a failure.
  leftover="$(box list 2>/dev/null | grep -E '^(drill|clone|archive|peer|tpl)([[:space:]]|$)' || true)"
  [ -z "$leftover" ] && ok "teardown: every box the drill minted is gone" \
                     || no "a drill box survived teardown: $(printf '%s' "$leftover" | awk '{print $1}' | tr '\n' ' ')"
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
inf "this host still has Incus, boxnet, the ACL, the profile and the firewall rules"
inf "(plus, unless re-run: dns.mode=none and NIC filtering from the D phase)."
inf "to undo:  ~/.local/share/claudebox/host/teardown-host.sh [--purge-incus]"
[ "$fail" -eq 0 ]
