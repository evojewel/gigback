# shellcheck shell=bash
# gigback target table + tier logic.
#
# THIS FILE IS THE SAFETY SURFACE. Every path gigback can touch is defined
# here, with its tier and regeneration command. Changes require a test and
# review (see CONTRIBUTING.md).
#
# Tiers:
#   SAFE  — deletable via `gigback clean --apply`; regenerates automatically
#   CHECK — regenerable but context-dependent; each item confirmed one by one
#   DATA  — sized and reported only. There is NO delete code for these.
#
# Every path is overridable via GB_* env vars so tests run against fixtures,
# never the real system.

# shellcheck disable=SC2034  # LOG_DIR / SAFE_IDS are consumed by bin/gigback
GB_HOME="${GB_HOME:-$HOME}"

DERIVED_DATA="${GB_DERIVED_DATA:-$GB_HOME/Library/Developer/Xcode/DerivedData}"
ARCHIVES_DIR="${GB_ARCHIVES:-$GB_HOME/Library/Developer/Xcode/Archives}"
USER_CACHES="${GB_USER_CACHES:-$GB_HOME/Library/Caches}"
NPM_DIR="${GB_NPM_DIR:-$GB_HOME/.npm}"
GRADLE_CACHES="${GB_GRADLE_CACHES:-$GB_HOME/.gradle/caches}"
DOT_CACHE="${GB_DOT_CACHE:-$GB_HOME/.cache}"
PROJECTS_DIR="${GB_PROJECTS_DIR:-$GB_HOME/Projects}"
APP_SUPPORT="${GB_APP_SUPPORT:-$GB_HOME/Library/Application Support}"
BREW_VAR="${GB_BREW_VAR:-/opt/homebrew/var}"
LOG_DIR="${GB_LOG_DIR:-$GB_HOME/.gigback}"

# ---------- helpers ----------

dir_kb() { # $1: path -> size in KB (0 if absent)
  if [ -e "$1" ]; then du -sk "$1" 2>/dev/null | cut -f1; else echo 0; fi
}

human_kb() { # $1: KB -> human string
  awk -v k="$1" 'BEGIN {
    if (k == "?" || k == "") { print "?"; exit }
    if (k >= 1048576)      printf "%.1f GB", k/1048576
    else if (k >= 1024)    printf "%.1f MB", k/1024
    else                   printf "%d KB", k
  }'
}

free_kb() { df -k / | awk 'NR==2 {print $4}'; }

have_simctl() {
  [ -z "${GB_NO_SIMCTL:-}" ] && command -v xcrun >/dev/null 2>&1
}

have_npm() {
  [ -z "${GB_NO_NPM:-}" ] && command -v npm >/dev/null 2>&1
}

# ---------- SAFE tier ----------
# One id per target. Each id answers: desc, path, size_kb, regen, apply.

SAFE_IDS="derived-data user-caches npm-cache gradle-cache sim-devices sim-runtimes"

safe_desc() {
  case "$1" in
    derived-data) echo "Xcode DerivedData (build caches)" ;;
    user-caches)  echo "User app caches" ;;
    npm-cache)    echo "npm cache" ;;
    gradle-cache) echo "Gradle caches" ;;
    sim-devices)  echo "Orphaned iOS simulator devices" ;;
    sim-runtimes) echo "Old iOS simulator runtimes: $(old_runtime_versions)" ;;
  esac
}

safe_path() {
  case "$1" in
    derived-data) echo "$DERIVED_DATA" ;;
    user-caches)  echo "$USER_CACHES" ;;
    npm-cache)    echo "$NPM_DIR" ;;
    gradle-cache) echo "$GRADLE_CACHES" ;;
    sim-devices)  echo "(xcrun simctl delete unavailable)" ;;
    sim-runtimes) echo "(xcrun simctl runtime delete <old>)" ;;
  esac
}

