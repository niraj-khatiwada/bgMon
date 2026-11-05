import SwiftUI
import AppKit
import Darwin

enum ProcessMemory {
    static func display(pid: Int32) -> String {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return "—" }
        return String(format: "%.1f MB", Double(usage.ri_phys_footprint) / 1_000_000)
    }
}

struct Entry: Identifiable, Sendable {
    let id: Int32
    let parent: Int32
    let cpu: String
    let memory: String
    let command: String
    var identity: ProcessIdentity?
    var ports: [Int] = []
    var name: String { URL(fileURLWithPath: command).lastPathComponent }
}

struct ProcessGroup: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let entries: [Entry]
    // Bundle identifiers survive app updates and moves; standalone processes use their path.
    var warningID: String { Bundle(path: id)?.bundleIdentifier.map { "bundle:\($0)" } ?? "path:\(id)" }
    var ports: [Int] { Set(entries.flatMap(\.ports)).sorted() }
    var cpuTotal: Double { entries.reduce(0) { $0 + (Double($1.cpu) ?? 0) } }
    var memoryTotal: Double { entries.reduce(0) { $0 + (Double($1.memory.replacingOccurrences(of: " MB", with: "")) ?? 0) } }
    var totals: String {
        let cpu = entries.reduce(0.0) { $0 + (Double($1.cpu) ?? 0) }
        let values = entries.compactMap { Double($0.memory.replacingOccurrences(of: " MB", with: "")) }
        let memory = values.reduce(0, +)
        let suffix = values.count == entries.count ? "" : " + unknown"
        return String(format: "CPU %.1f%% · %.1f MB", cpu, memory) + suffix
    }
}

