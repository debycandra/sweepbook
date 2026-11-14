# Changelog

All notable changes to this project are listed here.
Versions follow [Semantic Versioning](https://semver.org).

## [0.0.1] - 2026-11-14

First public release.

- Scan, review and delete in one window. Safe items start ticked, REVIEW items start unticked.
- Sidebar with results per area and a disk gauge, an animated scan checklist, a confirmation sheet
  listing exactly what will be deleted, delete progress, and a results screen.
- Shortcuts: ⌘R to scan, ⌘⌫ to delete the selection.
- Android: Gradle caches, debug/profile APKs and build intermediates, emulators (whole AVD or just
  snapshots), unused NDKs and system images, release APK/AAB in `build/outputs`.
- Docker: build cache, unused images, orphan anonymous volumes. Named volumes are never listed.
- Dev caches: Go, npm, Yarn, pip, uv, Homebrew, CocoaPods, node-gyp, Dart/Flutter, Xcode, Playwright,
  Kotlin/Native.
- Apps: VS Code, Chrome and Edge caches (blocked while the app is open), Trash.
- Hard path check: never deletes outside your home folder or the Android SDK.
- Deletions are logged to `~/Library/Logs/Sweepbook.log`.
- `--scan` prints a read-only scan in the terminal.
- Universal app (Apple Silicon + Intel), macOS 13+.
- Vector app icon (`assets/icon.svg`).
