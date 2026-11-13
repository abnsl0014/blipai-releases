#!/bin/bash
# Writes the job summary from results.tsv, removes tokens and email addresses from every
# text file in the artifact (this repo and its artifacts are public), and fails the job
# if any check failed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

redact() {
  sed -E \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<jwt>/g' \
    -e 's/((access_|refresh_)?token)=[^&" ]+/\1=<redacted>/g' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/-]+/\1<redacted>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'
}

log=$(app_log)
[ -n "$log" ] && redact < "$log" > "$OUT/main.log"
# Signed-in window text (ui-*.txt) and the results file can show the account too.
for f in "$OUT"/*.log "$OUT"/*.txt "$OUT"/*.tsv; do
  [ -f "$f" ] && { redact < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
done

pass=$(grep -c '^PASS' "$RESULTS" || true)
fail=$(grep -c '^FAIL' "$RESULTS" || true)
warn=$(grep -c '^WARN' "$RESULTS" || true)
skip=$(grep -c '^SKIP' "$RESULTS" || true)
{
  echo "## Blip ${TAG:-?} on $(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
  echo
  echo "**$pass passed, $fail failed, $warn warnings, $skip skipped.** Screenshots and redacted logs are in the run's artifact."
  echo
  echo "| | Check | Detail |"
  echo "|---|---|---|"
  while IFS=$'\t' read -r status name detail; do
    case "$status" in
      PASS) icon="✅" ;; FAIL) icon="❌" ;; WARN|SKIP) icon="⚠️" ;; *) icon="ℹ️" ;;
    esac
    detail="${detail//|/\\|}"
    echo "| $icon | $name | $detail |"
  done < "$RESULTS"
} | redact >> "$GITHUB_STEP_SUMMARY"

echo "$pass passed, $fail failed, $warn warnings, $skip skipped"
[ "$fail" -eq 0 ]
