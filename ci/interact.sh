#!/usr/bin/env bash
# Source of truth for the PUBLIC repo imtestia88/rescata-ci (ci/interact.sh).
# Private mirror: scripts/github/interact.sh (same logic, private paths).
# Hardening v3 history:
#   v1: first working harness (public run #1).
#   v2: + send_action_app_error=0, emergency Wait tap, longer settles.
#   v3: wake screen + stayon (run #2 recorded BLACK: screen was off),
#       wait_healthy poll (app foreground + no ANR dialog before acting),
#       uiautomator-based ANR "Wait" dismissal, AOT compile of the debug
#       APK (debug builds verify at runtime: 20s+ cold start), lighter
#       recording (540x1170 @ 8Mbps), state-pre.png evidence artifact.

APP_SRC="$GITHUB_WORKSPACE/app-src"
[ -d "$APP_SRC" ] || APP_SRC="app-src"
PKG="com.rescata.app"
ACT="$PKG/.MainActivity"
TMP="/data/local/tmp"
SAVED="/storage/emulated/0/Android/data/$PKG/files/Saved"

echo "[harness] starting interaction script"

# ---- 0. Keep the display awake (BLACK recordings = screen was off) -------
adb shell svc power stayon true || true
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true

# ---- 1. Install the freshly built APK ------------------------------------
adb install -r "$APP_SRC/app/build/outputs/apk/debug/app-debug.apk"

# ---- 2. Silent runtime grants BEFORE first launch ------------------------
adb shell pm grant $PKG android.permission.READ_MEDIA_IMAGES || true
adb shell pm grant $PKG android.permission.READ_MEDIA_VIDEO || true
adb shell pm grant $PKG android.permission.READ_MEDIA_AUDIO || true
adb shell pm grant $PKG android.permission.READ_MEDIA_VISUAL_USER_SELECTED || true
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
adb shell appops set --uid $PKG MANAGE_EXTERNAL_STORAGE allow || true

# ---- 3. Reduce system load / suppress system error dialogs ---------------
adb shell settings put global send_action_app_error 0 || true
adb shell settings put global window_animation_scale 0.0 || true
adb shell settings put global transition_animation_scale 0.0 || true
adb shell settings put global animator_duration_scale 0.0 || true
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true
# Full AOT compile so the first launch is fast (otherwise 20s+ cold start)
adb shell cmd package compile -m speed -f $PKG || true

# ---- 4. Guards: ANR dialog detection + dismissal -------------------------
dismiss_now() {
  if anr_present; then tap_wait_btn; sleep 3; fi
}
anr_present() {
  timeout 25 adb shell uiautomator dump $TMP/ui.xml >/dev/null 2>&1 || return 1
  timeout 20 adb pull $TMP/ui.xml /tmp/ui.xml >/dev/null 2>&1 || return 1
  grep -q "responding" /tmp/ui.xml
}
tap_wait_btn() {
  seg=$(grep -o '<node[^>]*text="Wait"[^>]*>' /tmp/ui.xml | head -n1)
  b=$(echo "$seg" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -n1 | grep -oE '[0-9]+,[0-9]+')
  x1=$(echo "$b" | sed -n '1p' | cut -d, -f1)
  y1=$(echo "$b" | sed -n '1p' | cut -d, -f2)
  x2=$(echo "$b" | sed -n '2p' | cut -d, -f1)
  y2=$(echo "$b" | sed -n '2p' | cut -d, -f2)
  if [ -n "$x1" ] && [ -n "$x2" ]; then
    adb shell input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 )) || true
  else
    adb shell input tap 540 1315 || true
  fi
}
# Loop until the app is foreground with no ANR dialog and no folder picker.
wait_healthy() {
  local i focus
  for i in $(seq 1 40); do
    focus=$(timeout 20 adb shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -n1)
    echo "[harness] health[$i] focus=$focus"
    case "$focus" in
      *documentsui*)
        adb shell input keyevent 4 || true; sleep 2; continue ;;
      *$PKG*)
        if anr_present; then
          echo "[harness] ANR dialog over app -> tapping Wait"
          tap_wait_btn; sleep 5; continue
        fi
        echo "[harness] HEALTHY: app foreground, no dialogs"; return 0 ;;
    esac
    if anr_present; then
      echo "[harness] ANR dialog up -> tapping Wait"
      tap_wait_btn; sleep 5; continue
    fi
    sleep 4
  done
  echo "[harness] HEALTH_WAIT_TIMEOUT (continuing best-effort)"
  return 1
}

# ---- 5. First launch (creates Saved dir; SAF prompt may appear) ----------
adb shell am start -n $ACT
wait_healthy || true

# ---- 6. Seed the Vault with sample photos --------------------------------
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

# ---- 7. Relaunch (Vault now has items) and wait until truly ready --------
adb shell am start -n $ACT
wait_healthy || true

adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell dumpsys display | grep mScreenState | head -n1 || true
adb shell dumpsys window | grep mCurrentFocus | head -n1 || true
adb shell screencap -p $TMP/state-pre.png || true
adb pull $TMP/state-pre.png state-pre.png || true

# ---- 8. Record (smaller capture = far less CPU on software rendering) ----
adb shell "screenrecord --size 540x1170 --bit-rate 8000000 --time-limit 90 $TMP/rescata-run.mp4" &
REC_PID=$!
sleep 3

# Dock tabs: Statuses, Chats, Vault (floating dock, pixel_5 1080x2340)
dismiss_now
adb shell input tap 135 2250; sleep 4
adb shell input tap 405 2250; sleep 4
adb shell input tap 675 2250; sleep 4    # Vault
adb shell ls "$SAVED" || true

# Open first tile, close, open tile 2
dismiss_now
adb shell input tap 176 620; sleep 5     # viewer opens over grid
adb shell screencap -p $TMP/viewer-open.png || true
adb pull $TMP/viewer-open.png viewer-open.png || true
adb shell input keyevent 4; sleep 3      # back = close viewer
adb shell input tap 490 620; sleep 5     # second tile
adb shell input keyevent 4; sleep 3

# Sweep: Settings, back to Statuses, small scroll
dismiss_now
adb shell input tap 945 2250; sleep 4
adb shell input tap 135 2250; sleep 4
adb shell input swipe 540 1700 540 700 300; sleep 2
adb shell input tap 135 2250; sleep 4

wait "$REC_PID" || true

# ---- 9. Pull evidence ------------------------------------------------------
adb pull $TMP/rescata-run.mp4 rescata-run.mp4 || true
ls -la rescata-run.mp4 viewer-open.png state-pre.png || true
echo "[harness] INTERACT_DONE"