safe_size_kb() {
  case "$1" in
    derived-data) dir_kb "$DERIVED_DATA" ;;
    user-caches)  dir_kb "$USER_CACHES" ;;
    npm-cache)    dir_kb "$NPM_DIR" ;;
    gradle-cache) dir_kb "$GRADLE_CACHES" ;;
    # Simulator sizes are unreliable via du (runtime volumes are mounted
    # images and double-count); freed space is measured as the df delta.
    sim-devices|sim-runtimes) echo "?" ;;
  esac
}

safe_regen() {
  case "$1" in
    derived-data) echo "next Xcode build" ;;
    user-caches)  echo "apps rebuild caches on launch" ;;
    npm-cache)    echo "npm refills on next install" ;;
    gradle-cache) echo "next Gradle build re-downloads" ;;
    sim-devices)  echo "Xcode recreates devices on demand" ;;
    sim-runtimes) echo "Xcode re-downloads runtimes on demand" ;;
  esac
}

safe_present() { # is this target worth listing right now?
  case "$1" in
    derived-data) [ -d "$DERIVED_DATA" ] && [ "$(dir_kb "$DERIVED_DATA")" -gt 0 ] ;;
    user-caches)  [ -d "$USER_CACHES" ] && [ "$(dir_kb "$USER_CACHES")" -gt 0 ] ;;
    npm-cache)    have_npm && [ -d "$NPM_DIR" ] ;;
    gradle-cache) [ -d "$GRADLE_CACHES" ] ;;
    sim-devices)  have_simctl ;;
    sim-runtimes) have_simctl && [ -n "$(old_runtime_versions)" ] ;;
  esac
}

