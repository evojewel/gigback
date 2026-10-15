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

# Tools gigback asks about simulator state. Overridable so tests answer from
# fixtures and never reach the real xcrun or hdiutil.
XCRUN="${GB_XCRUN:-xcrun}"
HDIUTIL="${GB_HDIUTIL:-hdiutil}"

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
  [ -z "${GB_NO_SIMCTL:-}" ] && command -v "$XCRUN" >/dev/null 2>&1
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
    sim-devices)  "$XCRUN" simctl delete unavailable >/dev/null 2>&1 || true ;;
    sim-runtimes) delete_old_runtimes ;;
  esac
}

# ---------- simulator runtime logic ----------
# iOS runtimes come in two kinds, and simctl lists them in two places:
#
#   Disk images: `simctl runtime list` lines look like
#     iOS 26.5 (23F77) - 631FC479-2466-4354-9CD5-C833E4F86FCE (Ready)
#   and `simctl runtime delete <uuid>` removes them without sudo.
#
#   Bundles (older downloads, e.g. a Cryptex SimRuntimeBundle): only
#   `simctl list runtimes` shows them. `simctl runtime delete` matches only
#   what `simctl runtime list` lists, so gigback has no sudo-free way to
#   remove them; they go on the MANUAL list with the by-hand route instead.
#
# Across both kinds we keep the newest iOS version plus anything in
# --keep-runtime. Image deletion is async; we report versions, not bytes.

sort_versions() { sort -t. -k1,1n -k2,2n -k3,3n; } # lines starting x.y[.z]

ready_runtimes() { # prints "version uuid" lines for deletable images, oldest first
  have_simctl || return 0
  "$XCRUN" simctl runtime list 2>/dev/null \
    | awk '/^iOS / && /\(Ready\)$/ {print $2, $5}' \
    | sort_versions
}

image_runtime_builds() { # builds of every iOS disk image in any state, space-separated
  have_simctl || return 0
  "$XCRUN" simctl runtime list 2>/dev/null \
    | awk '/^iOS / {b = $3; gsub(/[()]/, "", b); printf "%s ", b}'
}

listed_runtimes() { # every available iOS runtime: version<TAB>build<TAB>bundle path
  # `simctl list runtimes -v` lines look like
  #   iOS 18.1 (18.1 - 22B81) - com.apple.CoreSimulator.SimRuntime.iOS-18-1 [/…/iOS 18.1.simruntime]
  have_simctl || return 0
  "$XCRUN" simctl list runtimes -v 2>/dev/null \
    | awk '/^iOS / && !/unavailable/ && match($0, /\[.*\]$/) {
        b = $5; sub(/\)$/, "", b)
        printf "%s\t%s\t%s\n", $2, b, substr($0, RSTART + 1, RLENGTH - 2)
      }'
}

bundle_runtimes() { # listed runtimes that are not disk images: version<TAB>build<TAB>bundle path
  local images v b path
  images=" $(image_runtime_builds) "
  listed_runtimes | while IFS=$(printf '\t') read -r v b path; do
    case "$images" in *" $b "*) continue ;; esac
    printf '%s\t%s\t%s\n' "$v" "$b" "$path"
  done
}

newest_runtime_version() { # newest iOS version of either kind
  { ready_runtimes; listed_runtimes; } | awk '{print $1}' | sort_versions | awk 'END {print}'
}

