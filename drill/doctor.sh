#!/usr/bin/env bash
# doctor.sh — is this host fit to mint boxes (and to drill), and if not, what
# is wrong? Users reach it as 'claudebox doctor'; the drill runs it directly.
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

FIX=0; PIN=0
case "${1:-}" in
  --fix)     FIX=1 ;;
  --pin-dns) PIN=1 ;;
  "")        ;;
  *) echo "usage: doctor.sh [--fix | --pin-dns]"; exit 2 ;;
esac

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
  # dns.mode=none is SHIPPED — it is what stops a box enumerating its siblings
  # through the gateway's dnsmasq. Its ABSENCE is the problem, not its presence.
  dns="$(incus network get claudenet dns.mode 2>/dev/null)"
  if [ "$dns" = none ]; then
    ok "dns.mode = none — a box cannot enumerate its siblings by name"
  else
    no "dns.mode = ${dns:-<unset>} — a box can RESOLVE its siblings' names and addresses"
    inf "fix:  re-run  ~/.local/share/claudebox/host/setup-host.sh"
    [ "$FIX" = 1 ] && { incus network set claudenet dns.mode=none && inf "set: dns.mode=none"; }
  fi
  inf "ipv4.address = $(incus network get claudenet ipv4.address 2>/dev/null)"
  # Incus reports the network as "Created" whether or not anything is actually
  # SERVING it. Kill the daemon uncleanly (a wedge, an OOM, a SIGKILL) and it
  # can come back without respawning this network's dnsmasq — the bridge is up,
  # the config is perfect, and every box minted afterwards gets NO DHCP lease,
  # so it dies deep inside cloud-init with "Temporary failure resolving
  # deb.debian.org". Two cold mints and an hour of hunting went into learning
  # that Incus's own status does not cover this. Ask the process table instead.
  if pgrep -af 'dnsmasq.*--interface=claudenet' >/dev/null 2>&1; then
    ok "a dnsmasq is serving claudenet (DHCP + DNS)"
  else
    no "NO dnsmasq is serving claudenet — the bridge is up and incus says 'Created', but nothing hands out leases"
    inf "every box minted now gets no address, no DNS, and dies in cloud-init"
    inf "fix:  timeout 60 incus delete -f <any boxes>; sudo systemctl restart incus"
    inf "      (if it does not come back: teardown-host.sh, then re-run the drill)"
    [ "$FIX" = 1 ] && {
      inf "restarting incus to respawn it…"
      sudo systemctl restart incus && sleep 5
      pgrep -af 'dnsmasq.*--interface=claudenet' >/dev/null 2>&1 \
        && inf "reverted: dnsmasq is serving claudenet again" \
        || inf "STILL missing — run teardown-host.sh and let the drill rebuild the network"
    }
  fi
  ipv6="$(incus network get claudenet ipv6.address 2>/dev/null)"
  [ "$ipv6" = none ] && ok "ipv6.address = none (the isolation contract — every ACL rule is IPv4-only)" \
                     || no "ipv6.address = $ipv6 — IPv6 is on and NOT covered by any ACL rule"
else
  inf "claudenet does not exist (a fresh host — setup-host.sh will create it)"
fi

head_ "Firewall — the box-to-box drop"
if sudo nft list table bridge claudebox >/dev/null 2>&1; then
  ok "nft bridge table 'claudebox' is present — boxes cannot reach each other"
else
  no "the box-to-box drop is MISSING — boxes can reach each other"
  inf "an L3 ACL never sees frames switched between two ports of one bridge;"
  inf "the drop is an nft BRIDGE-family rule, and without it siblings are wide open."
  inf "fix:  sudo /usr/local/sbin/claudebox-firewall"
  inf "      (or: sudo systemctl restart claudebox-firewall.service)"
fi

head_ "Profile — claude-dev (the NIC is the isolation contract)"
if incus profile show claude-dev >/dev/null 2>&1; then
  iso="$(incus profile device get claude-dev eth0 security.port_isolation 2>/dev/null)"
  if [ "$iso" = "true" ]; then
    ok "security.port_isolation = true — boxes cannot reach each other at L2"
  else
    no "security.port_isolation is NOT set — BOXES CAN REACH EACH OTHER"
    inf "an L3 ACL cannot do this: two boxes on one bridge are on the same L2"
    inf "segment, so their frames are switched, never routed past the ACL."
    inf "fix:  re-run  ~/.local/share/claudebox/host/setup-host.sh"
  fi
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

# Config is a claim; the bridge port is the fact. Incus can accept
# security.port_isolation and the kernel can still have 'isolated off' on the
# tap — and then boxes reach each other while every config says they cannot.
# Ask the kernel.
head_ "Bridge ports — the KERNEL's view (config is a claim; this is the fact)"
BRIDGE=""
for c in bridge /usr/sbin/bridge /sbin/bridge; do
  sudo "$c" -V >/dev/null 2>&1 && { BRIDGE="$c"; break; }
done
if [ -n "$BRIDGE" ]; then
  ports="$(sudo "$BRIDGE" -d link show 2>/dev/null | grep -A1 'master claudenet')"
  if [ -z "$ports" ]; then
    inf "no instance is attached to claudenet right now (mint a box to check the taps)"
  else
    printf '%s\n' "$ports" | sed 's/^/        /'
    if printf '%s' "$ports" | grep -q 'isolated on'; then
      ok "the bridge ports are ISOLATED — boxes cannot exchange frames at L2"
    else
      no "the bridge ports are NOT isolated ('isolated off') — BOXES CAN REACH EACH OTHER"
      inf "security.port_isolation in the profile is a claim; this line is the fact."
      inf "if the profile says true and the kernel says off, the flag is not being"
      inf "applied to VM taps and the isolation needs a different mechanism."
    fi
  fi
