# Shared bats setup: build a fixture tree and point every gigback path at it.
# No test may ever touch the real filesystem outside $FIXTURE.

setup_fixture() {
  FIXTURE="$(mktemp -d "${BATS_TMPDIR}/gigback-fixture.XXXXXX")"

  mkdir -p "$FIXTURE/DerivedData/SomeApp-abc"
  echo "build junk" > "$FIXTURE/DerivedData/SomeApp-abc/junk.o"

  mkdir -p "$FIXTURE/Caches/com.example.app"
  echo "cache" > "$FIXTURE/Caches/com.example.app/blob"

  mkdir -p "$FIXTURE/gradle-caches"
  echo "gradle" > "$FIXTURE/gradle-caches/dep.jar"

  mkdir -p "$FIXTURE/Projects/stale-app/node_modules/leftpad"
  echo "lib" > "$FIXTURE/Projects/stale-app/node_modules/leftpad/index.js"

  mkdir -p "$FIXTURE/dot-cache/sometool"
  echo "tool cache" > "$FIXTURE/dot-cache/sometool/blob"

  mkdir -p "$FIXTURE/AppSupport/Cursor/User/globalStorage"
  echo "chat history" > "$FIXTURE/AppSupport/Cursor/User/globalStorage/state.vscdb"

  mkdir -p "$FIXTURE/brew-var/postgresql@14/base"
  echo "db page" > "$FIXTURE/brew-var/postgresql@14/base/pg"

  mkdir -p "$FIXTURE/log"

  export GB_DERIVED_DATA="$FIXTURE/DerivedData"
  export GB_USER_CACHES="$FIXTURE/Caches"
  export GB_GRADLE_CACHES="$FIXTURE/gradle-caches"
  export GB_PROJECTS_DIR="$FIXTURE/Projects"
  export GB_DOT_CACHE="$FIXTURE/dot-cache"
  export GB_ARCHIVES="$FIXTURE/Archives"          # intentionally absent
  export GB_APP_SUPPORT="$FIXTURE/AppSupport"
  export GB_BREW_VAR="$FIXTURE/brew-var"
  export GB_LOG_DIR="$FIXTURE/log"
  export GB_NO_SIMCTL=1                            # never touch real simulators
  export GB_NO_NPM=1                               # never touch the real npm cache

  GIGBACK="$BATS_TEST_DIRNAME/../bin/gigback"
}

teardown_fixture() {
  rm -rf "$FIXTURE"
}

# Output assertions. Under bash 3.2 (macOS /bin/bash) a failing [[ ]] that
# isn't the last line of a test does not fail it; these always do.
output_has() {
  [[ "$output" == *"$1"* ]] || { echo "expected output to contain: $1"; return 1; }
}

output_lacks() {
  [[ "$output" != *"$1"* ]] || { echo "expected output not to contain: $1"; return 1; }
}

fixture_file_count() {
  find "$FIXTURE" -type f | wc -l | tr -d ' '
}

# Fake xcrun + hdiutil that answer from fixture text modelled on a real Mac
# (2026-10): iOS 26.5 and 17.5 are disk images; iOS 18.1 is a bundle runtime,
# mounted from an image inside a MobileAsset image, that `simctl runtime list`
# does not show. Every call is logged to $SIM_LOG so tests can prove what
# gigback asked for — the real xcrun is never reachable.
use_fake_simctl() {
  local sim="$FIXTURE/sim" vol="$FIXTURE/sim/Volumes" bundle
  bundle="$sim/Cryptex/bundle/SimRuntimeBundle-4B26"
  mkdir -p "$sim/bin" "$sim/AssetsV2/4d6f.asset/AssetData" "$bundle/Restore"
  mkdir -p "$vol/iOS_23F77/Runtimes/iOS 26.5.simruntime" \
           "$vol/iOS_21F79/Runtimes/iOS 17.5.simruntime" \
           "$vol/iOS_22B81/Runtimes/iOS 18.1.simruntime"
  # outer MobileAsset image 2 MB; inner runtime image 1 MB (must not be the one sized)
  dd if=/dev/zero of="$sim/AssetsV2/4d6f.asset/AssetData/044-04621-122.dmg" bs=1024 count=2048 2>/dev/null
  dd if=/dev/zero of="$bundle/Restore/044-05093-123.dmg" bs=1024 count=1024 2>/dev/null
  SIM_LOG="$sim/calls.log"
  : > "$SIM_LOG"

  cat > "$sim/runtime-list.txt" <<TXT
== Disk Images ==
-- iOS --
iOS 17.5 (21F79) - AAAAAAAA-1111-1111-1111-111111111111 (Ready)
iOS 26.5 (23F77) - BBBBBBBB-2222-2222-2222-222222222222 (Ready)

Total Disk Images: 2 (16G)
TXT
  cat > "$sim/list-runtimes-v.txt" <<TXT
== Runtimes ==
iOS 17.5 (17.5 - 21F79) - com.apple.CoreSimulator.SimRuntime.iOS-17-5 [$vol/iOS_21F79/Runtimes/iOS 17.5.simruntime]
iOS 18.1 (18.1 - 22B81) - com.apple.CoreSimulator.SimRuntime.iOS-18-1 [$vol/iOS_22B81/Runtimes/iOS 18.1.simruntime]
iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5 [$vol/iOS_23F77/Runtimes/iOS 26.5.simruntime]
TXT
  {
    printf 'framework       : 710\ndriver          : 710\nimages          : 3\n'
    printf '================================================\n'
    printf 'image-path      : %s\n' "$sim/AssetsV2/4d6f.asset/AssetData/044-04621-122.dmg"
    printf 'image-type      : read/write disk image\n'
    printf '/dev/disk4\tGUID_partition_scheme\t\n'
    printf '/dev/disk6s1\t41504653-0000-11AA-AA11-00306543ECAC\t%s\n' "$bundle"
    printf '================================================\n'
    printf 'image-path      : %s\n' "$bundle/Restore/044-05093-123.dmg"
    printf '/dev/disk8\tGUID_partition_scheme\t\n'
    printf '/dev/disk9s1\t41504653-0000-11AA-AA11-00306543ECAC\t%s\n' "$vol/iOS_22B81"
  } > "$sim/hdiutil-info.txt"

  cat > "$sim/bin/xcrun" <<SH
#!/bin/bash
echo "xcrun \$*" >> "$SIM_LOG"
case "\$*" in
  "simctl runtime list") cat "$sim/runtime-list.txt" ;;
  "simctl list runtimes -v") cat "$sim/list-runtimes-v.txt" ;;
  "simctl runtime delete "*|"simctl delete unavailable") ;;
  *) echo "fake xcrun: unexpected call: \$*" >&2; exit 1 ;;
esac
SH
  cat > "$sim/bin/hdiutil" <<SH
#!/bin/bash
echo "hdiutil \$*" >> "$SIM_LOG"
[ "\$*" = info ] && cat "$sim/hdiutil-info.txt"
SH
  chmod +x "$sim/bin/xcrun" "$sim/bin/hdiutil"

  unset GB_NO_SIMCTL
  export GB_XCRUN="$sim/bin/xcrun"
  export GB_HDIUTIL="$sim/bin/hdiutil"
  # Also first on PATH, so code that ignores GB_XCRUN still gets the fake.
  export PATH="$sim/bin:$PATH"
}
