#!/usr/bin/env bash
# wipe.sh — scorched earth for drill hosts. Remove EVERY trace of box and of
# pre-0.4.0 claudebox, so the next drill run starts from a truly bare host and
# its verdict means something.
#
#   bash drill/wipe.sh                   # asks first
#   bash drill/wipe.sh --yes             # no prompt
#   bash drill/wipe.sh --purge-storage   # also delete cached images AND the
#                                        # 'default' storage pool, so setup-host
#                                        # exercises its pool bootstrap (#29)
#
# What teardown-host.sh does NOT cover, this does: instances the drill names
# but never tagged, instances of either tag generation, cached images, and
# (opt-in) the storage pool. teardown is the polite uninstall; this is the
# reset button for the staging server.
#
# NOT 'set -e': on a wipe, a step that finds nothing to remove is success,
# not failure. Every removal states what it did; silence is never trusted
# (the exit-code lesson, again).
set -u

YES=0; PURGE_STORAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --purge-storage) PURGE_STORAGE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "wipe: unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf 'wipe: %s\n' "$*"; }

if [ "$YES" -ne 1 ]; then
  cat <<EOF
This wipes EVERY trace of box/claudebox from this host ($(hostname)):
  · every instance tagged user.box=1 or user.claudebox=1
  · every instance the drill has ever named (drill, clone, archive, peer,
    payroll, cbprobe, cbcopy, cbnotours, tpl)
  · networks boxnet + claudenet, ACLs box-isolate + claude-isolate
  · profiles box-net + claude-dev
  · firewall units, scripts and nft tables of BOTH name generations
  · every cached Incus image (the next mint re-downloads)
$( [ "$PURGE_STORAGE" = 1 ] && echo "  · the 'default' storage pool (--purge-storage)" )
Uncommitted work inside any box is LOST. Only do this on a drill host.
EOF
  [ -t 0 ] || { echo "wipe: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
  printf 'Continue? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
fi

command -v incus >/dev/null || { say "incus is not installed — nothing box-shaped can exist; only firewall crumbs checked."; }

if command -v incus >/dev/null; then
  # --- instances: both tags, then every name the drill has ever used --------
  # One delete at a time — a multi-name 'incus delete' aborts at the first
  # missing name (drill trap 5).
  for tag in "user.box=1" "user.claudebox=1"; do
    for i in $(incus list "$tag" -f csv -c n 2>/dev/null); do
      timeout -k 5 60 incus delete -f "$i" >/dev/null 2>&1 \
        && say "deleted instance $i ($tag)" || say "instance $i: delete FAILED — look at it by hand"
    done
  done
  for n in drill clone archive peer payroll cbprobe cbcopy cbnotours tpl; do
    incus info "$n" >/dev/null 2>&1 || continue
    timeout -k 5 60 incus delete -f "$n" >/dev/null 2>&1 \
      && say "deleted untagged drill instance $n" || say "instance $n: delete FAILED — look at it by hand"
  done

  # --- profiles, networks, ACLs — both generations ---------------------------
  for p in box-net claude-dev; do
    incus profile delete "$p" >/dev/null 2>&1 && say "deleted profile $p"
  done
  for net in boxnet claudenet; do
    incus network delete "$net" >/dev/null 2>&1 && say "deleted network $net"
  done
  for acl in box-isolate claude-isolate; do
    incus network acl delete "$acl" >/dev/null 2>&1 && say "deleted ACL $acl"
  done

  # --- cached images: the pool's other tenants -------------------------------
  for f in $(incus image list -f csv -c f 2>/dev/null); do
    incus image delete "$f" >/dev/null 2>&1 && say "deleted image $f"
  done

  # --- the pool itself (opt-in): lets setup-host's bootstrap run for real ----
  if [ "$PURGE_STORAGE" = 1 ]; then
    incus profile device remove default root >/dev/null 2>&1 && say "removed default profile's root device"
    if incus storage delete default >/dev/null 2>&1; then
      say "deleted storage pool 'default' — setup-host will rebuild it (btrfs where it can)"
    else
      incus storage show default >/dev/null 2>&1 \
        && say "pool 'default' NOT deleted — something still uses it: incus storage volume list default" \
        || say "no 'default' pool existed"
    fi
  fi
fi

# --- firewall: units, scripts, nft tables, UFW and Docker crumbs -------------
for unit in box-firewall claudebox-firewall; do
  sudo systemctl disable --now "$unit.service" >/dev/null 2>&1 && say "disabled $unit.service"
  sudo rm -f "/etc/systemd/system/$unit.service" "/usr/local/sbin/$unit"
done
sudo systemctl daemon-reload
for t in "inet box" "bridge box" "inet claudebox" "bridge claudebox"; do
  # shellcheck disable=SC2086 # the table spec is two words by design
  sudo nft delete table $t >/dev/null 2>&1 && say "deleted nft table $t"
done
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  for net in boxnet claudenet; do
    while sudo ufw status numbered | grep -q "on $net"; do
      n="$(sudo ufw status numbered | grep -m1 "on $net" | sed -E 's/^\[ *([0-9]+)\].*/\1/')"
      sudo ufw --force delete "$n" >/dev/null && say "deleted UFW rule on $net"
    done
  done
fi
if command -v docker >/dev/null; then
  for net in boxnet claudenet; do
    sudo iptables -D DOCKER-USER -i "$net" -j ACCEPT 2>/dev/null && say "removed DOCKER-USER -i $net"
    sudo iptables -D DOCKER-USER -o "$net" -j ACCEPT 2>/dev/null && say "removed DOCKER-USER -o $net"
  done
fi

# --- verdict: assert the ABSENCE, don't trust the removals' exit codes -------
left=""
if command -v incus >/dev/null; then
  for tag in "user.box=1" "user.claudebox=1"; do
    [ -n "$(incus list "$tag" -f csv -c n 2>/dev/null)" ] && left="$left instances($tag)"
  done
  for net in boxnet claudenet; do incus network show "$net" >/dev/null 2>&1 && left="$left $net"; done
  for p in box-net claude-dev; do incus profile show "$p" >/dev/null 2>&1 && left="$left $p"; done
fi
for t in "inet box" "bridge box" "inet claudebox" "bridge claudebox"; do
  # shellcheck disable=SC2086
  sudo nft list table $t >/dev/null 2>&1 && left="$left nft:${t// /-}"
done
if [ -n "$left" ]; then
  say "NOT clean — still present:$left"
  exit 1
fi
say "clean — no trace of box or claudebox remains. The drill will rebuild everything."
