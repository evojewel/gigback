#!/usr/bin/env bats
# Run history: every scan / clean / report appends one record to
# $GB_LOG_DIR/history.jsonl; `gigback history` reads them back. History only
# ever appends to, trims and reads its own file — it never deletes anything else.

load helpers

setup() {
  setup_fixture
  HISTORY="$GB_LOG_DIR/history.jsonl"
}
teardown() { teardown_fixture; }

need_jq() { command -v jq >/dev/null 2>&1 || skip "jq not installed"; }

last_record() { tail -n 1 "$HISTORY"; }

@test "scan appends one valid record with tiers, items and disk" {
  need_jq
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HISTORY" | tr -d ' ')" -eq 1 ]
  last_record | jq -e '
    .cmd == "scan" and .version != "" and (.epoch | type) == "number"
    and (.disk.free_kb | type) == "number" and (.disk.total_kb | type) == "number"
    and (.tiers.SAFE | type) == "number" and (.tiers.CHECK | type) == "number"
    and (.tiers.MANUAL | type) == "number" and (.tiers.DATA | type) == "number"
    and ([.items[] | select(.tier == "SAFE" and .id == "derived-data" and (.kb | type) == "number")] | length) == 1
    and ([.items[] | select(.tier == "DATA" and .id == "editor-state")] | length) == 1
    and .tm_local_snapshots == null' >/dev/null
}

@test "paths under HOME are stored as ~/…" {
  need_jq
  GB_HOME="$FIXTURE" run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  [ "$(last_record | jq -r '.items[] | select(.id == "derived-data") | .path')" = "~/DerivedData" ]
  run grep -c "\"$FIXTURE/" "$HISTORY"
  [ "$output" = "0" ]
}

@test "clean dry run records SAFE and leaves unmeasured tiers null, not zero" {
  need_jq
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  last_record | jq -e '.cmd == "clean" and .mode == "dry-run"
    and (.tiers.SAFE | type) == "number" and .tiers.CHECK == null and .tiers.DATA == null' >/dev/null
}

@test "clean --apply records sizes before deleting, free space before and after, and still logs deletions" {
  need_jq
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  last_record | jq -e '.mode == "apply" and (.disk.free_before_kb | type) == "number"
    and ([.items[] | select(.id == "derived-data" and .kb > 0)] | length) == 1' >/dev/null
  grep -q '"target":"derived-data"' "$GB_LOG_DIR/log.jsonl"
}

@test "report records the DATA tier it prints, without Postgres database names" {
  need_jq
  run "$GIGBACK" report
  [ "$status" -eq 0 ]
  last_record | jq -e '.cmd == "report" and (.tiers.DATA | type) == "number" and .tiers.SAFE == null
    and ([.items[] | select(.id == "database")] | length) == 1
    and ([.items[] | select(.id == "app-support")] | length) >= 1
    and ([.items[] | select(.tier == "DATA") | .id] - ["database", "editor-state", "app-support"] | length) == 0' >/dev/null
}

@test "GIGBACK_NO_HISTORY=1 and --no-history record nothing" {
  GIGBACK_NO_HISTORY=1 run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  run "$GIGBACK" clean --no-history
  [ "$status" -eq 0 ]
  [ ! -e "$HISTORY" ]
}

@test "history is bounded by GIGBACK_HISTORY_MAX, keeping the newest runs" {
  export GIGBACK_HISTORY_MAX=3
  local i
  for i in 1 2 3 4 5; do "$GIGBACK" clean >/dev/null; done
  "$GIGBACK" report >/dev/null
  [ "$(wc -l < "$HISTORY" | tr -d ' ')" -eq 3 ]
  tail -n 1 "$HISTORY" | grep -q '"cmd":"report"'
  [ ! -e "$HISTORY.tmp" ]
}

@test "history never deletes: trimming touches only its own file" {
  export GIGBACK_HISTORY_MAX=1
  before="$(fixture_file_count)"
  "$GIGBACK" scan >/dev/null
  "$GIGBACK" scan >/dev/null
  [ "$before" -eq "$(fixture_file_count)" ]
  [ "$(ls "$GB_LOG_DIR")" = "history.jsonl" ]
}

