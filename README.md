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

**If brew complains about Xcode / Command Line Tools** (macOS betas with lagging CLT,
or machines without CLT): gigback is plain bash and needs no compiler — install it
without brew:

```bash
git clone https://github.com/evojewel/gigback ~/.gigback-src
ln -s ~/.gigback-src/bin/gigback /opt/homebrew/bin/gigback
```

## Usage

```bash
gigback scan            # read-only report of everything, always safe
gigback clean           # dry-run plan — shows what WOULD be deleted, and how it regenerates
gigback clean --apply   # execute the SAFE plan (one y/N confirm)
gigback clean --check   # also offer CHECK items, each confirmed one by one
gigback report          # DATA tier: databases & editor state — sized, never deleted
gigback log             # what past runs deleted, when, how much
gigback history         # recent runs: free-space trend and what grew most
```

Flags: `--projects-dir <path>` (default `~/Projects`) · `--stale-days <n>` (default 90) ·
`--worktree-stale-days <n>` (default 30, linked git worktrees) ·
`--keep-runtime <ver>` (repeatable) · `--yes` (SAFE tier only) · `--json` (scan, history) ·
`--last <n>` (history, default 10) · `--no-history`

## Run history

One scan shows what is big. Only a series shows what is **growing** — which is the question
when free space keeps dropping. So every `scan`, `clean` (dry run included) and `report`
appends one line to `~/.gigback/history.jsonl`, and `gigback history` reads them back:

```
gigback history — last 2 runs (~/.gigback/history.jsonl)

WHEN (UTC)        COMMAND            FREE      SAFE     CHECK    MANUAL      DATA  TM SNAPSHOTS
2026-10-20 06:00  scan            23.0 GB    1.0 GB      0 KB      0 KB   10.0 GB  3
2026-10-20 08:00  scan            13.0 GB    1.0 GB      0 KB      0 KB   12.0 GB  9

Free space: 23.0 GB -> 13.0 GB over 2h 0m (-5.0 GB per hour)

Grew most between the first and last run shown (items both runs measured):
  +2.0 GB    DATA    app-support    ~/Library/Application Support/Cursor

Free space fell 10.0 GB; what both runs measured changed by 2.0 GB.
About 8.0 GB went somewhere gigback does not measure (Time Machine local snapshots,
system updates, other folders). Snapshots: 3 -> 9.
```

`gigback history --json` prints the same runs as a JSON array for your own analysis
(`--last <n>` picks how many). `gigback log` is unchanged: it still lists deletions only.

**What a record holds:** time (UTC and epoch), gigback version, command and mode (`dry-run`,
`apply`, `check`), disk total and free (and free at the start of the run), the number of
Time Machine local snapshots, a total per tier, and every size the run measured — tier, id,
KB and path. Paths under your home folder are stored as `~/…`. A tier the run didn't look at
is `null`, not `0` (a dry-run `clean` doesn't size CHECK), so a trend never counts a skipped
tier as an empty one. Sizes gigback can't measure (simulator targets) are `null` too.

**What it never holds:** file contents, and Postgres database names (`report` prints them,
history doesn't keep them).

**Bounded:** the newest 1000 runs are kept (a few MB at most); set
`GIGBACK_HISTORY_MAX=<n>` to change that. Older lines are trimmed from the file itself.

**Off:** `--no-history` for one run, or `GIGBACK_NO_HISTORY=1` for all of them. Delete
`~/.gigback/history.jsonl` to forget what was recorded.

History only ever appends to, trims and reads its own file — it has no delete path for
anything else, and if the file can't be written the command runs and exits exactly as it
would have. It measures nothing new either: it records what the run already measured.

## The safety model

Every path gigback can touch lives in one reviewed table
([lib/targets.sh](lib/targets.sh)), sorted into three tiers:

| Tier | What | Behavior |
|---|---|---|
| **SAFE** | Xcode DerivedData, app caches, npm/Gradle caches, orphaned simulator devices, superseded simulator runtimes | Deletable via `clean --apply`. Regenerates automatically. |
| **CHECK** | Project build artifacts — `node_modules`, Rust `target/` (next to a `Cargo.toml`), Python `venv`/`env` (holding a `pyvenv.cfg`) — in repos and in their linked git worktrees, wherever they live (e.g. `.claude/worktrees/*`) — with no commits on that checkout's own HEAD for 90+ days (repos, `--stale-days`) or 30+ days (worktrees, `--worktree-stale-days`), Xcode archives, `~/.cache` entries | Regenerable, but context-dependent — each item is confirmed individually. Worktree items show their branch and whether they have uncommitted changes. Symlinked artifacts are skipped (they free nothing). Model caches are flagged (slow to re-download). |
| **DATA** | Local Postgres/MySQL data dirs, editor state (VS Code / Cursor `globalStorage` holds your AI chat history), Application Support | **Report only. There is no code path in gigback that deletes these.** |
| **MANUAL** | Things gigback can't remove without sudo: older bundle-style simulator runtimes, and runtime images left on disk that no simulator uses | Sized and listed with how to handle them by hand (shown by `scan`, `clean` and `report`). No delete code. |

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

Runtimes come in two kinds. Disk-image runtimes show up in `xcrun simctl runtime list`
and gigback deletes old ones with `simctl runtime delete`. Older bundle-style runtimes
(e.g. an iOS 18 runtime mounted from a `SimRuntimeBundle`) show up only in
`xcrun simctl list runtimes`; `simctl runtime delete` matches only what `runtime list`
shows, so there is no sudo-free way for gigback to remove them. gigback lists them under
**MANUAL** with their real on-disk size (the backing image file, not the ~2× mounted
volume) and the newest/`--keep-runtime` rule applied across both kinds. Remove them in
Xcode → Settings → Components.

A runtime delete is checked, not assumed. `simctl runtime delete` can exit 0 and still leave
the image file in `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime`,
which macOS protects (SIP), so after each delete gigback waits up to a minute for it to
settle and reports one of: *removed, X GB freed* · *unregistered, but the X GB image was
left at <path>* · *still registered* · *simctl failed: <message>*. Each outcome goes to
`~/.gigback/log.jsonl`. Images left behind like this, known to neither `simctl` list, then
appear on the **MANUAL** list with their size; gigback has no way to remove them.

> Not to be confused with **DevCleaner**, a GUI app focused on Xcode caches. gigback is a
> CLI, covers more than Xcode, and is built around the tier model above.

## Development

```bash
git clone https://github.com/evojewel/gigback && cd gigback
./bin/gigback scan          # runs from the checkout
shellcheck bin/gigback lib/*.sh
bats test                   # brew install bats-core
```

Tests run entirely against fixture trees — `GB_*` environment variables point every path
at a temp dir, and `GB_NO_SIMCTL` / `GB_NO_NPM` / `GB_NO_TMUTIL` keep the real system out of reach.
Simulator tests use fake `xcrun` / `hdiutil` scripts (`GB_XCRUN`, `GB_HDIUTIL`, see
`use_fake_simctl` in `test/helpers.bash`) that answer from fixture state and log every call;
`$SIM_DIR/delete-mode` picks how a fake `runtime delete` behaves (removed / left / stuck / fail).

## License

MIT — see [LICENSE](LICENSE).
