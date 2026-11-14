#!/bin/bash
# Tests the cleanup rules against a FAKE home folder: nothing real is touched.
# Run after ./build.sh.
set -euo pipefail
cd "$(dirname "$0")"
BIN=build/Sweepbook.app/Contents/MacOS/Sweepbook
# Use the resolved path (/private/var/...): it catches mismatches between /var and /private/var.
H=$(cd "$(mktemp -d)" && pwd -P)/home
mkdir -p "$H"
SDK=$H/android-sdk
trap 'rm -rf "$(dirname "$H")"' EXIT

mk() { mkdir -p "$(dirname "$1")"; head -c "${2:-2}000000" /dev/zero > "$1"; }   # size in MB

# Should be deleted (safe)
mk "$H/.gradle/caches/9.3.1/big.bin" 5
mk "$H/Projects/shop-app/build/app/outputs/flutter-apk/app-debug.apk"
mk "$H/Projects/shop-app/build/app/outputs/apk/profile/app-profile.apk"
mk "$H/Projects/puzzle-game/unity/Library/Bee/Android/x/build/intermediates/b/intermediary-bundle.aab"
mk "$H/Library/Caches/go-build/aa/blob" 3
mk "$H/Library/Caches/com.microsoft.VSCode.ShipIt/update.zip"
# Must survive
mk "$H/.gradle/wrapper/dists/gradle-9.3.1-all/gradle.zip"
echo "secret=1" > "$H/.gradle/gradle.properties"
mk "$H/Projects/shop-app/build/app/outputs/flutter-apk/app-release.apk"          # REVIEW only
mk "$H/Projects/shop-app/build/release-1.2.0+12/app-release.aab"                # archived release
mk "$H/Projects/puzzle-game/unity/Builds/Android/Game.apk"                         # Unity final build
mk "$H/Projects/puzzle-game/unity/Builds/archive/Game-0.4.1-debug.apk"            # archive
mk "$H/Documents/old.apk"                                                # personal folder: never scanned
mk "$H/.android/avd/Test_Phone.avd/userdata-qemu.img.qcow2" 3            # AVD: REVIEW only
mk "$H/.android/avd/Test_Phone.avd/snapshots/default_boot/ram.bin" 2
printf 'path=%s\n' "$H/.android/avd/Test_Phone.avd" > "$H/.android/avd/Test_Phone.ini"
printf 'image.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\n' > "$H/.android/avd/Test_Phone.avd/config.ini"
mk "$SDK/system-images/android-34/google_apis/arm64-v8a/system.img"      # used by the AVD: not listed
mk "$SDK/system-images/android-30/google_apis/x86_64/system.img"         # unused: REVIEW
mk "$SDK/ndk/27.0.12077973/x.bin"                                         # unused old NDK: REVIEW
mk "$SDK/ndk/28.2.13676358/x.bin"                                         # pinned by project: kept
mk "$SDK/ndk/29.0.13113456/x.bin"                                         # newest: kept
# A cache folder that is really a symlink to something outside home: must never be followed
mkdir -p "$(dirname "$H")/outside"; mk "$(dirname "$H")/outside/precious.bin"
mkdir -p "$H/Library/Caches"; ln -s "$(dirname "$H")/outside" "$H/Library/Caches/Yarn"
mkdir -p "$H/Projects/shop-app/android/app"; echo 'android { ndkVersion = "28.2.13676358" }' > "$H/Projects/shop-app/android/app/build.gradle.kts"

echo "== scan =="
SWEEPBOOK_HOME=$H SWEEPBOOK_ANDROID_HOME=$SDK "$BIN" --clean-safe 2>/dev/null

fail=0
gone()  { [ ! -e "$1" ] && echo "ok   deleted: ${1#$H/}" || { echo "FAIL still there: ${1#$H/}"; fail=1; }; }
kept()  { [ -e "$1" ] && echo "ok   kept:    ${1#$H/}" || { echo "FAIL deleted: ${1#$H/}"; fail=1; }; }
echo; echo "== checks =="
gone "$H/.gradle/caches"
gone "$H/Projects/shop-app/build/app/outputs/flutter-apk/app-debug.apk"
gone "$H/Projects/shop-app/build/app/outputs/apk/profile/app-profile.apk"
gone "$H/Projects/puzzle-game/unity/Library/Bee/Android/x/build/intermediates/b/intermediary-bundle.aab"
gone "$H/Library/Caches/go-build"
gone "$H/Library/Caches/com.microsoft.VSCode.ShipIt"
kept "$H/.gradle/wrapper/dists/gradle-9.3.1-all/gradle.zip"
kept "$H/.gradle/gradle.properties"
kept "$H/Projects/shop-app/build/app/outputs/flutter-apk/app-release.apk"
kept "$H/Projects/shop-app/build/release-1.2.0+12/app-release.aab"
kept "$H/Projects/puzzle-game/unity/Builds/Android/Game.apk"
kept "$H/Projects/puzzle-game/unity/Builds/archive/Game-0.4.1-debug.apk"
kept "$H/Documents/old.apk"
kept "$H/.android/avd/Test_Phone.avd/snapshots/default_boot/ram.bin"
kept "$SDK/ndk/27.0.12077973"
kept "$(dirname "$H")/outside/precious.bin"
kept "$SDK/system-images/android-30/google_apis/x86_64/system.img"
exit $fail
