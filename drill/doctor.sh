#!/usr/bin/env bash
# doctor.sh — is this host fit to mint boxes (and to drill), and if not, what
# is wrong? Users reach it as 'box doctor'; the drill runs it directly.
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
#
# ok/no/inf/head_ all return 0, so the 'A && ok "…" || no "…"' idiom this file
# is built on cannot hit the C-may-run-when-A-is-true trap SC2015 warns about
# (same reasoning as drill.sh's ok/no).
# shellcheck disable=SC2015
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

# --- The #80 signature: a nested box stack squatting on the gateway ---------
# setup-host run INSIDE a box builds a nested boxnet on the guest's own uplink
# subnet. The measured mechanism, and the two lines this function reads for:
# hold your own gateway's address and the kernel's local table eats packets
# meant for the real gateway (DNS, unicast DHCP renewals); carry two connected
# routes for the uplink subnet and whichever link last has carrier wins — a
# nested bridge gaining carrier blackholes egress instantly. Pure text in,
# findings out (one per line, silence is clean), so test/cli.sh drives it
# against synthetic route tables and the guest probe can feed it routes read
# INSIDE a box. Inputs: `ip -4 route show` and `ip -4 -o addr show` output.
gw_squat_signature() {
  local routes="$1" addrs="$2" gw updev
  gw="$(printf '%s\n' "$routes" | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "via") { print $(i+1); exit } }')"
  updev="$(printf '%s\n' "$routes" | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
  [ -n "$gw" ] || return 0    # no default route: nothing to squat on
  printf '%s\n' "$addrs" | awk -v gw="$gw" '
    { split($4, a, "/")
      if (a[1] == gw) { print "the default gateway " gw " is held as a LOCAL address (on " $2 ") — the kernel delivers packets meant for the gateway to this machine itself"; exit } }'
  printf '%s\n' "$routes" | awk -v updev="$updev" '
    / proto kernel / && $2 == "dev" {
      cnt[$1]++; devs[$1] = devs[$1] (devs[$1] ? ", " : "") $3
      if ($3 == updev) up = $1
    }
    END { if (up != "" && cnt[up] > 1)
      print "duplicate connected routes for the uplink subnet " up " (" devs[up] ") — whichever link last gains carrier wins, and a nested bridge with carrier blackholes egress" }'
}

# --- The UFW half of the gateway carve-out (#86 review) ---------------------
# setup-host converges the ACL's gateway allow and box-firewall converges
# UFW's — but a doctor that reads only the ACL hands a remapped UFW host a
# clean bill while a stale 'allow … to <old-gw> port 53' quietly drops
# box→gateway DNS. This reads UFW's own table. Pure text in (`ufw status`
# output, the network, the live gateway), findings out (one per line,
# silence is agreement) — the gw_squat_signature seam, so test/cli.sh drives
# it against canned tables. Judged only where UFW is active: the no-UFW nft
# carve-out is interface-scoped (no gateway address to go stale).
ufw_dns_findings() {
  local status="$1" net="$2" gw="$3" allows stale
  allows="$(printf '%s\n' "$status" | awk -v net="$net" '
    $2 ~ /^53\// && $3 == "on" && $4 == net { print $1 }' | sort -u)"
  if [ -z "$allows" ]; then
    # No DNS allow at all is a drop only if OUR deny is there to do the
    # dropping — a UFW host box-firewall never touched has nothing to judge.
    printf '%s\n' "$status" | grep " on $net" | grep -q "DENY" \
      && printf 'UFW denies in on %s with NO DNS allow at all — box DNS to the gateway is dropped\n' "$net"
    return 0
  fi
  if ! printf '%s\n' "$allows" | grep -qxF "$gw"; then
    printf "UFW's DNS allow points at %s — NOT %s's live gateway (%s): box DNS dies at UFW's deny\n" \
      "$(printf '%s' "$allows" | tr '\n' ' ')" "$net" "$gw"
    return 0
  fi
  stale="$(printf '%s\n' "$allows" | grep -vxF "$gw")" || true
  [ -n "$stale" ] \
    && printf "stale UFW DNS allow(s) for %s left beside the live gateway's — box-firewall converges these away now\n" \
         "$(printf '%s' "$stale" | tr '\n' ' ')"
  return 0
}

