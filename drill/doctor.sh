#!/usr/bin/env bash
# doctor.sh — is this host in a fit state to drill, and if not, what is wrong?
#
#   bash drill/doctor.sh          # report
#   bash drill/doctor.sh --fix    # report, then revert what the drill left behind
#
# The drill MUTATES the host in phase D (dns.mode, NIC filtering, ACL rules) to
# rehearse the #16 hardening. If a run aborts before it reverts them, those
# mutations outlive it — and the next run mints boxes on a broken network. That
# is not a hypothetical: it is how a box came up with no DNS at all
# ("Temporary failure resolving deb.debian.org" in cloud-init), and how a false
# design veto against #16 got posted from a poisoned baseline.
#
# This script is the answer to "what state is the host actually in?" — the
# question that kept getting answered by hand.
set -u

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

bad=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
no()   { printf '  \033[31mDIRTY\033[0m %s\n' "$*"; bad=$((bad + 1)); }
inf()  { printf '        %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v incus >/dev/null || { echo "doctor: incus is not installed on this host."; exit 1; }
timeout 10 incus list >/dev/null 2>&1 || {
  echo "doctor: the incus daemon is not answering (see issue #26 for recovery):"
  echo "  sudo pkill -9 -f 'incusd shutdown'"
  echo "  sudo systemctl stop incus.service incus.socket"
  echo "  sudo systemctl reset-failed incus.service incus.socket"
  echo "  sudo systemctl start incus.socket incus.service"
  exit 1
}

head_ "Network — claudenet"
if incus network show claudenet >/dev/null 2>&1; then
  dns="$(incus network get claudenet dns.mode 2>/dev/null)"
  if [ -z "$dns" ] || [ "$dns" = managed ]; then
    ok "dns.mode = ${dns:-<unset, i.e. managed>}"
  else
    no "dns.mode = $dns  ← the drill's phase D left this behind. Boxes minted now get NO working DNS."
    [ "$FIX" = 1 ] && { incus network unset claudenet dns.mode && inf "reverted: dns.mode unset"; }
  fi
  inf "ipv4.address = $(incus network get claudenet ipv4.address 2>/dev/null)"
  ipv6="$(incus network get claudenet ipv6.address 2>/dev/null)"
  [ "$ipv6" = none ] && ok "ipv6.address = none (the isolation contract — every ACL rule is IPv4-only)" \
                     || no "ipv6.address = $ipv6 — IPv6 is on and NOT covered by any ACL rule"
else
  inf "claudenet does not exist (a fresh host — setup-host.sh will create it)"
fi

head_ "Profile — claude-dev (the NIC is the isolation contract)"
if incus profile show claude-dev >/dev/null 2>&1; then
  for k in security.mac_filtering security.ipv4_filtering; do
    v="$(incus profile device get claude-dev eth0 "$k" 2>/dev/null)"
    if [ -z "$v" ]; then
      ok "$k unset (as shipped)"
    else
      no "$k = $v  ← phase D left this behind. A box can fail to get on the network at all."
      [ "$FIX" = 1 ] && { incus profile device unset claude-dev eth0 "$k" && inf "reverted: $k unset"; }
    fi
  done
  inf "cpu/mem: $(incus profile get claude-dev limits.cpu 2>/dev/null)/$(incus profile get claude-dev limits.memory 2>/dev/null) (the drill lowers these on a small host)"
else
  inf "claude-dev does not exist (a fresh host)"
fi

head_ "ACL — claude-isolate"
if incus network acl show claude-isolate >/dev/null 2>&1; then
  n="$(incus network acl show claude-isolate | grep -c 'action:' || true)"
  inf "$n rules"
  incus network acl show claude-isolate | grep -E 'action:|destination:' | sed 's/^/        /'
  if incus network acl show claude-isolate | grep -q '@internal'; then
    no "an @internal rule survived phase D"
    [ "$FIX" = 1 ] && { incus network acl rule remove claude-isolate egress action=drop destination=@internal && inf "reverted: @internal rule removed"; }
  fi
else
  inf "claude-isolate does not exist (a fresh host)"
fi

head_ "Instances"
left="$(incus list --format csv --columns ns 2>/dev/null)"
[ -z "$left" ] && inf "(none)" || printf '        %s\n' "$left"
for b in drill clone archive peer payroll cbprobe cbcopy cbnotours; do
  if incus config show "$b" >/dev/null 2>&1; then
    no "leftover drill box: $b"
    [ "$FIX" = 1 ] && { timeout 60 incus delete -f "$b" >/dev/null 2>&1 && inf "reverted: deleted $b"; }
  fi
done

head_ "Can a box actually resolve DNS?"
probe=""
for b in drill archive peer clone; do
  incus config show "$b" >/dev/null 2>&1 && { probe="$b"; break; }
done
if [ -n "$probe" ] && [ "$FIX" != 1 ]; then
  inf "probing inside '$probe' (the cheapest test of a poisoned network):"
  inf "resolv.conf: $(timeout 20 incus exec "$probe" -- sh -c 'grep -m2 nameserver /etc/resolv.conf' 2>/dev/null | tr '\n' ' ')"
  if timeout 25 incus exec "$probe" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "$probe resolves deb.debian.org"
  else
    no "$probe CANNOT resolve deb.debian.org — this is what breaks cloud-init on every new box"
  fi
  timeout 20 incus exec "$probe" -- ping -c1 -W2 10.87.0.1 >/dev/null 2>&1 \
    && ok "$probe reaches the gateway (10.87.0.1) — so it is DNS, not routing" \
    || no "$probe cannot even reach the gateway"
else
  inf "no box to probe with (mint one, or run without --fix after a run)"
fi

head_ "Verdict"
if [ "$bad" -eq 0 ]; then
  printf '  \033[32mclean\033[0m — this host is fit to drill.\n\n'
  exit 0
fi
printf '  \033[31m%s problem(s)\033[0m — this host is NOT fit to drill.\n' "$bad"
if [ "$FIX" = 1 ]; then
  printf '  reverted what could be reverted; re-run doctor to confirm.\n\n'
else
  printf '  run:  bash drill/doctor.sh --fix\n\n'
fi
exit 1
