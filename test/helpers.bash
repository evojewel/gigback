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

  mkdir -p "$FIXTURE/Projects/stale-rust-app/target/debug"
  echo "binary" > "$FIXTURE/Projects/stale-rust-app/target/debug/app"

  mkdir -p "$FIXTURE/Projects/stale-py-app/venv/lib"
  echo "site-packages" > "$FIXTURE/Projects/stale-py-app/venv/lib/blob"

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

fixture_file_count() {
  find "$FIXTURE" -type f | wc -l | tr -d ' '
}
