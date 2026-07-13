# The drill

An end-to-end rehearsal of claudebox against a **real** Incus: install the CLI,
set up the host, mint a box, drive the whole surface, and check that the
isolation actually holds.

> ⚠ **It rearranges the host it runs on.** Incus, a systemd unit, a network, an
> ACL, a profile, and rewritten firewall rules. **Run it on a machine you can
> format** — a spare server, a cloud VM you'll destroy, a VM on your laptop.
> Not your workstation.

```sh
git clone https://github.com/heavy-duty/claudebox && cd claudebox
bash drill/drill.sh            # asks before it touches anything
```

Useful flags: `--yes` (skip the prompt), `--ref <branch>` (drill a branch rather
than the default), `--keep-boxes` (leave the boxes up to poke at).

Exit 0 means every check passed. Roughly 15 minutes, most of it the cold box.

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
reads `RUNNING`; that `incus rename` really does refuse a running instance; and
that snapshot-list's first CSV field is the label.

**B. The surface.** Mint, list, info, snapshot, clone-from-a-snapshot-of-a-
renamed-box, rename (running must refuse, stopped must work), the escape hatch
and its isolation warning, the `rm` confirmation guard, and the CLI contract
(typo'd command, typo'd flag, `list <box>`).

**The boundary** gets its own treatment: the drill launches an instance
claudebox did *not* mint, aims `down`, `rm` and the escape hatch at it, and
requires all three to refuse — and the instance to still be standing afterwards.

**C. Isolation.** From inside a real box: public egress works; the box cannot
reach a listener on the host's claudenet gateway; RFC1918 is dropped.

## What it does not check

`claude /login` — it's interactive by design, and the box is creds-free by
design. The drill confirms Claude Code is installed and runnable; authenticating
is yours.

If the host has no `/dev/kvm`, claudebox falls back to container mode. The drill
still runs, but it says loudly that **the VM trust boundary was not validated**
rather than passing quietly on a weaker one.