# The signature, probed INSIDE a box: its routes, read where they live. A
# poisoned guest looks healthy from every host-side config check — the nested
# bridge and the captured gateway exist only in the guest's kernel.
probe_sig() {
  local b="$1" routes addrs sig line
  routes="$(timeout -k 5 20 incus exec "$b" -- ip -4 route show </dev/null 2>/dev/null)"
  addrs="$(timeout -k 5 20 incus exec "$b" -- ip -4 -o addr show </dev/null 2>/dev/null)"
  if [ -z "$routes" ]; then
    inf "could not read routes inside '$b' — the #80 signature was not probed"
    return 0
  fi
  sig="$(gw_squat_signature "$routes" "$addrs")"
  if [ -n "$sig" ]; then
    while IFS= read -r line; do no "inside '$b': $line"; done <<<"$sig"
    inf "a box stack was installed INSIDE this box — its nested bridge claims the"
    inf "box's own uplink subnet, and egress blacks out intermittently (issue #80)."
    inf "fix, inside the box:  sudo incus network set boxnet ipv4.address 10.89.0.1/24"
    inf "      (or remove the nested stack there:  box teardown-host)"
  else
    ok "no #80 signature inside '$b' — nothing is squatting on its gateway"
  fi
}

command -v incus >/dev/null || { echo "doctor: incus is not installed on this host."; exit 1; }

# THIS MACHINE first, both tiers, before anything that needs the daemon: the
# #80 signature is a fact about the kernel's routing tables, not about incus —
# and a poisoned guest is exactly where the daemon answering below may be the
# WRONG (nested) one, judging its own impostor stack clean.
head_ "This machine — is a nested box stack squatting on the gateway? (#80)"
sig="$(gw_squat_signature "$(ip -4 route show 2>/dev/null)" "$(ip -4 -o addr show 2>/dev/null)")"
if [ -n "$sig" ]; then
  while IFS= read -r line; do no "$line"; done <<<"$sig"
  inf "a box stack was built on a machine whose uplink already owns its subnet —"
  inf "run inside a box, that is issue #80: egress blacks out intermittently while"
  inf "everything looks healthy. setup-host now refuses this; this machine already has it."
  inf "fix:  move the nested bridge off the uplink's subnet:"
  inf "        sudo incus network set boxnet ipv4.address 10.89.0.1/24"
  inf "      (or remove the nested stack:  box teardown-host)"
else
  ok "the default gateway is not held locally, and the uplink subnet has one connected route"
fi
timeout 10 incus list >/dev/null 2>&1 || {
  echo "doctor: the incus daemon is not answering (see issue #26 for recovery):"
  echo "  sudo pkill -9 -f 'incusd shutdown'"
  echo "  sudo systemctl stop incus.service incus.socket"
  echo "  sudo systemctl reset-failed incus.service incus.socket"
  echo "  sudo systemctl start incus.socket incus.service"
  exit 1
}

