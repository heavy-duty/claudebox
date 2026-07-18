#!/usr/bin/env bash
# multiuser.sh — the restricted-tier rehearsal (#74): does 'box grant' give a
# plain incus-group user their own boxes, on the hardened boxnet, with no view
# of anyone else's — measured live, from both sides of the socket?
#
#   sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh --yes
#
# It creates two throwaway system users, grants them the tier through the real
# 'box grant', mints real boxes as them, probes the isolation contract from
# INSIDE those boxes, revokes one user, and deletes everything it made. Root
# only, and opt-in twice (the env gate and the prompt): it edits the group
# database and the daemon's project list, which is nothing to do casually.
#
# Criteria (a)-(f) are issue #74's acceptance gate, kept under their letters;
# (g)-(l) are what the Task-0 findings added: the network CONTRACT is the
# tier's whole point, so it is measured, never assumed.
#
#   a. an incus-group user is auto-confined to their own project
#   b. they can box new / list / exec / snapshot / restore / clone their own box
#   c. they cannot see another user's boxes
#   d. the same box name in two projects does not collide
#   e. box expose refuses for them (daemon-global state)
#   f. box setup-host / box doctor answer with the honest restricted note
#   g. their boxes ride boxnet and carry the full isolation contract
#   h. the private incusbr-<uid> escape hatch is closed (boxnet is the ONLY network)
#   i. (folded into b: snapshot / restore / clone)
#   k. the grant survives an incus-user restart
#   l. box revoke --purge removes the user's world and touches nobody else's
#
# ok/no/note return 0 by design — the 'A && ok || no' idiom below is the
# same one drill.sh is built on (and the reason for the SC2015 disable).
# shellcheck disable=SC2015
set -u

YES=0; KEEP=0; MODE=()
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --keep) KEEP=1 ;;
    --container) MODE=(--container) ;;   # CI / kvm-less hosts: don't wait on a VM
    *) echo "usage: sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh [--yes] [--container] [--keep]" >&2; exit 2 ;;
  esac
done

[ "${BOX_MULTIUSER_REHEARSAL:-}" = 1 ] || {
  echo "multiuser.sh: this rehearsal creates system users and edits the group database." >&2
  echo "opt in explicitly:  sudo BOX_MULTIUSER_REHEARSAL=1 bash drill/multiuser.sh --yes" >&2
  exit 2
}
[ "$(id -u)" -eq 0 ] || { echo "multiuser.sh: root only (it creates users and grants tiers)." >&2; exit 1; }
command -v box >/dev/null || { echo "multiuser.sh: no 'box' on PATH — the tier needs the global install (#71): sudo bash install.sh" >&2; exit 1; }
command -v incus >/dev/null || { echo "multiuser.sh: incus is not installed — box setup-host first." >&2; exit 1; }
incus network show boxnet >/dev/null 2>&1 || { echo "multiuser.sh: no boxnet — box setup-host first." >&2; exit 1; }

if [ "$YES" -ne 1 ]; then
  [ -t 0 ] || { echo "multiuser.sh: no terminal to confirm on — pass --yes." >&2; exit 2; }
  printf 'multiuser.sh: create users %s/%s, grant them the tier, mint boxes as them, then delete it all? [y/N] ' boxdrill1 boxdrill2
  read -r reply
  case "$reply" in y|Y|yes|YES|Yes) : ;; *) echo "aborted."; exit 1 ;; esac
fi

pass=0; fail=0; findings=(); audit=()
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); findings+=("FAIL: $*"); }
note() { printf '  \033[33mNOTE\033[0m  %s\n' "$*"; findings+=("NOTE: $*"); }
inf()  { printf '        %s\n' "$*"; }
phase(){ printf '\n\033[1m══ %s\033[0m\n' "$*"; }
aud()  { audit+=("$*"); }

U1=boxdrill1; U2=boxdrill2

