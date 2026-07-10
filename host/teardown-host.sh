#!/usr/bin/env bash
# Reverse everything host/setup-host.sh created: all claude-* instances, the
# claudenet network + ACL, the claude-dev profile, and the firewall rules.
# Usage: ./host/teardown-host.sh [--purge-incus]
#   --purge-incus  also apt-purge Incus itself (skipped if non-claudebox
#                  instances still exist on this host)
set -euo pipefail

purge=false
[ "${1:-}" = "--purge-incus" ] && purge=true

echo "This removes ALL claude-* instances (uncommitted work in them is lost),"
echo "the claudenet network/ACL/profile, and the claudebox firewall rules."
$purge && echo "Incus itself will also be uninstalled (--purge-incus)."
read -rp "Continue? [y/N] " a
case "$a" in y|Y) ;; *) echo "aborted"; exit 1 ;; esac

# Instances
for i in $(incus list -f csv -c n | grep '^claude-' || true); do
  echo "deleting instance $i"
  incus delete -f "$i"
done

incus profile delete claude-dev 2>/dev/null || true
incus network delete claudenet 2>/dev/null || true
incus network acl delete claude-isolate 2>/dev/null || true

# Boot-persistence unit
sudo systemctl disable --now claudebox-firewall.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/claudebox-firewall.service /usr/local/sbin/claudebox-firewall
sudo systemctl daemon-reload

# Firewall crumbs — UFW rules mentioning claudenet (numbers shift after each
# delete, so re-scan and remove the first match until none remain)
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  while sudo ufw status numbered | grep -q "on claudenet"; do
    n="$(sudo ufw status numbered | grep -m1 "on claudenet" | sed -E 's/^\[ *([0-9]+)\].*/\1/')"
    sudo ufw --force delete "$n"
  done
fi
sudo nft delete table inet claudebox 2>/dev/null || true
if command -v docker >/dev/null; then
  sudo iptables -D DOCKER-USER -i claudenet -j ACCEPT 2>/dev/null || true
  sudo iptables -D DOCKER-USER -o claudenet -j ACCEPT 2>/dev/null || true
fi

if $purge; then
  remaining="$(incus list -f csv 2>/dev/null | wc -l)"
  if [ "$remaining" -gt 0 ]; then
    echo "NOTE: $remaining non-claudebox instance(s) remain on this host — leaving Incus installed."
  else
    sudo apt-get purge -y incus
    sudo apt-get autoremove -y
  fi
fi

echo "Teardown complete. (Your ~/.local/bin/claudebox symlink and ~/.local/share/claudebox remain — remove by hand if wanted.)"
