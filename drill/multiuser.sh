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
#   m. a RAW attach to boxnet (no box-net profile) keeps every network- and
#      host-owned control — the scoped guarantee, measured (#75 review)
#   n. a grant that fails is fail-closed: fresh user backed out (verified),
#      pre-existing member warned loudly, re-run converges (#75 review)
#   o. an incus-admin-ONLY member is provisioned for real: the group step
#      opens incus-user's socket, the lazy project appears, and dropping
#      incus-admin lands them in it with no re-grant (#99, #101 review)
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
  local u="$1" b="$2" url="$3" out rc
  out="$(as_u "$u" timeout -k 5 30 incus exec "$b" -- curl -sS -m 15 -o /dev/null "$url" 2>&1)"; rc=$?
  # Silence + success is the only 'reachable': when the OUTER timeout kills a
  # wedged exec (the #26 shape), curl never spoke — empty output with rc 124
  # must not read as an open door.
  case "$rc:$out" in
    0:) echo reachable ;;
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

# The hardened network's gateway and prefix, read off the network — never
# hardcoded, because BOX_SUBNET moves the whole subnet now (#80).
boxnet_gw()  { incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1; }
boxnet_pfx() { local gw; gw="$(boxnet_gw)"; printf '%s.' "${gw%.*}"; }

cleanup() {
  [ "$KEEP" = 1 ] && { echo "(--keep: users and boxes left for inspection)"; return; }
  echo
  echo "── cleanup"
  for u in "$U1" "$U2" boxdrill3 boxdrill4 boxdrill5; do
    id "$u" >/dev/null 2>&1 || continue
    # A half-failed purge followed by userdel leaves a project owned by
    # nobody — and doctor's leftover check keys on the USER existing. Keep
    # the user when the purge fails, and name what survived.
    if BOX_YES=1 box revoke "$u" --purge >/dev/null 2>&1; then
      userdel -r "$u" >/dev/null 2>&1
      id "$u" >/dev/null 2>&1 && echo "  WARNING: user $u still exists" || echo "  removed $u (tier, boxes, account)"
    else
      echo "  WARNING: purge FAILED for $u — kept the account so 'box doctor' can name it; project user-$(id -u "$u") may survive"
    fi
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

# The same shape for backups (#70): export rides the backup API, which
# restricted projects block by default exactly like snapshots. A grant that
# missed this key strands every post-upgrade 'box export' at the tier.
bkups="$(incus project get "$p1" restricted.backups 2>/dev/null)"
[ "$bkups" = allow ] && ok "backups allowed in $p1 (box export works at this tier)" \
                     || no "restricted.backups = '$bkups' — box export will refuse"

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
as_u "$U1" box info mine 2>/dev/null | grep -qF "$(boxnet_pfx)" \
  && ok "(g) box info shows a boxnet ($(boxnet_pfx)x) address — placed on the hardened network" \
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
case "$ip1" in "$(boxnet_pfx)"*) ok "(g) $U1's box holds a boxnet lease" ;; *) no "(g) $U1's box is NOT on boxnet: '$ip1'" ;; esac

r="$(probe_up "$U1" mine https://1.1.1.1)"
[ "$r" = reachable ] && ok "(g) egress to the public internet works (curl 1.1.1.1: $r)" || no "(g) public egress broken: $r"
as_u "$U1" timeout -k 5 20 incus exec mine -- getent hosts deb.debian.org >/dev/null 2>&1 \
  && ok "(g) public DNS resolves (via the pinned resolver)" || no "(g) DNS broken inside the box"

r="$(probe_from "$U1" mine "http://$(boxnet_gw):22")"
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
# Each probe asserts more than a nonzero exit — an image hiccup or a name
# collision also exits nonzero, and reading that as "the escape is closed"
# is a false verdict wearing a green light (the drill has relearned this
# enough times to earn a rule). For the attach, the incus ERROR WORDING
# drifts between 6.0.x releases (6.0.4 refuses before "Launching", 6.0.0
# after — MU-4), so the assertion is the OUTCOME: nothing may end up running
# on the private bridge, and the refusal line is printed as evidence.
out="$(as_u "$U1" incus launch images:debian/13 esc --network "incusbr-$uid1" 2>&1)"; rc=$?
st="$(incus --project "$p1" list esc --format csv --columns s 2>/dev/null | head -n1)"
if [ "$rc" -eq 0 ] || [ "$st" = RUNNING ]; then
  no "(h) the private-bridge attach was NOT refused (rc=$rc, esc state: ${st:-none}):"
  printf '%s\n' "$out" | tail -3 | sed 's/^/        /'
else
  ok "(h) attaching the private incusbr-$uid1 is refused (rc=$rc, nothing running on it)"
  inf "refusal: $(printf '%s\n' "$out" | grep -m1 -i 'error' || printf '%s\n' "$out" | tail -1)"
