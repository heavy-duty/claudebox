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

# --- The subnet: never build on one something already owns ------------------
# (#80.) The stack's subnet was hardcoded, and running setup-host INSIDE a box
# gave the guest a nested boxnet claiming the exact subnet and gateway of its
# own uplink: the guest then held its gateway's address as a LOCAL address,
# carried two connected routes for the subnet, and suffered intermittent,
# self-recovering egress blackouts nobody could attribute — the host looked
# clean the whole time. The flagship use case funnels agents toward doing
# exactly this (working on box, in a box), so the decision must happen BEFORE
# any mutation. An explicit BOX_SUBNET is honored or refused, never overridden;
# with no pin, choose_subnet below converges on an existing bridge or picks a
# free /24 itself — a drill inside a box now just works, zero flags.

# BOX_SUBNET must be a /24 with a zero host octet — a.b.c.0/24. Everything
# the stack derives (the bridge address, the gateway carve-out, the firewall)
# assumes that shape, and a garbage value must die HERE, never inside an
# incus create or an nft rule.
valid_subnet() {
  local o a="" b="" c="" rest=""
  case "$1" in *.0/24) ;; *) return 1 ;; esac
  IFS=. read -r a b c rest <<<"${1%/24}"
  [ "$rest" = 0 ] || return 1
  for o in "$a" "$b" "$c"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || return 1
  done
}

# Who, other than box's own bridge, already owns an address inside $1?
# Prints the claimant and succeeds when the subnet is claimed by a FOREIGNER;
# stays silent and fails when it is free — or held only by boxnet, which is
# the legitimate re-run, converging a stack this script built before. The
# most telling claimant is the default route's gateway: if it sits inside the
# target subnet, this machine's own uplink lives there — i.e. this is almost
# certainly the inside of a box. Pure over `ip` output, so test/cli.sh can
# drive it against canned tables with a shim ip.
subnet_claimant() {
  local pfx hit
  pfx="${1%0/24}"
  hit="$(ip -4 route show default 2>/dev/null | awk -v p="$pfx" '
    { gw = ""; dev = ""
      for (i = 1; i < NF; i++) { if ($i == "via") gw = $(i+1); if ($i == "dev") dev = $(i+1) }
      if (index(gw, p) == 1 && dev != "boxnet") {
        print "this machine\047s own DEFAULT GATEWAY (" gw " via " dev ")"; exit } }')"
  if [ -z "$hit" ]; then
    hit="$(ip -4 -o addr show 2>/dev/null | awk -v p="$pfx" '
      $2 != "boxnet" && index($4, p) == 1 { print "interface " $2 " (" $4 ")"; exit }')"
  fi
  [ -n "$hit" ] && printf '%s\n' "$hit"
}

