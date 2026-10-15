#!/usr/bin/env bats

load helpers

setup() { setup_fixture; use_fake_simctl; }
teardown() { teardown_fixture; }

@test "scan lists a bundle runtime that 'simctl runtime list' doesn't show" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "MANUAL"
  output_has "iOS 18.1 (22B81)"
  output_has "Xcode → Settings → Components"
}

@test "a bundle runtime is sized by its outermost image file, not the mounted volume" {
  run "$GIGBACK" scan --json
  [ "$status" -eq 0 ]
  # outer MobileAsset image is 2048 KB; the inner image (1024 KB) must not be used
  output_has '{"id":"sim-runtime","tier":"MANUAL","kb":2048,"path":"iOS 18.1 (22B81)"}'
}

@test "image runtimes stay in SAFE; the newest is kept whatever its kind" {
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "Old iOS simulator runtimes: iOS-17.5"
  output_lacks "iOS-18.1"
  output_lacks "26.5"
}

@test "--keep-runtime keeps a bundle runtime off the MANUAL list" {
  run "$GIGBACK" scan --keep-runtime 18.1
  [ "$status" -eq 0 ]
  output_lacks "iOS 18.1"
  output_lacks "MANUAL"
}

@test "a bundle runtime that is the newest is kept" {
  sed -i '' 's/^iOS 18.1 (18.1 - 22B81)/iOS 27.0 (27.0 - 22B81)/' "$FIXTURE/sim/list-runtimes-v.txt"
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "MANUAL"
  # and both images are now superseded
  output_has "Old iOS simulator runtimes: iOS-17.5 iOS-26.5"
}

@test "versions sort numerically across three parts" {
  sed -i '' 's/^iOS 18.1 (18.1 - 22B81)/iOS 26.5.1 (26.5.1 - 22B81)/' "$FIXTURE/sim/list-runtimes-v.txt"
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "MANUAL"
  output_has "Old iOS simulator runtimes: iOS-17.5 iOS-26.5"
}

@test "clean dry run shows the MANUAL runtime but calls no delete" {
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  output_has "DRY RUN"
  output_has "iOS 18.1 (22B81)"
  [ "$(grep -c 'delete' "$SIM_LOG")" -eq 0 ]
}

@test "clean --apply deletes old images by uuid and never touches the bundle runtime" {
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  grep -qx 'xcrun simctl runtime delete AAAAAAAA-1111-1111-1111-111111111111' "$SIM_LOG"
  [ "$(grep -c 'runtime delete' "$SIM_LOG")" -eq 1 ]
  [ "$(grep -c -e 'delete.*BBBBBBBB' -e 'delete.*22B81' -e 'delete.*18' "$SIM_LOG")" -eq 0 ]
}

@test "without simctl there is no MANUAL list and no simulator lines" {
  export GB_NO_SIMCTL=1
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "MANUAL"
  output_lacks "sim-"
  [ ! -s "$SIM_LOG" ]
}

# ---- checked runtime deletes: every outcome is reported honestly ----

@test "a runtime that is really removed reports the space it freed" {
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  output_has "iOS 17.5: removed, 3.0 MB freed"
  output_lacks "deleted: sim-runtimes"
  [ ! -e "$GB_SIM_ASSETS/1111.asset" ]
  grep -q '"target":"sim-runtime","kb":3072,"cmd":"simctl runtime delete AAAAAAAA-1111-1111-1111-111111111111 (iOS 17.5): removed, 3.0 MB freed"' \
    "$GB_LOG_DIR/log.jsonl"
}

@test "an image left behind after unregistering is reported, not called freed" {
  echo left > "$SIM_DIR/delete-mode"
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  output_has "iOS 17.5: unregistered, but the 3.0 MB image was left at $GB_SIM_ASSETS/1111.asset/AssetData/Restore/171.dmg (protected by macOS; gigback can't remove it)"
  output_lacks "freed"
  grep -q '"target":"sim-runtime","kb":0,.*unregistered, but the 3.0 MB image was left' "$GB_LOG_DIR/log.jsonl"
}

@test "a leftover image then shows up on the MANUAL list in scan and report" {
  echo left > "$SIM_DIR/delete-mode"
  "$GIGBACK" clean --apply --yes >/dev/null
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_has "runtime-image  iOS 17.5 (21F79) image left at $GB_SIM_ASSETS/1111.asset"
  output_has "macOS protects this folder (SIP), so gigback can't remove it"
  run "$GIGBACK" report
  [ "$status" -eq 0 ]
  output_has "iOS 17.5 (21F79) image left at"
}

@test "a simctl failure is shown with its message and logged" {
  echo fail > "$SIM_DIR/delete-mode"
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  output_has "iOS 17.5: simctl failed: An error was encountered processing the command"
  output_has "Unable to delete runtime"
  output_lacks "freed"
  # the error text contains quotes; the log line must stay valid JSON
  tail -n 1 "$GB_LOG_DIR/log.jsonl" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]'
  grep -q '"target":"sim-runtime","kb":0,.*simctl failed' "$GB_LOG_DIR/log.jsonl"
}

@test "simctl exiting 0 without removing anything is not called success" {
  echo stuck > "$SIM_DIR/delete-mode"
  run "$GIGBACK" clean --apply --yes
  [ "$status" -eq 0 ]
  output_has "iOS 17.5: still registered 0s after simctl returned"
  output_lacks "freed"
  [ -f "$GB_SIM_ASSETS/1111.asset/AssetData/Restore/171.dmg" ]
}

@test "an orphaned runtime image neither simctl list knows is on the MANUAL list, sized" {
  add_runtime_asset 6fb1 22E238 18.4 4096 090-44150-318.dmg
  run "$GIGBACK" scan --json
  [ "$status" -eq 0 ]
  output_has "{\"id\":\"runtime-image\",\"tier\":\"MANUAL\",\"kb\":4"
  output_has "iOS 18.4 (22E238) image left at $GB_SIM_ASSETS/6fb1.asset"
  # images simctl still knows (in use, or the bundle runtime's) are not orphans
  output_lacks "(23F77) image left"
  output_lacks "(22B81) image left"
  output_lacks "(21F79) image left"
}

@test "an asset folder with no image file left is not listed" {
  mkdir -p "$GB_SIM_ASSETS/9999.asset"
  printf '<plist version="1.0"><dict><key>MobileAssetProperties</key><dict><key>Build</key><string>21A1</string></dict></dict></plist>\n' \
    > "$GB_SIM_ASSETS/9999.asset/Info.plist"
  run "$GIGBACK" scan
  [ "$status" -eq 0 ]
  output_lacks "21A1"
}

@test "orphan detection never runs a delete and stays out of the clean plan's SAFE list" {
  add_runtime_asset 6fb1 22E238 18.4 4096 090-44150-318.dmg
  run "$GIGBACK" clean
  [ "$status" -eq 0 ]
  output_has "iOS 18.4 (22E238) image left at"
  [ "$(grep -c 'delete' "$SIM_LOG")" -eq 0 ]
  [ -f "$GB_SIM_ASSETS/6fb1.asset/090-44150-318.dmg" ] || [ -f "$GB_SIM_ASSETS/6fb1.asset/AssetData/090-44150-318.dmg" ]
}
