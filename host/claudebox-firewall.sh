#!/usr/bin/env bash
# Apply the claudebox host-firewall rules. Idempotent; runs as root.
# Invoked by setup-host.sh at install time and by claudebox-firewall.service
# at every boot (UFW rules persist on their own; the nft fallback table and
# Docker's DOCKER-USER rules are runtime-only and need re-applying).
set -euo pipefail

GW=10.87.0.1
NET=claudenet

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  if ! ufw status | grep "on $NET" | grep -q "DENY"; then
    ufw insert 1 deny in on "$NET"
    ufw insert 1 allow in on "$NET" to "$GW" port 53 proto tcp
    ufw insert 1 allow in on "$NET" to "$GW" port 53 proto udp
    ufw insert 1 allow in on "$NET" to any port 67 proto udp
    ufw route allow in on "$NET"
  fi
else
  # No UFW: protect the host's own sockets with a dedicated nft table.
  if ! nft list table inet claudebox >/dev/null 2>&1; then
    nft add table inet claudebox
    nft 'add chain inet claudebox input { type filter hook input priority -5 ; }'
    nft add rule inet claudebox input iifname "$NET" udp dport '{ 53, 67 }' accept
    nft add rule inet claudebox input iifname "$NET" tcp dport 53 accept
    nft add rule inet claudebox input iifname "$NET" drop
  fi
fi

# --- Sibling isolation: a box must not reach another box --------------------
#
# This is the ONE rule that makes "isolated even from each other" true, and it
# is not the one anyone expected. The Incus ACL drops egress to 10.0.0.0/8, and
# claudenet's 10.87.0.0/24 sits inside it — so on paper box→box was already
# blocked twice over (the ingress default is drop as well). It was not: a live
# probe found box A's SYN arriving at box B and B answering with a RST.
#
# Why: two boxes on one bridge are on the same L2 segment. Their frames are
# SWITCHED between bridge ports, never routed — so they never traverse the
# netfilter path where an L3 ACL lives. The ACL is not wrong, it simply never
# sees this traffic.
#
# The bridge family DOES see it. Its forward hook fires exactly when a frame is
# passed from one bridge port to another — which, on claudenet, means box→box
# and nothing else: frames addressed to the gateway are delivered locally (the
# INPUT hook), and so is anything being routed out to the internet. So dropping
# every forwarded frame on this bridge isolates the boxes from one another and
# costs them nothing else. DHCP and ARP still work: they are broadcast, and the
# local delivery to dnsmasq happens on INPUT, not FORWARD.
if ! nft list table bridge claudebox >/dev/null 2>&1; then
  nft add table bridge claudebox
  nft "add chain bridge claudebox forward { type filter hook forward priority -200 ; policy accept ; }"
  nft add rule bridge claudebox forward meta ibrname "$NET" meta obrname "$NET" drop
fi

# Docker rewrites FORWARD policy to DROP; DOCKER-USER is its escape hatch.
if command -v docker >/dev/null && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  iptables -C DOCKER-USER -i "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i "$NET" -j ACCEPT
  iptables -C DOCKER-USER -o "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o "$NET" -j ACCEPT
fi