else
  inf "'bridge' (iproute2) not found — cannot read the kernel's view"
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

# --- the box's DNS comes from the HOST's resolver. See issue #33. -----------
head_ "Host resolver — a box's DNS is forwarded through this"
hostns="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
inf "/etc/resolv.conf: ${hostns:-<none>}"
raw="$(incus network get claudenet raw.dnsmasq 2>/dev/null | tr '\n' ';')"
if [ -n "$raw" ]; then
  ok "claudenet has a pinned resolver (raw.dnsmasq: $raw)"
  inf "boxes do NOT inherit the host's resolver — good (issue #33)"
else
  # 100.64.0.0/10 is CGNAT — which is exactly Tailscale's range.
  if printf '%s' "$hostns" | grep -qE '(^| )100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    no "the host resolves via a CGNAT/Tailscale resolver ($hostns), and boxes INHERIT it — see issue #33"
    inf "· box DNS breaks whenever the tailnet's resolver does (this is what kills cold mints)"
    inf "· and tailnet names RESOLVE from inside a box, though its ACL blocks connecting to them"
    inf "fix:  re-run  ~/.local/share/claudebox/host/setup-host.sh  (it pins the resolver)"
    inf "      or quick-test the pin alone:  bash drill/doctor.sh --pin-dns"
  else
    inf "boxes inherit the host's resolver (unpinned — setup-host.sh pins this now; re-run it)"
  fi
fi

if [ "$PIN" = 1 ]; then
  head_ "Pinning claudenet's resolver (issue #33)"
  if incus network set claudenet raw.dnsmasq "$(printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\n')" 2>/tmp/pin.err; then
    ok "set raw.dnsmasq: no-resolv + 1.1.1.1 + 8.8.8.8 — dnsmasq now ignores /etc/resolv.conf"
    inf "a box's DNS no longer depends on the host's VPN state, and MagicDNS is out of the path"
    inf "re-run the drill; if the cold mint now succeeds, issue #33 is confirmed and the fix belongs in setup-host.sh"
  else
    no "incus rejected raw.dnsmasq: $(head -1 /tmp/pin.err 2>/dev/null)"
    inf "then raw.dnsmasq is the wrong lever and #33 needs a different mechanism — say so on the issue"
  fi
fi

head_ "Can a box actually resolve DNS?"
# Any box will do — the drill's names are not the only boxes on a host.
probe="$(incus list "user.claudebox=1" --format csv --columns ns 2>/dev/null \
         | awk -F, '$2 == "RUNNING" { print $1; exit }')"
if [ -n "$probe" ] && [ "$FIX" != 1 ]; then
  # Stdin MUST be pinned to /dev/null: with a TTY on stdin, 'incus exec' goes
  # interactive and puts the terminal in raw mode — the probe hangs forever,
  # timeout's TERM never takes (hence -k), and ^C is forwarded INTO the box
  # instead of killing the script. The drill learned this in #22; same rule here.
  inf "probing inside '$probe' — this separates DNS from routing, which is the whole question:"
  inf "its resolv.conf: $(timeout -k 5 20 incus exec "$probe" -- sh -c 'grep -m2 nameserver /etc/resolv.conf' </dev/null 2>/dev/null | tr '\n' ' ')"

  # Routing is probed by ADDRESS against the public internet, NOT by pinging
  # the gateway: claudebox-firewall.sh drops everything from a box to the host
  # except DNS/DHCP, so ICMP to 10.87.0.1 fails BY DESIGN on a healthy host.
  # A gateway ping here is a check that can only ever lie.
  if timeout -k 5 25 incus exec "$probe" -- curl -sS -m 10 -o /dev/null https://1.1.1.1 </dev/null 2>/dev/null; then
    routing=1; ok "reaches 1.1.1.1 by address — egress routing is fine"
  else
    routing=0; no "cannot reach 1.1.1.1 by address — egress routing is broken (this is not DNS)"
  fi

  if timeout -k 5 25 incus exec "$probe" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
    ok "resolves deb.debian.org — DNS works"
  else
    no "CANNOT resolve deb.debian.org — this is exactly what kills cloud-init on every cold mint"
    # Egress by address was probed above. If it worked, the fault is purely
    # name resolution — i.e. the forwarder, i.e. issue #33.
    if [ "$routing" = 1 ]; then
      inf "…but it CAN reach 1.1.1.1 by address. So egress works and only NAME RESOLUTION is broken:"
      inf "the fault is the forwarder the box inherits from the host — issue #33."
      inf "test the fix:  bash drill/doctor.sh --pin-dns   then re-run the drill"
    else
      inf "…and it cannot reach 1.1.1.1 by address either — so egress itself is broken, not just DNS."
    fi
  fi
else
  inf "no box to probe with (mint one, or run without --fix after a run)"
fi

head_ "Verdict"
if [ "$bad" -eq 0 ]; then
  printf '  \033[32mclean\033[0m — this host is fit to mint boxes (and to drill).\n\n'
  exit 0
fi
printf '  \033[31m%s problem(s)\033[0m — this host is NOT fit to mint boxes (or to drill).\n' "$bad"
if [ "$FIX" = 1 ]; then
  printf '  reverted what could be reverted; re-run doctor to confirm.\n\n'
else
  printf '  run:  bash drill/doctor.sh --fix\n\n'
fi
exit 1
