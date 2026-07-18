#!/usr/bin/env bash
# box grant <user> — give a host user the restricted tier (#74).
#
# The tier rides incus-user: the user lands in an auto-created project
# user-<uid> and can only ever see their own instances. What incus-user does
# NOT do is put them on box's hardened network — it auto-creates a private
# bridge incusbr-<uid> (a plain NAT bridge: no ACL, no DNS isolation, IPv6 on,
# none of box's contract) and pins the project to it. Measured on Debian 13 /
# Incus 6.0.4; the full write-up is in docs/plans/2026-07-18-restricted-tier.md.
#
# So granting is a per-user CONVERGENCE, and it must be run by an admin:
#   1. put the user in the 'incus' group (not incus-admin — that is the tier)
#   2. touch incus-user AS the user, so the lazy project exists to converge
#   3. unpin the private bridge (drop eth0 from the project's default profile)
#   4. restrict the project's network access to boxnet and ONLY boxnet —
#      "boxnet,incusbr-<uid>" would leave an unhardened NAT bridge one
#      '--network' flag away from any box they mint
#   5. allow snapshots (incus-user blocks them; box's clone workflow is built
#      on them)
#   6. allow backups (blocked too; 'box export' rides the backup API — #70)
#   7. install the shipped box-net profile into their project
#
# Idempotent: every step converges, so re-running (including after a box
# upgrade, to refresh the profile) is safe. incus-user never rewrites a
# project it already created (verified against its source: setup is skipped
# once the project exists and the user's certificate is trusted), so nothing
# here is fighting a re-sync.
set -euo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
here="$(dirname "$(dirname "$self")")"

usage() { echo "usage: box grant <user>" >&2; exit 2; }

[ $# -eq 1 ] || usage
user="$1"
case "$user" in -*) usage ;; esac

# Root, or sudo — same decision, same reasons as setup-host.sh: granting
# needs usermod and a run-as-the-user touch, both root's to give.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: box grant needs root and 'sudo' was not found." >&2
  echo "       re-run as root: $self $user" >&2
  exit 1
fi

# Run a command as the granted user. 'runuser' when we are root (sudo may not
# exist there), sudo -u otherwise. -H so incus's client state lands in THEIR
# home, not the admin's. stdin pinned: an incus client with a terminal on
# stdin can go interactive and wedge a script that will never answer it.
run_as() {
  local u="$1"; shift
  if [ -n "$SUDO" ]; then $SUDO -u "$u" -H -- "$@" </dev/null
  else runuser -u "$u" -- "$@" </dev/null
  fi
}

getent passwd "$user" >/dev/null || { echo "box grant: no such user: $user" >&2; exit 1; }
uid="$(id -u "$user")"
[ "$uid" -eq 0 ] && { echo "box grant: root does not need a tier — UID 0 owns the daemon socket outright." >&2; exit 1; }

# An incus-admin member already holds the full socket; "granting" them the
# restricted tier would not restrict anything (admin membership wins at the
# socket), it would only mislead whoever reads the group list later.
if id -nG "$user" | tr ' ' '\n' | grep -qx incus-admin; then
  echo "box grant: $user is in incus-admin — they already have the admin tier; there is nothing tighter to grant." >&2
  exit 1
fi

# The stack the tier converges ONTO must exist first. Checked via the daemon,
# not config files: setup-host is the only thing that builds boxnet.
incus network show boxnet >/dev/null 2>&1 </dev/null \
  || { echo "box grant: no boxnet on this host — build the stack first: box setup-host" >&2; exit 1; }

# incus-user is the mechanism under the whole tier. Debian 13 and Ubuntu 24.04
# ship it in the incus package; a host without it cannot hold this tier at all.
if ! systemctl is-active --quiet incus-user.socket; then
  $SUDO systemctl enable --now incus-user.socket 2>/dev/null \
    || { echo "box grant: incus-user.socket is not available — this Incus cannot serve the restricted tier (see #74)." >&2; exit 1; }
fi

# 1. The group. 'incus' is the restricted socket; membership takes effect at
# the user's next login, but run_as below starts a fresh process with the
# database's groups, so the grant itself never waits on a re-login.
#
# If THIS run granted the group and a later step fails, take it back on the
# way out: a half-granted user would otherwise hold live socket access to an
# UN-NARROWED project — the stock unhardened bridge attachable — until an
# admin re-runs. Backing out the group closes that window completely for a
# fresh grant (their existing sessions predate the membership, so no process
# holds it yet). A user who was already in the group keeps it: not ours to
# take on a re-run's failure.
added_group=0; was_member=0
backout() {
  if [ "$added_group" -eq 1 ]; then
    $SUDO gpasswd -d "$user" incus >/dev/null 2>&1 || true
    # VERIFY the removal — an unverified rollback printing a security
    # guarantee is a lie waiting for its day. Exact-token match, live DB.
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx incus; then
      echo "box grant: ROLLBACK INCOMPLETE — the grant failed AND $user is still in the 'incus' group." >&2
      echo "           remove it by hand NOW:  gpasswd -d $user incus   (then fix the cause and re-run)" >&2
      exit 1
    fi
    echo "box grant: FAILED — removed $user from 'incus' again (verified against the group database); fix the cause and re-run" >&2
    # The one window the database cannot close: a login STARTED between our
    # usermod and this backout keeps the group in its session credentials.
    # For a fresh grant that is a rare race, but rare is not never — name it
    # and the remedy instead of overclaiming.
    if pgrep -u "$user" >/dev/null 2>&1; then
      echo "box grant: NOTE — $user has live processes; a session begun during this grant would still hold" >&2
      echo "           the group until it ends:  sudo loginctl terminate-user $user" >&2
    fi
  elif [ "$was_member" -eq 1 ]; then
    # A user who was ALREADY in the group keeps it — stripping a membership
    # this run did not add could break a working user over a failed re-run.
    # But silence here would leave them holding a socket onto part-converged
    # policy without the admin being told. Loud, with both remediations.
    echo "box grant: FAILED with $user still holding socket access (their membership predates this run)." >&2
    echo "           their project may be part-converged — harmless in itself, and a re-run converges the rest." >&2
    echo "           if their access is not acceptable while you fix the cause:  box revoke $user" >&2
  fi
}
trap backout EXIT

