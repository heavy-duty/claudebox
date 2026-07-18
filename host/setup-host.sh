#!/usr/bin/env bash
# One-time host setup: install Incus, create the isolated network + ACL and
# the box-net profile. Idempotent. Ubuntu 24.04 / Debian 13.
set -euo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
here="$(dirname "$(dirname "$self")")"

# Byte-identical copy of bin/box's box_tier() — this script must know the
# tier before any install tree exists, and test/cli.sh diffs the two copies
# so they cannot drift.
box_tier() {
  [ "$(id -u)" -eq 0 ] && { printf 'admin\n'; return; }
  local groups; groups="$(id -nG 2>/dev/null | tr ' ' '\n')"
  if   printf '%s\n' "$groups" | grep -qx incus-admin; then printf 'admin\n'
  elif printf '%s\n' "$groups" | grep -qx incus;       then printf 'restricted\n'
  else printf 'none\n'
  fi
}

# A restricted (incus-group) user cannot build daemon-global state, and
# telling them to escalate would be wrong twice: the stack is the admin's to
# own, and if 'box new' works for them it already exists. Say so and succeed —
# this must sit BEFORE the sudo resolution below, which would otherwise bury
# the honest answer under a privilege error. Gated on the tier, not on
# 'command -v sudo': having the sudo binary is not the same as holding a grant.
if [ "$(id -u)" -ne 0 ] && [ "$(box_tier)" = restricted ]; then
  echo "You are in the 'incus' group (restricted tier): you manage your own boxes," >&2
  echo "but the host's daemon-global stack is built by an admin. It is already set" >&2
  echo "up if 'box new' works. Nothing for you to do here." >&2
  exit 0
fi

# How we reach root, decided once. 'sudo' cannot be hardcoded: at UID 0 it is
# unnecessary, and on a minimal root image it is not installed at all — this
# script died on 'sudo: command not found' before doing anything, which made
# install.sh's deliberate root path unusable on exactly the hosts it was for.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: host setup needs root and 'sudo' was not found." >&2
  echo "       re-run this as root: $self" >&2
  exit 1
fi