@MainActor final class Monitor: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var warnings: [String: String] = [:]
    @Published private(set) var ignoredWarningApps = WarningIgnoreList()
    private var cachedGroups: [ProcessGroup] = []
    private var ownerCache: [Int32: URL] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var eligibleGroupIDs = Set<String>()
    private var highCPUSamples: [String: Int] = [:]
    private let cpuSampler = CPUSampler()
    private var previousCPUThreshold: Double?
    var cpuThreshold: Double { UserDefaults.standard.object(forKey: "warningCPUPercent") as? Double ?? 75 }
    var memoryThreshold: Double { UserDefaults.standard.object(forKey: "warningMemoryGB") as? Double ?? 2 }
    @Published var search = ""
    @Published var includeSystem = false { didSet { updateStatusWarning() } }
    @Published var highUsageOnly = false
    @Published var message: String? {
        didSet {
            messageDismissTask?.cancel()
            guard message != nil else { return }
            messageDismissTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { self?.message = nil }
            }
        }
    }
    private var messageDismissTask: Task<Void, Never>?
    @Published var refreshing = false
    @Published var apps: [pid_t: NSRunningApplication] = [:]
    func isSystemURL(_ url: URL) -> Bool {
        let path = url.path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/usr/")
    }
    func included(_ entry: Entry) -> Bool {
        let owner = ownerURL(entry)
        let appleApp = owner.flatMap { Bundle(url: $0)?.bundleIdentifier }?.hasPrefix("com.apple.") == true
        return includeSystem || !(appleApp || isSystemURL(owner ?? URL(fileURLWithPath: entry.command)))
    }
    var filtered: [Entry] {
        entries.filter { entry in
            let ownerName = ownerURL(entry)?.deletingPathExtension().lastPathComponent ?? ""
            return included(entry) && (search.isEmpty || entry.command.localizedCaseInsensitiveContains(search) || ownerName.localizedCaseInsensitiveContains(search))
        }
    }
    func updateStatusWarning() {
        eligibleGroupIDs = Set(entries.filter { included($0) }.map { ownerURL($0)?.path ?? $0.command })
        let activeGroups = cachedGroups.filter { eligibleGroupIDs.contains($0.id) && warnings[$0.id] != nil }
        PanelController.shared.updateWarning(!activeGroups.isEmpty)
    }
    func ownerURL(_ entry: Entry) -> URL? { ownerCache[entry.id] }
    func resolveOwner(_ entry: Entry, byPID: [Int32: Entry]) -> URL? {
        var current = entry
        var visited = Set<Int32>()
        var fallback: URL?
        while visited.insert(current.id).inserted {
            let candidate: URL?
            if let range = current.command.range(of: ".app/") {
                candidate = URL(fileURLWithPath: String(current.command[..<range.lowerBound]) + ".app")
            } else { candidate = apps[current.id]?.bundleURL }
            if let candidate {
                // A system helper can belong to a third-party ancestor.
                if !isSystemURL(candidate) { return candidate }
                if fallback == nil { fallback = candidate }
            }
            guard let parent = byPID[current.parent] else { break }
            current = parent
        }
        return fallback
    }
    var groups: [ProcessGroup] {
        cachedGroups.filter { group in
            eligibleGroupIDs.contains(group.id) && (!highUsageOnly || warnings[group.id] != nil) &&
            (search.isEmpty || group.name.localizedCaseInsensitiveContains(search) ||
             group.entries.contains { $0.command.localizedCaseInsensitiveContains(search) })
        }
    }
    func icon(for entry: Entry) -> NSImage? {
        ownerURL(entry).flatMap { iconCache[$0.path] }
    }
    func makeGroups(_ processes: [Entry]) -> [ProcessGroup] {
        let buckets = Dictionary(grouping: processes) { entry in
            ownerURL(entry)?.path ?? entry.command
        }
        return buckets.map { key, members in
            let url = ownerURL(members[0])
            let bundle = url.flatMap { Bundle(url: $0) }
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url?.deletingPathExtension().lastPathComponent ?? members[0].name
            if let url, iconCache[url.path] == nil { iconCache[url.path] = NSWorkspace.shared.icon(forFile: url.path) }
            return ProcessGroup(id: key, name: name,
                icon: url.flatMap { iconCache[$0.path] }, entries: members.sorted { lhs, rhs in
                    let leftCPU = Double(lhs.cpu) ?? -1
                    let rightCPU = Double(rhs.cpu) ?? -1
                    if leftCPU != rightCPU { return leftCPU > rightCPU }
                    let leftMemory = Double(lhs.memory.replacingOccurrences(of: " MB", with: "")) ?? -1
                    let rightMemory = Double(rhs.memory.replacingOccurrences(of: " MB", with: "")) ?? -1
                    if leftMemory != rightMemory { return leftMemory > rightMemory }
                    return lhs.id < rhs.id
                })
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let sampler = cpuSampler
        let result = await Task.detached(priority: .utility) {
            let ports = ListeningPorts.scan()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-U", String(getuid()), "-o", "pid=,ppid=,%cpu=,rss=,comm="]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return [Entry]() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Entry? in
                let fields = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard fields.count == 5, let pid = Int32(fields[0]), let parent = Int32(fields[1]), pid != getpid(), pid != task.processIdentifier else { return nil }
                var entry = Entry(id: pid, parent: parent, cpu: sampler.display(pid: pid), memory: ProcessMemory.display(pid: pid), command: String(fields[4]))
                entry.identity = ProcessIdentity.read(pid: pid)
                entry.ports = ports[pid] ?? []
                return entry
            }
        }.value
        cpuSampler.prune(livePIDs: Set(result.map(\.id)))
        apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })
        entries = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let byPID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        ownerCache = [:]
        for entry in entries { ownerCache[entry.id] = resolveOwner(entry, byPID: byPID) }
        cachedGroups = makeGroups(entries)
        reevaluateWarnings(countSample: true)
        refreshing = false
    }
    func ignoreWarnings(for group: ProcessGroup) {
        ignoredWarningApps.ignore(id: group.warningID, name: group.name)
        reevaluateWarnings()
    }
    func restoreWarnings(for id: String) {
        ignoredWarningApps.remove(id)
        reevaluateWarnings()
    }
    func reevaluateWarnings(countSample: Bool = false) {
        if previousCPUThreshold != cpuThreshold { highCPUSamples.removeAll(); previousCPUThreshold = cpuThreshold }
        var updated: [String: String] = [:]
        let allGroups = cachedGroups
        let liveIDs = Set(allGroups.map(\.id))
        highCPUSamples = highCPUSamples.filter { liveIDs.contains($0.key) }
        for group in allGroups {
            guard !ignoredWarningApps.contains(group.warningID) else {
                highCPUSamples.removeValue(forKey: group.id)
                continue
            }
            if countSample { highCPUSamples[group.id] = group.cpuTotal > cpuThreshold ? (highCPUSamples[group.id] ?? 0) + 1 : 0 }
            var reasons: [String] = []
            if (highCPUSamples[group.id] ?? 0) >= 3 { reasons.append("CPU above \(cpuThreshold.formatted())% for three refreshes") }
            if group.memoryTotal > memoryThreshold * 1000 { reasons.append("Memory above \(memoryThreshold.formatted()) GB") }
            if !reasons.isEmpty { updated[group.id] = reasons.joined(separator: " · ") }
        }
        warnings = updated
        updateStatusWarning()
    }
    func showInFinder(_ entry: Entry) {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(entry.id, &buffer, UInt32(buffer.count))
        let currentPath = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard count > 0, currentPath == entry.command else {
            message = "This process changed or exited. Refresh and try again."
            return
        }
        guard FileManager.default.fileExists(atPath: currentPath) else {
            message = "The executable file is no longer available."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: currentPath)])
    }
    private var groupQuitRequests: [String: Date] = [:]
    func recentlyRequestedQuit(_ group: ProcessGroup) -> Bool {
        guard let date = groupQuitRequests[group.id] else { return false }
        return Date().timeIntervalSince(date) < 10
    }
    func stopAll(_ group: ProcessGroup, force: Bool = false) {
        groupQuitRequests = groupQuitRequests.filter { Date().timeIntervalSince($0.value) < 10 }
        groupQuitRequests[group.id] = Date()
        for entry in group.entries { stop(entry, force: force, refreshAfter: false) }
        Task { await refresh() }
    }
    func stop(_ entry: Entry, force: Bool, refreshAfter: Bool = true) {
        if let failure = ProcessControl.validate(pid: entry.id, command: entry.command, identity: entry.identity) {
            message = failure.message
            return
        }
        if !force, let app = apps[entry.id] {
            message = app.terminate() ? "Quit requested. The app may ask you to save work." : "The app declined the quit request."
        } else {
            if let failure = ProcessControl.stop(pid: entry.id, command: entry.command, identity: entry.identity, force: force) {
                message = failure.message
            } else {
                message = force ? "Force quit requested. A supervising service may restart it." : "Stop requested. A supervising service may restart it."
            }
        }
        if refreshAfter { Task { await refresh() } }
    }
}

