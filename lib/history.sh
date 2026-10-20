# shellcheck shell=bash
# gigback run history: one record per scan / clean / report run, appended to
# $LOG_DIR/history.jsonl, so free space and target sizes can be compared over
# time. A single scan shows what is big; only a series shows what is growing.
#
# What a record holds: when, gigback version, the command and mode, disk free
# and total, the Time Machine local snapshot count, per-tier totals, and every
# size the run measured (tier, id, KB, path). Paths under $HOME are stored as
# "~/…". Never file contents, never Postgres database names.
#
# This file only ever appends to, trims and reads history.jsonl. It has no
# delete path for anything else, and a failure here never changes what the
# command did or its exit status.

HISTORY_FILE="$LOG_DIR/history.jsonl"
HISTORY_MAX_DEFAULT=1000      # runs kept; ~1–5 KB each, so a few MB at most
HISTORY_LAST_DEFAULT=10       # runs shown by `gigback history`
HISTORY_TOP_GROWTH=5          # growers listed by `gigback history`

HIST_BUF=""                   # this run's measurements, one TSV line each

history_enabled() {
  [ -z "${GIGBACK_NO_HISTORY:-}" ] && [ "${NO_HISTORY:-0}" = 0 ]
}

history_max() {
  case "${GIGBACK_HISTORY_MAX:-}" in
    ''|*[!0-9]*|0) echo "$HISTORY_MAX_DEFAULT" ;;
    *) echo "$GIGBACK_HISTORY_MAX" ;;
  esac
}

history_begin() { # start buffering this run's measurements
  history_enabled || return 0
  HIST_BUF="$(mktemp 2>/dev/null)" || HIST_BUF=""
  HIST_FREE_BEFORE="$(free_kb)"
}

hist_measured() { # $1: tier -> this run looked at the whole tier (a 0 total is real)
  [ -n "$HIST_BUF" ] || return 0
  printf '#\t%s\n' "$1" >> "$HIST_BUF" 2>/dev/null || true
}

hist_item() { # $1 tier, $2 id, $3 kb or "?", $4 path or description
  [ -n "$HIST_BUF" ] || return 0
  # Tabs and newlines would break the buffer's columns; no real target has them.
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\t\n' '  ')" \
    >> "$HIST_BUF" 2>/dev/null || true
}

tm_snapshot_count() { # Time Machine local snapshots on / (they hold deleted space)
  if [ -n "${GB_NO_TMUTIL:-}" ] || ! command -v tmutil >/dev/null 2>&1; then
    echo null
    return 0
  fi
  tmutil listlocalsnapshots / 2>/dev/null | grep -c '^com\.apple\.TimeMachine\.' || true
}

history_end() { # $1 command, $2 mode -> append one JSON line, then trim
  [ -n "$HIST_BUF" ] || return 0
  local total free snaps max lines
  total="$(df -k / | awk 'NR==2 {print $2}')"
  free="$(free_kb)"
  snaps="$(tm_snapshot_count)"
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    awk -F'\t' -v ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -v epoch="$(date +%s)" \
        -v ver="$VERSION" -v cmd="$1" -v mode="$2" -v free="$free" -v total="$total" \
        -v before="${HIST_FREE_BEFORE:-}" -v snaps="$snaps" -v home="$GB_HOME/" '
      function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
      function rel(p) { return (index(p, home) == 1) ? "~/" substr(p, length(home) + 1) : p }
      $1 == "#" { measured[$2] = 1; next }
      {
        tier = $1; measured[tier] = 1
        kb = ($3 ~ /^[0-9]+$/) ? $3 : "null"
        if (kb != "null") sum[tier] += kb
        items = items (n++ ? "," : "") \
          sprintf("{\"tier\":\"%s\",\"id\":\"%s\",\"kb\":%s,\"path\":\"%s\"}", tier, esc($2), kb, esc(rel($4)))
      }
      END {
        split("SAFE CHECK MANUAL DATA", order, " ")
        tiers = ""
        for (i = 1; i <= 4; i++) {
          t = order[i]
          v = (t in measured) ? (sum[t] + 0) : "null"
          tiers = tiers (i > 1 ? "," : "") sprintf("\"%s\":%s", t, v)
        }
        printf "{\"ts\":\"%s\",\"epoch\":%s,\"version\":\"%s\",\"cmd\":\"%s\",\"mode\":\"%s\",", ts, epoch, ver, cmd, mode
        printf "\"disk\":{\"total_kb\":%s,\"free_kb\":%s", total, free
        if (before ~ /^[0-9]+$/) printf ",\"free_before_kb\":%s", before
        printf "},\"tm_local_snapshots\":%s,\"tiers\":{%s},\"items\":[%s]}\n", snaps, tiers, items
      }' "$HIST_BUF" >> "$HISTORY_FILE" 2>/dev/null || true
    max="$(history_max)"
    lines="$(wc -l < "$HISTORY_FILE" 2>/dev/null | tr -d ' ')"
    if [ "${lines:-0}" -gt "$max" ]; then
      if tail -n "$max" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" 2>/dev/null; then
        mv "$HISTORY_FILE.tmp" "$HISTORY_FILE" 2>/dev/null
      fi
      rm -f "$HISTORY_FILE.tmp"
    fi
  fi
  rm -f "$HIST_BUF"
  HIST_BUF=""
}

# ---------- reading it back ----------

