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
  run "$GIGBACK" scan --stale-days 300        # older than every commit: nothing from git
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