# The tier changes what this doctor can SEE, so it changes what it may JUDGE.
# bin/box exports BOX_TIER; unset means a hand-run, which was always admin.
# A restricted (incus-group) user cannot read the nft tables, the kernel's
# bridge ports, or boxnet's (redacted) config — reporting those as DIRTY
# would blame the host for the reader's own, correct, confinement. They get
# the checks that are theirs: is the tier granted, is the contract in their
# project, do their boxes actually resolve and route.
TIER="${BOX_TIER:-admin}"
if [ "$TIER" = restricted ]; then
  head_ "Access tier — restricted (the incus group: your own boxes, nothing else)"
  inf "the host stack (network, ACL, firewall, kernel state) is admin-owned;"
  inf "this doctor judges only what is yours to see"
  if [ "$FIX" = 1 ] || [ "$PIN" = 1 ]; then
    inf "--fix / --pin-dns are admin levers — ignored on this tier"
    FIX=0; PIN=0
  fi

  head_ "Your project — is the tier granted?"
  if incus profile show box-net >/dev/null 2>&1 </dev/null; then
    ok "the box-net profile is in your project — 'box new' lands on the hardened boxnet"
    iso="$(incus profile device get box-net eth0 security.port_isolation </dev/null 2>/dev/null)"
    [ "$iso" = "true" ] \
      && ok "security.port_isolation = true (as shipped)" \
      || no "security.port_isolation is NOT set in your box-net profile — re-grant refreshes it: ask an admin to re-run 'box grant $(id -un)'"
  else
    no "no box-net profile in your project — the restricted tier is granted per user"
    inf "fix:  an admin runs:  box grant $(id -un)"
  fi
  if incus network show boxnet >/dev/null 2>&1 </dev/null; then
    ok "boxnet is reachable from your project"
  else
    no "boxnet is not visible from your project — ask an admin to re-run 'box grant $(id -un)'"
  fi

  head_ "Can one of your boxes actually resolve DNS?"
  probe="$({ incus list "user.box=1" --format csv --columns ns 2>/dev/null
             incus list "user.claudebox=1" --format csv --columns ns 2>/dev/null; } \
           | awk -F, '$2 == "RUNNING" { print $1; exit }')"
  if [ -n "$probe" ]; then
    inf "probing inside '$probe':"
    if timeout -k 5 25 incus exec "$probe" -- curl -sS -m 10 -o /dev/null https://1.1.1.1 </dev/null 2>/dev/null; then
      routing=1; ok "reaches 1.1.1.1 by address — egress routing is fine"
    else
      routing=0; no "cannot reach 1.1.1.1 by address — egress routing is broken (an admin problem: box doctor as admin)"
    fi
    if timeout -k 5 25 incus exec "$probe" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
      ok "resolves deb.debian.org — DNS works"
      # Egress broken while DNS resolves is #80's fingerprint: an impostor
      # dnsmasq on a captured gateway address answers names happily (it
      # forwards upstream via the default route) while direct IP egress dies.
      [ "$routing" = 0 ] && inf "…egress broken while DNS resolves is #80's fingerprint — the signature probe below answers whether something inside this box squats on its gateway"
    else
      no "CANNOT resolve deb.debian.org — an admin problem (the resolver pin lives on the host): box doctor as admin"
    fi
    probe_sig "$probe"
  else
    inf "no running box to probe with (mint one: box new --name work)"
  fi

  head_ "Verdict"
  if [ "$bad" -eq 0 ]; then
    printf '  \033[32mclean\033[0m — your tier is granted and your boxes are fit.\n\n'
    exit 0
  fi
  printf '  \033[31m%s problem(s)\033[0m — see the fixes above (most need an admin).\n\n' "$bad"
  exit 1
fi

# A FRESH host (no boxnet) is not a DIRTY one. Everything below that would
# scream about a missing piece must first ask: missing from a stack, or never
# set up? setup-host creates all of it, and the drill runs setup-host itself —
# a bare host went 84/84 green minutes after this doctor called it unfit.
FRESH=0

head_ "Network — boxnet"
if incus network show boxnet >/dev/null 2>&1; then
  # dns.mode=none is SHIPPED — it is what stops a box enumerating its siblings
  # through the gateway's dnsmasq. Its ABSENCE is the problem, not its presence.
  dns="$(incus network get boxnet dns.mode 2>/dev/null)"
  if [ "$dns" = none ]; then
    ok "dns.mode = none — a box cannot enumerate its siblings by name"
  else
    no "dns.mode = ${dns:-<unset>} — a box can RESOLVE its siblings' names and addresses"
    inf "fix:  re-run:  box setup-host"
    [ "$FIX" = 1 ] && { incus network set boxnet dns.mode=none && inf "set: dns.mode=none"; }
  fi
  inf "ipv4.address = $(incus network get boxnet ipv4.address 2>/dev/null)"
  # Incus reports the network as "Created" whether or not anything is actually
  # SERVING it. Kill the daemon uncleanly (a wedge, an OOM, a SIGKILL) and it
  # can come back without respawning this network's dnsmasq — the bridge is up,
  # the config is perfect, and every box minted afterwards gets NO DHCP lease,
  # so it dies deep inside cloud-init with "Temporary failure resolving
  # deb.debian.org". Two cold mints and an hour of hunting went into learning
  # that Incus's own status does not cover this. Ask the process table instead.
  if pgrep -af 'dnsmasq.*--interface=boxnet' >/dev/null 2>&1; then
    ok "a dnsmasq is serving boxnet (DHCP + DNS)"
  else
    no "NO dnsmasq is serving boxnet — the bridge is up and incus says 'Created', but nothing hands out leases"
    inf "every box minted now gets no address, no DNS, and dies in cloud-init"
    inf "fix:  timeout 60 incus delete -f <any boxes>; sudo systemctl restart incus"
    inf "      (if it does not come back: teardown-host.sh, then re-run the drill)"
    [ "$FIX" = 1 ] && {
      inf "restarting incus to respawn it…"
      sudo systemctl restart incus && sleep 5
      pgrep -af 'dnsmasq.*--interface=boxnet' >/dev/null 2>&1 \
        && inf "reverted: dnsmasq is serving boxnet again" \
        || inf "STILL missing — run teardown-host.sh and let the drill rebuild the network"
    }
  fi
  ipv6="$(incus network get boxnet ipv6.address 2>/dev/null)"
  [ "$ipv6" = none ] && ok "ipv6.address = none (the isolation contract — every ACL rule is IPv4-only)" \
                     || no "ipv6.address = $ipv6 — IPv6 is on and NOT covered by any ACL rule"
