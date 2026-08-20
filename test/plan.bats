#!/usr/bin/env bats

load helpers

setup() { setup_fixture; }
teardown() { teardown_fixture; }

@test "clean without --apply is a dry run and deletes nothing" {
  before="$(fixture_file_count)"
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [ "$before" -eq "$(fixture_file_count)" ]
}

@test "clean plan names a regeneration command per target" {
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  [[ "$output" == *"regen:"* ]]
}

@test "DATA-tier paths never appear in the clean plan" {
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  [[ "$output" != *"postgresql"* ]]
  [[ "$output" != *"globalStorage"* ]]
}

@test "--yes together with --check is refused" {
  run "$GIGBACK" clean --check --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"refused"* ]]
}

@test "unknown flags are rejected, not ignored" {
  run "$GIGBACK" clean --nuke-everything
  [ "$status" -eq 2 ]
}