is_kept_runtime() { # $1: version -> 0 if user asked to keep it
  case " ${KEEP_RUNTIMES:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

old_runtime_versions() { # deletable image versions, space-separated
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

delete_old_runtimes() { # images only — bundle runtimes never reach a delete command
  local newest v uuid
  newest="$(newest_runtime_version)"
  while read -r v uuid; do
    [ -n "$v" ] || continue
    [ "$v" = "$newest" ] && continue
    is_kept_runtime "$v" && continue
    "$XCRUN" simctl runtime delete "$uuid" >/dev/null 2>&1 || true
  done <<EOF
$(ready_runtimes)
EOF
}

old_bundle_runtimes() { # bundle runtimes outside the keep rule: version<TAB>build<TAB>bundle path
  local newest v b path
  newest="$(newest_runtime_version)"
  bundle_runtimes | while IFS=$(printf '\t') read -r v b path; do
    [ "$v" = "$newest" ] && continue
    is_kept_runtime "$v" && continue
    printf '%s\t%s\t%s\n' "$v" "$b" "$path"
  done
}

mounted_images() { # hdiutil info -> mount point<TAB>image file, one line per mounted volume
  "$HDIUTIL" info 2>/dev/null | awk -F'\t' '
    /^image-path/ { img = $0; sub(/^image-path[ \t]*:[ \t]*/, "", img); next }
    /^\/dev\// && $3 != "" { print $3 "\t" img }'
}

containing_image() { # $1: path; stdin: mounted_images -> image whose volume holds $1
  awk -F'\t' -v p="$1" '
    index(p "/", $1 "/") == 1 && length($1) > best { best = length($1); img = $2 }
    END { if (best) print img }'
}

runtime_kb() { # $1: runtime bundle path -> KB it holds on disk, or "?"
  # A runtime volume is a mounted image, and du on it counts the expanded
  # contents (about twice the file). Size the image file instead, walking
  # outward while that file sits inside another mounted image (a runtime
  # bundle inside a MobileAsset image): the outermost file holds the space.
  local mounts img outer hops=0
  mounts="$(mounted_images)"
  img="$(printf '%s\n' "$mounts" | containing_image "$1")"
  if [ -z "$img" ]; then dir_kb "$1"; return 0; fi # not on a mounted image: du is honest
  while [ "$hops" -lt 4 ]; do
    outer="$(printf '%s\n' "$mounts" | containing_image "$img")"
    [ -n "$outer" ] || break
    img="$outer"
    hops=$((hops + 1))
  done
  if [ -f "$img" ]; then dir_kb "$img"; else echo "?"; fi
}

# ---------- CHECK tier ----------
# Items are enumerated dynamically; each is confirmed individually.
# check_items prints: kind<TAB>kb<TAB>path-or-cmd<TAB>note

# Stale project build artifacts: subdirectory -> CHECK kind -> regen command.
# One line per project-local build artifact we know how to rebuild. A
# candidate must also carry its tool's marker, so a folder that only shares
# the name (an env/ of config files, a Maven target/) is never offered.
PROJECT_ARTIFACT_SUBDIRS="node_modules target venv env"

project_artifact_kind() {
  case "$1" in
    node_modules) echo "node_modules" ;;
    target)       echo "rust-target" ;;
    venv|env)     echo "venv" ;;
  esac
}

project_artifact_regen() {
  case "$1" in
    node_modules) echo "npm install" ;;
    target)       echo "cargo build" ;;
    venv|env)     echo "python3 -m venv $1 && pip install -r requirements.txt" ;;
  esac
}

project_artifact_is_real() { # $1: checkout, $2: subdir -> 0 if it is that tool's artifact
  case "$2" in
    node_modules) return 0 ;;
    target)       [ -f "$1/Cargo.toml" ] ;;    # a Rust target/ sits next to Cargo.toml
    venv|env)     [ -f "$1/$2/pyvenv.cfg" ] ;; # written by python -m venv and virtualenv
    *)            return 1 ;;
  esac
}

# Checkouts that may hold project artifacts: each project dir, plus every
# linked git worktree of those repos wherever it lives (.claude/worktrees/*,
# a sibling dir, /tmp) — git knows where. Each checkout is printed once.
project_checkouts() {
  local d w
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    echo "$d"
    [ -e "$d/.git" ] || continue
    # first entry is the main checkout, which the glob already covers
    git -C "$d" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | sed 1d
  done | while IFS= read -r w; do
    [ -d "$w" ] || continue # prunable: the worktree dir is gone
    printf '%s\t%s\n' "$(cd "$w" && pwd -P)" "$w"
  done | awk -F'\t' '!seen[$1]++ { print $2 }'
}

