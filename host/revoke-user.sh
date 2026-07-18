#!/usr/bin/env bash
# box revoke <user> [--purge] — take the restricted tier back (#74).
#
# Two strengths, deliberately:
#   · bare revoke removes the user from the 'incus' group. That closes the
#     socket — the only path their certificate can travel — so access ends at
#     their next login, while their project and boxes stay intact (and their
#     boxes stay RUNNING: revoking a person does not kill their workloads).
#     'box grant' restores everything untouched.
#   · --purge also deletes what the tier created: their boxes, their images,
#     their project, the private bridge, the trust-store certificate, the
#     incus-user state. Irreversible, so it asks first.
set -euo pipefail

usage() { echo "usage: box revoke <user> [--purge]" >&2; exit 2; }

user=""; purge=0
for a in "$@"; do
  case "$a" in
    --purge) purge=1 ;;
    -*) usage ;;
    *) [ -z "$user" ] || usage; user="$a" ;;
  esac
done
[ -n "$user" ] || usage

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: box revoke needs root and 'sudo' was not found." >&2
  exit 1
fi

getent passwd "$user" >/dev/null || { echo "box revoke: no such user: $user" >&2; exit 1; }
uid="$(id -u "$user")"
project="user-$uid"
# incus-user's own naming rule, mirrored exactly: the bridge is incusbr-<uid>
# unless that would not fit in an interface name (15 chars), then user-<uid>.
bridge="incusbr-$uid"
[ "${#bridge}" -gt 15 ] && bridge="user-$uid"

if [ "$purge" -eq 1 ]; then
  # Destructive and irreversible: a TTY to ask on, or BOX_YES=1, or refuse —
  # the same non-interactive contract as install.sh.
  if [ -z "${BOX_YES:-}" ]; then
    if [ -t 0 ]; then
      printf 'box revoke: delete ALL of %s'\''s boxes, images and their project %s? this cannot be undone. [y/N] ' "$user" "$project"
      read -r reply
      case "$reply" in y|Y|yes|YES|Yes) : ;; *) echo "box revoke: aborted." >&2; exit 1 ;; esac
    else
      echo "box revoke: refusing to --purge without a terminal to confirm on. BOX_YES=1 means yes." >&2
      exit 2
    fi
  fi
fi

# The group, first — access ends even if a purge step below trips.
if id -nG "$user" | tr ' ' '\n' | grep -qx incus; then
  $SUDO gpasswd -d "$user" incus >/dev/null
  echo "group: removed $user from 'incus'"
else
  echo "group: $user was not in 'incus'"
fi

# Supplementary groups are fixed AT LOGIN: the database change above does
# nothing to a session the user already holds — a leftover tmux keeps the
# socket until it dies. For a bare revoke that is an honest warning. For
# --purge it is a hole: a stale-group process can touch incus-user AFTER the
# purge and lazily recreate the project with incus-user's stock defaults —
# the unhardened NAT bridge, un-narrowed — which is strictly worse than the
# granted state this script is unwinding. So --purge terminates the user's
# sessions first (it is already the destructive, confirmed path), and a bare
# revoke says out loud what it did not do.
if pgrep -u "$user" >/dev/null 2>&1; then
  if [ "$purge" -eq 1 ]; then
    echo "sessions: $user has live processes — terminating them (a stale session could recreate the project, unhardened, after the purge)"
    $SUDO loginctl terminate-user "$user" 2>/dev/null || true
    $SUDO pkill -u "$user" 2>/dev/null || true
    sleep 1
    $SUDO pkill -9 -u "$user" 2>/dev/null || true
    if pgrep -u "$user" >/dev/null 2>&1; then
      echo "box revoke: could not terminate $user's processes — refusing to purge under them" >&2
      echo "            (they retain the socket until those sessions end, and could recreate the project)" >&2
      exit 1
    fi
  else
    echo "WARNING: $user has live sessions, and group membership is read at login —"
    echo "         those sessions keep the socket until they end. To end them now:"
    echo "         sudo loginctl terminate-user $user"
  fi
fi

if [ "$purge" -eq 0 ]; then
  if incus project show "$project" >/dev/null 2>&1 </dev/null; then
    echo "kept: project $project and its boxes (still running — revoking a person does not kill their workloads)"
    echo "      'box revoke $user --purge' deletes them; 'box grant $user' restores access"
  fi
  echo "revoked: $user no longer has the restricted tier."
  exit 0
fi

# --purge: unmake what the tier made. Instances one at a time — a wildcard
# delete that half-fails leaves a state nobody can name; a loop that fails
# names the box it failed on (the wipe.sh discipline).
if incus project show "$project" >/dev/null 2>&1 </dev/null; then
  while IFS=, read -r inst _; do
    [ -n "$inst" ] || continue
    echo "purge: deleting instance $inst"
    incus --project "$project" delete -f "$inst" </dev/null
  done < <(incus --project "$project" list --format csv --columns n 2>/dev/null)

  while IFS=, read -r fp _; do
    [ -n "$fp" ] || continue
    incus --project "$project" image delete "$fp" </dev/null
  done < <(incus --project "$project" image list --format csv --columns f 2>/dev/null)

  incus --project "$project" profile delete box-net >/dev/null 2>&1 </dev/null || true
  incus project delete "$project" </dev/null \
    || { echo "box revoke: could not delete $project — something is still in it (incus --project $project list / image list / storage volume list)" >&2; exit 1; }
  echo "purge: project $project removed"
fi

if incus network delete "$bridge" >/dev/null 2>&1 </dev/null; then
  echo "purge: private bridge $bridge removed"
fi

# The trust-store certificate incus-user minted for them. Named, not guessed:
# incus-user calls it incus-user-<uid>.
while IFS=, read -r name fp _; do
  [ "$name" = "incus-user-$uid" ] || continue
  incus config trust remove "$fp" </dev/null && echo "purge: trust-store certificate $name removed"
done < <(incus config trust list --format csv --columns nf 2>/dev/null)

# incus-user's per-user client state (their key pair). Removed so a future
# re-grant starts clean instead of trusting a key the purge revoked.
# $SUDO test, not a bare [ -d ]: /var/lib/incus is not traversable by a
# non-root admin, so an unprivileged stat answers "absent" for a directory
# that is very much there — the same lie the absence assert below must dodge.
if $SUDO test -d "/var/lib/incus/users/$uid" 2>/dev/null; then
  $SUDO rm -rf "/var/lib/incus/users/$uid"
  echo "purge: incus-user state for uid $uid removed"
fi

# Assert absence rather than trusting exit codes — the wipe.sh discipline.
# The certificate included: its removal above is set -e-exempt (left of &&),
# and a promise the header makes is a promise this block checks. The
# incus-user state directory too — it was purged for releases without being
# re-checked, which is exactly the gap this block exists to close.
leftover=""
incus project show "$project" >/dev/null 2>&1 </dev/null && leftover="$leftover $project"
incus network show "$bridge" >/dev/null 2>&1 </dev/null && leftover="$leftover $bridge"
incus config trust list --format csv --columns nf 2>/dev/null | grep -q "^incus-user-$uid," \
  && leftover="$leftover cert:incus-user-$uid"
$SUDO test -d "/var/lib/incus/users/$uid" 2>/dev/null \
  && leftover="$leftover /var/lib/incus/users/$uid"
if [ -n "$leftover" ]; then
  echo "box revoke: purge INCOMPLETE — still present:$leftover" >&2
  exit 1
fi

echo "revoked: $user is out, and everything the tier created is gone."