@test "an unwritable history location never fails the command" {
  echo "not a dir" > "$FIXTURE/blocker"
  GB_LOG_DIR="$FIXTURE/blocker/log" run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "SAFE"
}

@test "log still shows deletions only, not history records" {
  "$GIGBACK" scan >/dev/null
  run "$GIGBACK" log
  [ "$status" -eq 0 ]
  output_has "no runs logged yet"
}

@test "a path with a double quote stays valid JSON" {
  need_jq
  mkdir -p "$GB_PROJECTS_DIR/say \"hi\" app/node_modules/x"
  echo "lib" > "$GB_PROJECTS_DIR/say \"hi\" app/node_modules/x/index.js"
  run "$GIGBACK" scan --stale-days 0
  [ "$status" -eq 0 ]
  last_record | jq -e '[.items[] | select(.path | contains("say \"hi\" app"))] | length == 1' >/dev/null
}

@test "history with nothing recorded says how to start, and --json gives []" {
  run "$GIGBACK" history
  [ "$status" -eq 0 ]
  output_has "no history yet"
  run "$GIGBACK" history --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "history --json returns the recorded runs; --last limits them" {
  need_jq
  "$GIGBACK" clean >/dev/null; "$GIGBACK" scan >/dev/null; "$GIGBACK" report >/dev/null
  run "$GIGBACK" history --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" -eq 3 ]
  run "$GIGBACK" history --json --last 1
  [ "$(echo "$output" | jq -r '.[0].cmd')" = "report" ]
}

@test "--last rejects zero and non-numbers" {
  run "$GIGBACK" history --last 0
  [ "$status" -eq 2 ]
  run "$GIGBACK" history --last ten
  [ "$status" -eq 2 ]
}

@test "history shows which measured item grew between real runs" {
  "$GIGBACK" scan >/dev/null
  dd if=/dev/zero of="$GB_DERIVED_DATA/SomeApp-abc/grown.o" bs=1024 count=2048 2>/dev/null
  "$GIGBACK" scan >/dev/null
  run "$GIGBACK" history
  [ "$status" -eq 0 ]
  output_has "last 2 runs"
  output_has "Grew most"
  output_has "SAFE    derived-data"
}

# The trend maths, checked on a hand-written history: free space falls 10 GB in
# 2 hours while measured items grow 2 GB, so ~8 GB is outside gigback's view.
@test "history reports the free-space rate and growth outside what gigback measures" {
  mkdir -p "$GB_LOG_DIR"
  cat > "$HISTORY" <<'JSONL'
{"ts":"2026-10-20T06:00:00Z","epoch":1792476000,"version":"0.2.0","cmd":"scan","mode":"","disk":{"total_kb":482344960,"free_kb":24117248},"tm_local_snapshots":3,"tiers":{"SAFE":1048576,"CHECK":0,"MANUAL":0,"DATA":10485760},"items":[{"tier":"SAFE","id":"user-caches","kb":1048576,"path":"~/Library/Caches"},{"tier":"DATA","id":"app-support","kb":10485760,"path":"~/Library/Application Support/Cursor"}]}
{"ts":"2026-10-20T08:00:00Z","epoch":1792483200,"version":"0.2.0","cmd":"scan","mode":"","disk":{"total_kb":482344960,"free_kb":13631488},"tm_local_snapshots":9,"tiers":{"SAFE":1048576,"CHECK":0,"MANUAL":0,"DATA":12582912},"items":[{"tier":"SAFE","id":"user-caches","kb":1048576,"path":"~/Library/Caches"},{"tier":"DATA","id":"app-support","kb":12582912,"path":"~/Library/Application Support/Cursor"}]}
JSONL
  run "$GIGBACK" history
  [ "$status" -eq 0 ]
  output_has "23.0 GB -> 13.0 GB over 2h 0m (-5.0 GB per hour)"
  output_has "+2.0 GB    DATA    app-support    ~/Library/Application Support/Cursor"
  output_has "About 8.0 GB went somewhere gigback does not measure"
  output_has "Snapshots: 3 -> 9"
}
