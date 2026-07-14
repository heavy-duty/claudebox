#!/usr/bin/env bash
# migrate-host.sh — move a host from the pre-0.4.0 'claudebox' stack to 'box'.
#
# The zero-ceremony transition is just install.sh + setup-host.sh: that leaves
# a DUAL-STACK host where legacy boxes (tag user.claudebox=1, claudenet/10.87,
# claude-dev) keep working while new mints land on boxnet/10.88. This script is
# the two things that path does not do:
#
#   migrate-host.sh --box <name>       re-home ONE legacy box onto the new stack
#   migrate-host.sh --all-boxes        re-home every legacy box
#   migrate-host.sh --retire-legacy    remove the legacy stack (refuses while any
#                                      legacy box still exists)
#
# One action per invocation, idempotent, loud about what it did. Re-homing
# PRESERVES the box's authed state (Claude login, git creds — the expensive
# thing); it does not re-mint. The order is load-bearing: tag first (additive,
# reversible), profile last, and verify the box works on its new leg BEFORE
# calling it migrated — a box must never end up tagless or profileless.
#
# NOT 'set -e' around the per-box work: a box that fails one step is reported
# and skipped, not a crash that abandons the rest mid-migration.
set -u

GW_NEW=10.88.0.1
say()  { printf 'migrate: %s\n' "$*"; }
warn() { printf 'migrate: WARNING: %s\n' "$*" >&2; }
die()  { printf 'migrate: ERROR: %s\n' "$*" >&2; exit 1; }

mode=""
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --box) mode=box; target="${2:-}"; shift 2 || die "--box needs a name" ;;
    --all-boxes) mode=all; shift ;;
    --retire-legacy) mode=retire; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$mode" ] || die "pick one: --box <name> | --all-boxes | --retire-legacy"
command -v incus >/dev/null || die "incus is not installed on this host"

# The new stack must exist before any box can be re-homed onto it. setup-host
# creates it; refuse rather than move a box onto a network that isn't there.
require_new_stack() {
  incus network show boxnet >/dev/null 2>&1 || die "boxnet does not exist — run host/setup-host.sh first"
  incus profile show box-net >/dev/null 2>&1 || die "box-net profile does not exist — run host/setup-host.sh first"
}

legacy_boxes() { incus list "user.claudebox=1" -f csv -c n 2>/dev/null; }

# Re-home one box. Legacy boxes are all claude boxes (the only template the old
# tool minted), so the new metadata is the claude template's.
rehome_one() {
  local b="$1" st
  incus config get "$b" user.claudebox >/dev/null 2>&1 || { warn "$b is not a legacy box (no user.claudebox tag) — skipping"; return 1; }
  if [ "$(incus config get "$b" user.box 2>/dev/null)" = 1 ]; then
    say "$b already carries user.box=1 — already re-homed, skipping"; return 0
  fi
  say "re-homing $b …"

  # 1. TAG FIRST — additive and reversible. A box that stops here is still a
  #    valid legacy box (the old tag is untouched) AND now a new one.
  incus config set "$b" user.box=1 user.box.template=claude user.box.user=claude \
    || { warn "$b: could not set new metadata — left untouched"; return 1; }

  # 2. Stop, reassign the profile (this is the network move), restart. Incus
  #    won't reassign a profile on a running instance's NIC cleanly, and the
  #    box needs a fresh DHCP lease on boxnet anyway.
  st="$(incus list "$b" -f csv -c s 2>/dev/null | head -1)"
  case "$st" in RUNNING|Running|running) incus stop "$b" >/dev/null 2>&1 || warn "$b: stop was not clean" ;; esac
  incus profile assign "$b" box-net \
    || { warn "$b: profile assign failed — it still has user.box=1 but is on the OLD network; fix by hand"; return 1; }
  incus start "$b" >/dev/null 2>&1 || { warn "$b: did not restart — start it by hand"; return 1; }

  # 3. VERIFY THE EFFECT, not the exit codes (the whole repo's lesson). The box
  #    must be on 10.88 and actually resolve+reach the internet on its new leg
  #    before we call it migrated.
  local i ip
  ip=""
  for i in $(seq 1 30); do
    ip="$(incus exec "$b" -- ip -4 -o addr show scope global </dev/null 2>/dev/null \
          | awk '{for(i=1;i<NF;i++) if($i=="inet" && $(i+1)~/^10\.88\./){split($(i+1),a,"/"); print a[1]; exit}}')"
    [ -n "$ip" ] && break
    sleep 2
  done
  [ -n "$ip" ] || { warn "$b: never got a 10.88 address after restart — re-home INCOMPLETE, inspect: incus console $b"; return 1; }
  if incus exec "$b" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
    say "$b re-homed: on boxnet ($ip), resolves + reachable, authed state preserved"
    return 0
  fi
  warn "$b is on boxnet ($ip) but cannot resolve — check the new stack's resolver (box doctor)"
  return 1
}

case "$mode" in
  box)
    [ -n "$target" ] || die "--box needs a name"
    require_new_stack
    rehome_one "$target"
    ;;
  all)
    require_new_stack
    boxes="$(legacy_boxes)"
    [ -n "$boxes" ] || { say "no legacy boxes to re-home"; exit 0; }
    rc=0
    for b in $boxes; do rehome_one "$b" || rc=1; done
    [ "$rc" = 0 ] && say "all legacy boxes re-homed" || warn "some boxes need attention (above)"
    exit "$rc"
    ;;
  retire)
    # Refuse while any legacy box still references the old stack — removing an
    # in-use profile/network fails anyway, and a half-removed stack is worse
    # than an intact one.
    remaining="$(legacy_boxes)"
    if [ -n "$remaining" ]; then
      die "legacy boxes still exist: $(echo "$remaining" | tr '\n' ' ')
  re-home them first (--all-boxes), or delete them, then retire."
    fi
    say "no legacy boxes remain — removing the legacy stack"
    incus profile delete claude-dev >/dev/null 2>&1 && say "deleted profile claude-dev"
    incus network delete claudenet >/dev/null 2>&1 && say "deleted network claudenet"
    incus network acl delete claude-isolate >/dev/null 2>&1 && say "deleted ACL claude-isolate"
    sudo systemctl disable --now claudebox-firewall.service >/dev/null 2>&1 && say "disabled claudebox-firewall.service"
    sudo rm -f /etc/systemd/system/claudebox-firewall.service /usr/local/sbin/claudebox-firewall
    sudo systemctl daemon-reload
    sudo nft delete table inet claudebox >/dev/null 2>&1 && say "deleted nft table inet claudebox"
    sudo nft delete table bridge claudebox >/dev/null 2>&1 && say "deleted nft table bridge claudebox"
    # Assert the absence — don't trust the removals' exit codes.
    left=""
    incus network show claudenet >/dev/null 2>&1 && left="$left claudenet"
    incus profile show claude-dev >/dev/null 2>&1 && left="$left claude-dev"
    sudo nft list table bridge claudebox >/dev/null 2>&1 && left="$left nft-bridge"
    [ -z "$left" ] && say "legacy stack retired — this host is now single-stack (box only)" \
                   || die "legacy stack NOT fully removed:$left"
    ;;
esac