@MainActor final class PanelController: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = PanelController()
    @Published var pinned = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var trackingMenus = Set<ObjectIdentifier>()
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 438, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "bgMon Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: WarningSettingsView())
            window.center()
            settingsWindow = window
        }
        if !pinned { popover.performClose(nil) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    let monitor = Monitor()
    private var monitoringTask: Task<Void, Never>?
    func updateWarning(_ active: Bool) {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "bgMon")
        if active, let image {
            let colored = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.systemRed.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            colored.isTemplate = false
            button.image = colored
        } else { image?.isTemplate = true; button.image = image }
        button.toolTip = active ? "bgMon: High CPU or Memory Usage" : "bgMon"
    }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "bgMon")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MonitorView())
        NotificationCenter.default.addObserver(self, selector: #selector(menuBeganTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEndedTracking(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await monitor.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        if popover.isShown {
            if !pinned { popover.performClose(nil) }
        } else if let button = statusItem?.button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    @objc private func menuBeganTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
    }

    @objc private func menuEndedTracking(_ notification: Notification) {
        if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
    }

    func popoverDidShow(_ notification: Notification) {
        removeClickMonitors()
        // Native transient dismissal can stop working after a SwiftUI Menu tracks.
        // Monitor both this app's windows and clicks delivered to other apps.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(event) }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeOnOutsideClick() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    private func handleLocalClick(_ event: NSEvent) {
        guard let window = event.window else { return }
        if window === NSApp.modalWindow { return }
        if let popoverWindow = popover.contentViewController?.view.window,
           window === popoverWindow || window.sheetParent === popoverWindow || window.parent === popoverWindow { return }
        // Let the status button's action toggle the panel without reopening it.
        if let button = statusItem?.button, window === button.window,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { return }
        closeOnOutsideClick()
    }

    private func closeOnOutsideClick() {
        guard popover.isShown, !pinned, trackingMenus.isEmpty else { return }
        popover.performClose(nil)
    }

    func togglePin() {
        pinned.toggle()
        popover.behavior = pinned ? .applicationDefined : .transient
        popover.contentViewController?.view.window?.level = pinned ? .floating : .popUpMenu
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        PanelController.shared.start()
    }
}

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Processes"
        field.controlSize = .regular
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct MonitorView: View {
    @ObservedObject private var monitor = PanelController.shared.monitor
    @ObservedObject private var panel = PanelController.shared
    @State private var pending: Entry?
    @State private var pendingGroup: ProcessGroup?
    @State private var expanded = Set<String>()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("bgMon").font(.title2.bold())
                Button { panel.togglePin() } label: {
                    Image(systemName: panel.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.plain)
                .foregroundStyle(panel.pinned ? Color.accentColor : Color.secondary)
                .help(panel.pinned ? "Unpin Window" : "Pin Window")
                .accessibilityLabel(panel.pinned ? "Unpin Window" : "Pin Window")
                Button { panel.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.blue).help("Settings").accessibilityLabel("Settings")
                Spacer()
                Text("\(monitor.groups.reduce(0) { $0 + $1.entries.count }) processes").foregroundStyle(.secondary)
                Button { Task { await monitor.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.blue).help("Refresh").accessibilityLabel("Refresh").disabled(monitor.refreshing)
            }
            HStack(spacing: 8) {
                NativeSearchField(text: $monitor.search).frame(height: 24)
                Menu {
                    Toggle("Include Apple apps and system helpers", isOn: $monitor.includeSystem)
                    Toggle("High resource usage", isOn: $monitor.highUsageOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(monitor.includeSystem || monitor.highUsageOnly ? Color.blue : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filters")
                .accessibilityLabel("Filters")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(monitor.groups) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(group.id) },
                            set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } }
                        )) {
                            ForEach(group.entries) { entry in
                        HStack(spacing: 8) {
                            if let icon = monitor.icon(for: entry) {
                                Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "terminal").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 18, height: 18)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(monitor.apps[entry.id]?.localizedName ?? entry.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                Text("PID \(entry.id) · CPU \(entry.cpu)% · \(entry.memory)").font(.system(size: 10)).foregroundStyle(.secondary)
                                if !entry.ports.isEmpty {
                                    Text("Listening: " + entry.ports.map(String.init).joined(separator: ", "))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button { monitor.stop(entry, force: false) } label: {
                                Image(systemName: "power").frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Stop Process")
                            .accessibilityLabel("Stop Process")
                            Menu {
                                Button("Show in Finder") { monitor.showInFinder(entry) }
                                Divider()
                                Button("Force Stop…", role: .destructive) { pending = entry }
                            } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).menuStyle(.borderlessButton).frame(width: 20).help("More actions")
                        }.controlSize(.small).font(.system(size: 11)).padding(.leading, 12).padding(.vertical, 6).help(entry.command + "\nParent PID: \(entry.parent)")

                            }
                        } label: {
                            HStack(spacing: 8) {
                                Button {
                                    if expanded.contains(group.id) { expanded.remove(group.id) }
                                    else { expanded.insert(group.id) }
                                } label: {
                                    if let icon = group.icon {
                                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                                    } else {
                                        Image(systemName: "terminal").frame(width: 28, height: 28).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Button {
                                            if expanded.contains(group.id) { expanded.remove(group.id) }
                                            else { expanded.insert(group.id) }
                                        } label: {
                                            Text(group.name).fontWeight(.medium).lineLimit(1)
                                        }.buttonStyle(.plain)
                                        if monitor.warnings[group.id] != nil {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                            Button { monitor.ignoreWarnings(for: group) } label: {
                                                Image(systemName: "bell.slash")
                                                    .frame(width: 20, height: 20)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                            .help("Ignore resource warnings for " + group.name)
                                            .accessibilityLabel("Ignore resource warnings for " + group.name)
                                        }
                                    }
                                    Text(group.totals).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    if !group.ports.isEmpty {
                                        Text("Ports: " + group.ports.map(String.init).joined(separator: ", "))
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                            .help("Listening TCP ports: " + group.ports.map(String.init).joined(separator: ", "))
                                    }
                                }
                                Spacer()
                                Text("\(group.entries.count)").font(.caption).foregroundStyle(.secondary)
                                Button {
                                    if monitor.recentlyRequestedQuit(group) { pendingGroup = group }
                                    else { monitor.stopAll(group) }
                                } label: {
                                    Image(systemName: "power").frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                                .help("Stop All Processes in " + group.name)
                                .accessibilityLabel("Stop All Processes in " + group.name)
                            }
                        }.padding(.vertical, 9)
                        .help(monitor.warnings[group.id] ?? "")
                        Divider()
                    }
                }

            }.scrollIndicators(.hidden).frame(height: 420)
        }.padding(12).frame(width: 360)
        .overlay(alignment: .bottom) {
            if let message = monitor.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // NSPopover supplies the material and corner shape, including its arrow.
        .animation(.easeInOut(duration: 0.25), value: monitor.message)
        .tint(.blue)
        .buttonStyle(.borderedProminent)

        .confirmationDialog("Quit \(pendingGroup?.name ?? "App")?", isPresented: Binding(
            get: { pendingGroup != nil },
            set: { if !$0 { pendingGroup = nil } }
        ), titleVisibility: .visible) {
            Button("Quit Normally") {
                if let group = pendingGroup { monitor.stopAll(group) }
                pendingGroup = nil
            }
            Button("Force Quit All", role: .destructive) {
                if let group = pendingGroup { monitor.stopAll(group, force: true) }
                pendingGroup = nil
            }
            Button("Cancel", role: .cancel) { pendingGroup = nil }
        } message: {
            Text("A quit was already requested. Force quitting stops all listed processes in this group and may lose unsaved work.")
        }
        .alert("Force stop this process?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Force Stop", role: .destructive) { if let pending { monitor.stop(pending, force: true) }; pending = nil }
        } message: { Text("Unsaved work may be lost. \(pending?.name ?? "")") }
    }
}