# The one place the stack's subnet is decided. Four deliberate cases (#80's
# fix #1, completed — the refusal shipped first, this adds the auto-pick):
#   1. explicit BOX_SUBNET       — use it; a foreign claimant or a disagreeing
#      bridge still REFUSES. An operator's pin is never silently overridden:
#      a script that says 10.90 gets 10.90 or a loud stop, never a surprise.
#   2. no pin, boxnet exists     — converge to the bridge's own subnet: the
#      bridge IS the pin (boxes hold leases on it; setup-host never
#      re-addresses it). What used to be an agree-gate refusal on a bare
#      re-run against a moved bridge is now plain convergence. A FOREIGN
#      claimant on the bridge's own subnet still refuses — that is #80's
#      poisoned state, and converging would rebuild on it.
#   3. no pin, no bridge, 10.88.0.0/24 free — the default, as always.
#   4. no pin, no bridge, default claimed   — the nested case (a drill or
#      rehearsal inside a box): scan 10.89.0.0/24 … 10.127.0.0/24 in order,
#      take the first free candidate, and say so loudly; refuse only when
#      EVERY candidate is claimed. The scan only ever runs bridge-less —
#      an existing bridge is case 2, which precedes it.
# Prints the chosen subnet on stdout, explains itself on stderr, fails when
# it refuses. Everything downstream (BOX_GW, the bridge, the ACL carve-out,
# the firewall, the doctor's expectations) derives from the choice, which is
# why it happens here, before any of them. Pure over `ip` (via
# subnet_claimant and the bridge read), so test/cli.sh drives every case
# against canned tables with a shim ip.
choose_subnet() {
  local pin="$1" have_gw have_sub hit cand b
  # ('|| true': under pipefail, `ip … dev boxnet` on a fresh host — no such
  # device — would kill the script here instead of answering "no bridge".)
  have_gw="$(ip -4 -o addr show dev boxnet 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }' || true)"
  have_sub="${have_gw:+${have_gw%.*}.0/24}"

  if [ -n "$pin" ]; then
    if ! valid_subnet "$pin"; then
      echo "ERROR: BOX_SUBNET='$pin' is not a sane subnet — the stack takes a" >&2
      echo "       /24 with a zero host octet, e.g. BOX_SUBNET=10.89.0.0/24" >&2
      return 1
    fi
    if hit="$(subnet_claimant "$pin")"; then
      echo "ERROR: refusing to build boxnet on $pin — that subnet is already" >&2
      echo "       claimed here by $hit." >&2
      echo "       If that is this machine's uplink, you are INSIDE a box: a nested" >&2
      echo "       stack on the guest's own subnet captures its gateway address and" >&2
      echo "       blackholes its egress, intermittently (issue #80)." >&2
      echo "       Nothing was changed. Drop the pin to let setup-host auto-pick a" >&2
      echo "       free subnet, or pick one yourself:  BOX_SUBNET=<a.b.c.0/24> box setup-host" >&2
      return 1
    fi
    if [ -n "$have_sub" ] && [ "$have_sub" != "$pin" ]; then
      echo "ERROR: boxnet already exists on $have_sub and the target is $pin —" >&2
      echo "       setup-host converges an existing bridge, it never re-addresses one." >&2
      echo "       Re-run with the bridge's own subnet (a bare 'box setup-host'" >&2
      echo "       converges on it automatically):" >&2
      echo "         BOX_SUBNET=$have_sub box setup-host" >&2
      echo "       (or move the bridge first:  incus network set boxnet ipv4.address ${pin%.0/24}.1/24)" >&2
      return 1
    fi
    printf '%s\n' "$pin"
    return 0
  fi

  if [ -n "$have_sub" ]; then
    if hit="$(subnet_claimant "$have_sub")"; then
      echo "ERROR: boxnet lives on $have_sub, but that subnet is ALSO claimed here" >&2
      echo "       by $hit — the #80 poisoned state. Converging would rebuild on it." >&2
      echo "       Move the bridge off the claimed subnet first:" >&2
      echo "         incus network set boxnet ipv4.address 10.89.0.1/24" >&2
      echo "       then re-run:  box setup-host" >&2
      return 1
    fi
    if [ "$have_sub" != 10.88.0.0/24 ]; then
      echo "boxnet already lives on $have_sub — converging to it." >&2
      echo "(pin it explicitly with BOX_SUBNET=$have_sub if you script this host)" >&2
    fi
    printf '%s\n' "$have_sub"
    return 0
  fi

  if ! hit="$(subnet_claimant 10.88.0.0/24)"; then
    printf '10.88.0.0/24\n'
    return 0
  fi
  for b in {89..127}; do
    cand="10.$b.0.0/24"
    subnet_claimant "$cand" >/dev/null && continue
    echo "10.88.0.0/24 is claimed here by $hit —" >&2
    echo "most likely this machine IS a box (a nested drill or rehearsal, issue #80)." >&2
    echo "auto-picked $cand for this stack instead." >&2
    echo "(pin it explicitly with BOX_SUBNET=$cand if you script this host)" >&2
    printf '%s\n' "$cand"
    return 0
  done
  echo "ERROR: refusing to build boxnet — 10.88.0.0/24 is already claimed here by" >&2
  echo "       $hit, and so is every candidate through 10.127.0.0/24." >&2
  echo "       If that first claimant is this machine's uplink, you are INSIDE a" >&2
  echo "       box: a nested stack on the guest's own subnet captures its gateway" >&2
  echo "       address and blackholes its egress, intermittently (issue #80)." >&2
  echo "       Nothing was changed. Pick a free subnet yourself:" >&2
  echo "         BOX_SUBNET=<a.b.c.0/24> box setup-host" >&2
  return 1
}

BOX_SUBNET="$(choose_subnet "${BOX_SUBNET:-}")" || exit 1
BOX_GW="${BOX_SUBNET%.0/24}.1"

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
# The default is 10.88 — not 10.87: a pre-rename host may still carry
# claudenet on 10.87 with legacy boxes attached — two bridges must not claim
# one subnet. BOX_SUBNET holds whatever choose_subnet decided above (an
# explicit pin, the existing bridge, the default, or an auto-picked free
# /24); the gateway and every rule below derive from it.
incus network show boxnet >/dev/null 2>&1 || incus network create boxnet \
  ipv4.address="$BOX_GW/24" ipv4.nat=true ipv6.address=none

# ACL: default egress allow (internet), explicit drops for private space.
# Gateway carve-out first so instance DNS (dnsmasq on the gateway) survives.
# 'edit' the full shipped ruleset, not create-once: the carve-out derives
# from BOX_SUBNET now, and a bridge moved off a colliding subnet (#80's
# escape hatch) left the OLD /32 behind — box DNS to the new gateway then
# died inside the 10.0.0.0/8 drop, looking like a dead resolver, not a stale
# ACL. A conditional 'rule add' cannot converge that (the stale carve-out
# would survive beside the new one); replacing the ruleset does, idempotently.
incus network acl show box-isolate >/dev/null 2>&1 || incus network acl create box-isolate
incus network acl edit box-isolate <<ACL
description: ""
egress:
- action: allow
  destination: $BOX_GW/32
  state: enabled
- action: drop
  destination: 10.0.0.0/8
  state: enabled
- action: drop
  destination: 172.16.0.0/12
  state: enabled
- action: drop
  destination: 192.168.0.0/16
  state: enabled
- action: drop
  destination: 169.254.0.0/16
  state: enabled
- action: drop
  destination: 100.64.0.0/10
  state: enabled
ingress: []
ACL
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