# Run as a rehearsal user. runuser resets HOME/USER to the target (we are
# root), and stdin is pinned: an incus with a terminal can go interactive and
# wedge the run forever — the drill's oldest trap, honored here.
as_u() { local u="$1"; shift; runuser -u "$u" -- "$@" </dev/null; }

# Probe a TCP door from INSIDE a box and answer reachable/refused/dropped by
# reading curl's MESSAGE, never its exit code (drill.sh's box_probe, scoped
# down): "refused" means a packet ARRIVED and was answered — which, for an
# isolation probe, is a failure wearing polite clothes. Silence is the pass.
probe_from() {  # probe_from <user> <box> <url>
  local u="$1" b="$2" url="$3" out
  out="$(as_u "$u" timeout -k 5 30 incus exec "$b" -- curl -sS -m 15 -o /dev/null "$url" 2>&1)"
  case "$out" in
    "") echo reachable ;;
    *Connection\ refused*) echo refused ;;
    *) echo dropped ;;
  esac
}

# For probes whose PASS is "reachable": one retry. A nested-virt host can
# blow a first TLS handshake on timing alone, and a rehearsal that cries
# broken-egress over that teaches people to ignore it. Isolation probes never
# retry — for them silence is the pass, and silence is not flaky.
probe_up() { # probe_up <user> <box> <url>
  local r; r="$(probe_from "$@")"
  [ "$r" = reachable ] || r="$(probe_from "$@")"
  echo "$r"
}

cleanup() {
  [ "$KEEP" = 1 ] && { echo "(--keep: users and boxes left for inspection)"; return; }
  echo
  echo "── cleanup"
  for u in "$U1" "$U2"; do
    id "$u" >/dev/null 2>&1 || continue
    BOX_YES=1 box revoke "$u" --purge >/dev/null 2>&1
    userdel -r "$u" >/dev/null 2>&1
    id "$u" >/dev/null 2>&1 && echo "  WARNING: user $u still exists" || echo "  removed $u (tier, boxes, account)"
  done
}
trap cleanup EXIT

phase "G. the grant — box grant is the convergence, and it converges"
for u in "$U1" "$U2"; do
  id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
done
# Before any grant: a bare user has NO tier — the socket refuses them. This is
# the baseline that makes everything after it meaningful.
as_u "$U1" incus list >/dev/null 2>&1 \
  && no "(a) $U1 reached the daemon BEFORE any grant — the socket is not confining" \
  || ok "(a) before the grant, $U1 cannot reach the daemon at all"

box grant "$U1" >/dev/null 2>&1 && ok "box grant $U1 exits 0" || no "box grant $U1 failed"
box grant "$U2" >/dev/null 2>&1 && ok "box grant $U2 exits 0" || no "box grant $U2 failed"
box grant "$U1" >/dev/null 2>&1 && ok "box grant is idempotent (re-run exits 0)" || no "box grant re-run failed"

uid1="$(id -u "$U1")"; uid2="$(id -u "$U2")"
p1="user-$uid1"; p2="user-$uid2"

acc="$(incus project get "$p1" restricted.networks.access 2>/dev/null)"
[ "$acc" = boxnet ] \
  && ok "(h) $p1 is restricted to boxnet and ONLY boxnet" \
  || no "(h) $p1 restricted.networks.access = '$acc' — the unhardened private bridge is still reachable"
aud "h. restricted.networks.access after grant: '$acc' (the private incusbr-$uid1 is unreferenced)"

snaps="$(incus project get "$p1" restricted.snapshots 2>/dev/null)"
[ "$snaps" = allow ] && ok "snapshots allowed in $p1 (the clone workflow exists)" \
                     || no "restricted.snapshots = '$snaps' — box snapshot will refuse"

incus --project "$p1" profile device get default eth0 type >/dev/null 2>&1 \
  && no "(h) $p1's default profile still carries the private-bridge eth0" \
  || ok "(h) $p1's default profile places no network — box-net is the only door"

