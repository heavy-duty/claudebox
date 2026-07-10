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

# Docker rewrites FORWARD policy to DROP; DOCKER-USER is its escape hatch.
if command -v docker >/dev/null && iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  iptables -C DOCKER-USER -i "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i "$NET" -j ACCEPT
  iptables -C DOCKER-USER -o "$NET" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o "$NET" -j ACCEPT
fi