fi
as_u "$U1" incus delete -f esc >/dev/null 2>&1
out="$(as_u "$U1" incus project set "$p1" restricted.networks.access "boxnet,incusbr-$uid1" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'restricted'; then
  ok "(h) a restricted certificate cannot widen its own project"
else
  no "(h) project-widen attempt: rc=$rc, said: $(printf '%s' "$out" | head -1)"
fi
out="$(as_u "$U1" incus network set boxnet dns.mode=managed 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiE 'permission|restricted'; then
  ok "(h) boxnet's config refuses a restricted certificate"
else
  no "(h) boxnet edit attempt: rc=$rc, said: $(printf '%s' "$out" | head -1)"
fi

phase "m. a raw attach to boxnet — the scoped guarantee, measured"
# A restricted user CAN 'incus launch --network boxnet' without the box-net
# profile: boxnet must be in restricted.networks.access for the profile to
# work at all, and Incus has no allow-via-profile-only lever. What the raw
# NIC loses is per-NIC security.port_isolation — the deliberately redundant
# L2 twin of the host-owned nft bridge drop. Everything else binds to the
# NETWORK (ACL, dns.mode=none, resolver pin) or the HOST (nft drop), so the
# contract's claim for raw attachments is "every control except the
# redundant per-NIC layer" — and a claim is a measurement here, not prose.
# Same image the blank template mints (the /cloud variant): the plain image
# has no DHCP client, so its raw instance holds NO lease — and against a
# dead NIC every negative probe below "passes" vacuously while the contract
# goes unmeasured. Caught on this criterion's first run (MU-5).
rawout="$(as_u "$U1" incus launch images:debian/13/cloud esc2 --network boxnet 2>&1)"; rawrc=$?
if [ "$rawrc" -ne 0 ]; then
  # Version fork, measured: 6.0.4 permits a restricted cert a raw --network
  # reference to an allowed network; 6.0.0 refuses it at the permission
  # layer. A refusal is not a broken probe — it is the STRONGEST of the
  # three resolutions (prevention): on such a daemon the bypass this
  # criterion measures cannot be expressed at all. Anything else (an image
  # error, a name collision) is a broken probe and says so with its log.
  if printf '%s' "$rawout" | grep -qiE 'permission|not allowed|restricted'; then
    ok "(m) raw attach to boxnet is REFUSED outright by this incus — prevention, the strongest resolution"
    inf "refusal: $(printf '%s\n' "$rawout" | grep -m1 -i 'error' || printf '%s\n' "$rawout" | tail -1)"
    aud "m. this incus version refuses raw --network for restricted certs; where permitted (6.0.4, MU-5) the raw NIC keeps every network- and host-owned control — both worlds measured"
  else
    no "(m) raw attach failed for a reason that is neither refusal nor success — unmeasured:"
    printf '%s\n' "$rawout" | tail -3 | sed 's/^/        /'
  fi
