# Drill run log

What the drill has actually found, what has broken *in the drill itself*, and
how to diagnose the next stall without starting from zero. Append a section per
run; keep the traps table current — it is the part that saves time.

The audit this fed, [#15](https://github.com/heavy-duty/claudebox/issues/15), is
**complete** (run 10, 48/49).

## The audit's answer

| Probe | Answer |
| --- | --- |
| A1/A5 egress + gateway DNS | PASS |
| A2 box → host | dropped |
| A2 box → RFC1918 | dropped |
| **A3 sibling isolation** | 🔴 **FAIL — tcp REFUSED, i.e. the packet ARRIVED.** Boxes reach each other. #12's central claim was wrong; **#16 is a fix, not a formalization** |
| A4 DNS enumeration | LEAKS — a box resolves its sibling by name and address |
| A6 IPv6 off | `none` ✓ |
| A7 inbound host → box | dropped |
| B1 `@internal` on a bridge ACL | REJECTED — `Unsupported nftables subject` ⇒ #16 derives the subnet |
| B2 `incus copy` preserves `user.*` | YES ⇒ #17's metadata design holds |
| B3 `dns.mode=none` | VIABLE — closes the leak, egress survives, no outage window |
| B4 `config get` unset key | empty + exit 0 ⇒ #17 must use `${var:-}` |
| B5 L2 filtering | 🔴 `ipv4_filtering` **BREAKS the box** — design veto (measured on a healthy baseline) |

**The headline:** the tool's contract — *"a box reaches the public internet and
nothing else"* — is **false today**. It also reaches every other box on the host.

## Findings in claudebox (not in the drill)

| Finding | Status |
| --- | --- |
| `setup-host.sh` called `nft` but a stock Debian 13 cloud image ships neither nftables nor UFW — host setup died on a fresh cloud host | **fixed** (setup-host installs it) |
| `claudebox exec box -- claude …` — the help's own example — failed: the binary is in `~/.local/bin`, but cloud-init exported PATH only in `.bashrc`/`.zshrc`, which the non-interactive shell behind `exec` never reads (login shell is zsh, so even `sudo -i` misses both) | **fixed** (symlink into `/usr/local/bin`) |
| Cold mint takes **~95s**, not the ~10 min the docs claim — consistently. Either the host is fast, or `cloud-init status --wait` returns before `runcmd` finishes (which would hand over boxes whose installs are still running) | **open** — worth its own issue if run 6 shows cloud-init mid-flight |

## Traps this script has already fallen into

Read this before adding a probe. Every one of these cost a run.

1. **`set -o pipefail` breaks refusal checks.** Half the drill is
   `claudebox <refusal> 2>&1 | grep -q 'text'`. The refusal exits 1/2 *by
   design*, and `grep -q` SIGPIPEs the left side when it matches early. Under
   pipefail both become false FAILs. The pipeline's verdict must be grep's
   alone — hence `set -u` and no pipefail.
2. **`$( )` waits for stdout to CLOSE, not for the command to exit.** A
   grandchild inheriting an `incus exec` session's stdout holds the
   substitution open forever, and `timeout` does *not* save you: it kills the
   wrapper, not the process holding the pipe. Use `in_box`/`box_curl`, which
   talk to `incus exec` directly, pin stdin to `/dev/null`, and land output in
   a file rather than a pipe.
3. **Never start a background process inside a box.** Same mechanism as (2),
   and it is why the drill now runs **no listener anywhere**. It does not need
   one: `curl` exit `7` (refused) means the packet *arrived*, `28` (timeout)
   means it was *dropped*. A closed port answers the question.
4. **The box's address is hard to read, and every way of getting it wrong was
   tried.** (a) `incus list` name filters are **not regexes** — `incus list
   "^peer$"` silently matches nothing. (b) Its CSV quotes a multi-address box
   across lines. (c) **The interface is not `eth0`.** The *profile* names the
   device `eth0`, but inside a **VM guest** predictable naming renames it
   **`enp5s0`** — so `ip addr show dev eth0` finds nothing either. That is the
   real reason A3 went unprobed for six runs, through two "fixes" of mine that
   never questioned the interface name. Read it from inside the box and select
   by **subnet** (`10.87.x`), not by interface name: docker0 (`172.17.x`) is
   the decoy, and the NIC's name is the guest's business.
   *Lesson: when the same probe fails three different ways, stop patching the
   probe and go look at the thing itself.*
5. **`incus delete -f a b c` aborts at the first MISSING name.** One interrupted
   run then poisons the next: stale boxes survive cleanup and cascade into
   half a dozen unrelated FAILs. Delete one name at a time.
6. **`apt-get -qq … >/dev/null` hides both a sudo prompt and the apt lock.**
   `apt-daily`/`unattended-upgrades` hold the lock on a cloud image and apt
   waits in complete silence. Pre-authorize sudo, set `DPkg::Lock::Timeout`,
   and narrate.
7. **`claudebox exec` is `sudo -u claude -i`** — a *login zsh* with oh-my-zsh.
   Fine for a human, needless machinery for a probe, and one more thing that
   can hold an fd. Probes use `incus exec` directly.
8. **Clean before you set up, not after.** `setup-host.sh` reconfigures the
   network's ACLs, and a previous run's boxes are still *attached* to that
   network — `incus network set` then has to push the change onto every live
   NIC. An aborted run also leaves the D-phase mutations (`dns.mode=none`, NIC
   filtering) in place, so setup converges against a moving target. Delete the
   boxes and revert the mutations **first**.

9. **Never render a verdict on a broken baseline.** Run 7's box had no network
   (a clone/source IP collision), and phase D dutifully reported *"L2 filtering
   BREAKS the box — design veto"*. It did not; the box was already broken. A
   measurement taken on a broken instrument is not evidence, and #16 would have
   been redesigned around a fiction. Phase D is now gated on baseline egress
   passing, and refuses to judge otherwise. This is the same failure as the B3
   flip, in a different costume: **check that the thing you are measuring with
   still works before you trust what it tells you.**

10. **The drill mutates the host, and those mutations outlive an aborted run.**
    Phase D sets `dns.mode=none` and NIC filtering. If the run dies before
    reverting them, **every box minted afterwards has no DNS** — cloud-init
    fails with `Temporary failure resolving deb.debian.org` — and the next run
    reports that breakage as a *finding*. This is the worst failure mode in the
    whole list: a poisoned host does not fail honestly, it produces confident
    wrong answers. Hence the `trap`-armed revert, the verified (not
    `/dev/null`-ed) unset, the refusal to start on a dirty host, and
    `doctor.sh`.

11. **A network Incus calls `Created` may have nothing serving it.** After an
    unclean daemon death (a wedge, a SIGKILL, an OOM), Incus can come back
    without respawning a network's **dnsmasq**. The bridge is up, `incus
    network show` is perfect, `status: Created` — and no DHCP server exists, so
    every box minted afterwards gets **no lease, no gateway, no DNS**, and dies
    deep in cloud-init blaming Debian's mirrors. Incus's own status does not
    cover this; the process table does. `doctor.sh` now checks it, because two
    cold mints and an hour went into learning it the other way.

12. **A `curl` exit code cannot tell you whether the packet arrived.** Exit 7 is
    "failed to connect", and it means *both* `Connection refused` (a RST came
    back — **reachable**) and `Could not connect` / `No route to host` (nothing
    came back — **isolated**). Opposite conclusions, one number. The drill
    mapped 7 → "it arrived" and reported a **working** boundary as a broken one
    for two full runs after the fix had landed, while the kernel had `isolated
    on` on the bridge ports the whole time. **Read the message.** A refusal is
    instant; an unreachable host burns the timeout. This is the same disease as
    every other trap here — trusting a proxy for the fact instead of the fact.

## Diagnosing a stall

**Start here: `bash drill/doctor.sh`** — it answers "what state is this host
actually in?" (network, profile, ACL, leftover boxes, and whether a box can
still resolve DNS), and `--fix` reverts what the drill left behind.

If the drill goes quiet mid-run, open a second terminal:

```sh
# what is actually running / blocked?
ps -eo pid,etimes,stat,args | grep -Ev grep | grep -E 'apt|dpkg|incus|setup-host|sudo|curl'

# apt lock held by a background upgrade? (the classic silent stall)
sudo fuser -v /var/lib/dpkg/lock-frontend
systemctl status unattended-upgrades apt-daily.service

# incus itself wedged?
incus list
journalctl -u incus --no-pager -n 30
```

## Running one probe by hand

Nothing in the audit requires the whole drill. To answer **A3** on a host that
already has two boxes up (`archive` and `peer`):

```sh
PEER_IP=$(timeout 20 incus exec peer -- ip -4 -o addr show dev eth0 \
          | awk '{split($4,a,"/"); print a[1]}')
timeout 30 incus exec archive -- curl -sS -m 5 -o /dev/null "http://$PEER_IP:8088"
echo "curl exit: $?"    # 28 = dropped (isolated) · 7 = refused (it ARRIVED) · 0 = connected
timeout 30 incus exec archive -- ping -c1 -W2 "$PEER_IP"
echo "ping exit: $?"    # 0 = ICMP replies — isolation is partial at best
```

No listener is needed, and none should be started: see trap 3.

## Run history

| Run | Result | What it cost |
| --- | --- | --- |
| 1 | hung at C7; ~9 false FAILs | traps 1, 2, 4 — pipefail, the exec-pty hang, the DHCP race |
| 2 | 42/49 | trap 5 — an interrupted run 1 left boxes behind, cascading 5 FAILs. Found the `claude`-on-PATH bug. Phase D delivered B1 (`@internal` rejected) and a B3 reading of *broken* |
| 3 | 48/49 | trap 4 — `eth0_ip` never matched, so A3 again unprobed. B3 now read *intact*, contradicting run 2 |
| 4 | hung at C4 | trap 2 again, this time via `claudebox exec` in a command substitution |
| 5 | stalled in host setup | trap 6 — silence through apt/sudo |
| 6 | stalled in `setup-host.sh` | trap 8 — cleanup ran *after* setup. Recovering the host exposed **two real claudebox bugs**: `setup-host` deadlocks the incus daemon when re-run with boxes up (#26), and clones inherit their source's machine-id → same DHCP lease → **two boxes, one IP** (#27) |
| **10** | **48/49 — the audit is complete** | 🔴 **A3 answered: sibling isolation DOES NOT HOLD** (tcp refused = the packet arrived). B5's `ipv4_filtering` veto confirmed on a *healthy* baseline. B3 cleared. Every #15 probe answered |
| 9 | aborted: cold mint failed, twice | **not** the drill and **not** the host's mutations (doctor was green): `claudenet` had **no dnsmasq** — it never respawned after the SIGKILL in run 6's recovery. Boxes got no DHCP lease at all. Trap 11 |
| 8 | aborted: cold mint failed | `cloud-init status: error` — **the box had no DNS at all**. Run 7's phase-D `dns.mode=none` survived the run and poisoned the host. Trap 10, and the reason `doctor.sh` exists |
| 7 | 41/49 | the clone-identity fix could not reboot (systemd needs a valid machine-id to shut down cleanly), so it never took effect → the IP collision persisted → the box lost networking → **phase D reported a false design veto against #16**. Trap 9. Also found: `dir` storage makes every clone a full disk copy (#29) |

**The instrument was less reliable than the thing it measured.** Of ten runs,
four died on drill plumbing and three on bugs in claudebox or the host. It still
paid for itself many times over — every one of those seven failures was a real
defect, and the audit's headline finding overturned the premise it was written
to confirm. But the lesson stands: **if a probe can be answered by hand, answer
it by hand** rather than paying for another full run.

### The B3 flip — a lesson worth keeping

Run 2 said `dns.mode=none` **broke** egress; run 3 said it was **intact**. Both
probed ~2s after setting the key, and setting `dns.mode` restarts the network's
dnsmasq — so run 2 caught the restart window and run 3 missed it. A design veto
was posted to #16 on the strength of run 2, then retracted.

**A verdict drawn from one observation of a system with restart semantics is not
a verdict.** The probe now distinguishes *transient* (recovers within 30s) from
*broken* (does not), and any test #16 ships must tolerate that window rather
than race it.
