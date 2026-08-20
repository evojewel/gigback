# Contributing to gigback

Thanks for helping! One rule matters more than all others here.

## The tier table is the safety surface

Every path gigback can delete is defined in [lib/targets.sh](lib/targets.sh), sorted into
SAFE / CHECK / DATA tiers. Because a bug in that table is the tool's entire risk surface:

- **Any change to the tier table requires a test** in `test/` proving the new behavior —
  including that DATA-tier paths remain untouchable.
- **Never add a delete path for a DATA-tier target** — not behind a flag, not
  "temporarily". The absence of that code is the guarantee.
- **New SAFE targets must name their regeneration command** (`safe_regen`). If you can't
  name how it grows back, it isn't SAFE.
- No `sudo`, no user-supplied deletion paths, no `eval`.

## Practical bits

- Bash 3.2-compatible (macOS default shell) — no associative arrays, no `mapfile`.
- `shellcheck bin/gigback lib/targets.sh` and `bats test` must pass (CI enforces both).
- Tests run against fixtures only: use the `GB_*` env overrides (see `test/helpers.bash`)
  and never touch the real filesystem, simulators, or npm cache.
- Conventional commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).

## Reporting issues

Include the output of `gigback scan` (redact anything private) and your macOS + Xcode
versions. If a deletion surprised you, attach the relevant lines from
`~/.gigback/log.jsonl` — that's exactly what it's for.
