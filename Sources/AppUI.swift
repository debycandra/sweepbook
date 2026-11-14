import AppKit
import SwiftUI

struct SweepbookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var vm = Cleaner()

    var body: some Scene {
        WindowGroup("Sweepbook") {
            ContentView()
                .environmentObject(vm)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { vm.scan() }
                    .keyboardShortcut("r")
                    .disabled(vm.isBusy)
                Button("Delete Selected…") { vm.askToDelete() }
                    .keyboardShortcut(.delete)
                    .disabled(!vm.canDelete)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { Settings.migrateFromOldName() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Settings {
    /// Early local builds used another bundle id. Copy their settings over once.
    /// Window positions are skipped: they're keyed by old type names.
    static let oldBundleIds = ["local.mydeviceclean.app"]

    static func migrateFromOldName() {
        let defaults = UserDefaults.standard
        let flag = "migratedFromOldBundleIds"
        guard !defaults.bool(forKey: flag) else { return }
        for id in oldBundleIds {
            for (key, value) in defaults.persistentDomain(forName: id) ?? [:]
            where !key.hasPrefix("NSWindow Frame") && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: flag)
    }
}

// MARK: - State

enum SidebarItem: Hashable {
    case overview
    case group(ItemGroup)
}

@MainActor
final class Cleaner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(step: Int)
        case waiting(String)
        case ready
        case cleaning(done: Int, total: Int, current: String)
        case done
    }

    @Published var phase: Phase = .idle
    @Published var items: [CleanItem] = []
    @Published var selected: Set<String> = []
    @Published var section: SidebarItem = .overview
    @Published var disk = Engine.diskFree()
    @Published var results: [CleanResult] = []
    @Published var freed: Int64 = 0
    @Published var showConfirm = false

    var isBusy: Bool {
        switch phase {
        case .scanning, .waiting, .cleaning: return true
        default: return false
        }
    }
    var canDelete: Bool { phase == .ready && !selectedItems.isEmpty }

    var selectedItems: [CleanItem] {
        // Skip a child (AVD snapshots) when its parent (the whole AVD) is selected too.
        items.filter { selected.contains($0.id) && $0.selectable && !($0.parent.map(selected.contains) ?? false) }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var groupsPresent: [ItemGroup] { ItemGroup.allCases.filter { g in items.contains { $0.group == g } } }
    func rows(in group: ItemGroup) -> [CleanItem] {
        items.filter { $0.group == group }
            .sorted { ($0.action == nil ? 1 : 0, $0.bytes) > ($1.action == nil ? 1 : 0, $1.bytes) }
    }
    func bytes(in group: ItemGroup?) -> Int64 {
        items.filter { (group == nil || $0.group == group) && $0.parent == nil }.reduce(0) { $0 + $1.bytes }
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(get: { self.selected.contains(id) },
                set: { on in if on { self.selected.insert(id) } else { self.selected.remove(id) } })
    }

    func selectSafe() { selected = Set(items.filter { $0.risk == .safe && $0.selectable }.map(\.id)) }
    func askToDelete() { if canDelete { showConfirm = true } }

    func scan() {
        guard !isBusy else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .scanning(step: 0)
            results = []
        }
        Task.detached(priority: .userInitiated) {
            let found = Engine.scan { i in
                Task { @MainActor in
                    if case .scanning(let current) = self.phase, i > current {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.phase = .scanning(step: i) }
                    }
                }
            }
            let disk = Engine.diskFree()
            try? await Task.sleep(nanoseconds: 400_000_000)   // let the last tick show
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.items = found
                    self.disk = disk
                    self.selectSafe()
                    self.section = .overview
                    self.phase = .ready
                }
            }
        }
    }

    func clean() {
        let todo = selectedItems
        guard !todo.isEmpty, !isBusy else { return }
        showConfirm = false
        let before = Engine.diskFree().free
        Engine.log("---- Delete started: \(todo.count) items, \(formatBytes(selectedBytes))")
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = .cleaning(done: 0, total: todo.count, current: todo[0].title)
        }
        Task.detached(priority: .userInitiated) {
            var res: [CleanResult] = []
            for (i, item) in todo.enumerated() {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.phase = .cleaning(done: i, total: todo.count, current: item.title)
                    }
                }
                let r = Engine.clean(item)
                res.append(CleanResult(title: item.title, bytes: item.bytes, ok: r.ok, message: r.message))
            }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.phase = .cleaning(done: todo.count, total: todo.count, current: "Finishing up…")
                }
            }
            let after = Engine.diskFree()
            let finalResults = res
            Engine.log("---- Delete finished: free space \(formatBytes(before)) -> \(formatBytes(after.free))")
            try? await Task.sleep(nanoseconds: 400_000_000)
            await MainActor.run {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    self.results = finalResults
                    self.freed = max(0, after.free - before)
                    self.disk = after
                    self.items = []
                    self.selected = []
                    self.section = .overview
                    self.phase = .done
                }
            }
        }
    }

    func openDocker() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        withAnimation { phase = .waiting("Waiting for Docker to start…") }
        Task.detached {
            for _ in 0..<90 {
                if Shell.run("docker info >/dev/null 2>&1", timeout: 10).code == 0 { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await MainActor.run {
                self.phase = .idle
                self.scan()
            }
        }
    }

    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Env.logFile)) }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        // A hand-made sidebar layout. NavigationSplitView on macOS 26 leaves a stray blurred
        // glass layer over the content, so it isn't used.
        HStack(spacing: 0) {
            Sidebar().frame(width: 236)
            Divider()
            DetailView()
                .noScrollEdgeEffect()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Sweepbook")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: vm.scan) {
                    Label(vm.phase == .idle ? "Scan" : "Scan Again", systemImage: "arrow.clockwise")
                }
                .help("Scan (⌘R)")
                .disabled(vm.isBusy)
            }
        }
        .sheet(isPresented: $vm.showConfirm) {
            ConfirmSheet().environmentObject(vm)
        }
        .task {
            // The split view sometimes skips drawing the sidebar until state changes once.
            try? await Task.sleep(nanoseconds: 150_000_000)
            vm.disk = Engine.diskFree()
        }
    }

    private var subtitle: String {
        switch vm.phase {
        case .ready: return vm.items.isEmpty ? "All clean" : "\(formatBytes(vm.bytes(in: nil))) found"
        case .scanning: return "Scanning…"
        case .cleaning: return "Deleting…"
        case .done: return "Freed \(formatBytes(vm.freed))"
        default: return ""
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sweepbook").font(.headline)
                    Text("Dev junk sweeper").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 14)

            Text("Results").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 2)
            SidebarRow(title: "Overview", symbol: "square.grid.2x2.fill", bytes: vm.bytes(in: nil),
                       isSelected: vm.section == .overview) { vm.section = .overview }
            ForEach(vm.groupsPresent, id: \.self) { group in
                SidebarRow(title: group.shortTitle, symbol: group.symbol, bytes: vm.bytes(in: group),
                           isSelected: vm.section == .group(group)) { vm.section = .group(group) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer()
            DiskGauge()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let bytes: Int64
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if bytes > 0 {
                    Text(formatBytes(bytes)).font(.caption.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor : (hovering ? Color.secondary.opacity(0.12) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DiskGauge: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        let total = Double(max(1, vm.disk.total))
        let used = Double(max(0, vm.disk.total - vm.disk.free))
        VStack(alignment: .leading, spacing: 6) {
            Label("Disk", systemImage: "internaldrive").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ProgressView(value: used, total: total)
                .tint(used / total > 0.9 ? .red : (used / total > 0.8 ? .orange : .accentColor))
            Text("\(formatBytes(vm.disk.free)) free of \(formatBytes(vm.disk.total))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.8), value: vm.disk.free)
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        ZStack {
            switch vm.phase {
            case .idle:
                WelcomeView().transition(.opacity)
            case .scanning(let step):
                ScanningView(step: step).transition(.opacity)
            case .waiting(let message):
                BusyView(title: message, detail: "This can take up to a few minutes.").transition(.opacity)
            case .ready:
                ItemsView().transition(.opacity.combined(with: .move(edge: .bottom)))
            case .cleaning(let done, let total, let current):
                CleaningView(done: done, total: total, current: current).transition(.opacity)
            case .done:
                DoneView().transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Plain SwiftUI progress bar. (The AppKit-backed ProgressView leaves a blurred band
/// behind in the window on macOS 26 after it's removed.)
struct Bar: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeInOut(duration: 0.35), value: fraction)
    }
}

/// Small spinner drawn in SwiftUI, for the same reason as `Bar`.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: 14, height: 14)
    }
}

/// The app icon, swinging like a broom. Driven by a TimelineView rather than a repeatForever
/// animation, so it stops cleanly when the view goes away (a never-ending animation can leave
/// the leaving view stuck on screen mid-transition).
struct SweepingIcon: View {
    var size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let swing = sin(t * 2 * .pi / 1.1)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(7 * swing), anchor: .bottom)
                .offset(x: 5 * swing)
        }
        .frame(width: size, height: size)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var vm: Cleaner
    @State private var appear = false

    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .scaleEffect(appear ? 1 : 0.85)
                .opacity(appear ? 1 : 0)
            VStack(spacing: 8) {
                Text("Ready when you are").font(.largeTitle.bold())
                Text("Sweepbook looks for caches and build leftovers from Android, Docker and other dev tools. "
                     + "Nothing is deleted until you pick it and confirm.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 470)
            }
            Button(action: vm.scan) {
                Label("Scan my Mac", systemImage: "magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(alignment: .top, spacing: 14) {
                LegendCard(symbol: "checkmark.shield.fill", color: .green, title: "Safe",
                           text: "The tool rebuilds or re-downloads it. Ticked for you.")
                LegendCard(symbol: "exclamationmark.triangle.fill", color: .orange, title: "Review",
                           text: "Can come back, but think first. Starts unticked.")
                LegendCard(symbol: "lock.fill", color: .gray, title: "Never listed",
                           text: "Release builds, databases, documents and photos.")
            }
            .frame(maxWidth: 640)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 14)
        }
        .padding(40)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { appear = true }
        }
    }
}

struct LegendCard: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ScanningView: View {
    let step: Int

    var body: some View {
        let steps = Engine.scanSteps
        VStack(spacing: 24) {
            SweepingIcon(size: 96)
            Text("Scanning…").font(.title2.bold())
            Bar(fraction: Double(min(step, steps.count)) / Double(steps.count)).frame(width: 320)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 10) {
                        ZStack {
                            if i < step {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    .transition(.scale.combined(with: .opacity))
                            } else if i == step {
                                Spinner()
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(s.title).foregroundStyle(i <= step ? .primary : .secondary)
                    }
                }
            }
            .frame(width: 320, alignment: .leading)
        }
    }
}