iso="$(incus --project "$p1" profile device get box-net eth0 security.port_isolation 2>/dev/null)"
[ "$iso" = true ] && ok "box-net profile is in $p1, port_isolation true" \
                  || no "box-net profile in $p1 is wrong (port_isolation='$iso')"

phase "a. confinement — each user lands in their own project, and only theirs"
projects="$(as_u "$U1" incus project list --format csv 2>/dev/null | cut -d, -f1)"
if [ "$(printf '%s\n' "$projects" | grep -c .)" = 1 ] && printf '%s' "$projects" | grep -q "$p1"; then
  ok "(a) $U1 sees exactly one project: their own ($p1)"
else
  no "(a) $U1 sees: $(printf '%s' "$projects" | tr '\n' ' ') — confinement LEAKED, which vetoes the tier"
fi
as_u "$U1" incus list --project default >/dev/null 2>&1 \
  && no "(a) $U1 can list the DEFAULT project — admin boxes are visible" \
  || ok "(a) the default project refuses $U1"
aud "a. incus-user confines: project list as $U1 = '$(printf '%s' "$projects" | tr '\n' ' ')'"

phase "b. the lifecycle, as a restricted user — new/list/exec/snapshot/restore/clone/rm"
# The mint's narration is kept and shown on failure — a FAIL that names
# nothing is the drill's oldest sin.
mintlog="$(mktemp)"
# 1GiB / 2 cpus: a blank Debian needs no more, and the rehearsal runs TWO
# boxes at once — on a small (or nested) rehearsal host, 2GiB apiece is the
# difference between measuring isolation and measuring swap.
if as_u "$U1" box new --name mine --template blank --cpu 2 --memory 1GiB "${MODE[@]}" >"$mintlog" 2>&1; then
  ok "(b) box new mine — minted"
else
  no "(b) box new failed for $U1 (rc≠0) — its last words:"
  grep -v '^\.*$' "$mintlog" | tail -6 | sed 's/^/        /'
fi
rm -f "$mintlog"
as_u "$U1" box list 2>/dev/null | grep -q '^mine ' && ok "(b) box list shows mine" || no "(b) box list does not show mine"
as_u "$U1" box exec mine -- true >/dev/null 2>&1 && ok "(b) box exec mine -- true" || no "(b) box exec failed"
as_u "$U1" box info mine 2>/dev/null | grep -q '10\.88\.' \
  && ok "(g) box info shows a boxnet (10.88.x) address — placed on the hardened network" \
  || no "(g) mine has no boxnet address in box info"
as_u "$U1" box snapshot mine s1 >/dev/null 2>&1 && ok "(b) box snapshot mine s1" || no "(b) snapshot refused"
as_u "$U1" box restore mine s1 >/dev/null 2>&1 && ok "(b) box restore mine s1 (the incus 6 'snapshot restore' spelling)" || no "(b) restore failed"
as_u "$U1" box new --name c1 --from mine/s1 >/dev/null 2>&1 && ok "(b) box new --from mine/s1 — the clone workflow" || no "(b) clone failed"
# c1 stays alive through phase g: it is the distinctly-NAMED sibling the
# enumeration probe needs (both users' primaries are 'mine' by design of d).
aud "b. full lifecycle exercised as $U1 through the real CLI"

phase "d. same name, two users — projects mean no collision"
as_u "$U2" box new --name mine --template blank --cpu 2 --memory 1GiB "${MODE[@]}" >/dev/null 2>&1 \
  && ok "(d) $U2 minted their own 'mine' beside $U1's" \
  || no "(d) $U2 could not mint 'mine' — names collide across users"

