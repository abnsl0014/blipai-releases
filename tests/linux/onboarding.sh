#!/bin/bash
# GNOME and KDE jobs (sourced by run-app.sh, signed in, onboarding window up): the rest of the
# onboarding, screen by screen, as a new user goes through it, pressing its buttons over
# AT-SPI. On the Linux setup screen that includes "Allow Blip to paste": the app asks the
# desktop's RemoteDesktop portal, and the test answers the desktop's own dialog over AT-SPI
# as a person would (GNOME: turn on "Allow Remote Interaction", then Share; KDE: Approve).
# Nothing about the portal is bypassed: the grant and its restore token are the desktop's.

ui_now() {  # ui_now NAME → the onboarding's text, one element per line
  ui_dump "$1" > /dev/null 2>&1
  grep -v '^== window' "$OUT/ui-$1.txt" 2> /dev/null
}
wait_screen() {  # wait_screen NAME SECONDS PATTERN → 0 once the UI shows PATTERN (ERE)
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ui_now "$1" | grep -qiE -- "$3" && return 0
    sleep 1
  done
  return 1
}
portal_dialog() { with_timeout 30 "$PY" "$here/atspi.py" portal-dialog 2> /dev/null; }
rd_token_file() { local d; d=$(app_userdata); [ -n "$d" ] && [ -s "$d/wayland-remotedesktop.json" ] && echo "$d/wayland-remotedesktop.json"; }

onboarding_walk() {
  local screens=() step title i dlg how
  if ! wait_screen onboarding-privacy 30 'we value your privacy|stays private'; then
    record FAIL "Onboarding: privacy screen after sign-in" "the onboarding didn't move on after sign-in: $(ui_now onboarding-privacy | head -n 6 | paste -sd'|' | cut -c1-200)"
    return 1
  fi
  screens+=(privacy)
  press "Continue" > /dev/null

  # The Linux setup screen, one step at a time. Expected here: only "Allow Blip to paste"
  # (the hotkey reads the keyboard through the input group; wl-clipboard is installed).
  if wait_screen onboarding-setup 30 'Allow Blip to paste|Let Blip hear|Install the paste helper|Speak to test your microphone'; then
    for i in 1 2 3 4; do
      title=$(grep -m1 -iE '^(Allow Blip to paste|Let Blip hear your shortcut|Install the paste helper)$' "$OUT/ui-onboarding-setup.txt")
      [ -z "$title" ] && break
      screens+=("setup: $title")
      record INFO "Onboarding: $(grep -m1 '^Setting up Blip for' "$OUT/ui-onboarding-setup.txt" | cut -c1-80) step" "$title: $(grep -A1 -xF "$title" "$OUT/ui-onboarding-setup.txt" | tail -n 1 | cut -c1-200)"
      if [ "$title" = "Allow Blip to paste" ]; then
        grant_paste_permission || return 1
      else
        record WARN "Onboarding: setup step \"$title\"" "shown though this computer is set up for it (the test skips it, as a user could): $(grep -A1 -xF "$title" "$OUT/ui-onboarding-setup.txt" | tail -n 1 | cut -c1-160)"
        press "Skip this step" > /dev/null
      fi
      sleep 2
      wait_screen onboarding-setup 20 'Allow Blip to paste|Let Blip hear|Install the paste helper|Speak to test your microphone' || break
    done
  fi
  if [ ! "$(rd_token_file)" ] && ! printf '%s\n' "${screens[@]}" | grep -q 'Allow Blip to paste'; then
    record FAIL "Onboarding asks for the paste permission (${XDG_CURRENT_DESKTOP})" "no \"Allow Blip to paste\" step: $(printf '%s, ' "${screens[@]}")"
  fi

  if wait_screen onboarding-mic 30 'Speak to test your microphone'; then
    screens+=(microphone)
    speak "Testing the virtual microphone."
    press "Yes, continue" > /dev/null
  fi
  wait_screen onboarding-hotkey 20 'Your push-to-talk key' && { screens+=(hotkey); press "Continue" > /dev/null; }
  wait_screen onboarding-try 20 'Dictate the message into the textbox' && { screens+=(try); press "Continue" > /dev/null; }
  wait_screen onboarding-action 20 'Hey Blip' && { screens+=("action mode"); press "Skip for now" > /dev/null; }
  if wait_screen onboarding-complete 20 "You're all set"; then
    screens+=(done)
    screenshot onboarding-complete
    press "Get Started" > /dev/null
    sleep 4
    record PASS "Onboarding: every screen through Get Started" "$(printf '%s → ' "${screens[@]}" | sed 's/ → $//'); windows now: $(app_windows)"
  else
    record FAIL "Onboarding: every screen through Get Started" "stopped after: $(printf '%s → ' "${screens[@]}" | sed 's/ → $//'); showing: $(ui_now onboarding-stuck | head -n 6 | paste -sd'|' | cut -c1-200)"
  fi
}