struct BusyView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            SweepingIcon(size: 96)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

struct CleaningView: View {
    let done: Int
    let total: Int
    let current: String

    var body: some View {
        VStack(spacing: 20) {
            SweepingIcon(size: 96)
            Text("Sweeping…").font(.title2.bold())
            Bar(fraction: Double(done) / Double(max(total, 1))).frame(width: 340)
            Text(current).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 440)
            Text("\(min(done + 1, total)) of \(total)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Results list

struct ItemsView: View {
    @EnvironmentObject private var vm: Cleaner

    private var groups: [ItemGroup] {
        if case .group(let g) = vm.section { return [g] }
        return vm.groupsPresent
    }
    private var title: String {
        if case .group(let g) = vm.section { return g.title }
        return "Overview"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.bold())
                    Text("\(groups.flatMap { vm.rows(in: $0) }.count) items · "
                         + "\(formatBytes(groups.reduce(0) { $0 + vm.bytes(in: $1) })) found")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            if vm.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(.green)
                    Text("Nothing worth cleaning right now.").font(.title3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ScrollView instead of List: List is an AppKit table on macOS and draws a stray
                // blur band under the toolbar on macOS 26.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if vm.section == .overview {
                            Text("Safe items are already ticked. REVIEW items start unticked: tick them only if you're sure.")
                                .font(.callout).foregroundStyle(.secondary)
                                .padding(.bottom, 4)
                        }
                        ForEach(groups, id: \.self) { group in
                            HStack {
                                Label(group.title, systemImage: group.symbol)
                                Spacer()
                                Text(formatBytes(vm.bytes(in: group))).monospacedDigit()
                            }
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 18).padding(.bottom, 6).padding(.horizontal, 6)
                            ForEach(vm.rows(in: group)) { item in
                                ItemRow(item: item, isOn: vm.binding(for: item.id), openDocker: vm.openDocker)
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                Divider()
                FooterBar()
            }
        }
    }
}

struct FooterBar: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.selectedItems.count) selected").font(.callout).foregroundStyle(.secondary)
                Text(formatBytes(vm.selectedBytes))
                    .font(.title3.bold()).monospacedDigit()
                    .numericTransition()
                    .animation(.easeInOut(duration: 0.25), value: vm.selectedBytes)
            }
            Button("Select Safe") { withAnimation { vm.selectSafe() } }
            Button("Select None") { withAnimation { vm.selected = [] } }
            Spacer()
            Button(role: .destructive, action: vm.askToDelete) {
                Label("Delete Selected…", systemImage: "trash").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .help("Delete Selected (⌘⌫)")
            .disabled(!vm.canDelete)
        }
        .padding(16)
    }
}

