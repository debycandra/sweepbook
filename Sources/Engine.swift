import Foundation

// What Sweepbook looks for, and how it cleans each thing.
// Scanning never deletes anything. Deleting only happens in `Engine.clean(_:)`,
// and only for items the user ticked and approved.

// MARK: - Model

enum Risk { case safe, review }

enum ItemGroup: Int, CaseIterable {
    case android, docker, dev, apps
    var title: String {
        switch self {
        case .android: "Android (Gradle, APK, emulators, SDK)"
        case .docker: "Docker"
        case .dev: "Developer caches"
        case .apps: "Apps & Trash"
        }
    }
    var shortTitle: String {
        switch self {
        case .android: "Android"
        case .docker: "Docker"
        case .dev: "Dev caches"
        case .apps: "Apps & Trash"
        }
    }
    var symbol: String {
        switch self {
        case .android: "hammer.fill"
        case .docker: "shippingbox.fill"
        case .dev: "chevron.left.forwardslash.chevron.right"
        case .apps: "macwindow"
        }
    }
}

enum CleanAction {
    /// Delete these files/folders.
    case remove([String])
    /// Run an official cleaner first, then delete whatever is left in `fallback`.
    /// With an empty `fallback`, success = the command's exit code.
    case command(String, fallback: [String])
    /// Delete an emulator with avdmanager, then remove its files.
    case avd(name: String, paths: [String])
}

struct CleanItem: Identifiable {
    let id: String
    let group: ItemGroup
    let title: String
    var detail: String
    var bytes: Int64
    var risk: Risk = .safe
    /// nil = information row only (nothing to delete).
    let action: CleanAction?
    /// Why this can't be cleaned right now (e.g. the app is running).
    var blocked: String? = nil
    var files: [String] = []
    /// If the parent item is selected too, this one is skipped (it's inside the parent).
    var parent: String? = nil

    var selectable: Bool { action != nil && blocked == nil && bytes > 0 }
}

struct CleanResult: Identifiable {
    let id = UUID()
    let title: String
    let bytes: Int64
    let ok: Bool
    let message: String
}

// MARK: - Environment & shell

enum Env {
    static let processEnv = ProcessInfo.processInfo.environment
    /// SWEEPBOOK_HOME lets the test script point the app at a fake home folder.
    static let isTest = processEnv["SWEEPBOOK_HOME"] != nil
    static let home: String = processEnv["SWEEPBOOK_HOME"] ?? NSHomeDirectory()

    static let androidHome: String = {
        if isTest { return processEnv["SWEEPBOOK_ANDROID_HOME"] ?? home + "/android-sdk" }
        let candidates = [processEnv["ANDROID_HOME"], processEnv["ANDROID_SDK_ROOT"],
                          "/opt/homebrew/share/android-commandlinetools",
                          home + "/Library/Android/sdk",
                          "/usr/local/share/android-commandlinetools"]
        return candidates.compactMap { $0 }.first(where: FS.isDir) ?? home + "/Library/Android/sdk"
    }()