else
  FRESH=1
  inf "boxnet does not exist (a fresh host — setup-host.sh will create it)"
fi

head_ "Firewall — the box-to-box drop"
if sudo nft list table bridge box >/dev/null 2>&1; then
  ok "nft bridge table 'box' is present — boxes cannot reach each other"
elif [ "$FRESH" = 1 ]; then
  inf "not installed yet (a fresh host — setup-host.sh installs it)"
else
  no "the box-to-box drop is MISSING — boxes can reach each other"
  inf "an L3 ACL never sees frames switched between two ports of one bridge;"
  inf "the drop is an nft BRIDGE-family rule, and without it siblings are wide open."
  inf "fix:  sudo /usr/local/sbin/box-firewall"
  inf "      (or: sudo systemctl restart box-firewall.service)"
fi

# The UFW blind spot: the ACL check further down compares the ACL's carve-out
# to the live gateway, but on a UFW host the SAME stale-carve-out failure can
# live in UFW's own table — and did, invisibly (#86 review). Judge it here,
# from `ufw status`, wherever UFW is the active firewall and a bridge exists
# to compare against (a fresh host has neither).
if command -v ufw >/dev/null 2>&1; then
  ufw_out="$(sudo ufw status 2>/dev/null)"
  ufw_gw="$(incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1)"
  if printf '%s\n' "$ufw_out" | grep -q "Status: active" && [ -n "$ufw_gw" ]; then
    findings="$(ufw_dns_findings "$ufw_out" boxnet "$ufw_gw")"
    if [ -n "$findings" ]; then
      while IFS= read -r line; do no "$line"; done <<<"$findings"
      inf "the bridge moved (#80's escape hatch) and UFW did not follow"
      inf "fix:  sudo /usr/local/sbin/box-firewall   (it converges the UFW allows off the live bridge now)"
    else
      ok "no stale UFW DNS carve-out — box DNS to the gateway ($ufw_gw) survives UFW"
    fi
  fi
fi

# box-net is the placement contract since the 0.4.0 rename; claude-dev is its
# pre-rename ancestor and may linger while legacy boxes still reference it.
# Check whichever exist — an unisolated NIC is a fault on either.
PROFILES=""
incus profile show box-net >/dev/null 2>&1 && PROFILES="box-net"
incus profile show claude-dev >/dev/null 2>&1 && PROFILES="$PROFILES claude-dev"
head_ "Profile — the NIC is the isolation contract"
if [ -n "$PROFILES" ]; then
  for p in $PROFILES; do
    [ "$p" = claude-dev ] && inf "claude-dev is legacy (pre-rename boxes still reference it)"
    iso="$(incus profile device get "$p" eth0 security.port_isolation 2>/dev/null)"
    if [ "$iso" = "true" ]; then
      ok "$p: security.port_isolation = true — boxes cannot reach each other at L2"
    else
      no "$p: security.port_isolation is NOT set — BOXES CAN REACH EACH OTHER"
      inf "an L3 ACL cannot do this: two boxes on one bridge are on the same L2"
      inf "segment, so their frames are switched, never routed past the ACL."
      inf "fix:  re-run:  box setup-host"
    fi
    for k in security.mac_filtering security.ipv4_filtering; do
      v="$(incus profile device get "$p" eth0 "$k" 2>/dev/null)"
      if [ -z "$v" ]; then
        ok "$p: $k unset (as shipped)"
      else
        no "$p: $k = $v  ← phase D left this behind. A box can fail to get on the network at all."
        [ "$FIX" = 1 ] && { incus profile device unset "$p" eth0 "$k" && inf "reverted: $k unset"; }
      fi
    done
  done
  inf "resources are per-box since 0.4.0 (stamped from the template at mint; BOX_CPU/BOX_MEMORY override)"