grant_paste_permission() {
  local dlg how said deadline FAIL=FAIL
  [ -f "$OUT/.portal-broken" ] && FAIL=HARNESS   # the portal didn't answer the test's own probe either
  press "Allow" > "$OUT/onboarding-allow-press.txt"
  # The desktop's dialog (xdg-desktop-portal-gnome's "Remote Desktop" / -kde's "Remote Control").
  dlg=""
  deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do dlg=$(portal_dialog) && break; dlg=""; sleep 1; done
  screenshot portal-dialog
  if [ -z "$dlg" ]; then
    said=$(ui_now onboarding-allow | grep -iE 'window that opens|didn.t work|cancel|done' | head -n 2 | paste -sd'|')
    if grep -q 'RemoteDesktop' "$OUT/portal-dbus.log" 2> /dev/null; then
      record $FAIL "Onboarding: Allow opens the desktop's paste dialog" "the app asked the RemoteDesktop portal but no dialog appeared within 30 s; onboarding says: ${said:-nothing}; portal calls: $(grep -oE 'member=(CreateSession|SelectDevices|Start)' "$OUT/portal-dbus.log" | sort | uniq -c | xargs)"
    else
      record $FAIL "Onboarding: Allow opens the desktop's paste dialog" "the app made no RemoteDesktop portal call within 30 s of Allow ($(cat "$OUT/onboarding-allow-press.txt")); onboarding says: ${said:-nothing}"
    fi
    return 1
  fi
  record PASS "Onboarding: Allow opens the desktop's paste dialog" "$(cut -c1-250 <<< "$dlg")"
  # The onboarding tells the user: "Click Allow, then choose Share or Allow in the window that opens."
  if grep -q 'Share, greyed out' <<< "$dlg"; then
    record WARN "Onboarding's paste instructions match the dialog" "GNOME's dialog keeps Share greyed out until \"Allow Remote Interaction\" is switched on; the onboarding only says \"choose Share or Allow\""
  elif ! grep -qE '\((Share|Allow)\)' <<< "$dlg"; then
    record WARN "Onboarding's paste instructions match the dialog" "the onboarding says \"choose Share or Allow\", but this dialog's buttons are: $(grep -oE '\([^)]*\)' <<< "$dlg" | paste -sd' ')"
  fi
  how=$(with_timeout 30 "$PY" "$here/atspi.py" portal-approve 2>&1)
  record INFO "Paste dialog answered (AT-SPI, as a person would)" "$how"
  if wait_until 20 rd_token_file; then
    record PASS "Paste permission granted" "the portal granted the keyboard and the app saved its restore token; onboarding: $(ui_now onboarding-granted | grep -m1 -iE 'done|speak to test' )"
  else
    record $FAIL "Paste permission granted" "no restore token saved 20 s after \"$how\"; onboarding says: $(ui_now onboarding-granted | grep -iE 'window that opens|didn.t work|cancel|done' | head -n 2 | paste -sd'|'); portal responses: $(grep -A1 'member=Response' "$OUT/portal-dbus.log" | grep -oE 'uint32 [0-9]+' | paste -sd' ')"
    return 1
  fi
}

# A portal dialog after onboarding means the desktop asked again (the restore token wasn't
# used or didn't hold). A person would answer it again; so does this, and notes it.
start_portal_watch() {
  (
    while sleep 1.5; do
      d=$(with_timeout 20 "$PY" "$here/atspi.py" portal-dialog 2> /dev/null) || continue
      echo "$(date +%T) $d" >> "$OUT/portal-dialogs-later.log"
      screenshot portal-dialog-again
      with_timeout 20 "$PY" "$here/atspi.py" portal-approve >> "$OUT/portal-dialogs-later.log" 2>&1
      sleep 3
    done
  ) > /dev/null 2>&1 &
  PORTAL_WATCH_PID=$!
}
report_portal_watch() {
  [ -n "${PORTAL_WATCH_PID:-}" ] && kill "$PORTAL_WATCH_PID" 2> /dev/null
  if [ -s "$OUT/portal-dialogs-later.log" ]; then
    local sent  # SelectDevices calls that carried a restore token
    sent=$(awk '/^(method call|signal|method return|error) /{blk=/member=SelectDevices/} blk && /restore_token/{n++} END{print n+0}' "$OUT/portal-dbus.log" 2> /dev/null)
    if [ "${sent:-0}" -gt 0 ]; then
      record WARN "Paste permission is remembered" "the desktop asked again although the app passed its restore token: $(head -n 1 "$OUT/portal-dialogs-later.log" | cut -c1-200)"
    else
      record FAIL "Paste permission is remembered" "the desktop asked again; the app didn't pass a restore token: $(head -n 1 "$OUT/portal-dialogs-later.log" | cut -c1-200)"
    fi
  else
    record PASS "Paste permission is remembered" "no portal dialog after onboarding, across a relaunch"
  fi
}
