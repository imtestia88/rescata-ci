#!/usr/bin/env bash
# Source of truth for the PUBLIC repo imtestia88/rescata-ci (ci/interact.sh).
# Private mirror: scripts/github/interact.sh (same logic).
#
# Hardening history:
#   v1: first harness (public run #1: app ANR dialog never dismissed on tape).
#   v2: + send_action_app_error=0, emergency Wait tap, longer settles.
#   v3: wake/stayon (fixed BLACK recording), uiautomator ANR dismissal,
#       AOT compile, 40-try health loop. -> Run #3 forensics: AOT compile
#       saturated all guest vCPUs, SystemUI ANR'd and stayed wedged 30+ min
#       (health loop burned 20 min, taps landed on a dead system, frozen video).
#       v3 fallback Wait tap (540,1315) landed ABOVE the button row (real
#       center from run #1 dialog evidence: (540,1376)).
#   v4: - AOT compile REMOVED (the SystemUI killer).
#       - ANR detection via dumpsys mCurrentFocus string (cheap; uiautomator
#         dump hangs exactly when the system is degraded).
#       - Calibrated Wait tap (540,1376).
#       - SystemUI wedge recovery: adb root + killall com.android.systemui
#         (proven available: run #3 seeding via root worked while SystemUI
#         was wedged).
#       - Health loop capped at 12 tries (v3 did 2x40 tries = ~25 min of no-op).
#       - Per-tap visual probes (screencap md5 diff) logged for post-mortem.
#       - logcat tail + /data/anr traces uploaded as extra artifacts.

APP_SRC="$GITHUB_WORKSPACE/app-src"
[ -d "$APP_SRC" ] || APP_SRC="app-src"
PKG="com.rescata.app"
ACT="$PKG/.MainActivity"
TMP="/data/local/tmp"
SAVED="/storage/emulated/0/Android/data/$PKG/files/Saved"

echo "[harness] starting interaction script (v4)"

# ---- 0. Keep the display awake --------------------------------------------
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true

# ---- 1. Install the freshly built APK --------------------------------------
adb install -r "$APP_SRC/app/build/outputs/apk/debug/app-debug.apk"

# ---- 2. Silent runtime grants BEFORE first launch ---------------------------
adb shell pm grant $PKG android.permission.READ_MEDIA_IMAGES || true
adb shell pm grant $PKG android.permission.READ_MEDIA_VIDEO || true
adb shell pm grant $PKG android.permission.READ_MEDIA_AUDIO || true
adb shell pm grant $PKG android.permission.READ_MEDIA_VISUAL_USER_SELECTED || true
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
adb shell appops set --uid $PKG MANAGE_EXTERNAL_STORAGE allow || true

# ---- 3. Reduce system load / suppress system error dialogs ------------------
# NOTE: NO AOT compile here. It was removed in v4: `cmd package compile -m
# speed` pinned every guest vCPU for minutes, starved SystemUI -> permanent
# system-wide ANR wedge (run #3). Debug cold start is slower but recoverable
# via the ANR "Wait" dismissal below.
adb shell settings put global send_action_app_error 0 || true
adb shell settings put global window_animation_scale 0.0 || true
adb shell settings put global transition_animation_scale 0.0 || true
adb shell settings put global animator_duration_scale 0.0 || true
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true

# ---- 4. Cheap ANR helpers (dumpsys-based, no uiautomator) --------------------
focus_line() { timeout 15 adb shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -n1; }

anr_target() {
  echo "$1" | grep -oE 'Application Not Responding: [a-zA-Z0-9.]+' \
    | head -n1 | sed 's/Application Not Responding: //'
}

tap_wait() { adb shell input tap 540 1376 || true; }   # calibrated vs run #1 dialog

sysui_recover() {
  echo "[harness] SystemUI wedge -> root + killall com.android.systemui"
  adb root >/dev/null 2>&1 || true
  sleep 2; adb wait-for-device || true
  adb shell killall com.android.systemui || true
  sleep 10
  echo "[harness] SystemUI restarted: $(focus_line)"
}

wait_healthy() {  # cap ~2.5 min per call
  local i focus target sysui_strikes=0
  for i in $(seq 1 12); do
    focus=$(focus_line)
    target=$(anr_target "$focus")
    echo "[harness] health[$i] focus=$focus"
    if [ -n "$target" ]; then
      if [ "$target" = "com.android.systemui" ]; then
        sysui_strikes=$((sysui_strikes+1))
        tap_wait; sleep 4
        if [ "$sysui_strikes" -ge 2 ]; then sysui_recover; sysui_strikes=0; fi
        continue
      fi
      tap_wait; sleep 6; continue
    fi
    case "$focus" in
      *documentsui*) adb shell input keyevent 4 || true; sleep 2 ;;
      *$PKG*) echo "[harness] HEALTHY"; return 0 ;;
      *) sleep 5 ;;
    esac
  done
  echo "[harness] HEALTH_WAIT_TIMEOUT (continuing best-effort)"
  return 1
}

