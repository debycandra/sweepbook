#!/bin/bash
# Cut a release: ./release.sh 0.0.2
# Sets the version, builds, tests, zips the app and publishes a GitHub release with the zip + checksum.
# Notes come from the matching "## [x.y.z]" section in CHANGELOG.md.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>  (semver, e.g. 0.0.2)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a semver version: $VERSION"; exit 1; }
TAG="v$VERSION"
git diff --quiet && git diff --cached --quiet || { echo "Commit your changes first."; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "Add a '## [$VERSION]' section to CHANGELOG.md first."; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
if ! git diff --quiet Info.plist; then
  git commit -q -m "chore(release): $VERSION" Info.plist
fi

./build.sh
./test.sh

ZIP="build/Sweepbook-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Sweepbook.app "$ZIP"
(cd build && shasum -a 256 "Sweepbook-$VERSION.zip" > "Sweepbook-$VERSION.zip.sha256")

awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} /^## \[/ {on=0} on' CHANGELOG.md > build/notes.md

git tag -a "$TAG" -m "Sweepbook $VERSION"
git push origin HEAD "$TAG"
gh release create "$TAG" "$ZIP" "build/Sweepbook-$VERSION.zip.sha256" --title "Sweepbook $VERSION" --notes-file build/notes.md