else
  inf "box-net does not exist (a fresh host — setup-host.sh will create it)"
fi

head_ "ACL — box-isolate"
if incus network acl show box-isolate >/dev/null 2>&1; then
  n="$(incus network acl show box-isolate | grep -c 'action:' || true)"
  inf "$n rules"
  incus network acl show box-isolate | grep -E 'action:|destination:' | sed 's/^/        /'
  if incus network acl show box-isolate | grep -q '@internal'; then
    no "an @internal rule survived phase D"
    [ "$FIX" = 1 ] && { incus network acl rule remove box-isolate egress action=drop destination=@internal && inf "reverted: @internal rule removed"; }
  fi
  # The gateway carve-out must track the BRIDGE. #80's escape hatch moves
  # boxnet off a colliding subnet — and the stale /32 then strands box DNS
  # inside the 10.0.0.0/8 drop, which presents as a dead resolver, never as
  # a stale ACL. Compare the allow rule to boxnet's actual gateway.
  gwaddr="$(incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1)"
  carve="$(incus network acl show box-isolate 2>/dev/null \
           | awk '/- action: allow/ { hit = 1; next } hit && /destination:/ { sub("/32", "", $2); print $2; exit } { hit = 0 }')"
  if [ -n "$gwaddr" ] && [ -n "$carve" ]; then
    if [ "$carve" = "$gwaddr" ]; then
      ok "the gateway carve-out matches boxnet's gateway ($gwaddr) — box DNS survives the 10/8 drop"
    else
      no "the gateway carve-out ($carve/32) does NOT match boxnet's gateway ($gwaddr) — box DNS to the gateway dies inside the 10.0.0.0/8 drop"
      inf "the bridge moved (#80's escape hatch) and the ACL did not follow"
      inf "fix:  BOX_SUBNET=${gwaddr%.*}.0/24 box setup-host   (it converges the ACL now)"
    fi
  fi
else
  inf "box-isolate does not exist (a fresh host)"
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
  ports="$(sudo "$BRIDGE" -d link show 2>/dev/null | grep -A1 'master boxnet')"
  if [ -z "$ports" ]; then
    inf "no instance is attached to boxnet right now (mint a box to check the taps)"
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
# An interrupted multiuser.sh leaves its users (and their projects) behind —
# and nothing else on this host will ever mention them. Its own cleanup is
# 'box revoke --purge + userdel'; say so rather than absorbing them silently.
for u in boxdrill1 boxdrill2 boxdrill3 boxdrill4; do
  if getent passwd "$u" >/dev/null 2>&1; then
    no "leftover rehearsal user: $u (an interrupted drill/multiuser.sh run)"
    inf "fix:  sudo BOX_YES=1 box revoke $u --purge && sudo userdel -r $u"
  fi
done

# --- the box's DNS comes from the HOST's resolver. See issue #33. -----------
head_ "Host resolver — a box's DNS is forwarded through this"
hostns="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
inf "/etc/resolv.conf: ${hostns:-<none>}"
raw="$(incus network get boxnet raw.dnsmasq 2>/dev/null | tr '\n' ';')"
if [ -n "$raw" ]; then
  ok "boxnet has a pinned resolver (raw.dnsmasq: $raw)"
  inf "boxes do NOT inherit the host's resolver — good (issue #33)"
elif [ "$FRESH" = 1 ]; then
  # No boxnet, so there is nothing to pin YET. A VPN resolver on the host is
  # worth naming, but it is a fact about the host, not a fault in a stack
  # that does not exist — setup-host pins around it at creation.
  if printf '%s' "$hostns" | grep -qE '(^| )100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    inf "the host resolves via a CGNAT/Tailscale resolver ($hostns) — noted, not a fault:"
    inf "setup-host pins the box resolver to public upstreams, so boxes will not inherit it (issue #33)"
  else
    inf "no boxnet yet — setup-host.sh pins its resolver at creation"
  fi
else
  # 100.64.0.0/10 is CGNAT — which is exactly Tailscale's range.
  if printf '%s' "$hostns" | grep -qE '(^| )100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    no "the host resolves via a CGNAT/Tailscale resolver ($hostns), and boxes INHERIT it — see issue #33"
    inf "· box DNS breaks whenever the tailnet's resolver does (this is what kills cold mints)"
    inf "· and tailnet names RESOLVE from inside a box, though its ACL blocks connecting to them"
    inf "fix:  re-run:  box setup-host  (it pins the resolver)"
    inf "      or quick-test the pin alone:  bash drill/doctor.sh --pin-dns"
  else
    inf "boxes inherit the host's resolver (unpinned — setup-host.sh pins this now; re-run it)"
  fi