if id -nG "$user" | tr ' ' '\n' | grep -qx incus; then
  was_member=1
  echo "group: $user already in 'incus'"
else
  $SUDO usermod -aG incus "$user"
  added_group=1
  echo "group: added $user to 'incus' (their next login picks it up; the grant does not wait)"
fi

project="user-$uid"

# 2. The project is created LAZILY, on the user's first contact with
# incus-user — an admin cannot pre-create it (incus-user would fight over
# it), so make that first contact happen now, as the user.
if ! incus project show "$project" >/dev/null 2>&1 </dev/null; then
  echo "project: touching incus-user as $user to create $project..."
  run_as "$user" timeout 60 incus project list >/dev/null 2>&1 || true
  incus project show "$project" >/dev/null 2>&1 </dev/null \
    || { echo "box grant: incus-user did not create $project — is incus-user.socket healthy? (journalctl -u incus-user)" >&2; exit 1; }
  echo "project: $project created"
else
  echo "project: $project already exists"
fi

# 3. Unpin the private bridge. incus-user's default profile carries an eth0
# on incusbr-<uid>; while ANY profile references that bridge, the narrowing
# below is rejected by incus's own validation. Removing the device is also
# what it looks like: the default profile in this project places no network —
# box-net is the only door, which is the placement contract working.
if incus --project "$project" profile device get default eth0 type >/dev/null 2>&1 </dev/null; then
  incus --project "$project" profile device remove default eth0 >/dev/null </dev/null
  echo "profile: removed the private-bridge eth0 from $project's default profile"
fi

# 4. boxnet, and ONLY boxnet. The auto-created incusbr-<uid> is a stock NAT
# bridge with none of box's hardening — listing it here would keep a
# one-flag escape from the isolation contract open forever. Narrowed, the
# hardened network is not the default placement but the only one possible.
# This can fail honestly: an instance the user already parked on the private
# bridge blocks the narrowing, and incus's error names it.
if ! err="$(incus project set "$project" restricted.networks.access boxnet 2>&1 </dev/null)"; then
  echo "box grant: could not restrict $project to boxnet:" >&2
  echo "  $err" >&2
  echo "  (an instance still on the private bridge blocks this — move or delete it, then re-run)" >&2
  exit 1
fi
# The private bridge's name follows incus-user's own rule (revoke-user.sh
# mirrors it too): incusbr-<uid>, or user-<uid> when that would not fit an
# interface name — naming the wrong one here would be a true claim with the
# wrong noun on big-uid (SSSD/AD) hosts.
bridge="incusbr-$uid"; [ "${#bridge}" -gt 15 ] && bridge="user-$uid"
echo "network: $project restricted to boxnet (the private $bridge is unreferenced and unreachable)"

# 5. Snapshots. incus-user projects block them by default, and box's whole
# reuse story — log in once, snapshot, clone forever — is snapshots.
incus project set "$project" restricted.snapshots allow </dev/null
echo "snapshots: allowed"

# 6. Backups. 'box export' rides incus's backup API — an export IS "create a
# backup, download it, delete it" — and a restricted project blocks that by
# default: restricted.backups=block the moment restricted=true (incus 6.0,
# internal/server/project/permissions.go, enforced by AllowBackupCreation).
# 'box import' needs no key of its own — restoring a backup file is plain
# instance creation. Same convergence as snapshots, for the same reason: the
# tier is the same workflows on your own boxes, and export/import are
# workflows (#70).
incus project set "$project" restricted.backups allow </dev/null
echo "backups: allowed ('box export' rides them, #70)"

# 7. The placement contract itself, installed into their project. Created if
# missing, refreshed unconditionally — same convergence discipline as
# setup-host's own profile handling, so a box upgrade propagates by re-run.
incus --project "$project" profile show box-net >/dev/null 2>&1 </dev/null \
  || incus --project "$project" profile create box-net >/dev/null </dev/null
incus --project "$project" profile edit box-net < "$here/profiles/box-net.yaml"
echo "profile: box-net installed in $project"

# Prove the grant from the USER's side of the socket — the only side that
# matters. This catches the failure the steps above cannot see one at a time:
# a converged project the user still cannot reach.
run_as "$user" timeout 30 incus profile show box-net >/dev/null 2>&1 \
  || { echo "box grant: converged, but $user cannot see the box-net profile through incus-user — check journalctl -u incus-user" >&2; exit 1; }

trap - EXIT   # converged and verified: the grant stands
echo "granted: $user has the restricted tier — their 'box new' lands on the hardened boxnet."
echo "         (their boxes are theirs alone; 'box revoke $user' takes the tier back)"
