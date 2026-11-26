#!/bin/sh
# Fast visual loop: build once, install, launch a preview straight onto the
# screen, and capture a PNG. No XCUITest bundle, no test runner, no project
# regeneration — the screenshot harness only taps when a screen has no launch
# route.
#
#   scripts/quick-shot.sh home
#   scripts/quick-shot.sh chat
#   scripts/quick-shot.sh profile
#   scripts/quick-shot.sh settings
#   scripts/quick-shot.sh computer
#   scripts/quick-shot.sh browser
#   SKIP_BUILD=1 scripts/quick-shot.sh home
#   scripts/quick-shot.sh home -companion.prefs.appearance light
#   SETTLE=8 scripts/quick-shot.sh home   # max seconds to wait for a frame
#
# The PNG path is printed on the last line.
set -eu

cd "$(dirname "$0")/.."

SIMULATOR='iPhone 18 Pro'
DESTINATION="platform=iOS Simulator,name=$SIMULATOR"
BUNDLE='com.cantonapplet.openmausbot'
OUT="${OUT:-/tmp/mausbot-shot.png}"

case "${1:-home}" in
    home)    SCENARIO="-store-preview -roster-preview" ;;
    chat)    SCENARIO="-store-preview -threads-preview -open-preview-gmail" ;;
    profile) SCENARIO="-store-preview -threads-preview -open-preview-gmail -open-profile" ;;
    settings) SCENARIO="-store-preview -roster-preview -open-settings" ;;
    computer) SCENARIO="-store-preview -threads-preview -open-preview-gmail -open-computer" ;;
    browser) SCENARIO="-store-preview -browser-preview -browser-control-preview" ;;
    glass)   SCENARIO="-store-preview -roster-preview -glass-gallery" ;;
    *)
        echo "usage: $0 [home|chat|profile] [extra launch arguments...]" >&2
        exit 2
        ;;
esac
shift || true

INSTALL=$([ "${SKIP_BUILD:-0}" = "1" ] && echo 0 || echo 1)
if [ "$INSTALL" = 1 ]; then
    xcodebuild -quiet -project OpenMausCompanion.xcodeproj \
        -scheme OpenMausCompanion -sdk iphonesimulator \
        -destination "$DESTINATION" build

    APP_DIR=$(xcodebuild -project OpenMausCompanion.xcodeproj \
        -scheme OpenMausCompanion -sdk iphonesimulator \
        -destination "$DESTINATION" -showBuildSettings 2>/dev/null |
        awk '/ TARGET_BUILD_DIR = /{dir=$3} / WRAPPER_NAME = /{name=$3} END{print dir "/" name}')
    if [ ! -d "$APP_DIR" ]; then
        echo "built app not found: $APP_DIR" >&2
        exit 1
    fi
fi

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
if [ "$INSTALL" = 1 ]; then
    xcrun simctl install booted "$APP_DIR" >/dev/null
fi

# After an install the simulator can restore one prewarmed scene without the
# launch arguments, so launch twice in that case. A warm install needs one.
ATTEMPTS=$([ "$INSTALL" = 1 ] && echo 2 || echo 1)
for _ in $(seq 1 "$ATTEMPTS"); do
    xcrun simctl terminate booted "$BUNDLE" 2>/dev/null || true
    # shellcheck disable=SC2086
    xcrun simctl launch booted "$BUNDLE" \
        $SCENARIO \
        -companion.onboarding.welcomeSeen YES \
        -companion.onboarding.notificationsSeen YES \
        "$@" >/dev/null
    sleep 2
done

# Give the preview store time to hydrate, the theme to apply and the first
# frame to draw. Poll the screenshot and trust it only once two captures a
# beat apart agree, so a springboard flash, a launch screen or a theme flip
# never lands in the PNG. A blank frame has almost no distinct colors.
SETTLE_MAX="${SETTLE:-12}"

if ! python3 -c 'import PIL' >/dev/null 2>&1; then
    # No pixel probe available: fall back to a fixed wait.
    sleep "$SETTLE_MAX"
    xcrun simctl io booted screenshot "$OUT" >/dev/null 2>&1
else
    python3 - "$OUT" "$SETTLE_MAX" <<'PYEOF' 2>/dev/null
import subprocess, sys, time
from PIL import Image

out, max_wait = sys.argv[1], float(sys.argv[2])

def shot():
    subprocess.run(["xcrun", "simctl", "io", "booted", "screenshot", out],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def mean_luminance(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    crop = im.crop((0, int(h * 0.06), w, int(h * 0.96))).resize((120, 240))
    colors = crop.getcolors(maxcolors=1000000)
    if not colors or len(colors) < 20:
        return None
    px = list(im.convert("L").resize((60, 131)).getdata())
    return sum(px) / len(px)

time.sleep(3)  # skip the launch screen and the springboard hand-off
last = None
deadline = time.monotonic() + max_wait
while time.monotonic() < deadline:
    shot()
    mean = mean_luminance(out)
    if mean is not None and last is not None and abs(mean - last) < 3:
        sys.exit(0)
    last = mean
    time.sleep(1.5)
shot()
PYEOF
fi

echo "screenshot: $OUT"