else
  ok "(m) raw attach to boxnet launches (expected: the network must be usable for the profile to work)"
  ip_raw=""
  for _ in $(seq 1 45); do
    ip_raw="$(incus --project "$p1" list esc2 --format csv --columns 4 2>/dev/null | tr -d '"' | sed 's/ (.*//' | grep . | head -n1)"
    [ -n "$ip_raw" ] && as_u "$U1" timeout -k 5 15 incus exec esc2 -- true >/dev/null 2>&1 && break
    sleep 2
  done
  inf "raw instance esc2: ${ip_raw:-<no ip>}"
  if [ -z "$ip_raw" ]; then
    # Without an address the negative probes below would all pass vacuously
    # — a dead NIC drops everything, including the truth.
    no "(m) the raw instance never got a boxnet lease — the scoped guarantee went UNMEASURED"
  else
    r="$(probe_up "$U1" esc2 https://1.1.1.1)"
    [ "$r" = reachable ] && ok "(m) raw NIC: public egress works ($r)" || no "(m) raw NIC: egress broken: $r"
    r="$(probe_from "$U1" esc2 "http://192.168.0.1")"
    [ "$r" = dropped ] && ok "(m) raw NIC: RFC1918 still dropped (the ACL binds to the network, not the profile)" \
                       || no "(m) raw NIC: reaches private space ($r) — the ACL did not cover a raw attach"
    if [ -n "$ip2" ]; then
      r="$(probe_from "$U1" esc2 "http://$ip2:9")"
      [ "$r" = dropped ] && ok "(m) raw → another user's box is DROPPED (the nft drop is host-owned)" \
                         || no "(m) raw instance reached a sibling ($r) — the host drop did not cover it"
    fi
    r="$(probe_from "$U2" mine "http://$ip_raw:9")"
    [ "$r" = dropped ] && ok "(m) another user's box → raw is DROPPED (both directions hold)" \
                       || no "(m) a sibling reached the raw instance ($r)"
    as_u "$U1" timeout -k 5 20 incus exec esc2 -- getent hosts mine >/dev/null 2>&1 \
      && no "(m) raw NIC can enumerate instance names (dns.mode leak)" \
      || ok "(m) raw NIC: name enumeration still blocked (dns.mode=none is the network's)"
  fi
  as_u "$U1" incus delete -f esc2 >/dev/null 2>&1
  aud "m. raw boxnet attach keeps ACL + nft drop + dns.mode (measured); loses only per-NIC port_isolation — the scoped guarantee in box-design.md"
fi

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
# Revocation's hard case is a user who is LOGGED IN: groups are read at
# login, so a held session keeps the socket — and after a purge it could
# touch incus-user and recreate the project with stock, unhardened defaults.
# Hold a session open across the purge and demand it dies with the tier.
runuser -u "$U2" -- sleep 300 </dev/null >/dev/null 2>&1 &
sleep 1
BOX_YES=1 box revoke "$U2" --purge >/dev/null 2>&1 && ok "(l) box revoke $U2 --purge exits 0" || no "(l) revoke failed"
pgrep -u "$U2" >/dev/null 2>&1 \
  && no "(l) $U2 still has live processes after the purge — a stale session could recreate their project, unhardened" \
  || ok "(l) the purge terminated $U2's held session (no stale-group path back in)"
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

phase "n. a grant that fails is fail-closed — injected, both flavors"
U3=boxdrill3; U4=boxdrill4
BOXROOT="$(dirname "$(dirname "$(readlink -f "$(command -v box)")")")"

# Flavor 1: a FRESH user, fault injected at the LAST mutation (the profile
# edit) — so the backout runs after every earlier mutation has landed. The
# contract: nonzero exit, the group's absence VERIFIED, and a clean re-run
# converges the partial state (which is what makes re-run-to-repair real).
useradd -m -s /bin/bash "$U3" 2>/dev/null
badroot="$(mktemp -d)"
cp -r "$BOXROOT/." "$badroot/"
echo 'devices: {' > "$badroot/profiles/box-net.yaml"   # yaml that cannot load
out="$(bash "$badroot/host/grant-user.sh" "$U3" 2>&1)"; rc=$?
rm -rf "$badroot"
if [ "$rc" -ne 0 ] && ! id -nG "$U3" | tr ' ' '\n' | grep -qx incus; then
  ok "(n) fresh-user grant failed at the last mutation → backed out, group absence verified (rc=$rc)"
else
  no "(n) injected failure: rc=$rc, in-group=$(id -nG "$U3" | tr ' ' '\n' | grep -cx incus) — not fail-closed:"
  printf '%s\n' "$out" | tail -3 | sed 's/^/        /'
fi
printf '%s' "$out" | grep -q "verified against the group database" \
  && ok "(n) the backout message claims only what it verified" \
  || no "(n) the backout message is not the verified one"
box grant "$U3" >/dev/null 2>&1 \
  && ok "(n) a clean re-run converges the partial state left by the failure" \
  || no "(n) re-run after injected failure did NOT converge"

# Flavor 2: a PRE-EXISTING member (hand-added before box, the review's named
# scenario) with an instance parked on the private bridge by an
# instance-local NIC — narrowing must fail, the grant must fail LOUDLY
# saying they retain socket access, and must NOT strip the membership this
# run did not add. Unblock, re-run, converge.
useradd -m -s /bin/bash "$U4" 2>/dev/null
usermod -aG incus "$U4"
as_u "$U4" incus project list >/dev/null 2>&1   # materialize their project
# Stage the blocker with an INSTANCE-LOCAL NIC, the shape that actually
# blocks narrowing (a profile-inherited NIC is detached by grant's own
# eth0 removal — no conflict). A raw --network flag would do it on 6.0.4
# but 6.0.0 refuses that spelling for restricted certs (see criterion m);
# 'device override' lifts their own stock profile NIC into the instance —
# their instance, their config, permitted on both — same resulting state.
stage="$(as_u "$U4" incus launch images:debian/13 blocker 2>&1)"; stagerc=$?
[ "$stagerc" -eq 0 ] && { stage="$(as_u "$U4" incus config device override blocker eth0 2>&1)"; stagerc=$?; }
if [ "$stagerc" -eq 0 ]; then
  out="$(box grant "$U4" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "still holding socket access"; then
    ok "(n) blocked narrowing fails LOUDLY, naming the retained access (rc=$rc)"
  else
    no "(n) blocked narrowing: rc=$rc — the loud contract is missing:"
    printf '%s\n' "$out" | tail -3 | sed 's/^/        /'
  fi
  id -nG "$U4" | tr ' ' '\n' | grep -qx incus \
    && ok "(n) the pre-existing membership was NOT stripped by the failed re-grant" \
    || no "(n) the failed grant stripped a membership it did not add"
  as_u "$U4" incus delete -f blocker >/dev/null 2>&1
  box grant "$U4" >/dev/null 2>&1 \
    && ok "(n) unblocked re-run converges" \
    || no "(n) re-run after unblocking failed"
else
  no "(n) could not stage the private-bridge blocker — the blocked-narrowing contract went unmeasured:"
  printf '%s\n' "$stage" | tail -3 | sed 's/^/        /'
fi
aud "n. fail-closed injections: fresh-user backout verified; pre-existing member warned, not stripped; re-runs converge"

phase "o. an incus-admin-ONLY member — #99's canonical user, on real Incus"
# The case the shim suite structurally cannot reach: the fake 'incus' in
# test/cli.sh ignores INCUS_SOCKET and file permissions, so a grant that could
# never connect() still logged a clean run there. This is the same path over
# the real daemon, where the socket is a real file with a real owning group.
#
# The blocker it exists to catch (#101 review): incus-user's socket is
# /var/lib/incus/unix.socket.user, group 'incus', mode 0660. incus-admin opens
# the ADMIN socket and not that one, so an incus-admin-only member without an
# 'incus' membership takes EACCES on grant's pinned touch — swallowed by its
# '|| true' — no project is created, and the grant dies blaming a perfectly
# healthy incus-user. Every assertion below is dead under that implementation.
U5=boxdrill5
useradd -m -s /bin/bash "$U5" 2>/dev/null
usermod -aG incus-admin "$U5"
gpasswd -d "$U5" incus >/dev/null 2>&1 || true   # stage the ONLY, exactly
uid5="$(id -u "$U5")"; p5="user-$uid5"
id -nG "$U5" | tr ' ' '\n' | grep -qx incus \
  && no "(o) $U5 is already in 'incus' — the admin-ONLY precondition is not staged, so this phase proves nothing" \
  || ok "(o) $U5 staged in 'incus-admin' only (the precondition the blocker needed)"

out="$(box grant "$U5" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "(o) box grant converges an incus-admin-only member (rc=0)"
else
  no "(o) box grant FAILED for the admin-only member (rc=$rc) — #99 is still closed:"
  printf '%s\n' "$out" | tail -4 | sed 's/^/        /'
fi
id -nG "$U5" | tr ' ' '\n' | grep -qx incus \
  && ok "(o) the grant put them in 'incus' — the group that owns unix.socket.user" \
  || no "(o) still not in 'incus': the pinned touch cannot connect() to incus-user's socket"
incus project show "$p5" >/dev/null 2>&1 \
  && ok "(o) $p5 exists — the lazy touch really reached incus-user AS them" \
  || no "(o) $p5 was never created — the touch never reached incus-user (the EACCES this phase is for)"

# The socket, directly: the connect() that used to fail, measured as them.
# Resolved by incus's own directory rule, not hardcoded.
sockdir=/var/lib/incus; [ -e /run/incus/unix.socket ] && sockdir=/run/incus
as_u "$U5" env INCUS_SOCKET="$sockdir/unix.socket.user" incus --project "$p5" profile show box-net >/dev/null 2>&1 \
  && ok "(o) they can open unix.socket.user and read $p5's box-net profile" \
  || no "(o) EACCES/unreachable on $sockdir/unix.socket.user — the #101 blocker is back"
acc5="$(incus project get "$p5" restricted.networks.access 2>/dev/null)"
[ "$acc5" = boxnet ] \
  && ok "(o) $p5 is narrowed to boxnet like any other granted project" \
  || no "(o) $p5 restricted.networks.access = '$acc5' — the admin-only grant converged half a project"

# Grant's own closing promise, measured: "gpasswd -d <user> incus-admin (no
# re-grant needed; the project is ready)". True only because they were left in
# 'incus' — under the old no-op this drop left them in NEITHER group, box_tier
# 'none', and a ready project they could not open. So drop it and look.
gpasswd -d "$U5" incus-admin >/dev/null 2>&1
projects5="$(as_u "$U5" incus project list --format csv 2>/dev/null | cut -d, -f1)"
if [ "$(printf '%s\n' "$projects5" | grep -c .)" = 1 ] && printf '%s' "$projects5" | grep -q "$p5"; then
  ok "(o) dropping incus-admin lands them in $p5 with NO re-grant — the promise holds"
else
  no "(o) after dropping incus-admin they see: '$(printf '%s' "$projects5" | tr '\n' ' ')' — grant's no-re-grant promise is false"
fi
aud "o. incus-admin-only grant: in-'incus'=$(id -nG "$U5" 2>/dev/null | tr ' ' '\n' | grep -cx incus), project '$p5' access='$acc5', post-drop projects='$(printf '%s' "$projects5" | tr '\n' ' ')'"

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
