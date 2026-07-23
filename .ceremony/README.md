# .ceremony/ — the vendored doctrine mirror

Machine-managed by heavy-duty/ceremony's `actions/docs-sync`. Never edit
these files here: they are byte-identical copies of
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony) at this
repository's pinned ref, and CI re-diffs them on every PR — a hand edit
goes red. They are changed in heavy-duty/ceremony, through its own flow,
and arrive here when the pin moves.

The pin lives in `.github/workflows/release.yml` — the single
`uses: heavy-duty/ceremony/.github/workflows/release.yml@<ref>` line. One
pin governs machinery and doctrine alike: bump it and re-sync this mirror
in the same PR (`docs-sync --fix`, or let the red check on the bump PR say
what is stale).
