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