is_linked_worktree() { # $1: dir -> 0 if a linked worktree (its .git file points into .git/worktrees/)
  [ -f "$1/.git" ] && grep -q '^gitdir: .*/worktrees/' "$1/.git" 2>/dev/null
}

worktree_summary() { # $1: dir, rest: artifact subdirs -> "worktree on <branch>, clean|uncommitted changes"
  local dir="$1" branch state sub
  shift
  branch="$(git -C "$dir" symbolic-ref -q --short HEAD 2>/dev/null || echo "detached HEAD")"
  # The artifacts on offer don't count as uncommitted work: rewrite the
  # remaining args in place, each subdir becoming an exclude pathspec.
  for sub in "$@"; do set -- "$@" ":(exclude)$sub"; shift; done
  # --no-optional-locks: status must not rewrite the index, scan is read-only
  if [ -n "$(git --no-optional-locks -C "$dir" status --porcelain -- . "$@" 2>/dev/null)" ]; then
    state="uncommitted changes"
  else
    state="clean"
  fi
  echo "worktree on $branch, $state"
}

check_items() {
  # Stale project artifacts (node_modules, Rust target/, Python venv|env):
  # checkouts with no commit on their own HEAD in STALE_DAYS days (repos) or
  # WORKTREE_STALE_DAYS days (linked worktrees, which are usually
  # short-lived). A worktree is judged by its own HEAD, not its main repo's.
  if [ -d "$PROJECTS_DIR" ]; then
    local now d sub art arts last age note limit
    now=$(date +%s)
    project_checkouts | while IFS= read -r d; do
      arts=""
      for sub in $PROJECT_ARTIFACT_SUBDIRS; do
        art="$d/$sub"
        # A symlinked artifact (worktrees often link node_modules to the main
        # checkout's) holds no space of its own; removing the link frees nothing.
        [ -d "$art" ] && [ ! -L "$art" ] || continue
        project_artifact_is_real "$d" "$sub" || continue
        arts="$arts $sub"
      done
      [ -n "$arts" ] || continue
      last=$( (cd "$d" && git log -1 --format=%ct 2>/dev/null) || true )
      [ -n "$last" ] || last=$(stat -f %m "$d" 2>/dev/null || echo "$now")
      age=$(( (now - last) / 86400 ))
      if is_linked_worktree "$d"; then
        limit="${WORKTREE_STALE_DAYS:-30}"
        [ "$age" -ge "$limit" ] || continue
        # shellcheck disable=SC2086  # $arts: fixed subdir names, split on purpose
        note="no commits in ${age}d (worktree threshold ${limit}d); $(worktree_summary "$d" $arts)"
      else
        limit="${STALE_DAYS:-90}"
        [ "$age" -ge "$limit" ] || continue
        note="no commits in ${age}d (threshold ${limit}d)"
      fi
      for sub in $arts; do
        art="$d/$sub"
        printf '%s\t%s\t%s\t%s; regen: %s\n' "$(project_artifact_kind "$sub")" \
          "$(dir_kb "$art")" "$art" "$note" "$(project_artifact_regen "$sub")"
      done
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
    node_modules|rust-target|venv|xcode-archives|dot-cache) rm -rf "${2:?}" ;;
    *) echo "gigback: unknown CHECK kind '$1' — refusing" >&2; return 1 ;;
  esac
}

# ---------- MANUAL list ----------
# Regenerable, but gigback has no sudo-free way to remove these, so it sizes
# them and says how to remove them by hand. Like the DATA tier, there is no
# delete code for these.
# manual_items prints: kind<TAB>kb<TAB>what<TAB>how to remove

manual_items() {
  local v b path
  old_bundle_runtimes | while IFS=$(printf '\t') read -r v b path; do
    [ -n "$v" ] || continue
    printf 'sim-runtime\t%s\tiOS %s (%s)\t%s\n' "$(runtime_kb "$path")" "$v" "$b" \
      "remove in Xcode → Settings → Components; Xcode re-downloads runtimes on demand"
  done
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