struct WarningSettingsView: View {
    @AppStorage("warningCPUPercent") private var cpu = 75.0
    @AppStorage("warningMemoryGB") private var memory = 2.0
    @ObservedObject private var monitor = PanelController.shared.monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Resource Warnings").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    Text("CPU Threshold")
                    Stepper(value: $cpu, in: 1...1000, step: 5) {
                        Text("\(cpu.formatted())%").monospacedDigit().frame(width: 85, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("Memory Threshold")
                    Stepper(value: $memory, in: 0.25...128, step: 0.25) {
                        Text("\(memory.formatted()) GB").monospacedDigit().frame(width: 85, alignment: .trailing)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { cpu = 75; memory = 2 }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Ignored Apps").font(.headline)
                Text("Ignored apps stay in the process list but do not trigger resource warnings.")
                    .font(.caption).foregroundStyle(.secondary)
                if monitor.ignoredWarningApps.apps.isEmpty {
                    Text("No ignored apps")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(monitor.ignoredWarningApps.apps.keys.sorted {
                                let left = monitor.ignoredWarningApps.apps[$0] ?? $0
                                let right = monitor.ignoredWarningApps.apps[$1] ?? $1
                                return left == right ? $0 < $1 : left.localizedStandardCompare(right) == .orderedAscending
                            }, id: \.self) { id in
                                HStack {
                                    Text(monitor.ignoredWarningApps.apps[id] ?? id)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(id)
                                    Spacer()
                                    Button("Remove") { monitor.restoreWarnings(for: id) }
                                        .help("Re-enable resource warnings for this app")
                                        .accessibilityLabel("Re-enable resource warnings for " + (monitor.ignoredWarningApps.apps[id] ?? id))
                                }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("bgMon · Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(24).frame(width: 438, height: 460)
        .onChange(of: cpu) { PanelController.shared.monitor.reevaluateWarnings() }
        .onChange(of: memory) { PanelController.shared.monitor.reevaluateWarnings() }
    }
}

@main enum BgMonApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