struct ItemRow: View {
    let item: CleanItem
    @Binding var isOn: Bool
    let openDocker: () -> Void
    @State private var showFiles = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.action != nil {
                Toggle("", isOn: $isOn).toggleStyle(.checkbox).labelsHidden().disabled(!item.selectable)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.medium)
                    if item.risk == .review && item.action != nil {
                        Text("REVIEW").font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18)).foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = item.blocked {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                }
                if item.id == "docker:off" {
                    Button("Open Docker and Scan Again", action: openDocker)
                }
                if !item.files.isEmpty {
                    DisclosureGroup("Show \(item.files.count) file\(item.files.count == 1 ? "" : "s")", isExpanded: $showFiles.animation()) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(item.files.prefix(300), id: \.self) { f in
                                Text(f.replacingOccurrences(of: Env.home, with: "~"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 12)
            if item.bytes > 0 {
                Text(formatBytes(item.bytes)).font(.body.monospacedDigit()).fontWeight(.semibold)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(isOn && item.selectable ? Color.accentColor.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.selectable { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }
        }
        .opacity(item.blocked == nil ? 1 : 0.75)
    }
}

// MARK: - Confirm & done

struct ConfirmSheet: View {
    @EnvironmentObject private var vm: Cleaner

    var body: some View {
        let items = vm.selectedItems
        let review = items.filter { $0.risk == .review }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 42)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete \(items.count) item\(items.count == 1 ? "" : "s")?").font(.title2.bold())
                    Text("Frees about \(formatBytes(vm.selectedBytes)). This can't be undone.").foregroundStyle(.secondary)
                }
            }
            if !review.isEmpty {
                Label("\(review.count) REVIEW item\(review.count == 1 ? " is" : "s are") included. Double-check before you go on.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            List(items) { item in
                HStack {
                    Image(systemName: item.risk == .review ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(item.risk == .review ? Color.orange : Color.green)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(formatBytes(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 150, maxHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { vm.showConfirm = false }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: vm.clean) {
                    Text("Delete \(formatBytes(vm.selectedBytes))")
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(22)
        .frame(width: 540)
    }
}

struct DoneView: View {
    @EnvironmentObject private var vm: Cleaner
    @State private var shown: Double = 0
    @State private var pop = false

    var body: some View {
        let allOK = vm.results.allSatisfy(\.ok)
        VStack(spacing: 14) {
            Image(systemName: allOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(allOK ? Color.green : Color.orange)
                .scaleEffect(pop ? 1 : 0.3)
                .opacity(pop ? 1 : 0)
            CountingBytes(value: shown)
                .font(.system(size: 46, weight: .bold, design: .rounded))
            Text("freed · \(formatBytes(vm.disk.free)) free now").foregroundStyle(.secondary)
            Text("Docker gives space back to macOS over the next minute or so.")
                .font(.caption).foregroundStyle(.tertiary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { i, r in
                        HStack(alignment: .top) {
                            Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? Color.green : Color.red)
                            VStack(alignment: .leading) {
                                Text(r.title)
                                if !r.ok { Text(r.message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }
                            Spacer()
                            Text(formatBytes(r.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(i.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                    }
                }
            }
            .frame(maxWidth: 620, maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Button("Open Log", action: vm.openLog)
                Button("Scan Again", action: vm.scan).buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { pop = true }
            withAnimation(.easeOut(duration: 1.4)) { shown = Double(vm.freed) }
        }
    }
}

/// Text that counts up when `value` animates.
struct CountingBytes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(formatBytes(Int64(value))).monospacedDigit() }
}

extension View {
    /// macOS 26 blurs a band of content under the toolbar when a scroll view is on screen,
    /// and with this layout it lands in the middle of the page. Turn it off.
    @ViewBuilder func noScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) { self.scrollEdgeEffectHidden(true, for: .all) } else { self }
    }

    /// Rolling digits on macOS 14+, a plain fade on 13.
    @ViewBuilder func numericTransition() -> some View {
        if #available(macOS 14.0, *) { self.contentTransition(.numericText()) } else { self }
    }
}
