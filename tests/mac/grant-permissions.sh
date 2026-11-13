#!/bin/bash
# Grants the app the macOS privacy permissions a person grants in System Settings
# during onboarding: Microphone, Accessibility, Input Monitoring (for the Fn key
# listener) and Automation of System Events (for the paste keystroke and the
# frontmost-app lookup). A person clicks Allow; the runner writes the same rows into
# the TCC databases, which GitHub's Mac images allow because SIP is off there. This
# is the one step that differs from a real install; everything after it is the app's
# own behavior.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

record INFO "System Integrity Protection" "$(csrutil status 2>&1 | head -n 1)"

system_db="/Library/Application Support/com.apple.TCC/TCC.db"
user_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
now=$(date +%s)

grant() {  # grant DB SERVICE CLIENT CLIENT_TYPE [APPLE_EVENTS_TARGET]
  local db="$1" service="$2" client="$3" client_type="$4" target="${5:-UNUSED}"
  local sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason,
      auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
      indirect_object_code_identity, flags, last_modified)
    VALUES ('$service', '$client', $client_type, 2, 4, 1, NULL, NULL, 0, '$target', NULL, 0, $now);"
  if [ "$db" = "$system_db" ]; then sudo sqlite3 "$db" "$sql"; else sqlite3 "$db" "$sql"; fi
}

failed=()
for service in kTCCServiceMicrophone kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent; do
  grant "$system_db" "$service" "$BUNDLE_ID" 0 || failed+=("system $service")
done
grant "$user_db" kTCCServiceMicrophone "$BUNDLE_ID" 0 || failed+=("user kTCCServiceMicrophone")
grant "$user_db" kTCCServiceAppleEvents "$BUNDLE_ID" 0 com.apple.systemevents || failed+=("user kTCCServiceAppleEvents")
# MacKeyServer is a separate signed binary the app spawns; grant it by path as well,
# in case macOS attributes its event tap to itself rather than to the app.
if [ -n "${KEY_SERVER:-}" ]; then
  for service in kTCCServiceListenEvent kTCCServiceAccessibility kTCCServicePostEvent; do
    grant "$system_db" "$service" "$KEY_SERVER" 1 || failed+=("system $service (MacKeyServer)")
  done
fi

# Make tccd re-read the databases.
sudo killall tccd 2>/dev/null || true
killall tccd 2>/dev/null || true

{
  echo "--- system ---"
  sudo sqlite3 "$system_db" "SELECT service, client, auth_value FROM access WHERE client LIKE '%blipai%' OR client LIKE '%MacKeyServer%';"
  echo "--- user ---"
  sqlite3 "$user_db" "SELECT service, client, auth_value, indirect_object_identifier FROM access WHERE client LIKE '%blipai%';"
} > "$OUT/tcc-grants.txt" 2>&1
cat "$OUT/tcc-grants.txt"

if [ ${#failed[@]} -eq 0 ]; then
  record PASS "Grant Microphone, Accessibility, Input Monitoring, Automation" "$(grep -c '|2' "$OUT/tcc-grants.txt") rows"
else
  record FAIL "Grant Microphone, Accessibility, Input Monitoring, Automation" "could not write: ${failed[*]}"
fi
exit 0
