#!/usr/bin/env bash
# ci/interact.sh - drives the app on the CI emulator and records the screen.
# Runs INSIDE android-emulator-runner (emulator booted, adb ready).
# The app source was cloned into ../app-src by an earlier workflow step.
# Single-line safe: this file IS the entry point (bash ci/interact.sh).

# App source clone location (relative to repo root = $GITHUB_WORKSPACE)
APP_SRC="$GITHUB_WORKSPACE/app-src"
[ -d "$APP_SRC" ] || APP_SRC="app-src"

echo "[harness] starting interaction script"

# ---- 0. Install the freshly built APK ------------------------------------
adb install -r "$APP_SRC/app/build/outputs/apk/debug/app-debug.apk"

# ---- 1. Silent runtime grants BEFORE first launch ------------------------
adb shell pm grant com.rescata.app android.permission.READ_MEDIA_IMAGES || true
adb shell pm grant com.rescata.app android.permission.READ_MEDIA_VIDEO || true
adb shell pm grant com.rescata.app android.permission.READ_MEDIA_AUDIO || true
adb shell pm grant com.rescata.app android.permission.READ_MEDIA_VISUAL_USER_SELECTED || true
adb shell pm grant com.rescata.app android.permission.POST_NOTIFICATIONS || true
adb shell appops set --uid com.rescata.app MANAGE_EXTERNAL_STORAGE allow || true

# Suppress ANR/crash system dialogs (software-rendered emulator is slow on
# cold start; the dialog would contaminate the recording).
adb shell settings put global send_action_app_error 0 || true

# Emergency "Wait" tap if an ANR dialog still appears (centered dialog,
# Wait row ~y=1270 on 1080x2340).
wait_anr() {
  adb shell input tap 540 1270 || true
}

# ---- 2. First launch (creates Saved dir; SAF prompt may appear) ----------
adb shell am start -W -n com.rescata.app/.MainActivity
sleep 14
wait_anr                       # dismiss any ANR with "Wait"
sleep 4
adb shell input keyevent 4     # dismiss SAF folder picker if it appeared
sleep 2
adb shell input keyevent 4
sleep 2

# ---- 3. Seed the Vault with sample photos --------------------------------
adb push ci/samples /data/local/tmp/samples || true
SAVED="/storage/emulated/0/Android/data/com.rescata.app/files/Saved"
for f in sample-01-teal sample-02-purple sample-03-amber sample-04-coral; do
  adb shell run-as com.rescata.app cp "/data/local/tmp/samples/$f.jpg" "$SAVED/$f.jpg" \
    && echo "[harness] seeded via run-as: $f" \
    || { adb root; sleep 3; adb wait-for-device; \
         adb push "ci/samples/$f.jpg" "$SAVED/$f.jpg" && echo "[harness] seeded via root: $f"; }
done
adb shell "ls -la $SAVED" || true
adb shell am force-stop com.rescata.app
sleep 2

# ---- 4. Relaunch (Vault now has items) and record ------------------------
adb shell am start -W -n com.rescata.app/.MainActivity
sleep 16
wait_anr
sleep 4

adb shell "screenrecord --time-limit 100 /data/local/tmp/rescata-run.mp4" &
REC_PID=$!
sleep 3

# Dock tabs: Statuses, Chats, Vault, Settings (floating dock, pixel_5 1080x2340)
adb shell input tap 135 2250; sleep 4
adb shell input tap 405 2250; sleep 4
adb shell input tap 675 2250; sleep 4    # Vault
adb shell ls "$SAVED" || true

# Open first tile (estimated grid item 1), close, open tile 2
adb shell input tap 176 620; sleep 5     # viewer opens over grid
adb shell screencap -p /data/local/tmp/viewer-open.png || true
adb shell input keyevent 4; sleep 3      # back = close viewer
adb shell input tap 490 620; sleep 5     # second tile
adb shell input keyevent 4; sleep 3

# Sweep the rest: Settings, back to Statuses, small scroll
adb shell input tap 945 2250; sleep 4
adb shell input tap 135 2250; sleep 4
adb shell input swipe 540 1700 540 700 300; sleep 2
adb shell input tap 135 2250; sleep 4

wait "$REC_PID" || true

# ---- 5. Pull evidence ------------------------------------------------------
adb pull /data/local/tmp/rescata-run.mp4 rescata-run.mp4 || true
adb pull /data/local/tmp/viewer-open.png viewer-open.png || true
ls -la rescata-run.mp4 viewer-open.png || true
echo "[harness] INTERACT_DONE"
