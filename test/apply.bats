#!/usr/bin/env bats

load helpers

setup() { setup_fixture; }
teardown() { teardown_fixture; }

@test "clean --apply --yes deletes SAFE fixtures only" {
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]

  # SAFE targets gone
  [ ! -d "$GB_DERIVED_DATA" ]
  [ ! -d "$GB_GRADLE_CACHES" ]
  # user-caches: contents removed, dir kept
  [ -d "$GB_USER_CACHES" ]
  [ -z "$(ls -A "$GB_USER_CACHES")" ]

  # CHECK tier untouched without --check
  [ -d "$GB_PROJECTS_DIR/stale-app/node_modules" ]
  [ -d "$GB_PROJECTS_DIR/stale-rust-app/target" ]
  [ -d "$GB_PROJECTS_DIR/stale-py-app/venv" ]
  [ -d "$GB_DOT_CACHE/sometool" ]

  # DATA tier untouched, always
  [ -f "$GB_APP_SUPPORT/Cursor/User/globalStorage/state.vscdb" ]
  [ -f "$GB_BREW_VAR/postgresql@14/base/pg" ]
}

@test "apply writes an append-only log" {
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  [ -f "$GB_LOG_DIR/log.jsonl" ]
  grep -q '"target":"derived-data"' "$GB_LOG_DIR/log.jsonl"
}

@test "declining the confirm deletes nothing" {
  before="$(fixture_file_count)"
  run bash -c "echo n | '$GIGBACK' clean --apply"
  [ "$status" -eq 0 ]
  [ "$before" -eq "$(fixture_file_count)" ]
}

@test "check items are individually confirmable and 'n' keeps them" {
  run bash -c "yes n | '$GIGBACK' clean --check --stale-days 0"
  [ "$status" -eq 0 ]
  [ -d "$GB_PROJECTS_DIR/stale-app/node_modules" ]
  [ -d "$GB_PROJECTS_DIR/stale-rust-app/target" ]
  [ -d "$GB_PROJECTS_DIR/stale-py-app/venv" ]
  [ -d "$GB_DOT_CACHE/sometool" ]
}

@test "check items confirmed with 'y' are deleted" {
  run bash -c "yes y | '$GIGBACK' clean --check --stale-days 0"
  [ "$status" -eq 0 ]
  [ ! -d "$GB_PROJECTS_DIR/stale-app/node_modules" ]
  [ ! -d "$GB_PROJECTS_DIR/stale-rust-app/target" ]
  [ ! -d "$GB_PROJECTS_DIR/stale-py-app/venv" ]
  # DATA still untouched even when saying yes to everything
  [ -f "$GB_APP_SUPPORT/Cursor/User/globalStorage/state.vscdb" ]
  [ -f "$GB_BREW_VAR/postgresql@14/base/pg" ]
}
