#!/usr/bin/env bash
# Source of truth for the PUBLIC repo imtestia88/rescata-ci (ci/interact.sh).
# Private mirror: scripts/github/interact.sh (same logic).
#
# Hardening history:
#   v1: first harness (public run #1: app ANR dialog never dismissed on tape).
#   v2: + send_action_app_error=0, emergency Wait tap, longer settles.
#   v3: wake/stayon, uiautomator ANR dismissal, AOT compile, 40-try health
#       loop. -> Run #3 forensics: AOT compile saturated all guest vCPUs,
#       SystemUI ANR'd and stayed wedged 30+ min, frozen video.
#   v4: AOT REMOVED; dumpsys-based ANR detection (uiautomator hangs exactly
#       when the system is degraded); calibrated Wait tap (540,1376 from run
#       #1 dialog evidence; v3 fallback (540,1315) landed ABOVE the button);
#       SystemUI wedge recovery (adb root + killall); health loop capped 12.
#   v5: -cores 4 + emulator-boot-timeout 1500 (v4's -cores 2 broke boot
#       timeout - run #4). Run #5: taps WORKED (probes + viewer-open.png with
#       photo 1/4, NO dialog) but MP4 = 0 bytes (host-side bg screenrecord
#       killed without flushing).
#   v6: device-side nohup screenrecord + SIGINT clean stop + size check +
#       60s retry. *** REGRESSION ***: after a workspace wipe restored the
#       v3 file, v6 was edited on top of it and re-introduced AOT + 40-try
#       loops + uiautomator (run #6 wedged SystemUI again -> 60-min cancel).
#       LESSON: after any restore, grep the file for forbidden patterns
#       before pushing (see FORBIDDEN markers below).
#   v7: correct v4 base + v6 recorder + time cuts for the 60-min budget:
#       - single app launch (seed BEFORE first start; root push creates the
#         Saved dir - proven in runs #3/#5/#6), no force-stop/relaunch cycle
#         (saved ~8-10 min of ANR-prone cold start)
#       - screencap-based probes removed (cost ~40s each when wedged; the
#         artifacts themselves are the verification)
#       - logcat tail 1500 lines, trimmed sleeps
#       FORBIDDEN in this file: "cmd package compile", "uiautomator",
#       "seq 1 40". Verify with rg before every push.

APP_SRC="$GITHUB_WORKSPACE/app-src"
[ -d "$APP_SRC" ] || APP_SRC="app-src"
PKG="com.rescata.app"
ACT="$PKG/.MainActivity"
TMP="/data/local/tmp"
SAVED="/storage/emulated/0/Android/data/$PKG/files/Saved"

echo "[harness] starting interaction script (v7)"

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
# NOTE: NO AOT compile. It saturates all guest vCPUs, starves SystemUI and
# wedges the whole system (runs #3 and #6). Debug cold start is slower but
# recoverable via the ANR "Wait" dismissal below.
adb shell settings put global send_action_app_error 0 || true
adb shell settings put global window_animation_scale 0.0 || true
adb shell settings put global transition_animation_scale 0.0 || true
adb shell settings put global animator_duration_scale 0.0 || true
adb shell settings put global package_verifier_enable 0 || true
adb shell settings put global verifier_verify_adb_installs 0 || true

# ---- 4. Cheap ANR helpers (dumpsys-based) ------------------------------------
focus_line() { timeout 10 adb shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -n1; }

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
  sleep 8
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

# ---- 5. Seed the Vault BEFORE first launch (v7: no throwaway cold start) ----
# Runs #3/#5/#6 proved seeding via root push works; adb root + mkdir -p
# creates the dir, so the app can start ONCE with content already there.
adb root >/dev/null 2>&1 || true
sleep 2; adb wait-for-device || true
adb shell mkdir -p "$SAVED" || true
adb push ci/samples $TMP/samples || true
for f in sample-01-teal sample-02-purple sample-03-amber sample-04-coral; do
  adb push "ci/samples/$f.jpg" "$SAVED/$f.jpg" \
    && echo "[harness] seeded via root: $f" \
    || { adb shell run-as $PKG cp "$TMP/samples/$f.jpg" "$SAVED/$f.jpg" \
         && echo "[harness] seeded via run-as: $f"; }