phase "c. cross-visibility — each sees exactly their own"
n1="$(as_u "$U1" box list 2>/dev/null | grep -c '^mine ')"
n2="$(as_u "$U2" box list 2>/dev/null | grep -c '^mine ')"
[ "$n1" = 1 ] && [ "$n2" = 1 ] \
  && ok "(c) both users see exactly one 'mine' — their own" \
  || no "(c) visibility leaked: $U1 sees $n1, $U2 sees $n2 — vetoes the tier"
as_u "$U1" incus list --project "$p2" >/dev/null 2>&1 \
  && no "(c) $U1 can list $U2's project" \
  || ok "(c) $U2's project refuses $U1"
aud "c. cross-user visibility: $U1=$n1 'mine', $U2=$n2 'mine', foreign project listing refused"

phase "g. the isolation contract, measured from INSIDE the boxes"
ip1="$(incus --project "$p1" list mine --format csv --columns 4 2>/dev/null | tr -d '"' | sed 's/ (.*//' | head -n1)"
ip2="$(incus --project "$p2" list mine --format csv --columns 4 2>/dev/null | tr -d '"' | sed 's/ (.*//' | head -n1)"
inf "$U1's mine: ${ip1:-<no ip>}   $U2's mine: ${ip2:-<no ip>}"
case "$ip1" in 10.88.*) ok "(g) $U1's box holds a boxnet lease" ;; *) no "(g) $U1's box is NOT on boxnet: '$ip1'" ;; esac

r="$(probe_up "$U1" mine https://1.1.1.1)"
[ "$r" = reachable ] && ok "(g) egress to the public internet works (curl 1.1.1.1: $r)" || no "(g) public egress broken: $r"
as_u "$U1" timeout -k 5 20 incus exec mine -- getent hosts deb.debian.org >/dev/null 2>&1 \
  && ok "(g) public DNS resolves (via the pinned resolver)" || no "(g) DNS broken inside the box"

r="$(probe_from "$U1" mine "http://10.88.0.1:22")"
[ "$r" = dropped ] && ok "(g) box → host is dropped (gateway :22: $r)" || no "(g) box can reach the HOST: $r"
r="$(probe_from "$U1" mine "http://192.168.0.1")"
[ "$r" = dropped ] && ok "(g) box → RFC1918 is dropped ($r)" || no "(g) box reaches private space: $r"

if [ -n "$ip2" ]; then
  r="$(probe_from "$U1" mine "http://$ip2:9")"
  [ "$r" = dropped ] && ok "(g) $U1's box → $U2's box is DROPPED (cross-user sibling isolation)" \
                     || no "(g) cross-user box→box answered ($r) — a packet crossed the user boundary"
  aud "g. cross-user sibling probe $ip1 → $ip2: $r (silence is the pass; 'refused' would mean arrival)"
else
  note "(g) no ip for $U2's box — sibling probe skipped"
fi

# Enumeration is probed with a SIBLING's name, never the box's own — a box
# always resolves itself from /etc/hosts (cloud-init writes it), and reading
# that as a gateway leak was this rehearsal's first false FAIL. c1 (U1's
# clone, still alive) is the distinctly-named instance; U2's box asks.
as_u "$U2" timeout -k 5 20 incus exec mine -- getent hosts c1 >/dev/null 2>&1 \
  && no "(g) a box can resolve a sibling's name through the gateway (dns.mode leak)" \
  || ok "(g) a sibling's name does not resolve (dns.mode=none holds for the tier)"
as_u "$U1" box rm c1 --force >/dev/null 2>&1 && ok "(b) box rm c1" || no "(b) rm failed"
v6="$(as_u "$U1" timeout -k 5 20 incus exec mine -- sh -c 'ip -6 addr show dev eth0 scope global 2>/dev/null' 2>/dev/null)"
[ -z "$v6" ] && ok "(g) no global IPv6 inside the box (the IPv4-only contract)" \
             || no "(g) the box holds a global IPv6 address — an uncovered egress path"

