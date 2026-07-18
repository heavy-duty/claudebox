#!/usr/bin/env bash
# Apply the box host-firewall rules. Idempotent; runs as root.
# Invoked by setup-host.sh at install time and by box-firewall.service
# at every boot (UFW rules persist on their own; the nft fallback table and
# Docker's DOCKER-USER rules are runtime-only and need re-applying).
set -euo pipefail

NET=boxnet
# The gateway is read off the live bridge, not hardcoded: the subnet is an
# input now (BOX_SUBNET, setup-host.sh — #80), and a bridge moved off a
# colliding subnet must keep its firewall. setup-host runs us after the
# bridge exists, so the live read is the truth at install time. At boot the
# bridge may not be addressed yet — then GW is EMPTY and the UFW carve-out
# below is left alone rather than built for a guessed gateway: the old
# GW=10.88.0.1 fallback was wrong on every BOX_SUBNET host that hit the
# no-bridge window, a latent DNS drop (#86 review). Failing closed costs
# nothing: UFW rules persist across boots on their own, and nothing else in
# this script needs the gateway (the nft carve-out is interface-scoped).
# ('|| true': under pipefail an absent bridge would kill the script here.)
GW="$(ip -4 -o addr show dev "$NET" 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }' || true)"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  if [ -z "$GW" ]; then
    echo "box-firewall: $NET has no address yet — UFW DNS carve-out left as-is (no rule beats a wrong one; the persisted rules survive boots, and setup-host or a service restart converges them once the bridge is addressed)" >&2
  else
    # Converge, don't create-once (the ACL's own #86 lesson, applied to UFW):
    # gating this block on "a DENY on boxnet exists" pinned every host to the
    # gateway of the FIRST run — a bridge remapped off a colliding subnet
    # (#80's escape hatch) kept its stale 'allow … to <old-gw> port 53' and
    # never gained the live gateway's, so box→gateway DNS died at our own
    # deny while every config looked right. Drop the DNS allows aimed
    # anywhere else, then ensure the live set: ufw skips a rule that already
    # exists, so the re-run is a no-op and a fresh host gets exactly the
    # rules it always did.
    for stale in $(ufw status | awk -v net="$NET" -v gw="$GW" '
        $2 ~ /^53\// && $3 == "on" && $4 == net && $1 != gw { print $1 }' | sort -u); do
      ufw delete allow in on "$NET" to "$stale" port 53 proto tcp || true
      ufw delete allow in on "$NET" to "$stale" port 53 proto udp || true
    done
    ufw insert 1 deny in on "$NET"
    ufw insert 1 allow in on "$NET" to "$GW" port 53 proto tcp
    ufw insert 1 allow in on "$NET" to "$GW" port 53 proto udp
    ufw insert 1 allow in on "$NET" to any port 67 proto udp
    ufw route allow in on "$NET"
  fi
else
  # No UFW: protect the host's own sockets with a dedicated nft table.
  # Flush + rebuild rather than skip-if-present: a guard that only checks
  # existence pins every host to the rule set of the release that FIRST ran
  # here, and an upgraded rule never lands. 'add chain' with the same spec is
  # a no-op, so this converges.
  #
  # The established,related accept is load-bearing for 'box expose' (#55): the
  # door's traffic reaches the box masqueraded as the gateway, so the box's
  # REPLY arrives here as input on boxnet — a stateless drop eats it and the
  # door times out (drill-found). Boxes still cannot INITIATE toward the host:
  # a box-originated SYN is a NEW flow, and NEW is what the drop is for.
  # (UFW hosts get the same semantics from ufw's built-in RELATED,ESTABLISHED
  # accept in before.rules — this branch must match it.)
  nft add table inet box
  nft 'add chain inet box input { type filter hook input priority -5 ; }'
  nft flush chain inet box input
  nft add rule inet box input iifname "$NET" ct state established,related accept
  nft add rule inet box input iifname "$NET" udp dport '{ 53, 67 }' accept
  nft add rule inet box input iifname "$NET" tcp dport 53 accept
  nft add rule inet box input iifname "$NET" drop
fi

# --- Sibling isolation: a box must not reach another box --------------------
#
# This is the ONE rule that makes "isolated even from each other" true, and it
# is not the one anyone expected. The Incus ACL drops egress to 10.0.0.0/8, and
# boxnet's 10.88.0.0/24 sits inside it — so on paper box→box was already
# blocked twice over (the ingress default is drop as well). It was not: a live
# probe found box A's SYN arriving at box B and B answering with a RST.
#
# Why: two boxes on one bridge are on the same L2 segment. Their frames are
# SWITCHED between bridge ports, never routed — so they never traverse the
# netfilter path where an L3 ACL lives. The ACL is not wrong, it simply never
# sees this traffic.
#
# The bridge family DOES see it. Its forward hook fires exactly when a frame is
# passed from one bridge port to another — which, on boxnet, means box→box
# and nothing else: frames addressed to the gateway are delivered locally (the
# INPUT hook), and so is anything being routed out to the internet. So dropping
# every forwarded frame on this bridge isolates the boxes from one another and
# costs them nothing else. DHCP and ARP still work: they are broadcast, and the
# local delivery to dnsmasq happens on INPUT, not FORWARD.
if ! nft list table bridge box >/dev/null 2>&1; then
  nft add table bridge box
  nft "add chain bridge box forward { type filter hook forward priority -200 ; policy accept ; }"
  nft add rule bridge box forward meta ibrname "$NET" meta obrname "$NET" drop
fi

# --- The loopback door's missing half (box expose, #55) ----------------------
#
# 'box expose' publishes a box port on the host's 127.0.0.1 via an Incus
# NAT-mode proxy device. Incus installs the DNAT (prerouting + output hooks)
# and NOTHING else — its only SNAT is a hairpin rule for the box reaching its
# own exposure. A host-local `curl 127.0.0.1:<hport>` is therefore DNAT'd
# toward the box and then dies twice:
#   · the kernel refuses to route a loopback-SOURCED packet out a
#     non-loopback interface (a martian) unless route_localnet is set on the
#     egress bridge;
#   · even then, the box would reply to 127.0.0.1 — its OWN loopback —
#     unless the source is rewritten to something it can answer.
# This is exactly the plumbing Docker installs on docker0 to make
# `-p 127.0.0.1:x:y` work: route_localnet=1 on the bridge, plus a masquerade
# of loopback-sourced traffic leaving it (the box then sees the gateway and
# replies through it). Scoped to boxnet only, never 'all'.
#
# route_localnet's known risk — it makes 127/8 a routable DESTINATION on the
# interface, so a box could aim frames at the host's loopback services — is
# covered by the ingress stance above: everything arriving on boxnet at the
# host is dropped except DNS/DHCP (UFW 'deny in' or the inet-box input chain),
# and that drop fires regardless of the destination address.
if [ -e "/proc/sys/net/ipv4/conf/$NET/route_localnet" ]; then
  sysctl -qw "net.ipv4.conf.$NET.route_localnet=1"
else
  echo "box-firewall: $NET does not exist yet — route_localnet not set; expose's loopback door stays dead until this script runs again" >&2
fi
nft add table inet box
nft "add chain inet box expose-snat { type nat hook postrouting priority 110 ; }"
nft flush chain inet box expose-snat
nft add rule inet box expose-snat oifname "$NET" ip saddr 127.0.0.0/8 masquerade

# Docker rewrites FORWARD policy to DROP; DOCKER-USER is its escape hatch.
if command -v docker >/dev/null && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  iptables -C DOCKER-USER -i "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i "$NET" -j ACCEPT
  iptables -C DOCKER-USER -o "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o "$NET" -j ACCEPT
fi