safe_apply() {
  case "$1" in
    derived-data) rm -rf "${DERIVED_DATA:?}" ;;
    user-caches)  rm -rf "${USER_CACHES:?}"/* 2>/dev/null || true ;;
    npm-cache)    npm cache clean --force >/dev/null 2>&1 || true ;;
    gradle-cache) rm -rf "${GRADLE_CACHES:?}" ;;
    sim-devices)  xcrun simctl delete unavailable >/dev/null 2>&1 || true ;;
    sim-runtimes) delete_old_runtimes ;;
  esac
}

# ---------- simulator runtime logic ----------
# `xcrun simctl runtime list` lines look like:
#   iOS 26.5 (23F77) - 631FC479-2466-4354-9CD5-C833E4F86FCE (Ready)
# We keep the newest Ready iOS runtime plus anything in --keep-runtime,
# and delete the rest. Deletion is async; we report versions, not bytes.

ready_runtimes() { # prints "version uuid" lines, oldest first
  have_simctl || return 0
  xcrun simctl runtime list 2>/dev/null \
    | awk '/^iOS / && /\(Ready\)$/ {print $2, $5}' \
    | sort -t. -k1,1n -k2,2n
}

newest_runtime_version() { ready_runtimes | awk 'END {print $1}'; }

is_kept_runtime() { # $1: version -> 0 if user asked to keep it
  case " ${KEEP_RUNTIMES:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

old_runtime_versions() { # versions that would be deleted, space-separated
  local newest out v uuid
  newest="$(newest_runtime_version)"
  out=""
  while read -r v uuid; do
    [ -n "$v" ] || continue
    [ "$v" = "$newest" ] && continue
    is_kept_runtime "$v" && continue
    out="$out iOS-$v"
  done <<EOF
$(ready_runtimes)
EOF
  echo "${out# }"
}

delete_old_runtimes() {
  local newest v uuid
  newest="$(newest_runtime_version)"
  while read -r v uuid; do
    [ -n "$v" ] || continue
    [ "$v" = "$newest" ] && continue
    is_kept_runtime "$v" && continue
    xcrun simctl runtime delete "$uuid" >/dev/null 2>&1 || true
  done <<EOF
$(ready_runtimes)
EOF
}

# ---------- CHECK tier ----------
# Items are enumerated dynamically; each is confirmed individually.
# check_items prints: kind<TAB>kb<TAB>path-or-cmd<TAB>note

check_items() {
  # Stale node_modules: projects with no git commit in STALE_DAYS days
  if [ -d "$PROJECTS_DIR" ]; then
    local now d nm last age
    now=$(date +%s)
    for d in "$PROJECTS_DIR"/*/; do
      [ -d "$d" ] || continue
      nm="${d%/}/node_modules"
      [ -d "$nm" ] || continue
      last=$( (cd "$d" && git log -1 --format=%ct 2>/dev/null) || true )
      [ -n "$last" ] || last=$(stat -f %m "$d" 2>/dev/null || echo "$now")
      age=$(( (now - last) / 86400 ))
      [ "$age" -ge "$STALE_DAYS" ] || continue
      printf 'node_modules\t%s\t%s\tno commits in %sd; regen: npm install\n' \
        "$(dir_kb "$nm")" "$nm" "$age"
    done
  fi

  # Xcode archives — keep anything you may need to re-submit/symbolicate
  if [ -d "$ARCHIVES_DIR" ] && [ "$(dir_kb "$ARCHIVES_DIR")" -gt 0 ]; then
    printf 'xcode-archives\t%s\t%s\tcheck for builds you still ship/symbolicate\n' \
      "$(dir_kb "$ARCHIVES_DIR")" "$ARCHIVES_DIR"
  fi

  # ~/.cache entries — one by one; model caches are slow to re-download
  if [ -d "$DOT_CACHE" ]; then
    local e note
    for e in "$DOT_CACHE"/*/; do
      [ -d "$e" ] || continue
      case "$(basename "$e")" in
        whisper|torch|huggingface|models*) note="MODEL CACHE — slow to re-download" ;;
        *) note="re-downloads on next use" ;;
      esac
      printf 'dot-cache\t%s\t%s\t%s\n' "$(dir_kb "$e")" "${e%/}" "$note"
    done
  fi
}

check_apply() { # $1: kind, $2: path — the only delete verbs in CHECK tier
  case "$1" in
    node_modules|xcode-archives|dot-cache) rm -rf "${2:?}" ;;
    *) echo "gigback: unknown CHECK kind '$1' — refusing" >&2; return 1 ;;
  esac
}

# ---------- DATA tier ----------
# REPORT ONLY. No function in this file or anywhere in gigback deletes
# these. That absence is deliberate — do not add one.

data_report() {
  local d found
  echo "DATA tier — gigback never deletes these; sizes for your own review:"
  echo ""

  found=0
  for d in "$BREW_VAR"/postgresql* "$BREW_VAR"/postgres "$BREW_VAR"/mysql*; do
    [ -d "$d" ] || continue
    found=1
    printf '  %-10s %s\n' "$(human_kb "$(dir_kb "$d")")" "$d"
  done
  if [ "$found" = 1 ]; then
    if pgrep -x postgres >/dev/null 2>&1 && command -v psql >/dev/null 2>&1; then
      echo ""
      echo "  Postgres is running — per-database sizes:"
      psql -d postgres -Atc \
        "SELECT '    ' || pg_size_pretty(pg_database_size(datname)) || '  ' || datname
         FROM pg_database ORDER BY pg_database_size(datname) DESC;" 2>/dev/null || true
    else
      echo ""
      echo "  Postgres is not running. gigback will NOT start it. To size databases:"
      echo "    pg_ctl -D $BREW_VAR/postgresql@<ver> start   # then psql, then stop again"
    fi
    echo "  Drop stale snapshot DBs only via psql, only ones you can account for."
  fi

  echo ""
  echo "  Editor state (contains AI chat history — deleting erases it):"
  for d in "$APP_SUPPORT/Code/User/globalStorage" "$APP_SUPPORT/Cursor/User/globalStorage"; do
    [ -d "$d" ] || continue
    printf '  %-10s %s\n' "$(human_kb "$(dir_kb "$d")")" "$d"
  done

  echo ""
  echo "  Largest Application Support entries (mixed junk + real data — review by hand):"
  du -sk "$APP_SUPPORT"/* 2>/dev/null | sort -rn | head -5 \
    | while IFS=$(printf '\t') read -r kb path; do
        printf '  %-10s %s\n' "$(human_kb "$kb")" "$path"
      done
}
