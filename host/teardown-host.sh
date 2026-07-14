#!/usr/bin/env bash
# Reverse everything host/setup-host.sh created — and everything its pre-0.4.0
# ancestor created, so one teardown cleans a host of any generation: all boxes
# (both tags), the boxnet/claudenet networks + ACLs, the box-net/claude-dev
# profiles, and both generations of firewall units and nft tables.
# Usage: ./host/teardown-host.sh [--purge-incus]
#   --purge-incus  also apt-purge Incus itself (skipped if non-box
#                  instances still exist on this host)
set -euo pipefail

purge=false
[ "${1:-}" = "--purge-incus" ] && purge=true

echo "This removes ALL boxes (uncommitted work in them is lost), the"
echo "boxnet/claudenet networks, ACLs, profiles, and the box firewall rules"
echo "(both current and pre-0.4.0 names)."
$purge && echo "Incus itself will also be uninstalled (--purge-incus)."
read -rp "Continue? [y/N] " a
case "$a" in y|Y) ;; *) echo "aborted"; exit 1 ;; esac

# Instances — both tag generations, one delete at a time (a multi-name
# 'incus delete' aborts at the first missing name).
for tag in "user.box=1" "user.claudebox=1"; do
  for i in $(incus list "$tag" -f csv -c n 2>/dev/null || true); do
    echo "deleting instance $i"
    incus delete -f "$i"
  done
done

incus profile delete box-net 2>/dev/null || true
incus profile delete claude-dev 2>/dev/null || true    # legacy, pre-0.4.0
incus network delete boxnet 2>/dev/null || true
incus network delete claudenet 2>/dev/null || true     # legacy, pre-0.4.0
incus network acl delete box-isolate 2>/dev/null || true
incus network acl delete claude-isolate 2>/dev/null || true   # legacy

# Boot-persistence units — both generations
sudo systemctl disable --now box-firewall.service 2>/dev/null || true
sudo systemctl disable --now claudebox-firewall.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/box-firewall.service /usr/local/sbin/box-firewall \
           /etc/systemd/system/claudebox-firewall.service /usr/local/sbin/claudebox-firewall
sudo systemctl daemon-reload

# Firewall crumbs — UFW rules mentioning either network (numbers shift after
# each delete, so re-scan and remove the first match until none remain)
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  for net in boxnet claudenet; do
    while sudo ufw status numbered | grep -q "on $net"; do
      n="$(sudo ufw status numbered | grep -m1 "on $net" | sed -E 's/^\[ *([0-9]+)\].*/\1/')"
      sudo ufw --force delete "$n"
    done
  done
fi
sudo nft delete table inet box 2>/dev/null || true
sudo nft delete table bridge box 2>/dev/null || true
sudo nft delete table inet claudebox 2>/dev/null || true      # legacy
sudo nft delete table bridge claudebox 2>/dev/null || true    # legacy
if command -v docker >/dev/null; then
  for net in boxnet claudenet; do
    sudo iptables -D DOCKER-USER -i "$net" -j ACCEPT 2>/dev/null || true
    sudo iptables -D DOCKER-USER -o "$net" -j ACCEPT 2>/dev/null || true
  done
fi

if $purge; then
  remaining="$(incus list -f csv 2>/dev/null | wc -l)"
  if [ "$remaining" -gt 0 ]; then
    echo "NOTE: $remaining non-box instance(s) remain on this host — leaving Incus installed."
  else
    sudo apt-get purge -y incus
    sudo apt-get autoremove -y
  fi
fi

echo "Teardown complete. (Your ~/.local/bin/box symlink and ~/.local/share/claudebox remain — remove by hand if wanted.)"