    /// Apps opened from Finder get a bare PATH; add the usual tool locations.
    static let shellEnv: [String: String] = {
        var e = processEnv
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
                     "/Applications/Docker.app/Contents/Resources/bin",
                     home + "/go/bin", home + "/.local/bin", home + "/.cargo/bin"]
        e["PATH"] = (extra + [e["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        e["ANDROID_HOME"] = androidHome
        if isTest {
            // Keep test runs away from the real caches.
            e["HOME"] = home
            for k in ["GOCACHE", "GOMODCACHE", "GOPATH", "npm_config_cache", "UV_CACHE_DIR", "GRADLE_USER_HOME"] { e[k] = nil }
        }
        return e
    }()

    static var logFile: String { home + "/Library/Logs/Sweepbook.log" }
}

enum Shell {
    @discardableResult
    static func run(_ cmd: String, timeout: TimeInterval = 900) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", cmd]
        p.environment = Env.shellEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func has(_ tool: String) -> Bool { run("command -v \(tool) >/dev/null 2>&1").code == 0 }

    /// True if any process's command line contains `text`. (macOS `pgrep -f` misses some app main processes.)
    static func isRunning(_ text: String) -> Bool {
        run("ps -axww -o args=").out.split(separator: "\n").contains { $0.contains(text) }
    }
}

enum FS {
    static let fm = FileManager.default
    static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
    static func ls(_ p: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// On-disk size (what `du` reports), so the numbers match the space you get back.
    static func size(_ paths: [String]) -> Int64 {
        let existing = paths.filter(exists)
        guard !existing.isEmpty else { return 0 }
        let out = Shell.run("du -sk -- " + existing.map(Shell.q).joined(separator: " ") + " 2>/dev/null").out
        return out.split(separator: "\n").reduce(Int64(0)) { sum, line in
            let kb = line.split(separator: "\t").first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            return sum + kb * 1024
        }
    }

    static func fileSizes(_ files: [String]) -> Int64 {
        files.reduce(Int64(0)) { $0 + ((try? fm.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
    }

    /// Absolute path with symlinks resolved, so /tmp and /private/tmp (or a linked home) compare equal,
    /// and a symlink that points outside home is judged by where it really goes.
    static func realPath(_ p: String) -> String {
        // realpath(3) needs an existing path: resolve the nearest existing parent, then add the rest back.
        var base = URL(fileURLWithPath: p).standardizedFileURL
        var rest: [String] = []
        while !fm.fileExists(atPath: base.path) && base.path != "/" {
            rest.insert(base.lastPathComponent, at: 0)
            base.deleteLastPathComponent()
        }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(base.path, &buf) != nil ? String(cString: buf) : base.path
        return rest.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Hard guard: only paths inside home or the Android SDK, and never a top-level personal folder.
    static func isSafeTarget(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        let s = realPath(path)
        let home = realPath(Env.home), sdk = realPath(Env.androidHome)
        guard s.hasPrefix(home + "/") || s.hasPrefix(sdk + "/") else { return false }
        let neverExact = ["", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library",
                          "Library/Application Support", "Library/Caches", "Library/Containers", ".android",
                          ".gradle", "go", ".config", ".npm", ".cache", "Workspace"].map { $0.isEmpty ? home : home + "/" + $0 }
        if neverExact.contains(s) || s == sdk { return false }
        let neverInside = [".ssh", ".gnupg", "Library/Keychains", "Library/Mobile Documents", "Documents",
                           "Desktop", "Pictures", "Library/Containers", "Library/Group Containers"]
        return !neverInside.contains { s.hasPrefix(home + "/" + $0 + "/") }
    }

    /// Delete each path; retry with write permission for read-only trees (Go module cache).
    static func removeAll(_ paths: [String]) -> (ok: Bool, message: String) {
        var problems: [String] = []
        for p in paths {
            guard exists(p) else { continue }
            guard isSafeTarget(p) else { problems.append("refused (outside allowed folders): \(p)"); continue }
            Shell.run("rm -rf -- \(Shell.q(p))")
            if exists(p) { Shell.run("chmod -R u+w -- \(Shell.q(p)) 2>/dev/null; rm -rf -- \(Shell.q(p))") }
            if exists(p) { problems.append("could not fully delete (in use or no permission): \(p)") }
        }
        return problems.isEmpty ? (true, "Deleted") : (false, problems.joined(separator: "\n"))
    }
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
    return f
}()

func formatBytes(_ b: Int64) -> String { byteFormatter.string(fromByteCount: b) }

// MARK: - Engine

enum Engine {
    static var home: String { Env.home }
    static var sdk: String { Env.androidHome }

    static func diskFree() -> (free: Int64, total: Int64) {
        var st = statfs()
        let path = FS.exists("/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        guard statfs(path, &st) == 0 else { return (0, 0) }
        return (Int64(st.f_bavail) * Int64(st.f_bsize), Int64(st.f_blocks) * Int64(st.f_bsize))
    }

    static let scanSteps: [(title: String, run: () -> [CleanItem])] = [
        ("Gradle caches", Engine.gradle),
        ("Android emulators", Engine.avds),
        ("Android SDK", Engine.androidSDK),
        ("APK and AAB build files", Engine.apks),
        ("Docker", Engine.docker),
        ("Developer caches", Engine.devCaches),
        ("App caches and Trash", Engine.apps),
    ]

    /// `progress(i)` is called before step i starts, and with `scanSteps.count` at the end.
    static func scan(progress: (Int) -> Void) -> [CleanItem] {
        var items: [CleanItem] = []
        for (i, step) in scanSteps.enumerated() {
            progress(i)
            items += step.run()
        }
        progress(scanSteps.count)
        return items.filter { $0.action == nil || $0.bytes >= 1_000_000 }
    }

    static func clean(_ item: CleanItem) -> (ok: Bool, message: String) {
        let result: (ok: Bool, message: String)
        switch item.action {
        case nil:
            result = (false, "Nothing to delete")
        case .remove(let paths):
            result = FS.removeAll(paths)
        case .command(let cmd, let fallback):
            let r = Shell.run(cmd)
            if fallback.isEmpty {
                let last = r.out.split(separator: "\n").last.map(String.init) ?? ""
                result = (r.code == 0, r.code == 0 ? (last.isEmpty ? "Done" : last) : "Failed: \(last)")
            } else {
                let rm = FS.removeAll(fallback)
                result = (rm.ok, rm.message)
            }
        case .avd(let name, let paths):
            if let am = avdManager() { Shell.run("\(Shell.q(am)) delete avd -n \(Shell.q(name))", timeout: 120) }
            result = FS.removeAll(paths)
        }
        log("\(result.ok ? "OK  " : "FAIL") \(item.title) (\(formatBytes(item.bytes))): \(result.message)")
        return result
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        try? FS.fm.createDirectory(atPath: (Env.logFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: Env.logFile) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(toFile: Env.logFile, atomically: true, encoding: .utf8)
        }
    }

    /// Small helper for "delete this folder" items.
    static func folder(_ id: String, _ group: ItemGroup, _ title: String, _ detail: String,
                       _ rel: [String], risk: Risk = .safe, command: String? = nil) -> CleanItem {
        let paths = rel.map { $0.hasPrefix("/") ? $0 : home + "/" + $0 }
        let action: CleanAction = command.map { .command($0, fallback: paths) } ?? .remove(paths)
        return CleanItem(id: id, group: group, title: title, detail: detail, bytes: FS.size(paths), risk: risk, action: action)
    }

    // MARK: Gradle

    static func gradle() -> [CleanItem] {
        let paths = ["caches", "daemon", ".tmp", "kotlin-profile"].map { home + "/.gradle/" + $0 }
        let running = !Env.isTest && (Shell.isRunning("GradleDaemon") || Shell.isRunning("KotlinCompileDaemon"))
        var item = CleanItem(
            id: "gradle", group: .android, title: "Gradle caches",
            detail: "~/.gradle/caches, daemon logs and temp files. Rebuilt on the next build (that build is slower). "
                + "The Gradle wrapper and gradle.properties are kept.",
            bytes: FS.size(paths),
            action: .command(running ? "pkill -f GradleDaemon; pkill -f KotlinCompileDaemon; sleep 2; true" : "true",
                             fallback: paths))
        if running {
            item.risk = .review
            item.detail += " A Gradle daemon is running and will be stopped first, so don't clean in the middle of a build."
        }
        return [item]
    }

    // MARK: Emulators (AVD)

    struct AVD { let name: String; let ini: String; let dir: String }

    static func listAVDs() -> [AVD] {
        let dir = home + "/.android/avd"
        return ((try? FS.fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".ini") }.sorted().map { ini in
            let name = String(ini.dropLast(4))
            let iniPath = dir + "/" + ini
            var avdDir = dir + "/" + name + ".avd"
            if let txt = try? String(contentsOfFile: iniPath, encoding: .utf8),
               let line = txt.split(separator: "\n").first(where: { $0.hasPrefix("path=") }) {
                avdDir = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            return AVD(name: name, ini: iniPath, dir: avdDir)
        }
    }

    static func avdManager() -> String? {
        let latest = sdk + "/cmdline-tools/latest/bin/avdmanager"
        if FS.exists(latest) { return latest }
        return FS.ls(sdk + "/cmdline-tools").map { sdk + "/cmdline-tools/" + $0 + "/bin/avdmanager" }.first(where: FS.exists)
    }

    static func avds() -> [CleanItem] {
        let avds = listAVDs()
        guard !avds.isEmpty else { return [] }
        let blocked = Shell.isRunning("qemu-system") ? "An emulator is running. Close it first, then Scan again." : nil
        var out: [CleanItem] = []
        for a in avds {
            out.append(CleanItem(
                id: "avd:\(a.name)", group: .android, title: "Emulator “\(a.name)” (whole AVD)",
                detail: "Deletes the emulator and everything installed in it (apps, logins, test data). "
                    + "You'll have to create it again before testing on it. The system image is kept.",
                bytes: FS.size([a.dir]), risk: .review,
                action: .avd(name: a.name, paths: [a.dir, a.ini]), blocked: blocked))
            let snaps = a.dir + "/snapshots"
            let sb = FS.size([snaps])
            if sb > 0 {
                out.append(CleanItem(
                    id: "avdsnap:\(a.name)", group: .android, title: "Emulator “\(a.name)”: quick-boot snapshots only",
                    detail: "Apps and data inside the emulator stay. The next start is a slower cold boot.",
                    bytes: sb, risk: .review, action: .remove([snaps]), blocked: blocked, parent: "avd:\(a.name)"))
            }
        }
        return out
    }

    // MARK: Android SDK (old NDKs, unused system images)

    static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Top-level folders in home that may hold projects. Skips personal and cloud folders
    /// (so macOS doesn't ask for Documents/Desktop/Photos access) and hidden folders.
    static func projectRoots() -> [String] {
        let skip: Set<String> = ["Library", "Pictures", "Music", "Movies", "Documents", "Desktop", "Downloads",
                                 "Public", "Applications", "Sites", "go"]
        let cloud = ["OneDrive", "Google Drive", "Dropbox", "iCloud", "Creative Cloud"]
        return FS.ls(home)
            .filter { name in !skip.contains(name) && !cloud.contains(where: { name.hasPrefix($0) }) }
            .map { home + "/" + $0 }
            .filter(FS.isDir)
    }

    static func usedNdkVersions() -> Set<String> {
        var used = Set<String>()
        let pattern = #"ndkVersion *=? *"?[0-9]+\.[0-9.]+"#
        func collect(_ out: String) {
            for line in out.split(separator: "\n") {
                if let r = line.range(of: #"[0-9]+\.[0-9.]+"#, options: .regularExpression) { used.insert(String(line[r])) }
            }
        }
        // Flutter's default NDK
        let flutter = Shell.run("command -v flutter").out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flutter.isEmpty {
            let root = URL(fileURLWithPath: flutter).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().path
            collect(Shell.run("grep -rhoE \(Shell.q(pattern)) \(Shell.q(root + "/packages/flutter_tools/gradle/src/main")) 2>/dev/null").out)
        }
        // Versions pinned by projects
        let roots = projectRoots()
        if !roots.isEmpty {
            let cmd = "grep -rhoE \(Shell.q(pattern)) --include='*.gradle' --include='*.kts' --include='*.properties' "
                + "--exclude-dir=node_modules --exclude-dir=build --exclude-dir=Library --exclude-dir=.git "
                + "--exclude-dir=Pods --exclude-dir=.dart_tool " + roots.map(Shell.q).joined(separator: " ") + " 2>/dev/null"
            collect(Shell.run(cmd, timeout: 300).out)
        }
        return used
    }

    static func androidSDK() -> [CleanItem] {
        var out: [CleanItem] = []
        let ndkDir = sdk + "/ndk"
        let versions = FS.ls(ndkDir)
        if versions.count > 1, let newest = versions.max(by: versionLess) {
            let used = usedNdkVersions()
            let kept = ([newest] + versions.filter { used.contains($0) && $0 != newest }).joined(separator: ", ")
            for v in versions where !used.contains(v) && v != newest {
                out.append(CleanItem(
                    id: "ndk:\(v)", group: .android, title: "Android NDK \(v)",
                    detail: "Not used by Flutter or by any project ndkVersion found. Keeping: \(kept). "
                        + "If a build ever asks for it: sdkmanager \"ndk;\(v)\".",
                    bytes: FS.size([ndkDir + "/" + v]), risk: .review, action: .remove([ndkDir + "/" + v])))
            }
        }
        // System images that no emulator uses
        var usedImages = Set<String>()
        for a in listAVDs() {
            guard let cfg = try? String(contentsOfFile: a.dir + "/config.ini", encoding: .utf8) else { continue }
            for line in cfg.split(separator: "\n") where line.hasPrefix("image.sysdir.1=") {
                var rel = String(line.dropFirst("image.sysdir.1=".count)).trimmingCharacters(in: .whitespaces)
                while rel.hasSuffix("/") { rel.removeLast() }
                usedImages.insert(rel)
            }
        }
        let base = sdk + "/system-images"
        for api in FS.ls(base) {
            for tag in FS.ls(base + "/" + api) {
                for abi in FS.ls(base + "/" + api + "/" + tag) {
                    let rel = "system-images/\(api)/\(tag)/\(abi)"
                    guard !usedImages.contains(rel) else { continue }
                    out.append(CleanItem(
                        id: "img:\(rel)", group: .android, title: "Emulator system image \(api) / \(tag) / \(abi)",
                        detail: "No emulator uses it right now. Keep it if you'll create an emulator again soon "
                            + "(otherwise it's downloaded again with sdkmanager).",
                        bytes: FS.size([sdk + "/" + rel]), risk: .review, action: .remove([sdk + "/" + rel])))
                }
            }
        }
        return out
    }

    // MARK: APK / AAB

    enum APKKind { case junk, release, keep }

    static func classifyAPK(_ p: String) -> APKKind {
        if p.contains("/Builds/") || p.contains("/archive/") { return .keep }         // Unity final builds, archives
        if p.contains("/build/intermediates/") || p.contains("/Library/Bee/") { return .junk }
        if let b = p.range(of: "/build/"), let o = p.range(of: "/outputs/", range: b.upperBound..<p.endIndex) {
            let tail = p[o.upperBound...].lowercased()
            if tail.contains("release") { return .release }
            if tail.contains("debug") || tail.contains("profile") { return .junk }
        }
        return .keep   // loose APKs, archived releases like build/release-1.2.3/, etc.
    }

    static func apks() -> [CleanItem] {
        let roots = projectRoots()
        guard !roots.isEmpty else { return [] }
        let cmd = "find " + roots.map(Shell.q).joined(separator: " ")
            + " \\( -name node_modules -o -name .git -o -name Pods -o -name .dart_tool \\) -prune -o"
            + " -type f \\( -name '*.apk' -o -name '*.aab' \\) -size +1M -print 2>/dev/null"
        let files = Shell.run(cmd, timeout: 600).out.split(separator: "\n").map(String.init)
        var junk: [String] = [], release: [String] = [], kept = 0
        for f in files {
            switch classifyAPK(f) {
            case .junk: junk.append(f)
            case .release: release.append(f)
            case .keep: kept += 1
            }
        }
        var out: [CleanItem] = []
        if !junk.isEmpty {
            out.append(CleanItem(
                id: "apk:junk", group: .android, title: "Debug / profile APKs and build intermediates",
                detail: "Inside build/ folders (Flutter, Gradle, Unity Library/Bee). Made again by the next build.",
                bytes: FS.fileSizes(junk), action: .remove(junk), files: junk))
        }
        if !release.isEmpty {
            out.append(CleanItem(
                id: "apk:release", group: .android, title: "Release APK/AAB in build/outputs",
                detail: "Can be rebuilt, but build again before uploading to Play. "
                    + "Never touched: \(kept) final build(s) in Builds/ folders, archives and loose APKs.",
                bytes: FS.fileSizes(release), risk: .review, action: .remove(release), files: release))
        }
        return out
    }

    // MARK: Docker

    static func parseDockerSize(_ s: String) -> Int64 {
        let t = s.split(separator: " ").first.map(String.init) ?? ""
        guard let r = t.range(of: #"^[0-9.]+"#, options: .regularExpression), let n = Double(t[r]) else { return 0 }
        let unit = t[r.upperBound...].uppercased()
        let mult: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][unit] ?? 1
        return Int64(n * mult)
    }

    static func docker() -> [CleanItem] {
        if Env.isTest && Env.processEnv["SWEEPBOOK_DOCKER"] == nil { return [] }
        guard Shell.has("docker") || FS.exists("/Applications/Docker.app") else { return [] }
        if Shell.run("docker info >/dev/null 2>&1", timeout: 20).code != 0 {
            return [CleanItem(
                id: "docker:off", group: .docker, title: "Docker Desktop isn't running",
                detail: "Its build cache and unused images can only be checked while it runs. Opening Docker also "
                    + "starts containers set to restart: always.",
                bytes: 0, action: nil)]
        }
        var out: [CleanItem] = []
        for line in Shell.run("docker system df --format '{{.Type}}|{{.Reclaimable}}'", timeout: 60).out.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            let bytes = parseDockerSize(parts[1])
            switch parts[0] {
            case "Build Cache":
                out.append(CleanItem(id: "docker:build", group: .docker, title: "Docker build cache",
                                     detail: "Leftover layers from docker build. 100% safe; the next build is slower.",
                                     bytes: bytes, action: .command("docker builder prune -af", fallback: [])))
            case "Images":
                out.append(CleanItem(id: "docker:images", group: .docker, title: "Unused Docker images",
                                     detail: "Images no container (running or stopped) uses. Pulled or built again when needed.",
                                     bytes: bytes, action: .command("docker image prune -af", fallback: [])))
            default: break
            }
        }
        // Anonymous volumes not attached to any container. Named volumes (databases) are never offered.
        let json = Shell.run("docker system df -v --format json", timeout: 120).out
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vols = obj["Volumes"] as? [[String: Any]] {
            let orphans = vols.filter {
                ($0["Labels"] as? String ?? "").contains("com.docker.volume.anonymous") && ($0["Links"] as? String) == "0"
            }
            let names = orphans.compactMap { $0["Name"] as? String }
            let bytes = orphans.reduce(Int64(0)) { $0 + parseDockerSize($1["Size"] as? String ?? "") }
            let named = vols.count - orphans.count
            if !names.isEmpty {
                out.append(CleanItem(
                    id: "docker:anonvols", group: .docker, title: "Orphan anonymous Docker volumes (\(names.count))",
                    detail: "Unnamed volumes not attached to any container. The \(named) named volume(s) (e.g. *_db_data "
                        + "databases) are never listed here.",
                    bytes: bytes, risk: .review,
                    action: .command("docker volume rm " + names.map(Shell.q).joined(separator: " "), fallback: [])))
            }
        }
        return out
    }

    // MARK: Developer caches

    static func devCaches() -> [CleanItem] {
        let goClean = "command -v go >/dev/null && go clean -cache; true"
        return [
            folder("go-build", .dev, "Go build cache", "Rebuilt on the next go build.",
                   ["Library/Caches/go-build"], command: goClean),
            folder("go-mod", .dev, "Go module downloads", "Downloaded again by the next go build (needs internet).",
                   ["go/pkg/mod"], risk: .review, command: "command -v go >/dev/null && go clean -modcache; true"),
            folder("npm", .dev, "npm cache", "Downloaded again on npm install.",
                   [".npm/_cacache"], command: "command -v npm >/dev/null && npm cache clean --force; true"),
            folder("yarn", .dev, "Yarn cache", "Downloaded again on yarn install.", ["Library/Caches/Yarn"]),
            folder("pip", .dev, "pip cache", "Downloaded again on pip install.", ["Library/Caches/pip"]),
            folder("uv", .dev, "uv (Python) cache", "Downloaded again by uv.",
                   [".cache/uv"], command: "command -v uv >/dev/null && uv cache clean; true"),
            folder("brew", .dev, "Homebrew downloads", "Old installer downloads. Installed apps aren't affected.",
                   ["Library/Caches/Homebrew"]),
            folder("cocoapods", .dev, "CocoaPods cache", "Downloaded again on pod install.", ["Library/Caches/CocoaPods"]),
            folder("node-gyp", .dev, "node-gyp headers", "Downloaded again when a native npm module builds.",
                   ["Library/Caches/node-gyp"]),
            folder("dartserver", .dev, "Dart analysis cache", "Rebuilt by the Dart/Flutter extension.", [".dartServer"]),
            folder("pub", .dev, "Flutter/Dart package cache", "Run flutter pub get again in each project afterwards.",
                   [".pub-cache/hosted"], risk: .review),
            folder("xcode-dd", .dev, "Xcode DerivedData", "Rebuilt on the next Xcode build.",
                   ["Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches"]),
            folder("xcode-ds", .dev, "Xcode iOS DeviceSupport", "Copied again (slowly) when an iPhone is connected.",
                   ["Library/Developer/Xcode/iOS DeviceSupport"], risk: .review),
            folder("playwright", .dev, "Playwright browsers", "Downloaded again with npx playwright install.",
                   ["Library/Caches/ms-playwright"], risk: .review),
            folder("konan", .dev, "Kotlin/Native toolchains", "Downloaded again by the next Kotlin/Native build.",
                   [".konan"], risk: .review),
        ]
    }

    // MARK: Apps & Trash

    static func chromiumProfileCaches(_ userData: String) -> [String] {
        let sub = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "DawnCache", "GrShaderCache", "DawnGraphiteCache", "DawnWebGPUCache"]
        return FS.ls(userData).flatMap { profile in sub.map { userData + "/" + profile + "/" + $0 } }.filter(FS.isDir)
    }

    static func apps() -> [CleanItem] {
        var out: [CleanItem] = [
            folder("vscode-shipit", .apps, "VS Code update leftovers", "Old update downloads. Safe even while VS Code runs.",
                   ["Library/Caches/com.microsoft.VSCode.ShipIt"]),
            folder("vscode-vsix", .apps, "VS Code downloaded extension packages", "Installed extensions are not affected.",
                   ["Library/Application Support/Code/CachedExtensionVSIXs"]),
        ]

        var code = folder("vscode-cache", .apps, "VS Code caches", "Rebuilt when VS Code starts. Settings and extensions stay.",
                          ["Cache", "CachedData", "Code Cache", "GPUCache"].map { "Library/Application Support/Code/" + $0 },
                          risk: .review)
        if Shell.isRunning("Visual Studio Code.app/Contents/MacOS/") { code.blocked = "Quit VS Code first, then Scan again." }
        out.append(code)

        let browsers: [(id: String, name: String, cache: String, data: String, proc: String)] = [
            ("chrome", "Chrome", "Library/Caches/Google/Chrome", "Library/Application Support/Google/Chrome",
             "Google Chrome.app/Contents/MacOS/Google Chrome"),
            ("edge", "Edge", "Library/Caches/Microsoft Edge", "Library/Application Support/Microsoft Edge",
             "Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        ]
        for b in browsers {
            let paths = [home + "/" + b.cache] + chromiumProfileCaches(home + "/" + b.data)
            var item = CleanItem(id: b.id, group: .apps, title: "\(b.name) cache",
                                 detail: "Cached web files only. Bookmarks, passwords, history and logins are not touched.",
                                 bytes: FS.size(paths), risk: .review, action: .remove(paths))
            if Shell.isRunning(b.proc) { item.blocked = "Quit \(b.name) first, then Scan again." }
            out.append(item)
        }

        let trash = home + "/.Trash"
        if let entries = try? FS.fm.contentsOfDirectory(atPath: trash), !entries.isEmpty {
            let paths = entries.filter { $0 != ".DS_Store" }.map { trash + "/" + $0 }
            out.append(CleanItem(id: "trash", group: .apps, title: "Trash (\(paths.count) items)",
                                 detail: "Empties the Trash permanently. Check it in Finder first.",
                                 bytes: FS.size(paths), risk: .review, action: .remove(paths)))
        }
        return out
    }
}
