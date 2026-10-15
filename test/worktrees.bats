#!/usr/bin/env bats

load helpers

setup() { setup_fixture; setup_worktree_fixture; }
teardown() { teardown_fixture; }

@test "scan finds stale node_modules in a linked worktree under .claude/worktrees" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has ".claude/worktrees/old/node_modules"
  output_has "worktree on feat/old, clean"
}

@test "staleness is judged per worktree, not by the main checkout" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "/app/node_modules"            # main checkout: fresh commit
  output_lacks "worktrees/new/node_modules"   # fresh worktree of a repo with stale ones
  run "$GIGBACK" scan --worktree-stale-days 300   # older than every worktree commit
  [ "$status" -eq 0 ]
  output_lacks "worktree on"
}

@test "worktrees outside the projects dir are found, with uncommitted changes flagged" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "elsewhere/dirty/node_modules"
  output_has "worktree on fix/dirty, uncommitted changes"
}

@test "a detached worktree says so instead of naming a branch" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "worktrees/detached/node_modules"
  output_has "worktree on detached HEAD"
}

@test "a symlinked node_modules is not offered — it frees nothing" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "worktrees/linked/node_modules"
}

@test "a worktree that is also a top-level project dir is listed once" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'app-feature/node_modules')" -eq 1 ]
  output_has "worktree on feat/top, clean"
}

@test "scan does not change any worktree" {
  before="$(find "$FIXTURE" -newer "$GIT_CONFIG_GLOBAL" | wc -l)"
  sleep 1; touch "$GIT_CONFIG_GLOBAL"
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  [ "$(find "$FIXTURE" -newer "$GIT_CONFIG_GLOBAL" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "the clean --check plan line shows branch and state before each confirm" {
  run bash -c "yes n | '$GIGBACK' clean --check"
  [ "$status" -eq 0 ]
  output_has "worktree on feat/old, clean"
  output_has "worktree on fix/dirty, uncommitted changes"
  [ -d "$WT/old/node_modules" ]
}

@test "confirming a worktree item deletes only its node_modules" {
  run bash -c "yes y | '$GIGBACK' clean --check"
  [ "$status" -eq 0 ]
  [ ! -e "$WT/old/node_modules" ]
  [ ! -e "$FIXTURE/elsewhere/dirty/node_modules" ]
  # the worktree itself, its git link and uncommitted work are untouched
  [ -f "$WT/old/README" ]
  [ -f "$WT/old/.git" ]
  grep -q "edit in progress" "$FIXTURE/elsewhere/dirty/README"
  # fresh checkouts keep theirs; the symlink and its target survive
  [ -d "$GB_PROJECTS_DIR/app/node_modules/leftpad" ]
  [ -d "$WT/new/node_modules" ]
  [ -L "$WT/linked/node_modules" ]
}

@test "worktrees use a 30-day default; top-level repos keep 90" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "no commits in 45d (worktree threshold 30d); worktree on feat/mid, clean"
  output_lacks "repo45/node_modules"
}

@test "plan lines name the threshold that applied" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "no commits in 200d (worktree threshold 30d); worktree on feat/old, clean"
  run "$GIGBACK" scan --stale-days 0          # top-level stale-app (no git, fresh mtime)
  [ "$status" -eq 0 ]
  output_has "stale-app/node_modules  (no commits in 0d (threshold 0d)"
}

@test "--worktree-stale-days and --stale-days are independent" {
  run "$GIGBACK" scan --worktree-stale-days 60
  [ "$status" -eq 0 ]
  output_lacks "worktrees/mid/node_modules"
  output_has "no commits in 200d (worktree threshold 60d)"
  output_lacks "repo45/node_modules"

  run "$GIGBACK" scan --stale-days 40
  [ "$status" -eq 0 ]
  output_has "repo45/node_modules"
  output_has "no commits in 45d (threshold 40d)"
  output_has "no commits in 45d (worktree threshold 30d)"   # worktree default unchanged
}

@test "a worktree that is also a top-level dir uses the worktree threshold" {
  run "$GIGBACK" scan --stale-days 300
  [ "$status" -eq 0 ]
  output_has "app-feature/node_modules"
  output_has "worktree on feat/top, clean"
}

@test "--worktree-stale-days rejects a missing or non-numeric value" {
  run "$GIGBACK" scan --worktree-stale-days abc
  [ "$status" -eq 2 ]
  output_has "must be a number"
  run "$GIGBACK" scan --worktree-stale-days
  [ "$status" -eq 2 ]
}

@test "no test path reaches a real xcrun, hdiutil or npm" {
  run bash -c "yes y | '$GIGBACK' clean --check"
  [ "$status" -eq 0 ]
  [ ! -s "$FIXTURE/guard.log" ]
}