fi

if [ "$PIN" = 1 ]; then
  head_ "Pinning boxnet's resolver (issue #33)"
  if incus network set boxnet raw.dnsmasq "$(printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\n')" 2>/tmp/pin.err; then
    ok "set raw.dnsmasq: no-resolv + 1.1.1.1 + 8.8.8.8 — dnsmasq now ignores /etc/resolv.conf"
    inf "a box's DNS no longer depends on the host's VPN state, and MagicDNS is out of the path"
    inf "re-run the drill; if the cold mint now succeeds, issue #33 is confirmed and the fix belongs in setup-host.sh"
  else
    no "incus rejected raw.dnsmasq: $(head -1 /tmp/pin.err 2>/dev/null)"
    inf "then raw.dnsmasq is the wrong lever and #33 needs a different mechanism — say so on the issue"
  fi
fi

head_ "Can a box actually resolve DNS?"
# Any box will do — the drill's names are not the only boxes on a host, and
# a pre-rename box (legacy tag) is as good a probe as a new one.
probe="$({ incus list "user.box=1" --format csv --columns ns 2>/dev/null
           incus list "user.claudebox=1" --format csv --columns ns 2>/dev/null; } \
         | awk -F, '$2 == "RUNNING" { print $1; exit }')"
if [ -n "$probe" ] && [ "$FIX" != 1 ]; then
  # Stdin MUST be pinned to /dev/null: with a TTY on stdin, 'incus exec' goes
  # interactive and puts the terminal in raw mode — the probe hangs forever,
  # timeout's TERM never takes (hence -k), and ^C is forwarded INTO the box
  # instead of killing the script. The drill learned this in #22; same rule here.
  inf "probing inside '$probe' — this separates DNS from routing, which is the whole question:"
  inf "its resolv.conf: $(timeout -k 5 20 incus exec "$probe" -- sh -c 'grep -m2 nameserver /etc/resolv.conf' </dev/null 2>/dev/null | tr '\n' ' ')"

  # Routing is probed by ADDRESS against the public internet, NOT by pinging
  # the gateway: box-firewall.sh drops everything from a box to the host
  # except DNS/DHCP, so ICMP to 10.88.0.1 fails BY DESIGN on a healthy host.
  # A gateway ping here is a check that can only ever lie.
  if timeout -k 5 25 incus exec "$probe" -- curl -sS -m 10 -o /dev/null https://1.1.1.1 </dev/null 2>/dev/null; then
    routing=1; ok "reaches 1.1.1.1 by address — egress routing is fine"
  else
    routing=0; no "cannot reach 1.1.1.1 by address — egress routing is broken (this is not DNS)"
  fi

  if timeout -k 5 25 incus exec "$probe" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
    ok "resolves deb.debian.org — DNS works"
    # The OTHER split from the one below: egress broken while DNS resolves is
    # #80's fingerprint — an impostor dnsmasq on a captured gateway address
    # keeps answering names (it forwards upstream via the default route)
    # while direct IP egress dies. The signature probe underneath answers it.
    [ "$routing" = 0 ] && inf "…egress broken while DNS resolves is #80's fingerprint — see the signature probe below"
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

  probe_sig "$probe"
else
  inf "no box to probe with (mint one, or run without --fix after a run)"
fi

head_ "Verdict"
if [ "$bad" -eq 0 ]; then
  if [ "$FRESH" = 1 ]; then
    printf '  \033[32mfresh\033[0m — no box stack on this host yet, and nothing dirty either.\n'
    printf '  run:  box setup-host   (or the drill — it sets the host up itself)\n\n'
  else
    printf '  \033[32mclean\033[0m — this host is fit to mint boxes (and to drill).\n\n'
  fi
  exit 0
fi
printf '  \033[31m%s problem(s)\033[0m — this host is NOT fit to mint boxes (or to drill).\n' "$bad"
if [ "$FIX" = 1 ]; then
  printf '  reverted what could be reverted; re-run doctor to confirm.\n\n'
else
  printf '  run:  bash drill/doctor.sh --fix\n\n'
fi
exit 1
