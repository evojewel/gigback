#!/usr/bin/env bats

load helpers

setup() { setup_fixture; }
teardown() { teardown_fixture; }

@test "--version prints the version" {
  run "$GIGBACK" --version
  [ "$status" -eq 0 ]
  [[ "$output" == gigback* ]]
}

@test "scan exits 0 and reports all three tiers" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"SAFE"* ]]
  [[ "$output" == *"CHECK"* ]]
  [[ "$output" == *"DATA tier"* ]]
}

@test "scan is read-only — fixture untouched" {
  before="$(fixture_file_count)"
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  after="$(fixture_file_count)"
  [ "$before" -eq "$after" ]
}

@test "scan --json emits parseable structure" {
  run "$GIGBACK" scan --json
  [ "$status" -eq 0 ]
  [[ "$output" == '{"free_kb":'* ]]
  [[ "$output" == *'"tier":"SAFE"'* ]]
}

@test "scan surfaces stale node_modules as CHECK" {
  # fixture project has no git history -> falls back to dir mtime; force stale
  run "$GIGBACK" scan --stale-days 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"node_modules"* ]]
}

@test "scan surfaces stale Rust target/ and Python venv/ as CHECK" {
  run "$GIGBACK" scan --stale-days 0
  [ "$status" -eq 0 ]
  output_has "rust-target"
  output_has "cargo build"
  output_has "stale-py-app/venv"
  output_has "python3 -m venv venv"
}

@test "a target/ without Cargo.toml or an env/ without pyvenv.cfg is never offered" {
  run "$GIGBACK" scan --stale-days 0
  [ "$status" -eq 0 ]
  output_lacks "config-app/env"
  output_lacks "maven-app/target"
}

@test "report never deletes and mentions the data-tier stance" {
  before="$(fixture_file_count)"
  run "$GIGBACK" report
  [ "$status" -eq 0 ]
  [[ "$output" == *"never deletes"* ]]
  [ "$before" -eq "$(fixture_file_count)" ]
}
