import Foundation

// `Sweepbook --scan` prints the scan in the terminal (read-only).
// `--clean-safe` deletes the pre-ticked safe items, and only works with SWEEPBOOK_HOME set (used by test.sh).
let args = CommandLine.arguments

if args.contains("--scan") || args.contains("--clean-safe") {
    let items = Engine.scan { i in
        if i < Engine.scanSteps.count { FileHandle.standardError.write(Data("… \(Engine.scanSteps[i].title)\n".utf8)) }
    }
    for item in items {
        let mark = item.action == nil ? "info  " : (item.blocked != nil ? "BLOCK " : (item.risk == .safe ? "safe  " : "REVIEW"))
        print(String(format: "%@  %10@  %@", mark, formatBytes(item.bytes), item.title))
        for f in item.files { print("              - \(f)") }
    }
    let safe = items.filter { $0.risk == .safe && $0.selectable }
    print("Safe total: \(formatBytes(safe.reduce(0) { $0 + $1.bytes }))")

    if args.contains("--clean-safe") {
        guard Env.isTest else {
            FileHandle.standardError.write(Data("--clean-safe only runs with SWEEPBOOK_HOME set (tests). Use the app.\n".utf8))
            exit(2)
        }
        for item in safe {
            let r = Engine.clean(item)
            print("\(r.ok ? "deleted" : "FAILED ") \(item.title): \(r.message)")
        }
    }
    exit(0)
}

SweepbookApp.main()