dismiss_now() {
  focus=$(focus_line)
  case "$focus" in
    *Application\ Not\ Responding*)
      echo "[harness] ANR dialog up -> tapping Wait"
      tap_wait; sleep 5 ;;
  esac
}

# ---- 5. First launch (creates Saved dir; SAF prompt may appear) --------------
adb shell am start -n $ACT
wait_healthy || true

# ---- 6. Seed the Vault with sample photos ------------------------------------
adb push ci/samples $TMP/samples || true
for f in sample-01-teal sample-02-purple sample-03-amber sample-04-coral; do
  adb shell run-as $PKG cp "$TMP/samples/$f.jpg" "$SAVED/$f.jpg" \
    && echo "[harness] seeded via run-as: $f" \
    || { adb root; sleep 3; adb wait-for-device; \
         adb push "ci/samples/$f.jpg" "$SAVED/$f.jpg" && echo "[harness] seeded via root: $f"; }
done
adb shell "ls -la $SAVED" || true
adb shell am force-stop $PKG
sleep 3

# ---- 7. Relaunch (Vault now has items) and wait until truly ready ------------
adb shell am start -n $ACT
wait_healthy || true

adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell dumpsys display | grep mScreenState | head -n1 || true
adb shell dumpsys window | grep mCurrentFocus | head -n1 || true
adb shell screencap -p $TMP/state-pre.png || true
adb pull $TMP/state-pre.png state-pre.png || true

# ---- 8. Record ----------------------------------------------------------------
adb shell "screenrecord --size 540x1170 --bit-rate 8000000 --time-limit 90 $TMP/rescata-run.mp4" &
REC_PID=$!
sleep 3

probe_hash() { adb shell screencap -p $TMP/probe.png >/dev/null 2>&1 && adb shell md5sum $TMP/probe.png | awk '{print $1}'; }
probe_tap() {  # probe_tap <x> <y> <label>: tap + verify the screen visually changed
  local before after
  before=$(probe_hash)
  adb shell input tap "$1" "$2" || true
  sleep 4
  after=$(probe_hash)
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    echo "[harness] PROBE($3): NO visual change (tap may have hit a dead system)"
  else
    echo "[harness] PROBE($3): visual change detected"
  fi
}

# Dock tabs: Statuses, Chats, Vault (floating dock, pixel_5 1080x2340)
dismiss_now
probe_tap 135 2250 "dock-Statuses"
probe_tap 405 2250 "dock-Chats"
probe_tap 675 2250 "dock-Vault"
adb shell ls "$SAVED" || true

# Open first tile, close, open tile 2
dismiss_now
probe_tap 176 620 "tile-1"
adb shell screencap -p $TMP/viewer-open.png || true
adb pull $TMP/viewer-open.png viewer-open.png || true
adb shell input keyevent 4; sleep 3      # back = close viewer
probe_tap 490 620 "tile-2"
adb shell input keyevent 4; sleep 3

# Sweep: Settings, back to Statuses, small scroll
dismiss_now
adb shell input tap 945 2250; sleep 4
adb shell input tap 135 2250; sleep 4
adb shell input swipe 540 1700 540 700 300; sleep 2
adb shell input tap 135 2250; sleep 4

wait "$REC_PID" || true

# ---- 9. Pull evidence -----------------------------------------------------------
adb pull $TMP/rescata-run.mp4 rescata-run.mp4 || true
ls -la rescata-run.mp4 viewer-open.png state-pre.png || true

# logcat tail for post-mortem (ANR reasons, blocked main threads)
adb logcat -d -t 4000 > logcat-tail.txt 2>&1 || true

# ANR traces (root images only; best-effort)
adb root >/dev/null 2>&1 || true
sleep 2; adb wait-for-device || true
mkdir -p anr-traces
adb shell "ls /data/anr/ 2>/dev/null" | tr -d '\r' | head -n 6 \
  | while read -r f; do
      [ -n "$f" ] && adb pull "/data/anr/$f" "anr-traces/$f" >/dev/null 2>&1 || true
    done
ls -la anr-traces/ 2>/dev/null || true

echo "[harness] INTERACT_DONE"
