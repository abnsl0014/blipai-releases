#!/bin/bash
# Writes the job summary from results.tsv, removes tokens and email addresses from every
# text file in the artifact (this repo and its artifacts are public), and fails the job
# if any check failed. Runs on the GitHub runner itself.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

redact() {
  sed -E \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<jwt>/g' \
    -e 's/((access_|refresh_)?token)=[^&" ]+/\1=<redacted>/g' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/-]+/\1<redacted>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g'
}
for f in "$OUT"/*.log "$OUT"/*.txt "$OUT"/*.tsv "$OUT"/*.events "$OUT"/*.json; do
  [ -f "$f" ] && { redact < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
done

pass=$(grep -c '^PASS' "$RESULTS" || true)
fail=$(grep -c '^FAIL' "$RESULTS" || true)
warn=$(grep -c '^WARN' "$RESULTS" || true)
skip=$(grep -c '^SKIP' "$RESULTS" || true)
harness=$(grep -c '^HARNESS' "$RESULTS" || true)
where=$(cat "$OUT/distro.txt" 2>/dev/null || distro)
{
  echo "## Blip ${TAG:-?} on $where, ${SESSION}${DESKTOP:+ ($DESKTOP)}"
  echo
  echo "**$pass passed, $fail failed, $warn warnings, $skip skipped.** Screenshots and redacted logs are in the run's artifact."
  [ "$harness" -gt 0 ] && echo && echo "**🛠️ $harness test-harness problems:** the test couldn't do these steps, so they say nothing about the app."
  echo
  echo "| | Check | Detail |"
  echo "|---|---|---|"
  while IFS=$'\t' read -r status name detail _at; do
    case "$status" in
      PASS) icon="✅" ;; FAIL) icon="❌" ;; WARN|SKIP) icon="⚠️" ;; HARNESS) icon="🛠️" ;; *) icon="ℹ️" ;;
    esac
    echo "| $icon | $name | ${detail//|/\\|} |"
  done < "$RESULTS"
} | redact >> "$GITHUB_STEP_SUMMARY"

echo "$pass passed, $fail failed, $warn warnings, $skip skipped${DESKTOP:+, $harness harness problems}"
[ "$fail" -eq 0 ] && [ "$harness" -eq 0 ]