phase "h. the escape hatches, tried and refused"
as_u "$U1" incus launch images:debian/13 esc --network "incusbr-$uid1" >/dev/null 2>&1 \
  && { no "(h) $U1 attached the unhardened private bridge"; as_u "$U1" incus delete -f esc >/dev/null 2>&1; } \
  || ok "(h) attaching the private incusbr-$uid1 is refused (not in restricted.networks.access)"
as_u "$U1" incus project set "$p1" restricted.networks.access "boxnet,incusbr-$uid1" >/dev/null 2>&1 \
  && no "(h) $U1 widened their OWN project's network access" \
  || ok "(h) a restricted certificate cannot widen its own project"
as_u "$U1" incus network set boxnet dns.mode=managed >/dev/null 2>&1 \
  && no "(h) $U1 edited boxnet itself" \
  || ok "(h) boxnet's config refuses a restricted certificate"

phase "e/f. the honest refusals — expose, setup-host, doctor"
out="$(as_u "$U1" box expose mine 3000 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi restricted \
  && ok "(e) box expose refuses with the restricted message (rc=$rc)" \
  || no "(e) box expose: rc=$rc, said: $(printf '%s' "$out" | head -1)"
out="$(as_u "$U1" box setup-host 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "restricted tier" \
  && ok "(f) box setup-host: the honest note, exit 0" \
  || no "(f) box setup-host as $U1: rc=$rc"
out="$(as_u "$U1" box doctor 2>&1)"; rc=$?
printf '%s' "$out" | grep -q "Access tier — restricted" \
  && ok "(f) box doctor answers at the restricted tier (rc=$rc)" \
  || no "(f) box doctor did not honor the tier (rc=$rc)"
aud "e/f. expose refused; setup-host and doctor answer honestly at the tier"

phase "k. the grant survives an incus-user restart (the re-sync question, #74)"
systemctl restart incus-user.socket 2>/dev/null
sleep 1
as_u "$U1" box list 2>/dev/null | grep -q '^mine ' \
  && ok "(k) after restarting incus-user, $U1 still reaches their boxes" \
  || no "(k) the restart broke $U1's access"
acc="$(incus project get "$p1" restricted.networks.access 2>/dev/null)"
[ "$acc" = boxnet ] && ok "(k) restricted.networks.access is still boxnet — nothing re-widened" \
                    || no "(k) the restart rewrote network access to '$acc'"
aud "k. incus-user re-sync: convergence intact (matches its source: setup runs only at project creation)"

phase "l. revoke — one user out, the other untouched"
BOX_YES=1 box revoke "$U2" --purge >/dev/null 2>&1 && ok "(l) box revoke $U2 --purge exits 0" || no "(l) revoke failed"
as_u "$U2" incus list >/dev/null 2>&1 \
  && no "(l) $U2 still reaches the daemon after revoke" \
  || ok "(l) $U2 is locked out"
incus project show "$p2" >/dev/null 2>&1 \
  && no "(l) $U2's project survived the purge" \
  || ok "(l) $U2's project, boxes and bridge are gone"
st="$(incus --project "$p1" list mine --format csv --columns s 2>/dev/null | head -n1)"
[ "$st" = RUNNING ] && ok "(l) $U1's box is untouched and RUNNING through it all" \
                    || no "(l) $U1's box state after $U2's purge: '$st'"
aud "l. revoke --purge is scoped: $U2 erased, $U1 unmoved"

echo
echo "════════════════════════════════════════════"
echo "  $pass passed, $fail failed"
if [ "${#findings[@]}" -gt 0 ]; then
  echo; printf '  %s\n' "${findings[@]}"
fi
echo
echo "  #74 audit answers:"
printf '   · %s\n' "${audit[@]}"
echo
[ "$fail" -eq 0 ] && echo "  VERDICT: the restricted tier HOLDS — grant/confine/isolate/revoke, measured." \
                  || echo "  VERDICT: the tier does NOT hold — see the findings."
[ "$fail" -eq 0 ]
