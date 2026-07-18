# Restricted incus tier — implementation plan (issue #74)

> **Status: placeholder.** This PR is a work in progress; the design below is being
> validated by a live multi-user rehearsal before the implementation lands. Do not
> review yet — the PR stays in draft until the rehearsal passes.

## Scope

Deliver the restricted (`incus`-group) tier described in #74:

- A restricted user can `box new/list/shell/snapshot/rm` **their own** boxes.
- Their boxes ride a network carrying box's full isolation contract
  (ACL, `dns.mode=none`, resolver pin, `security.port_isolation`, nft box↔box drop).
- No cross-user visibility. Admin tier unchanged.
- The admin-side convergence is a documented, idempotent command — not manual
  per-user `incus project set`.

## Planned shape (subject to rehearsal)

- `box grant <user>` / `box revoke <user>` — admin convergence hook per #74
  option 1: widen `restricted.networks.access` to include `boxnet` and install
  the `box-net` profile into the user's `user-<uid>` project.
- CLI awareness of running inside a restricted project.
- `drill/multiuser.sh` rehearsal criteria (a)–(f) green on a real multi-user host.
- Test suite expansion + CI wiring.

Tracking issue: heavy-duty/box#74.
