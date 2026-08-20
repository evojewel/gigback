# gigback

**Get your gigabytes back. Only deletes what grows back.**

A storage cleaner for developer Macs. Born from a real cleanup that took one machine from
10 GB free to 150+ GB free — old iOS simulator runtimes, forgotten build caches, stale
`node_modules` — without losing a single file of real work.

```
$ gigback scan
gigback scan — free space on /: 12.4 GB

SAFE (regenerates automatically — 'gigback clean --apply'):
  3.1 GB     derived-data   Xcode DerivedData (build caches)
  7.8 GB     user-caches    User app caches
  4.8 GB     npm-cache      npm cache
  ?          sim-runtimes   Old iOS simulator runtimes: iOS-18.4 iOS-26.4
  ...
```

## Install

```bash
brew tap evojewel/tap
brew trust evojewel/tap   # newer Homebrew requires trusting third-party taps
brew install gigback
```

## Usage

```bash
gigback scan            # read-only report of everything, always safe
gigback clean           # dry-run plan — shows what WOULD be deleted, and how it regenerates
gigback clean --apply   # execute the SAFE plan (one y/N confirm)
gigback clean --check   # also offer CHECK items, each confirmed one by one
gigback report          # DATA tier: databases & editor state — sized, never deleted
gigback log             # what past runs deleted, when, how much
```

Flags: `--projects-dir <path>` (default `~/Projects`) · `--stale-days <n>` (default 90) ·
`--keep-runtime <ver>` (repeatable) · `--yes` (SAFE tier only) · `--json`

## The safety model

Every path gigback can touch lives in one reviewed table
([lib/targets.sh](lib/targets.sh)), sorted into three tiers:

| Tier | What | Behavior |
|---|---|---|
| **SAFE** | Xcode DerivedData, app caches, npm/Gradle caches, orphaned simulator devices, superseded simulator runtimes | Deletable via `clean --apply`. Regenerates automatically. |
| **CHECK** | `node_modules` in repos with no commits for 90+ days, Xcode archives, `~/.cache` entries | Regenerable, but context-dependent — each item is confirmed individually. Model caches are flagged (slow to re-download). |
| **DATA** | Local Postgres/MySQL data dirs, editor state (VS Code / Cursor `globalStorage` holds your AI chat history), Application Support | **Report only. There is no code path in gigback that deletes these.** |

Plus:

- **Dry-run is the default.** `clean` prints the plan; only `--apply` executes.
- **Every plan line names its regeneration command** — the tool's one rule made visible:
  only delete what you can name the regeneration path for.
- **No sudo, ever.** Anything needing elevation is out of scope.
- **`df` before/after** every apply, and an append-only log at `~/.gigback/log.jsonl`.
- **No user-supplied paths.** gigback deletes only what its own table names — there is no
  `gigback delete <path>`, by design.

## Why simulator runtimes matter

The single biggest finding behind this tool: `/Library/Developer/CoreSimulator` (the
system-level one) keeps a full 8–20 GB runtime image for *every* iOS version you've ever
simulated, and Xcode updates never clean them up. Six runtimes ≈ 100+ GB. gigback keeps
the newest (plus anything you `--keep-runtime`) and deletes the rest — Xcode re-downloads
any of them on demand.

Two gotchas gigback handles for you: runtime deletion is asynchronous (free space keeps
rising for a few minutes after), and `du` double-counts runtimes because their images are
mounted as volumes — which is why gigback measures success by the `df` delta, not by
summing what it deleted.

> Not to be confused with **DevCleaner**, a GUI app focused on Xcode caches. gigback is a
> CLI, covers more than Xcode, and is built around the tier model above.

## Development

```bash
git clone https://github.com/evojewel/gigback && cd gigback
./bin/gigback scan          # runs from the checkout
shellcheck bin/gigback lib/targets.sh
bats test                   # brew install bats-core
```

Tests run entirely against fixture trees — `GB_*` environment variables point every path
at a temp dir, and `GB_NO_SIMCTL` / `GB_NO_NPM` keep the real system out of reach.

## License

MIT — see [LICENSE](LICENSE).