done
adb shell "ls -la $SAVED" || true

# ---- 6. The only launch + wait until truly ready -----------------------------
adb shell am start -n $ACT
wait_healthy || true

adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell dumpsys display | grep mScreenState | head -n1 || true
adb shell dumpsys window | grep mCurrentFocus | head -n1 || true
adb shell screencap -p $TMP/state-pre.png || true
adb pull $TMP/state-pre.png state-pre.png || true

# ---- 7. Record (device-side nohup + clean SIGINT stop + size check) ----------
REC="$TMP/rescata-run.mp4"
adb shell "rm -f $REC" || true
adb shell "nohup screenrecord --time-limit 180 --size 540x1170 --bit-rate 6000000 $REC > $TMP/rec.log 2>&1 &" || true
sleep 4
RECPID="$(adb shell pidof screenrecord | tr -d '\r')"
if [ -n "$RECPID" ]; then echo "[harness] screenrecord running pid=$RECPID"; else echo "[harness] WARN: screenrecord did not start"; fi

rec_stop() {
  adb shell 'P=$(pidof screenrecord); if [ -n "$P" ]; then kill -INT $P; fi; exit 0' || true
  sleep 6
  adb shell stat -c %s $REC 2>/dev/null | tr -d '\r'
}

# Interactions: money shots FIRST (screenrecord hard cap 180s).
dismiss_now
adb shell input tap 135 2250; sleep 3    # Statuses
adb shell input tap 405 2250; sleep 3    # Chats
adb shell input tap 675 2250; sleep 5    # Vault
adb shell ls "$SAVED" || true

# Open first tile (THE money shot), capture, close; second tile quick look
dismiss_now
adb shell input tap 176 620; sleep 5     # viewer opens over grid
adb shell screencap -p $TMP/viewer-open.png || true
adb pull $TMP/viewer-open.png viewer-open.png || true
adb shell input keyevent 4; sleep 3      # back = close viewer
adb shell input tap 490 620; sleep 4     # second tile
adb shell input keyevent 4; sleep 2

# Sweep: Settings, back to Statuses, small scroll
dismiss_now
adb shell input tap 945 2250; sleep 3
adb shell input tap 135 2250; sleep 3
adb shell input swipe 540 1700 540 700 300; sleep 2
adb shell input tap 135 2250; sleep 3

RSIZE="$(rec_stop)"
echo "[harness] recording size=$RSIZE bytes"

# ---- 8. Pull evidence ----------------------------------------------------------
# Retry once with a compact script if the recorder died again (0 bytes).
if [ -z "$RSIZE" ] || [ "$RSIZE" = "0" ]; then
  echo "[harness] RECORD_EMPTY -> retry: 60s recording of vault + viewer"
  adb shell "rm -f $REC" || true
  adb shell "nohup screenrecord --time-limit 60 --size 540x1170 --bit-rate 6000000 $REC > $TMP/rec2.log 2>&1 &" || true
  sleep 4
  dismiss_now
  adb shell input tap 675 2250; sleep 5   # Vault
  adb shell input tap 176 620; sleep 5    # viewer
  adb shell screencap -p $TMP/viewer-retry.png || true
  adb pull $TMP/viewer-retry.png viewer-retry.png || true
  adb shell input keyevent 4; sleep 2
  adb shell input tap 405 2250; sleep 3   # Chats
  adb shell input tap 135 2250; sleep 3   # Statuses
  RSIZE="$(rec_stop)"
  echo "[harness] retry recording size=$RSIZE bytes"
fi

adb pull $REC rescata-run.mp4 || true
ls -la rescata-run.mp4 viewer-open.png state-pre.png || true

# logcat tail for post-mortem (bounded)
adb logcat -d -t 1500 > logcat-tail.txt 2>&1 || true

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