# apt, unattended-safe. install.sh now runs us without a human watching, and
# a fresh cloud image has apt-daily/unattended-upgrades holding the dpkg lock
# for the first minutes of its life — plain 'apt-get install' then waits on it
# in complete silence, indefinitely. Bound the wait and never prompt.
# 'env', not a bare VAR=val prefix: bash recognises assignments at PARSE time,
# so with $SUDO empty (we are root) 'DEBIAN_FRONTEND=x apt-get' would have
# already been parsed as a plain word and bash would try to EXECUTE it —
# 'DEBIAN_FRONTEND=noninteractive: command not found'. env is immune.
apt_get() {
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

if ! command -v incus >/dev/null; then
  apt_get update
  apt_get install -y incus
fi

if [ "$(id -u)" -eq 0 ]; then
  # Root needs no group: UID 0 opens /var/lib/incus/unix.socket regardless of
  # who owns it, and there is nothing to re-exec into. The HUMAN needs it — and
  # under 'sudo install.sh' that is SUDO_USER, not the root we are running as.
  # Adding root to incus-admin would be a no-op that also left the actual user
  # locked out of their own boxes.
  # NOTE: 'id -nG "$name"' here is deliberate and NOT the bug fixed below. That
  # bug was asking the DATABASE about our own process; this asks the database
  # about someone else's account, which is the only thing it can be asked.
  login_user="${SUDO_USER:-}"
  if [ -n "$login_user" ] && [ "$login_user" != root ]; then
    if ! id -nG "$login_user" | grep -qw incus-admin; then
      usermod -aG incus-admin "$login_user"
      echo "added $login_user to incus-admin — log out and back in for your shell to pick it up"
    fi
  fi
# Group membership is a property of THIS PROCESS's credentials, not of the group
# database — and the two disagree for exactly as long as it matters here.
# 'id -nG "$USER"' names a user, so it reads /etc/group and reports incus-admin
# the instant usermod returns; the running shell's own credentials still lack
# it, because supplementary groups are fixed at login. So the old check passed
# on a same-session re-run, sailed into the incus calls below, and died on a
# permission error that named neither the group nor the re-login. Argless
# 'id -nG' asks the process what it actually holds, which is what incus checks
# when it opens /var/lib/incus/unix.socket.
elif ! id -nG | grep -qw incus-admin; then
  $SUDO usermod -aG incus-admin "$USER"
  # Then finish the job rather than adjourning it. Exiting 0 here was a
  # success-shaped no-op: no boxnet, no ACL, no box-net profile, no firewall —
  # and the burden of knowing that on the reader of a NOTE (#63). 'sg' runs us
  # again with the new group in our credentials, no re-login, one invocation.
  # The guard makes that at most one hop: if sg somehow lands without the
  # group, we fail loudly instead of forking forever.
  if [ -z "${BOX_SETUP_HOST_REEXEC:-}" ]; then
    echo "added $USER to incus-admin — re-running under the new group (no re-login needed)"
    export BOX_SETUP_HOST_REEXEC=1
    exec sg incus-admin -c "$(printf '%q ' bash "$self" "$@")"
  fi
  echo "ERROR: still not in incus-admin after usermod + sg." >&2
  echo "       log out and back in, then re-run: box setup-host" >&2
  exit 1
fi

# Storage pool + base config (safe to re-run: skipped once the pool exists).
# NOT 'incus admin init --minimal': minimal picks the 'dir' backend, which has
# no copy-on-write — every snapshot and clone is a FULL copy of the box's root,
# several GB and minutes apiece once a box is provisioned, against a workflow
# whose whole point is "log in once, snapshot, clone forever" (#29). btrfs on
# a loop device gives CoW (near-instant, near-free clones) with no
# partitioning. The preseed mirrors exactly what --minimal creates (pool,
# incusbr0, default profile) with only the driver deliberate; dir remains the
# fallback so a host that cannot do btrfs still works — just slowly, and it
# says so.
if ! incus storage show default >/dev/null 2>&1; then
  driver=btrfs
  command -v mkfs.btrfs >/dev/null 2>&1 || apt_get install -y btrfs-progs || driver=dir
  if ! incus admin init --preseed <<PRESEED
storage_pools:
- name: default
  driver: $driver
networks:
- name: incusbr0
  type: bridge
profiles:
- name: default
  devices:
    root:
      path: /
      pool: default
      type: disk
    eth0:
      name: eth0
      network: incusbr0
      type: nic
PRESEED
  then
    echo "storage: $driver preseed failed — falling back to --minimal (dir: every clone is a full disk copy)" >&2
    incus admin init --minimal
  fi
  echo "storage: pool 'default' driver = $(incus storage show default | awk '/^driver:/ {print $2}')"
fi

# Isolated NAT network. IPv6 off: one less egress path to reason about.
# 10.88, not 10.87: a pre-rename host may still carry claudenet on 10.87 with
# legacy boxes attached — two bridges must not claim one subnet.
incus network show boxnet >/dev/null 2>&1 || incus network create boxnet \
  ipv4.address=10.88.0.1/24 ipv4.nat=true ipv6.address=none

# ACL: default egress allow (internet), explicit drops for private space.
# Gateway carve-out first so instance DNS (dnsmasq on 10.88.0.1) survives.
if ! incus network acl show box-isolate >/dev/null 2>&1; then
  incus network acl create box-isolate
  incus network acl rule add box-isolate egress action=allow destination=10.88.0.1/32
  incus network acl rule add box-isolate egress action=drop destination=10.0.0.0/8
  incus network acl rule add box-isolate egress action=drop destination=172.16.0.0/12
  incus network acl rule add box-isolate egress action=drop destination=192.168.0.0/16
  incus network acl rule add box-isolate egress action=drop destination=169.254.0.0/16
  incus network acl rule add box-isolate egress action=drop destination=100.64.0.0/10
fi
incus network set boxnet security.acls=box-isolate \
  security.acls.default.egress.action=allow \
  security.acls.default.ingress.action=drop

# A box must not be able to ENUMERATE its siblings, either. dnsmasq on the
# gateway serves DNS (that carve-out is what makes egress resolution work) and
# it holds a record for every instance on the network — so 'getent hosts <box>'
# from inside one box resolved another's name and address. Connection blocked,
# reconnaissance wide open. dns.mode=none stops it registering instance records;
# forwarding for public names is unaffected (verified live).
incus network set boxnet dns.mode=none

# A box's resolver must not be a function of the host's VPN posture (#33).
# The bridge's dnsmasq forwards to whatever sits in the HOST's /etc/resolv.conf
# at that moment. On a Tailscale/VPN host that is MagicDNS: box DNS flaps with
# the tailnet (this is what killed cold mints), and tailnet peer names and
# split-DNS zones RESOLVE from inside a box — name-level reconnaissance of a
# private network, the same shape as the sibling enumeration closed above.
# no-resolv detaches dnsmasq from the host's resolver entirely; server= pins a
# stable public upstream (override: BOX_DNS="ip ip…"). raw.dnsmasq is the
# lever — the bridge has no first-class upstream key. Verified live on the
# drill host: pin applied, box resolves, cold mint survives.
BOX_DNS="${BOX_DNS:-1.1.1.1 8.8.8.8}"
incus network set boxnet raw.dnsmasq \
  "$(printf 'no-resolv\n'; for s in $BOX_DNS; do printf 'server=%s\n' "$s"; done)"

# Sibling isolation itself is NOT an ACL rule — an L3 ACL never sees frames
# switched between two ports of one bridge. It lives in box-firewall.sh
# as an nftables bridge-family rule. See the comment there; it is the reason
# boxes cannot reach each other.

# IPv6 stays off (ipv6.address=none, above). Every rule in the ACL and every
# rule in the firewall is IPv4-only, so IPv6 would be an uncovered path, not a
# feature. That is a contract, not a default.

# --- Firewall coexistence ---------------------------------------------------
# Hosts running UFW (INPUT drop) and/or Docker (FORWARD drop) silently eat
# boxnet traffic. Punch minimal, ordered holes; the Incus ACL still layers
# on top. The trailing deny also blocks instance -> host's own (public) IPs,
# which the RFC1918-only ACL cannot express. Rules live in
# box-firewall.sh; a boot-time systemd unit re-applies the runtime-only
# parts (nft table, DOCKER-USER) after every reboot.
# The no-UFW path drives nft directly, and a stock Debian 13 cloud image ships
# neither nftables nor UFW — install the dependency we are about to use.
if ! command -v ufw >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
  apt_get install -y nftables
fi
$SUDO install -m 755 "$here/host/box-firewall.sh" /usr/local/sbin/box-firewall
$SUDO install -m 644 "$here/host/box-firewall.service" /etc/systemd/system/
$SUDO systemctl daemon-reload
$SUDO systemctl enable box-firewall.service
# RESTART, not 'enable --now'. The unit is RemainAfterExit, so once it has run
# it stays "active" forever — and 'enable --now' does nothing to an active unit.
# Re-running setup-host after upgrading the tool therefore installed the new
# rules to /usr/local/sbin and never applied them: the host kept the old
# firewall, silently, and the box→box hole stayed open through a release that
# claimed to close it. Restart re-runs the script, which is idempotent by design.
$SUDO systemctl restart box-firewall.service

# incus-user is what serves the restricted tier (box grant). Debian 13 and
# Ubuntu 24.04 ship it inside the incus package; enabling it here makes the
# host tier-ready, and costs a host that never grants anyone nothing. Failure
# is a NOTE, not an error: the admin tier does not depend on it.
$SUDO systemctl enable --now incus-user.socket 2>/dev/null \
  || echo "NOTE: could not enable incus-user.socket — 'box grant' (the restricted tier) needs it; this Incus may not ship incus-user (#74)." >&2

# Profile — box-net, the placement contract: the isolated NIC and the root
# disk, nothing a template controls (resources are stamped per-instance from
# the template at mint time). A legacy claude-dev profile is left alone:
# Incus refuses to delete an in-use profile, and pre-rename boxes reference
# it until their last one is gone — teardown-host removes it then.
if ! incus profile show box-net >/dev/null 2>&1; then
  incus profile create box-net
fi
incus profile edit box-net < "$here/profiles/box-net.yaml"

# The sibling drop is the one rule whose absence is invisible: everything keeps
# working, and boxes can simply reach each other. Assert it landed.
if $SUDO nft list table bridge box >/dev/null 2>&1; then
  echo "Isolation: box-to-box drop is live (nft bridge table 'box')."
else
  echo "WARNING: the box-to-box drop is NOT active — boxes can reach each other." >&2
  echo "         check: sudo /usr/local/sbin/box-firewall ; sudo nft list table bridge box" >&2
fi

echo "Host ready. Launch with: box new --name <box>"
