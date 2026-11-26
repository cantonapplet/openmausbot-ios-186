#!/bin/sh
# Run only the UI test classes you name, without rebuilding when nothing
# changed: `xcodebuild test` rebuilds first every time, which is most of the
# wait between small edits.
#
#   scripts/fast-ui-test.sh RosterDensityUITests
#   scripts/fast-ui-test.sh ThreadNavigationUITests LiveCallUITests
#   SKIP_BUILD=1 scripts/fast-ui-test.sh RosterDensityUITests
#
# The first build after a source change is the normal incremental build; every
# run after that is a 2-3 second no-op build plus the tests themselves.
set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <UITestClass> [<UITestClass> ...]" >&2
    echo "       SKIP_BUILD=1 $0 <UITestClass> ..." >&2
    exit 2
fi

cd "$(dirname "$0")/.."

DESTINATION='platform=iOS Simulator,name=iPhone 18 Pro'
ONLY_TESTING=""
for class in "$@"; do
    ONLY_TESTING="$ONLY_TESTING -only-testing:OpenMausCompanionUITests/$class"
done

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    xcodebuild -project OpenMausCompanion.xcodeproj -scheme OpenMausCompanion \
        -sdk iphonesimulator -destination "$DESTINATION" \
        build-for-testing
fi

# shellcheck disable=SC2086
xcodebuild test-without-building -project OpenMausCompanion.xcodeproj \
    -scheme OpenMausCompanion -sdk iphonesimulator -destination "$DESTINATION" \
    $ONLY_TESTING
