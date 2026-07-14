# The drill

An end-to-end rehearsal of claudebox against a **real** Incus: install the CLI,
set up the host, mint boxes, drive the whole surface, check that the isolation
actually holds — and run the full
[#15 audit](https://github.com/heavy-duty/claudebox/issues/15), including a live
rehearsal of the hardening
[#16](https://github.com/heavy-duty/claudebox/issues/16) proposes. It ends with
a block of audit answers to paste into #15.

> ⚠ **It rearranges the host it runs on.** Incus, a systemd unit, a network, an
> ACL, a profile, rewritten firewall rules — and, in the last phase, deliberate
> mutations to the network and profile. **Run it on a machine you can format** —
> a spare server, a cloud VM you'll destroy, a VM on your laptop.
> Not your workstation.

```sh
git clone https://github.com/heavy-duty/claudebox && cd claudebox
bash drill/drill.sh --yes      # run and forget; omit --yes to be asked first
```

Useful flags: `--ref <branch>` (drill a branch rather than `main`),
`--keep-boxes` (leave the boxes up to poke at — note the last phase's network
and profile mutations stay applied with them).

Exit 0 means every check passed. Roughly 20 minutes, most of it the cold box.

**Something wrong with the host?** `bash drill/doctor.sh` — it reports whether
the host is fit to drill (network, profile, ACL, leftover boxes, whether a box
can still resolve DNS), and `--fix` reverts what an aborted run left behind.
The drill mutates the host in phase D; an aborted run can leave a network that
mints boxes with **no DNS**.

**Iterating on the drill?** Read [RUNS.md](RUNS.md) first — it is the run log:
what the audit has answered so far, the bugs the drill has found in claudebox,
the traps this script has already fallen into (every one cost a run), how to
diagnose a stall, and how to run a single probe by hand instead of paying for a
whole run.

## Why it exists

The repo has no tests and no CI, and the CLI is a shell script that shells out to
`incus`. That means the interesting failures are not in the bash — they are in
what Incus actually does, which is exactly what unit tests would stub out and get
wrong. The drill runs the real thing.

## What it checks

**A. Incus semantics.** The assumptions claudebox is built on, probed directly:
that `incus config get <inst> user.claudebox` returns `1` (this is on the path of
*every* box command — if it lies, everything fails closed); that the
`user.claudebox=1` list filter selects our instances and excludes an untagged
one; that `--columns nstS` gives four clean CSV fields; that the state column
reads `RUNNING`; that `incus rename` really does refuse a running instance; that
snapshot-list's first CSV field is the label; that an **unset** config key reads
as empty with exit 0 (#15 B4); and that `incus copy` **preserves `user.*` keys**
(#15 B2 — the whole template-metadata design in #17 rests on it).

**B. The surface.** Mint, list, info, snapshot, clone-from-a-snapshot-of-a-
renamed-box, rename (running must refuse, stopped must work), the escape hatch
and its isolation warning, the `rm` confirmation guard, and the CLI contract
(typo'd command, typo'd flag, `list <box>`).

**The boundary** gets its own treatment: the drill launches an instance
claudebox did *not* mint, aims `down`, `rm` and the escape hatch at it, and
requires all three to refuse — and the instance to still be standing afterwards.

**C. Isolation baseline (#15 section A).** From inside a real box: public egress
works; the box cannot reach a listener on the host's claudenet gateway; RFC1918
is dropped; a **sibling box is unreachable** (a listener runs on the peer so
"refused" — the packet arrived — cannot masquerade as "dropped"); whether DNS
**enumerates** the sibling is recorded (#12 predicts it leaks today; that is
audit data, not a failure); IPv6 is off; and the host cannot connect **into**
a box.

**D. Hardening rehearsal (#15 section B).** The host is disposable, so the drill
applies the exact changes #16 proposes and watches what breaks: `dns.mode=none`
(must kill sibling resolution, must not kill egress), `security.mac_filtering` +
`security.ipv4_filtering` on the NIC (the box and its in-box Docker must keep
working), and `@internal` as an ACL drop destination on a bridge network (if
accepted and egress survives, #16's sibling drop is renumber-proof by
construction; if not, #16 derives the subnet instead). A FAIL in this phase is
a **design veto** for #16, caught before the code is written.

## What it does not check

`claude /login` — it's interactive by design, and the box is creds-free by
design. The drill confirms Claude Code is installed and runnable; authenticating
is yours.

If the host has no `/dev/kvm`, claudebox falls back to container mode. The drill
still runs, but it says loudly that **the VM trust boundary was not validated**
rather than passing quietly on a weaker one.
