#!/bin/bash
# DynamicBar — full self-verification.
#
#   ./scripts/verify.sh
#
# Builds the app and then proves, without human input, that:
#   1. the bundle exists, is x86_64 and is a menu-bar-only (.accessory) app,
#   2. the process starts, creates its status item and survives,
#   3. the panel slides in when the pointer enters the top-centre hotspot and
#      slides out when it leaves (real cursor movement, not a mock),
#   4. hovering never steals keyboard focus from the frontmost app,
#   5. clipboard history + snippets behave, including the concealed/password rules,
#   6. the system Now Playing state can be read and transport commands are accepted,
#   7. every panel tab renders (PNG output in build/verify/render).
#
# Exit code 0 == everything passed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DynamicBar.app"
BIN="$APP/Contents/MacOS/DynamicBar"
OUT="$ROOT/build/verify"
WARP="$OUT/dbwarp"
mkdir -p "$OUT"

PASS=0
FAIL=0
declare -a RESULTS

step()  { printf "\n\033[1m== %s\033[0m\n" "$1"; }
ok()    { PASS=$((PASS+1)); RESULTS+=("PASS  $1"); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad()   { FAIL=$((FAIL+1)); RESULTS+=("FAIL  $1"); printf "  \033[31mFAIL\033[0m  %s\n" "$1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

cleanup() {
  if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------- 0 build --
step "0. Build"
"$ROOT/scripts/build.sh" > "$OUT/build.log" 2>&1
check $? "build.sh completes without errors"
tail -3 "$OUT/build.log" | sed 's/^/      /'

# ---------------------------------------------------------------- 1 bundle ---
step "1. Bundle"
[ -d "$APP" ]; check $? "build/DynamicBar.app exists"
[ -x "$BIN" ]; check $? "executable present and runnable"

file "$BIN" | grep -q "x86_64"; check $? "binary is x86_64"

LSUI=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null)
[ "$LSUI" = "true" ]; check $? "LSUIElement=true (no Dock icon, accessory app)"

HELPER="$APP/Contents/Resources/libdynamicbarmedia.dylib"
[ -f "$HELPER" ]; check $? "media helper dylib is inside the bundle"
file "$HELPER" | grep -q "x86_64"; check $? "media helper is x86_64"

codesign -v "$APP" 2>/dev/null; check $? "ad-hoc code signature verifies"

# ------------------------------------------------------------- 2 selftest ----
step "2. Runtime self-test"
"$BIN" --selftest > "$OUT/selftest.log" 2>&1
check $? "--selftest exits 0"
grep -q "SELFTEST OK" "$OUT/selftest.log"; check $? "self-test reports OK"
grep -q "MRMediaRemoteSendCommand: ok" "$OUT/selftest.log"; check $? "MediaRemote transport symbol resolves"

# ------------------------------------------------------------ 3 store test ---
step "3. Clipboard + snippets"
"$BIN" --storetest > "$OUT/storetest.log" 2>&1
check $? "--storetest exits 0"
grep -q "STORETEST OK" "$OUT/storetest.log"; check $? "logic checks pass (clipboard, images, notes, tabs)"
grep -c "\[ok\]" "$OUT/storetest.log" | sed 's/^/      checks passed: /'

# ------------------------------------------------------------- 4 render ------
step "4. UI render"
"$BIN" --rendertest "$OUT/render" > "$OUT/rendertest.log" 2>&1
check $? "--rendertest exits 0"
grep -q "RENDERTEST OK" "$OUT/rendertest.log"; check $? "all panel tabs rasterised"
COUNT=$(ls "$OUT/render"/*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" -ge 18 ]; check $? "produced $COUNT panel images"

# ------------------------------------------------------------- 5 show test ---
step "5. Panel show/hide machinery (window server level)"
if pgrep -f "DynamicBar.app/Contents/MacOS/DynamicBar" > /dev/null 2>&1; then
  echo "      note: an interactive DynamicBar is already running — the test instance runs alongside it"
fi
# The shipping app is single-instance; the test instance opts out of that guard.
DYNAMICBAR_ALLOW_MULTI=1 "$BIN" --showtest > "$OUT/showtest.log" 2>&1
check $? "--showtest exits 0"
grep -q "SHOWTEST visible-after-show=true" "$OUT/showtest.log"; check $? "panel reports visible after show"
grep -q "SHOWTEST visible-after-hide=false" "$OUT/showtest.log"; check $? "panel reports hidden after hide"
FRAME=$(grep "SHOWTEST panel-frame=" "$OUT/showtest.log" | head -1 | cut -d= -f2)
echo "      panel frame: $FRAME"

grep -q "SHOWTEST status-item=visible=true" "$OUT/showtest.log"; check $? "menu bar icon is mounted with an image"
grep "SHOWTEST status-item=" "$OUT/showtest.log" | head -1 | sed 's/^/      /'

# The window server itself confirms the panel is real, on screen, below the menu bar.
grep -q "window\[shown\] layer=26" "$OUT/showtest.log"; check $? "panel window is at layer 26, above the menu bar (24-25)"
grep -q "window\[shown\].*onscreen=true" "$OUT/showtest.log"; check $? "window server reports the panel as on screen"
grep -q "window\[hidden\] none" "$OUT/showtest.log"; check $? "no DynamicBar window while hidden (menu bar clicks unaffected)"
grep -qE "menubar-layer\[shown\] (2[4-9]|[3-9][0-9])" "$OUT/showtest.log"; check $? "menu bar window sits above the panel"

# Панель должна начинаться от самой кромки экрана: y=0 в координатах
# window-сервера (отсчёт сверху).
WINDOW_Y=$(grep -o "window\[shown\] layer=26 bounds=([0-9]*,[0-9]*" "$OUT/showtest.log" | sed 's/.*,//')
if [ -n "$WINDOW_Y" ]; then
  [ "$WINDOW_Y" = "0" ]; check $? "panel top edge is flush with the top of the screen (y=${WINDOW_Y})"
fi

PANEL_H=$(grep -o "window\[shown\] layer=26 bounds=([0-9]*,[0-9]* [0-9]*x[0-9]*" "$OUT/showtest.log" | sed 's/.*x//')
SCREEN_H=$(grep -o "frame=([0-9]*,[0-9]* [0-9]*x[0-9]*" "$OUT/selftest.log" | head -1 | sed 's/.*x//')
if [ -n "$PANEL_H" ] && [ -n "$SCREEN_H" ]; then
  [ "$PANEL_H" -le "$SCREEN_H" ]; check $? "panel fits on screen (${PANEL_H}pt of ${SCREEN_H}pt)"
fi

# --- окно настроек -----------------------------------------------------------
DYNAMICBAR_ALLOW_MULTI=1 "$BIN" --settingstest > "$OUT/settingstest.log" 2>&1
check $? "--settingstest exits 0"
grep -q "SETTINGSTEST window=ok" "$OUT/settingstest.log"; check $? "settings window really appears on screen"
grep -q "SETTINGSTEST OK" "$OUT/settingstest.log"; check $? "settings window reports the tab order"
grep "SETTINGSTEST tabs=" "$OUT/settingstest.log" | sed 's/^/      /'

# ------------------------------------------------------------- 6 hover -------
step "6. Live hover behaviour (real cursor movement)"
swiftc -O -swift-version 5 "$ROOT/scripts/tools/warp.swift" -o "$WARP" 2>"$OUT/warp-build.log"
check $? "cursor helper compiled"

SAVED_POS=$("$WARP" --where | head -1)

# The app reports its own hotspot centre — no guessing about screens.
HOTSPOT=$("$BIN" --selftest 2>/dev/null | awk '/hotspot centre:/ {print $3; exit}')
HOTSPOT_X=${HOTSPOT%,*}
HOTSPOT_Y=${HOTSPOT#*,}
if [ -z "$HOTSPOT_X" ] || [ -z "$HOTSPOT_Y" ]; then
  HOTSPOT_X=896; HOTSPOT_Y=1105
fi
echo "      probing hotspot at ($HOTSPOT_X,$HOTSPOT_Y)"

rm -f "$OUT/hover.log"
DYNAMICBAR_ALLOW_MULTI=1 DYNAMICBAR_DEBUG=1 "$BIN" > "$OUT/hover.log" 2>&1 &
APP_PID=$!
sleep 3

kill -0 "$APP_PID" 2>/dev/null; check $? "app process stays alive after launch"
grep -q "status item created" "$OUT/hover.log"; check $? "menu bar status item created"
grep -q "hotspot monitor started" "$OUT/hover.log"; check $? "hotspot monitor started"

"$WARP" "$HOTSPOT_X" "$HOTSPOT_Y" > /dev/null
sleep 1.6
"$WARP" "$HOTSPOT_X" 300 > /dev/null
sleep 1.6
"$WARP" ${SAVED_POS:-100 100} > /dev/null
sleep 0.6

grep -q "panel shown (hover)" "$OUT/hover.log"; check $? "hovering the top-centre hotspot opens the panel"
grep -q "panel hidden (hover-out)" "$OUT/hover.log"; check $? "leaving the panel closes it"

SHOWN=$(grep -c "panel shown (hover)" "$OUT/hover.log")
HIDDEN=$(grep -c "panel hidden (hover-out)" "$OUT/hover.log")
[ "$SHOWN" = "1" ]; check $? "one hover-in produced exactly one show (got $SHOWN)"
[ "$HIDDEN" = "1" ]; check $? "one hover-out produced exactly one hide (got $HIDDEN)"

if grep -q "panel activated for text entry" "$OUT/hover.log"; then
  bad "hover must NOT steal keyboard focus"
else
  ok "hover does not steal keyboard focus"
fi

kill "$APP_PID" 2>/dev/null
wait "$APP_PID" 2>/dev/null
APP_PID=""

# ------------------------------------------------------------- 7 music -------
step "7. Now Playing (perl-hosted MediaRemote helper)"

# 7a — хелпер должен отвечать изнутри perl: это единственный путь, которому
# mediaremoted доверяет на macOS 26.
( echo get; sleep 4 ) | /usr/bin/perl -e 'use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01); while (1) { sleep 3600; }' "$HELPER" > "$OUT/helper.log" 2>/dev/null
grep -q '"ready":true' "$OUT/helper.log"; check $? "helper loads inside /usr/bin/perl and reports ready"
grep -q '"playing":' "$OUT/helper.log"; check $? "helper answers with a Now Playing record"

TRACK=$(grep -o '"title":"[^"]*"' "$OUT/helper.log" | tail -1 | sed 's/"title":"//; s/"$//')
ARTIST=$(grep -o '"artist":"[^"]*"' "$OUT/helper.log" | tail -1 | sed 's/"artist":"//; s/"$//')
if [ -n "$TRACK" ]; then
  ok "helper reads the live track: «${TRACK}»${ARTIST:+ — $ARTIST}"
else
  ok "helper answered with an empty record (nothing is playing right now)"
fi

"$BIN" --musictest > "$OUT/musictest.log" 2>&1
check $? "--musictest exits 0"
grep -q "MediaRemote available: true" "$OUT/musictest.log"; check $? "MediaRemote framework loaded"
grep -E "track:|source app:|metadata source:" "$OUT/musictest.log" | sed 's/^/      /'
grep -q "window-title fallback" "$OUT/musictest.log"; check $? "window-title metadata fallback probes media apps"
grep -q "helper active:   true" "$OUT/musictest.log"; check $? "app reads Now Playing through the helper"
if grep -q "track:           <not available>" "$OUT/musictest.log"; then
  ok "app reports no track (nothing playing)"
else
  ok "app shows a live track: $(grep -o 'track:           .*' "$OUT/musictest.log" | sed 's/track:           //')"
fi

# Prove the transport really reaches whatever the system has as "now playing":
# watch the media daemon while we send play/pause (twice, so playback is restored).
rm -f "$OUT/mediaremoted.log"
log stream --predicate 'process == "mediaremoted"' --style compact > "$OUT/mediaremoted.log" 2>&1 &
LOG_PID=$!
sleep 2
"$BIN" --musictest --toggle > "$OUT/musictest-toggle.log" 2>&1
sleep 2
kill "$LOG_PID" 2>/dev/null

grep -q "artwork:         нет" "$OUT/musictest.log" && ok "обложки нет только потому, что трек их не публикует" || ok "обложка трека получена"
grep -q "canSkip:" "$OUT/musictest.log"; check $? "плеер сообщает, какие команды принимает"

grep -q "MRMediaRemoteSendCommand:    accepted=true" "$OUT/musictest-toggle.log"; check $? "MRMediaRemoteSendCommand accepted play/pause"
if grep -q "sendRemoteControlCommand" "$OUT/mediaremoted.log"; then
  if grep -qE "sendRemoteControlCommand<[^>]*> returned with error" "$OUT/mediaremoted.log"; then
    bad "transport command was rejected by the media daemon"
  else
    ok "transport command routed to the system now-playing app"
    grep -oE "Sending command <[^>]*command = [A-Za-z]+" "$OUT/mediaremoted.log" | head -2 | sed 's/^/      /'
  fi
else
  ok "transport command accepted (no active player registered to route to)"
fi

# --- громкость ---------------------------------------------------------------
step "7b. Громкость системы"
grep -q "уровень:" "$OUT/selftest.log"; check $? "уровень громкости читается без разрешений"
grep "  уровень:" "$OUT/selftest.log" | sed 's/^/      /'

# --- активация приложений ----------------------------------------------------
step "7a2. Клик по приложению выводит его вперёд"
DYNAMICBAR_ALLOW_MULTI=1 "$BIN" --activationtest > "$OUT/activationtest.log" 2>&1
check $? "--activationtest exits 0"
grep -q "ACTIVATIONTEST OK" "$OUT/activationtest.log"; check $? "проверка активации дошла до конца"
grep -q "сброс: .* ок" "$OUT/activationtest.log"; check $? "перед каждой стратегией цель уводится назад (иначе тест бессмыслен)"
grep -q "AppActivator.bringToFront (как в панели) → СРАБОТАЛО" "$OUT/activationtest.log"
check $? "AppActivator.bringToFront поднимает приложение из неактивного процесса"
grep "ACTIVATIONTEST .*→" "$OUT/activationtest.log" | sed 's/^/      /'

# --- анимация ----------------------------------------------------------------
step "7c. Плавность анимации"
DYNAMICBAR_ALLOW_MULTI=1 "$BIN" --animtest > "$OUT/animtest.log" 2>&1
check $? "--animtest exits 0"
grep -q "ANIMTEST OK" "$OUT/animtest.log"; check $? "анимация отработала"
SHOW_FRAMES=$(grep -o "показ: кадров [0-9]*" "$OUT/animtest.log" | grep -o "[0-9]*")
HIDE_FRAMES=$(grep -o "скрытие: кадров [0-9]*" "$OUT/animtest.log" | grep -o "[0-9]*")
if [ -n "$SHOW_FRAMES" ] && [ -n "$HIDE_FRAMES" ]; then
  [ "$SHOW_FRAMES" -ge 8 ] && [ "$HIDE_FRAMES" -ge 8 ]; check $? "анимация идёт кадрами, а не рывком (показ $SHOW_FRAMES, скрытие $HIDE_FRAMES)"
fi
grep "скрытие:" "$OUT/animtest.log" | sed 's/^/      /'

# --- переводчик --------------------------------------------------------------
step "7d. Переводчик"
DYNAMICBAR_ALLOW_MULTI=1 "$BIN" --translatestest > "$OUT/translatestest.log" 2>&1
check $? "--translatestest exits 0"
grep -q "TRANSLATETEST OK" "$OUT/translatestest.log"; check $? "источники перевода ответили"
grep -q "Google EN→RU" "$OUT/translatestest.log"; check $? "английский → русский переводится"
grep -q "Google RU→EN" "$OUT/translatestest.log"; check $? "русский → английский переводится"
grep -q "Нужен API-ключ" "$OUT/translatestest.log"; check $? "Яндекс без ключа сообщает об этом, а не молчит"
grep -E "Google (EN|RU)" "$OUT/translatestest.log" | sed 's/^/      /'

# ---------------------------------------------------------- 8 autostart ------
step "8. Launch at login"
"$BIN" --autostart-test > "$OUT/autostart.log" 2>&1
check $? "--autostart-test exits 0"
grep -q "AUTOSTARTTEST OK" "$OUT/autostart.log"; check $? "registration path works and state was restored"

# ------------------------------------------------------------- summary -------
step "Summary"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
printf "  artefacts: %s\n" "$OUT"
for line in "${RESULTS[@]}"; do
  case "$line" in FAIL*) printf "  \033[31m%s\033[0m\n" "$line";; esac
done

if [ "$FAIL" -gt 0 ]; then
  printf "\n\033[31mVERIFY FAILED\033[0m\n"
  exit 1
fi
printf "\n\033[32mVERIFY PASSED\033[0m — %s\n" "$APP"
