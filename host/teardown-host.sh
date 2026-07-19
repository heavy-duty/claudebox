#!/usr/bin/env bash
# Reverse everything host/setup-host.sh created — and everything its pre-0.4.0
# ancestor created, so one teardown cleans a host of any generation: all boxes
# (both tags), the boxnet/claudenet networks + ACLs, the box-net/claude-dev
# profiles, and both generations of firewall units and nft tables.
# Usage: ./host/teardown-host.sh [--purge-incus] [--yes]
#   --purge-incus  also apt-purge Incus itself (skipped if non-box
#                  instances still exist on this host)
#   --yes          skip the confirmation (BOX_YES=1 does the same) — for
#                  automation: CI's uninstall drill and 'box uninstall
#                  --purge-host' run this unattended
set -euo pipefail

purge=false; yes=0
for arg in "$@"; do
  case "$arg" in
    --purge-incus) purge=true ;;
    --yes|-y) yes=1 ;;
    *) echo "teardown-host: unknown option: $arg" >&2; exit 2 ;;
  esac
done
[ -n "${BOX_YES:-}" ] && yes=1

echo "This removes ALL boxes (uncommitted work in them is lost), the"
echo "boxnet/claudenet networks, ACLs, profiles, and the box firewall rules"
echo "(both current and pre-0.4.0 names)."
$purge && echo "Incus itself will also be uninstalled (--purge-incus)."
if [ "$yes" -eq 1 ]; then
  echo "(confirmed non-interactively: --yes/BOX_YES)"
else
  # No terminal to ask on, and no consent given: refuse and say how to proceed,
  # rather than fall into 'read', hit instant EOF and abort with nothing but
  # "aborted" (#113). This must stay BELOW the --yes/BOX_YES arm above — the
  # order is the contract: consent given non-interactively still runs headless
  # (CI's uninstall drill and 'box uninstall --purge-host --force' depend on
  # it), consent NOT given without a terminal is a usage error, exit 2, the
  # same shape as host/revoke-user.sh and install.sh. It also lands before the
  # first 'incus' call below, so the refusal needs no daemon.
  if [ ! -t 0 ]; then
    echo "teardown-host: refusing to run without a terminal to confirm on. --yes (or BOX_YES=1) means yes." >&2
    exit 2
  fi
  # EOF (Ctrl-D) refuses, out loud: unguarded, errexit would end the run on
  # this line and the 'aborted' below would never print (#111).
  read -rp "Continue? [y/N] " a || { echo "aborted"; exit 1; }
  case "$a" in y|Y) ;; *) echo "aborted"; exit 1 ;; esac
fi

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
# Every ufw read is CAPTURED before it is matched, never piped into a reader
# that can exit early — the same discipline box-firewall.sh now uses, and for
# the same measured reason (#102). This file sets `pipefail` (line 12), so
# `ufw status | grep -q "Status: active"` returns the WRITER's exit: grep
# matches on the first line ufw prints, closes the pipe, ufw takes SIGPIPE,
# and the pipeline yields 141. A plainly-active UFW then reads as inactive
# and this entire block silently skips, leaving stale boxnet/claudenet rules
# on a host the operator was told is clean. It is a branch condition, so
# errexit never fires — there is no error to see, which is exactly why it
# went unnoticed here while the same shape was being measured next door.
#
# The numbered loop had the same defect for a different reason: its condition
# was also an early-exit reader, so it could end while rules remained. It now
# reads one capture per iteration and breaks on absence — the re-scan is still
# per-delete (numbers shift after each removal), just no longer racing.
ufw_status=""
if command -v ufw >/dev/null; then
  # '|| true': ufw exits non-zero when it cannot read its config, and under
  # pipefail+errexit that would kill a teardown instead of correctly deciding
  # "no usable ufw here, nothing to clean".
  ufw_status="$(sudo ufw status 2>/dev/null || true)"
fi

if [[ "$ufw_status" == *"Status: active"* ]]; then
  for net in boxnet claudenet; do
    while :; do
      numbered="$(sudo ufw status numbered 2>/dev/null || true)"
      line="$(printf '%s\n' "$numbered" | grep -m1 "on $net" || true)"
      [ -n "$line" ] || break
      n="$(printf '%s\n' "$line" | sed -E 's/^\[ *([0-9]+)\].*/\1/')"
      [ -n "$n" ] || break
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

echo "Teardown complete. (The box install tree itself remains — 'box uninstall' removes it, with a zero-residue check.)"