cmd_history() {
  if [ ! -s "$HISTORY_FILE" ]; then
    if [ "$JSON" = 1 ]; then echo "[]"; return 0; fi
    echo "gigback: no history yet ($HISTORY_FILE)."
    echo "Every scan, clean and report adds one record; run 'gigback scan' a few times over a day."
    return 0
  fi
  local last="${HISTORY_LAST:-$HISTORY_LAST_DEFAULT}" recent
  recent="$(tail -n "$last" "$HISTORY_FILE")"

  if [ "$JSON" = 1 ]; then
    printf '%s\n' "$recent" | awk 'BEGIN { printf "[" } { printf "%s%s", (NR > 1 ? "," : ""), $0 } END { print "]" }'
    return 0
  fi

  printf '%s\n' "$recent" | awk -v top="$HISTORY_TOP_GROWTH" -v file="$HISTORY_FILE" '
    function num(key, s,   m) {          # "key":<number> -> number, or "" when null/absent
      if (match(s, "\"" key "\":[0-9]+")) return substr(s, RSTART + length(key) + 3, RLENGTH - length(key) - 3) + 0
      return ""
    }
    function str(key, s) {
      if (match(s, "\"" key "\":\"[^\"]*\"")) return substr(s, RSTART + length(key) + 4, RLENGTH - length(key) - 5)
      return ""
    }
    function human(kb,   a, sign) {
      if (kb == "") return "-"
      sign = kb < 0 ? "-" : ""; a = kb < 0 ? -kb : kb
      if (a >= 1048576) return sprintf("%s%.1f GB", sign, a / 1048576)
      if (a >= 1024) return sprintf("%s%.1f MB", sign, a / 1024)
      return sprintf("%s%d KB", sign, a)
    }
    function span(sec,   h, m) { h = int(sec / 3600); m = int((sec % 3600) / 60); return (h ? h "h " : "") m "m" }
    function items_of(s, r,   rest, it, key, kb) {   # fills r[tier SUBSEP id SUBSEP path] = kb
      rest = s
      while (match(rest, /\{"tier":"[^"]*","id":"[^"]*","kb":(null|[0-9]+),"path":"([^"\\]|\\.)*"\}/)) {
        it = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        kb = num("kb", it)
        if (kb == "") continue
        key = str("tier", it) SUBSEP str("id", it) SUBSEP str("path", it)
        r[key] = kb
      }
    }
    { line[NR] = $0 }
    END {
      n = NR
      printf "gigback history — last %d run%s (%s)\n\n", n, (n == 1 ? "" : "s"), file
      printf "%-17s %-13s %9s %9s %9s %9s %9s  %s\n", "WHEN (UTC)", "COMMAND", "FREE", "SAFE", "CHECK", "MANUAL", "DATA", "TM SNAPSHOTS"
      for (i = 1; i <= n; i++) {
        s = line[i]; when = str("ts", s); sub(/T/, " ", when); sub(/:[0-9][0-9]Z$/, "", when)
        cmd = str("cmd", s); mode = str("mode", s); if (mode != "") cmd = cmd " " mode
        snaps = num("tm_local_snapshots", s)
        printf "%-17s %-13s %9s %9s %9s %9s %9s  %s\n", when, cmd, human(num("free_kb", s)),
          human(num("SAFE", s)), human(num("CHECK", s)), human(num("MANUAL", s)), human(num("DATA", s)),
          (snaps == "" ? "-" : snaps)
      }
      if (n < 2) { print "\nRun gigback again later to see a trend."; exit }

      a = line[1]; b = line[n]
      dt = num("epoch", b) - num("epoch", a)
      dfree = num("free_kb", b) - num("free_kb", a)
      printf "\nFree space: %s -> %s over %s", human(num("free_kb", a)), human(num("free_kb", b)), span(dt)
      if (dt >= 600) printf " (%s per hour)", human(int(dfree * 3600 / dt))
      printf "\n"

      items_of(a, A); items_of(b, B)
      net = 0; m = 0
      for (k in B) if (k in A) { d = B[k] - A[k]; net += d; if (d > 0) { grow[++m] = d; gkey[m] = k } }
      # largest first (m is small; a simple selection sort keeps this bash-3.2/BSD-awk friendly)
      for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (grow[j] > grow[i]) {
        t = grow[i]; grow[i] = grow[j]; grow[j] = t; t = gkey[i]; gkey[i] = gkey[j]; gkey[j] = t }

      printf "\nGrew most between the first and last run shown (items both runs measured):\n"
      if (m == 0) print "  nothing measured in both runs grew."
      for (i = 1; i <= m && i <= top; i++) {
        split(gkey[i], p, SUBSEP)
        printf "  +%-9s %-7s %-14s %s\n", substr(human(grow[i]), 1), p[1], p[2], p[3]
      }
      if (dfree < -102400) {   # under 100 MB is ordinary disk churn
        outside = -dfree - net
        printf "\nFree space fell %s; what both runs measured changed by %s.\n", human(-dfree), human(net)
        if (outside > 1048576)
          printf "About %s went somewhere gigback does not measure (Time Machine local snapshots,\nsystem updates, other folders). Snapshots: %s -> %s.\n",
            human(outside), (num("tm_local_snapshots", a) == "" ? "-" : num("tm_local_snapshots", a)),
            (num("tm_local_snapshots", b) == "" ? "-" : num("tm_local_snapshots", b))
      }
    }'
}
