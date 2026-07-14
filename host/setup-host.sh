#!/usr/bin/env bash
# One-time host setup: install Incus, create the isolated network + ACL and
# the claude-dev profile. Idempotent. Ubuntu 24.04 / Debian 13.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v incus >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y incus
fi

if ! id -nG "$USER" | grep -qw incus-admin; then
  sudo usermod -aG incus-admin "$USER"
  echo "NOTE: added $USER to incus-admin — re-login (or 'sg incus-admin') and re-run."
  exit 0
fi

# Storage pool + base config (safe to re-run; init is a no-op if configured)
incus storage show default >/dev/null 2>&1 || incus admin init --minimal

# Isolated NAT network. IPv6 off: one less egress path to reason about.
incus network show claudenet >/dev/null 2>&1 || incus network create claudenet \
  ipv4.address=10.87.0.1/24 ipv4.nat=true ipv6.address=none

# ACL: default egress allow (internet), explicit drops for private space.
# Gateway carve-out first so instance DNS (dnsmasq on 10.87.0.1) survives.
if ! incus network acl show claude-isolate >/dev/null 2>&1; then
  incus network acl create claude-isolate
  incus network acl rule add claude-isolate egress action=allow destination=10.87.0.1/32
  incus network acl rule add claude-isolate egress action=drop destination=10.0.0.0/8
  incus network acl rule add claude-isolate egress action=drop destination=172.16.0.0/12
  incus network acl rule add claude-isolate egress action=drop destination=192.168.0.0/16
  incus network acl rule add claude-isolate egress action=drop destination=169.254.0.0/16
  incus network acl rule add claude-isolate egress action=drop destination=100.64.0.0/10
fi
incus network set claudenet security.acls=claude-isolate \
  security.acls.default.egress.action=allow \
  security.acls.default.ingress.action=drop

# A box must not be able to ENUMERATE its siblings, either. dnsmasq on the
# gateway serves DNS (that carve-out is what makes egress resolution work) and
# it holds a record for every instance on the network — so 'getent hosts <box>'
# from inside one box resolved another's name and address. Connection blocked,
# reconnaissance wide open. dns.mode=none stops it registering instance records;
# forwarding for public names is unaffected (verified live).
incus network set claudenet dns.mode=none

# Sibling isolation itself is NOT an ACL rule — an L3 ACL never sees frames
# switched between two ports of one bridge. It lives in claudebox-firewall.sh
# as an nftables bridge-family rule. See the comment there; it is the reason
# boxes cannot reach each other.

# IPv6 stays off (ipv6.address=none, above). Every rule in the ACL and every
# rule in the firewall is IPv4-only, so IPv6 would be an uncovered path, not a
# feature. That is a contract, not a default.

# --- Firewall coexistence ---------------------------------------------------
# Hosts running UFW (INPUT drop) and/or Docker (FORWARD drop) silently eat
# claudenet traffic. Punch minimal, ordered holes; the Incus ACL still layers
# on top. The trailing deny also blocks instance -> host's own (public) IPs,
# which the RFC1918-only ACL cannot express. Rules live in
# claudebox-firewall.sh; a boot-time systemd unit re-applies the runtime-only
# parts (nft table, DOCKER-USER) after every reboot.
# The no-UFW path drives nft directly, and a stock Debian 13 cloud image ships
# neither nftables nor UFW — install the dependency we are about to use.
if ! command -v ufw >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
  sudo apt-get install -y nftables
fi
sudo install -m 755 "$here/host/claudebox-firewall.sh" /usr/local/sbin/claudebox-firewall
sudo install -m 644 "$here/host/claudebox-firewall.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable claudebox-firewall.service
# RESTART, not 'enable --now'. The unit is RemainAfterExit, so once it has run
# it stays "active" forever — and 'enable --now' does nothing to an active unit.
# Re-running setup-host after upgrading claudebox therefore installed the new
# rules to /usr/local/sbin and never applied them: the host kept the old
# firewall, silently, and the box→box hole stayed open through a release that
# claimed to close it. Restart re-runs the script, which is idempotent by design.
sudo systemctl restart claudebox-firewall.service

# Profile
if ! incus profile show claude-dev >/dev/null 2>&1; then
  incus profile create claude-dev
fi
incus profile edit claude-dev < "$here/profiles/claude-dev.yaml"

# The sibling drop is the one rule whose absence is invisible: everything keeps
# working, and boxes can simply reach each other. Assert it landed.
if sudo nft list table bridge claudebox >/dev/null 2>&1; then
  echo "Isolation: box-to-box drop is live (nft bridge table 'claudebox')."
else
  echo "WARNING: the box-to-box drop is NOT active — boxes can reach each other." >&2
  echo "         check: sudo /usr/local/sbin/claudebox-firewall ; sudo nft list table bridge claudebox" >&2
fi

echo "Host ready. Launch with: claudebox new --name <box>"
