// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

private enum Fonts {
    @MainActor static var panel: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    @MainActor static var panelTitle: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    }

    @MainActor static var panelIcon: NSFont {
        NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
    }

    @MainActor static var menu: NSFont {
        NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    }
}

@main
enum LutopApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--lutop-claude-statusline") {
            ClaudeStatusLineBridge.run()
            return
        }
        if CommandLine.arguments.contains("--lutop-claude-disconnect") {
            try? ClaudeBridgeManager.shared.disconnect()
            return
        }

        if CommandLine.arguments.contains("--snapshot")
            || ProcessInfo.processInfo.environment["LUTOP_SNAPSHOT"] == "1" {
            let monitor = SystemMonitor()
            _ = monitor.snapshot()
            Thread.sleep(forTimeInterval: 0.25)
            print(DashboardRenderer.plainText(for: monitor.snapshot()))
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

private extension Notification.Name {
    static let lutopClaudeQuotaUpdated = Notification.Name("dev.yiminglu.lutop.claudeQuotaUpdated")
}

private final class SnapshotProvider: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.yiminglu.lutop.snapshot", qos: .utility)
    private var monitor: SystemMonitor?
    private var isRunning = false
    private var hasPendingRefresh = false

    func request(_ completion: @escaping @MainActor (MetricsSnapshot) -> Void) {
        queue.async { [self] in
            if isRunning {
                hasPendingRefresh = true
                return
            }

            isRunning = true
            collect(completion)
        }
    }

    private func collect(_ completion: @escaping @MainActor (MetricsSnapshot) -> Void) {
        let snapshot = snapshot()
        Task { @MainActor in
            completion(snapshot)
        }

        queue.async { [self] in
            if hasPendingRefresh {
                hasPendingRefresh = false
                collect(completion)
            } else {
                isRunning = false
            }
        }
    }

    private func snapshot() -> MetricsSnapshot {
        if monitor == nil {
            monitor = SystemMonitor()
        }
        return monitor!.snapshot()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapshotProvider = SnapshotProvider()
    private let panel = MonitorPanelView(frame: NSRect(x: 0, y: 0, width: 695, height: 368))
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var rightClickMonitor: Any?
    private var startAtLoginEnabled = false
    private var claudeUsageAvailable = false
    private var claudeUsageConnected = false
    private lazy var panelWindow: NSPanel = {
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: panel.bounds.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = panel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .vibrantDark)
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.hidesOnDeactivate = false
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        item.button?.sendAction(on: [.leftMouseDown])
        statusItem = item
        startRightClickMonitor()
        startClaudeQuotaObserver()
        try? LoginItemManager.shared.migrateIfNeeded()
        startAtLoginEnabled = LoginItemManager.shared.isEnabled
        refreshClaudeUsageState()

        refresh()
        timer = Timer.scheduledTimer(
            timeInterval: 4,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panelWindow.isVisible {
            hidePanel()
            return
        }

        showPanel(from: sender)
    }

    @objc private func refresh() {
        snapshotProvider.request { [weak self] snapshot in
            self?.display(snapshot)
        }
    }

    private func display(_ snapshot: MetricsSnapshot) {
        panel.render(snapshot)
        updateStatusItem(snapshot)
    }

    @objc private func toggleStartAtLogin(_ sender: Any?) {
        do {
            let nextValue = !startAtLoginEnabled
            try LoginItemManager.shared.setEnabled(nextValue)
            startAtLoginEnabled = nextValue
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to update Start at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func toggleClaudeUsage(_ sender: Any?) {
        do {
            if claudeUsageConnected {
                try ClaudeBridgeManager.shared.disconnect()
            } else {
                try ClaudeBridgeManager.shared.connect()
            }
            refreshClaudeUsageState()
            refresh()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to update Claude Usage"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func handleClaudeQuotaNotification(_ notification: Notification) {
        QuotaMonitor.shared.updateClaude(from: notification.userInfo)
        refreshClaudeUsageState()
        refresh()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func showPanel(from sender: NSStatusBarButton) {
        refresh()

        let size = panel.bounds.size
        guard let sourceWindow = sender.window else {
            panelWindow.setFrame(NSRect(origin: .zero, size: size), display: true)
            panelWindow.orderFrontRegardless()
            startOutsideClickMonitor()
            return
        }

        let buttonFrame = sourceWindow.convertToScreen(sender.convert(sender.bounds, to: nil))
        let screenFrame = (sourceWindow.screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let margin: CGFloat = 8
        let x = min(max(buttonFrame.midX - size.width / 2, screenFrame.minX + margin), screenFrame.maxX - size.width - margin)
        var y = buttonFrame.minY - size.height - margin
        if y < screenFrame.minY + margin {
            y = buttonFrame.maxY + margin
        }

        panelWindow.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panelWindow.orderFrontRegardless()
        startOutsideClickMonitor()
    }

    private func hidePanel() {
        panelWindow.orderOut(nil)
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func startRightClickMonitor() {
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let sender = self.statusItem?.button,
                  event.window === sender.window else {
                return event
            }

            let point = sender.convert(event.locationInWindow, from: nil)
            guard sender.bounds.contains(point) else {
                return event
            }

            self.showContextMenu(from: sender)
            return nil
        }
    }

    private func startClaudeQuotaObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleClaudeQuotaNotification(_:)),
            name: .lutopClaudeQuotaUpdated,
            object: nil
        )
    }

    private func refreshClaudeUsageState() {
        claudeUsageAvailable = ClaudeBridgeManager.shared.isClaudeAvailable
        claudeUsageConnected = ClaudeBridgeManager.shared.isConnected
        QuotaMonitor.shared.setClaudeBridge(available: claudeUsageAvailable, connected: claudeUsageConnected)
    }

    private func showContextMenu(from sender: NSStatusBarButton) {
        hidePanel()
        let menu = NSMenu()

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = startAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let claudeItemTitle: String
        if !claudeUsageAvailable {
            claudeItemTitle = "Connect Claude Usage (Claude not found)"
        } else if claudeUsageConnected {
            claudeItemTitle = "Disconnect Claude Usage"
        } else {
            claudeItemTitle = "Connect Claude Usage"
        }
        let claudeItem = NSMenuItem(title: claudeItemTitle, action: #selector(toggleClaudeUsage(_:)), keyEquivalent: "")
        claudeItem.target = self
        claudeItem.isEnabled = claudeUsageAvailable
        claudeItem.state = claudeUsageConnected ? .on : .off
        menu.addItem(claudeItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Lutop", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    private func updateStatusItem(_ snapshot: MetricsSnapshot) {
        let attributed = NSMutableAttributedString()
        appendStatus("CPU ", to: attributed, color: NSColor.labelColor)
        appendStatus("\(Int(snapshot.cpu.totalUsage.rounded()))%", to: attributed, color: NSColor.labelColor)
        appendStatus("  MEM ", to: attributed, color: NSColor.labelColor)
        appendStatus("\(Int(snapshot.memory.usedPercent.rounded()))% ", to: attributed, color: NSColor.labelColor)
        statusItem?.button?.attributedTitle = attributed
        statusItem?.button?.toolTip = "Lutop resource monitor"
    }

    private func appendStatus(_ string: String, to attributed: NSMutableAttributedString, color: NSColor) {
        attributed.append(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: Fonts.menu,
                    .foregroundColor: color,
                    .baselineOffset: 0
                ]
            )
        )
    }
}

private final class MonitorPanelView: NSView {
    private let blurView = NSVisualEffectView(frame: .zero)
    private let tintView = NSView(frame: .zero)
    private let textView = NSTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        blurView.appearance = NSAppearance(named: .vibrantDark)
        blurView.material = .popover
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.alphaValue = 0.55
        blurView.autoresizingMask = [.width, .height]
        blurView.frame = bounds
        addSubview(blurView)

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = Palette.backgroundTint.cgColor
        tintView.autoresizingMask = [.width, .height]
        tintView.frame = bounds
        addSubview(tintView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width, .height]
        textView.frame = bounds
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func render(_ snapshot: MetricsSnapshot) {
        textView.textStorage?.setAttributedString(DashboardRenderer.attributedText(for: snapshot))
    }
}

@MainActor
private final class LoginItemManager {
    static let shared = LoginItemManager()

    private let label = "dev.yiminglu.lutop.login"
    private let fileManager = FileManager.default

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private var installedAppURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Lutop.app", isDirectory: true)
    }

    var isEnabled: Bool {
        guard let dict = launchAgentPlist(),
              let args = dict["ProgramArguments"] as? [String],
              dict["Label"] as? String == label else {
            return false
        }
        return args.contains(installedAppURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    func migrateIfNeeded() throws {
        guard let dict = launchAgentPlist(),
              let args = dict["ProgramArguments"] as? [String],
              dict["Label"] as? String == label,
              !args.contains(installedAppURL.path),
              args.contains(where: { $0.hasSuffix("/dist/Lutop.app") }),
              fileManager.fileExists(atPath: installedAppURL.path) else {
            return
        }
        try enable()
    }

    private func enable() throws {
        guard fileManager.fileExists(atPath: installedAppURL.path) else {
            throw LoginItemError.installedAppMissing(installedAppURL.path)
        }

        let directory = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-n", installedAppURL.path],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func disable() throws {
        guard fileManager.fileExists(atPath: launchAgentURL.path) else {
            return
        }
        try fileManager.removeItem(at: launchAgentURL)
    }

    private func launchAgentPlist() -> [String: Any]? {
        guard let data = try? Data(contentsOf: launchAgentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }
}

private enum LoginItemError: LocalizedError {
    case installedAppMissing(String)

    var errorDescription: String? {
        switch self {
        case .installedAppMissing(let path):
            return "Install Lutop to \(path) before enabling Start at Login."
        }
    }
}

private final class ClaudeBridgeManager: @unchecked Sendable {
    static let shared = ClaudeBridgeManager()

    private let fileManager = FileManager.default
    private let backupKey = "lutopStatusLineBackup"
    private let bridgeArgument = "--lutop-claude-statusline"

    var isClaudeAvailable: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var isConnected: Bool {
        guard let settings = try? readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command.contains(bridgeArgument)
    }

    func connect() throws {
        guard isClaudeAvailable else {
            throw ClaudeBridgeError.claudeNotFound(configDirectory.path)
        }
        guard fileManager.fileExists(atPath: installedExecutableURL.path) else {
            throw ClaudeBridgeError.installedAppMissing(installedExecutableURL.path)
        }

        var settings = try readSettings()
        if !isConnected {
            settings[backupKey] = [
                "version": 1,
                "hadStatusLine": settings["statusLine"] != nil,
                "statusLine": settings["statusLine"] ?? NSNull()
            ]
        } else if settings[backupKey] == nil {
            settings[backupKey] = [
                "version": 1,
                "hadStatusLine": false,
                "statusLine": NSNull()
            ]
        }

        settings["statusLine"] = [
            "type": "command",
            "command": "'\(shellEscaped(installedExecutableURL.path))' \(bridgeArgument)",
            "padding": 0
        ]
        try writeSettings(settings)
    }

    func disconnect() throws {
        guard var settings = try? readSettings() else {
            return
        }

        let currentIsBridge: Bool
        if let statusLine = settings["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String {
            currentIsBridge = command.contains(bridgeArgument)
        } else {
            currentIsBridge = false
        }

        if currentIsBridge,
           let backup = settings[backupKey] as? [String: Any],
           (backup["hadStatusLine"] as? Bool) == true,
           let original = backup["statusLine"],
           !(original is NSNull) {
            settings["statusLine"] = original
        } else if currentIsBridge {
            settings.removeValue(forKey: "statusLine")
        }
        settings.removeValue(forKey: backupKey)
        try writeSettings(settings)
    }

    func originalStatusLineCommand() -> String? {
        guard let settings = try? readSettings(),
              let backup = settings[backupKey] as? [String: Any],
              let original = backup["statusLine"] as? [String: Any],
              let command = original["command"] as? String,
              !command.contains(bridgeArgument) else {
            return nil
        }
        return command
    }

    private var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["LUTOP_CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private var settingsURL: URL {
        configDirectory.appendingPathComponent("settings.json")
    }

    private var installedExecutableURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Lutop.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/Lutop")
    }

    private func readSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

private enum ClaudeBridgeError: LocalizedError {
    case claudeNotFound(String)
    case installedAppMissing(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound(let path):
            return "Claude Code config was not found at \(path)."
        case .installedAppMissing(let path):
            return "Install Lutop to \(path) before connecting Claude Usage."
        }
    }
}

private enum ClaudeStatusLineBridge {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let quota = parseQuota(from: input) {
            DistributedNotificationCenter.default().postNotificationName(
                .lutopClaudeQuotaUpdated,
                object: nil,
                userInfo: quota,
                deliverImmediately: true
            )
        }

        if let command = ClaudeBridgeManager.shared.originalStatusLineCommand(),
           let output = runOriginalStatusLine(command: command, input: input),
           !output.isEmpty {
            FileHandle.standardOutput.write(output)
        }
    }

    private static func parseQuota(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return nil
        }

        let rateLimits = dictionary(root["rate_limits"])
            ?? dictionary(root["rateLimits"])
            ?? dictionary(root["rateLimit"])
        guard let rateLimits else {
            return nil
        }

        var output: [String: Any] = ["received_at": Date().timeIntervalSince1970]
        if let fiveHour = dictionary(rateLimits["five_hour"]) ?? dictionary(rateLimits["fiveHour"]) {
            output["five_hour_percent"] = remainingPercent(from: fiveHour)
            output["five_hour_reset"] = resetEpoch(from: fiveHour)
        }
        if let sevenDay = dictionary(rateLimits["seven_day"]) ?? dictionary(rateLimits["sevenDay"]) {
            output["seven_day_percent"] = remainingPercent(from: sevenDay)
            output["seven_day_reset"] = resetEpoch(from: sevenDay)
        }
        if let plan = root["plan"] as? String {
            output["plan"] = plan
        }
        return output.keys.count > 1 ? output : nil
    }

    private static func runOriginalStatusLine(command: String, input: Data) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(input)
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return outputPipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }
}

private enum Palette {
    static let backgroundTint = NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.42)
    static let foreground = NSColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
    static let muted = NSColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1)
    static let purple = NSColor(red: 0.79, green: 0.61, blue: 0.94, alpha: 1)
    static let green = NSColor(red: 0.64, green: 0.84, blue: 0.65, alpha: 1)
    static let yellow = NSColor(red: 0.97, green: 0.80, blue: 0.31, alpha: 1)
    static let red = NSColor(red: 0.96, green: 0.35, blue: 0.34, alpha: 1)
    static let barEmpty = NSColor(red: 0.29, green: 0.36, blue: 0.32, alpha: 1)

    static func loadColor(_ value: Double) -> NSColor {
        if value >= 85 {
            return red
        }
        if value >= 60 {
            return yellow
        }
        return green
    }

    static func capacityColor(_ value: Double) -> NSColor {
        if value < 25 {
            return red
        }
        if value < 50 {
            return yellow
        }
        return green
    }
}

private enum DashboardRenderer {
    private struct Card {
        let icon: String
        let title: String
        let lines: [String]
    }

    private static let columnWidth = 45
    private static let columnGap = "  "
    private static let labelWidth = 6
    private static let barWidth = 16
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
    private static var totalWidth: Int {
        columnWidth * 2 + columnGap.count
    }

    @MainActor
    static func attributedText(for snapshot: MetricsSnapshot) -> NSAttributedString {
        let text = plainText(for: snapshot)
        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: Fonts.panel,
                .foregroundColor: Palette.foreground
            ]
        )

        colorWords(["AC", "Charging", "Charged", "Healthy", "Connected"], in: output, color: Palette.green)
        colorWords(["Fair", "Waiting", "Stale"], in: output, color: Palette.yellow)
        colorWords(["Service Soon", "No battery", "Not connected", "No quota data", "Claude not found"], in: output, color: Palette.red)
        colorUptime(uptimeStatusText(snapshot.uptime), in: output, severity: uptimeSeverity(snapshot.uptime))
        colorCharacters(["░", "▯"], in: output, color: Palette.barEmpty)
        colorCharacters(["●"], in: output, color: Palette.green)
        emphasizeTitles(in: output)
        colorBars(in: output)
        colorTemperatures(in: output)
        applyHeaderSpacing(in: output)
        return output
    }

    static func plainText(for snapshot: MetricsSnapshot) -> String {
        var lines: [String] = []
        lines.append(
            headerLine(snapshot).fit(to: totalWidth)
        )

        let cards = [
            cpuCard(snapshot.cpu),
            memoryCard(snapshot.memory),
            diskCard(snapshot.disk),
            powerCard(snapshot.battery),
            processCard(snapshot.processes),
            networkCard(snapshot.network),
            quotaCard(title: "Codex", icon: "◎", status: snapshot.quota.codex),
            quotaCard(title: "Claude", icon: "✳", status: snapshot.quota.claude)
        ]
        lines.append(renderCards(cards))

        return lines.joined(separator: "\n")
    }

    private static func headerLine(_ snapshot: MetricsSnapshot) -> String {
        let output = "Status  Health ● \(snapshot.healthScore)"
        let summary = snapshot.hardware.summary(diskTotal: snapshot.disk.total)
        let uptime = uptimeStatusText(snapshot.uptime)
        let candidates = [
            "\(output)  \(summary) · macOS \(snapshot.osVersion) · \(uptime)",
            "\(output)  \(summary) · \(uptime)",
            "\(output)  \(summary)",
            "\(output)  \(uptime)",
            output
        ]
        return candidates.first { $0.count <= totalWidth } ?? output.fit(to: totalWidth)
    }

    private static func healthDiagnosis(_ snapshot: MetricsSnapshot) -> String {
        if snapshot.cpu.totalUsage > 85 {
            if let process = snapshot.processes.first, process.cpuPercent > 50 {
                return "\(process.name.fit(to: 18)) high CPU"
            }
            return "CPU load high"
        }
        if snapshot.memory.usedPercent > 88 {
            return "Memory pressure high"
        }
        if snapshot.disk.usedPercent > 93 {
            return "Disk low, \(shortBytes(snapshot.disk.free)) free"
        }
        if let battery = snapshot.battery {
            if battery.healthPercent < 80 {
                return "Battery health low"
            }
            if let cycles = battery.cycleCount, cycles > 800 {
                return "Battery cycles high"
            }
        }
        if uptimeSeverity(snapshot.uptime) == .danger {
            return "Long uptime"
        }
        return "All clear"
    }

    private static func cpuCard(_ cpu: CPUMetrics) -> Card {
        var lines = [
            row("Total", bar(cpu.totalUsage), String(format: "%5.1f%%", cpu.totalUsage))
        ]

        let hottest = cpu.coreUsages
            .enumerated()
            .sorted { $0.element > $1.element }
            .prefix(2)
        for core in hottest {
            lines.append(row("Core\(core.offset + 1)", bar(core.element), String(format: "%5.1f%%", core.element)))
        }

        lines.append(textLine("Load", "\(cpu.loadAverage), \(cpu.coreCount) cores"))
        return Card(icon: "◉", title: "CPU", lines: lines)
    }

    private static func memoryCard(_ memory: MemoryMetrics) -> Card {
        var lines = [
            row("Used", bar(memory.usedPercent), String(format: "%5.1f%%", memory.usedPercent)),
            row("Free", bar(memory.freePercent), String(format: "%5.1f%%", memory.freePercent))
        ]

        if memory.swapTotal > 0 || memory.swapUsed > 0 {
            lines.append(row("Swap", bar(memory.swapPercent), "\(shortBytes(memory.swapUsed))/\(shortBytes(memory.swapTotal))"))
            lines.append(textLine("Total", "\(bytes(memory.used)) / \(bytes(memory.total)) · Avail \(shortBytes(memory.free))"))
        } else {
            lines.append(textLine("Total", "\(bytes(memory.used)) / \(bytes(memory.total))"))
            lines.append(textLine("Avail", bytes(memory.free)))
        }
        return Card(icon: "◫", title: "Memory", lines: lines)
    }

    private static func diskCard(_ disk: DiskMetrics) -> Card {
        return Card(
            icon: "▥",
            title: "Disk",
            lines: [
                row("INTR", bar(disk.usedPercent), "\(shortBytes(disk.used)) used, \(shortBytes(disk.free)) free"),
                textLine("Total", "\(shortBytes(disk.total)) · \(disk.filesystem)"),
                textLine("Read", "\(ioBar(disk.readRate))  \(formatRate(disk.readRate))"),
                textLine("Write", "\(ioBar(disk.writeRate))  \(formatRate(disk.writeRate))")
            ]
        )
    }

    private static func powerCard(_ battery: BatteryMetrics?) -> Card {
        guard let battery else {
            return Card(icon: "◪", title: "Power", lines: [textLine("Battery", "No battery")])
        }

        var lines = [
            row("Level", batteryBar(battery.percent), String(format: "%5.1f%%", battery.percent)),
            row("Health", batteryBar(battery.healthPercent), String(format: "%5.0f%%", battery.healthPercent))
        ]

        lines.append(textLine("", powerStatusLine(battery)))
        lines.append(textLine("", batterySummaryLine(battery)))
        return Card(icon: "◪", title: "Power", lines: lines)
    }

    private static func processCard(_ processes: [TopProcess]) -> Card {
        guard !processes.isEmpty else {
            return Card(icon: "❊", title: "Processes", lines: [textLine("", "Collecting...")])
        }

        let lines = processes.prefix(3).enumerated().map { index, process in
            let rank = "#\(index + 1)"
            let prefix = "\(rank.padded(to: labelWidth)) \(miniBar(process.cpuPercent)) \(String(format: "%5.1f%%", process.cpuPercent))"
            let memory = processMemoryText(process)
            let withMemory = memory.isEmpty ? prefix : "\(prefix) \(memory.padded(to: 6))"
            let nameWidth = max(0, columnWidth - withMemory.count - 1)
            return "\(withMemory) \(process.name.fit(to: nameWidth))".fit(to: columnWidth)
        }
        return Card(icon: "❊", title: "Processes", lines: lines)
    }

    private static func networkCard(_ network: NetworkMetrics) -> Card {
        let sparkWidth = min(max(columnWidth - 22, 5), 16)
        var lines = [
            textLine("Down", "\(sparkline(network.downHistory, current: network.downRate, width: sparkWidth))  \(formatRate(network.downRate))"),
            textLine("Up", "\(sparkline(network.upHistory, current: network.upRate, width: sparkWidth))  \(formatRate(network.upRate))")
        ]
        if network.proxy != "Off" {
            lines.append(textLine("", "Proxy \(network.proxy)"))
        }
        return Card(icon: "⇅", title: "Network", lines: lines)
    }

    private static func quotaCard(title: String, icon: String, status: QuotaServiceStatus) -> Card {
        switch status.state {
        case .available, .stale:
            var lines = status.windows.prefix(2).map { window in
                row(window.label, bar(window.remainingPercent ?? 0), quotaValue(window))
            }
            lines.append(textLine("Reset", resetSummary(for: status.windows)))
            let detail = status.state == .stale ? "Stale · \(status.detail)" : status.detail
            lines.append(textLine("Plan", detail))
            return Card(icon: icon, title: title, lines: lines)
        case .waiting:
            return Card(icon: icon, title: title, lines: [
                textLine("", "Waiting for Claude"),
                textLine("", "Open Claude Code")
            ])
        case .notConnected:
            return Card(icon: icon, title: title, lines: [
                textLine("", "Not connected"),
                textLine("", "Right-click to connect")
            ])
        case .unavailable:
            return Card(icon: icon, title: title, lines: [
                textLine("", "Claude not found")
            ])
        case .noData:
            return Card(icon: icon, title: title, lines: [
                textLine("", "No quota data"),
                textLine("", "Run \(title) to update")
            ])
        }
    }

    private static func renderCards(_ cards: [Card]) -> String {
        var rows: [String] = []
        var index = 0
        while index < cards.count {
            let left = renderCard(cards[index])
            let right = index + 1 < cards.count ? renderCard(cards[index + 1]) : []
            let targetHeight = max(left.count, right.count)
            let paddedLeft = left + Array(repeating: "", count: targetHeight - left.count)
            let paddedRight = right + Array(repeating: "", count: targetHeight - right.count)

            for lineIndex in 0..<targetHeight {
                rows.append(paddedLeft[lineIndex].columnPadded(to: columnWidth) + columnGap + paddedRight[lineIndex].columnPadded(to: columnWidth))
            }
            index += 2
            if index < cards.count {
                rows.append("")
            }
        }
        return rows.joined(separator: "\n")
    }

    private static func renderCard(_ card: Card) -> [String] {
        let title = "\(card.icon) \(card.title)"
        let lineLength = max(0, columnWidth - title.count - 2)
        var lines = ["\(title)  \(String(repeating: "╌", count: lineLength))".fit(to: columnWidth)]
        lines.append(contentsOf: card.lines.map { $0.fit(to: columnWidth) })
        return lines
    }

    private static func row(_ label: String, _ barOrValue: String, _ value: String) -> String {
        "\(label.padded(to: labelWidth)) \(barOrValue)  \(value)".fit(to: columnWidth)
    }

    private static func textLine(_ label: String, _ value: String) -> String {
        if label.isEmpty {
            return value.fit(to: columnWidth)
        }
        return "\(label.padded(to: labelWidth)) \(value)".fit(to: columnWidth)
    }

    private static func quotaValue(_ window: QuotaWindow) -> String {
        guard let remainingPercent = window.remainingPercent else {
            return "--"
        }
        return String(format: "%4.0f%% left", remainingPercent)
    }

    private static func resetText(_ date: Date?) -> String {
        guard let date else {
            return "--"
        }
        if date <= Date() {
            return "reset"
        }

        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return DashboardRenderer.timeFormatter.string(from: date)
        }
        return DashboardRenderer.dateTimeFormatter.string(from: date)
    }

    private static func resetSummary(for windows: [QuotaWindow]) -> String {
        let visibleWindows = Array(windows.prefix(2))
        guard !visibleWindows.isEmpty else {
            return "--"
        }

        let summary = visibleWindows
            .map { "\($0.label) \(resetText($0.resetAt))" }
            .joined(separator: " · ")
        return summary
    }

    private static func powerStatusLine(_ power: BatteryMetrics) -> String {
        var parts = powerStatusParts(power)
        if let watts = powerStatusWatts(power) {
            parts.append(watts)
        }
        return parts.joined(separator: " · ")
    }

    private static func powerStatusParts(_ power: BatteryMetrics) -> [String] {
        var parts: [String]
        if power.source == .ac {
            if power.isCharging {
                parts = ["Charging"]
            } else if power.percent >= 99.5 {
                parts = ["Charged"]
            } else {
                parts = ["AC"]
            }
        } else {
            parts = ["Discharging"]
        }

        if power.timeText != "--" {
            parts.append(power.timeText)
        }
        return parts
    }

    private static func powerStatusWatts(_ power: BatteryMetrics) -> String? {
        if power.source == .ac {
            if let systemWatts = power.systemWatts, systemWatts > 0 {
                return String(format: "%.0fW ⚡︎", systemWatts)
            }
            if power.isCharging, let watts = power.watts, watts > 0 {
                return String(format: "%.0fW ⚡︎", watts)
            }
            if let inputWatts = power.inputWatts, inputWatts > 0 {
                return String(format: "%.0fW max", inputWatts)
            }
            return nil
        }

        guard let watts = power.watts, watts > 0 else {
            return nil
        }
        return String(format: "%.0fW", watts)
    }

    private static func batterySummaryLine(_ power: BatteryMetrics) -> String {
        var parts: [String] = []
        parts.append(batteryHealthLabel(power))
        if let cycleCount = power.cycleCount {
            parts.append("\(cycleCount) cycles")
        }
        if let temperature = power.temperatureC {
            parts.append(String(format: "Battery %.1f°C", temperature))
        }
        return parts.joined(separator: " · ")
    }

    private static func bar(_ percent: Double, width: Int = barWidth) -> String {
        bar(percent, maxValue: 100, width: width)
    }

    private static func bar(_ value: Double, maxValue: Double, width: Int = barWidth) -> String {
        guard maxValue > 0 else {
            return String(repeating: "░", count: width)
        }
        let ratio = max(0, min(value / maxValue, 1))
        let filled = Int(ratio * Double(width))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
    }

    private static func batteryBar(_ percent: Double) -> String {
        bar(percent)
    }

    private static func miniBar(_ percent: Double) -> String {
        let width = 5
        let filled = max(0, min(Int(percent / 20), width))
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: width - filled)
    }

    private static func ioBar(_ bytesPerSecond: Double) -> String {
        let mb = bytesPerSecond / 1_000_000
        let filled = max(0, min(Int(mb / 10), 5))
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: 5 - filled)
    }

    private static func sparkline(_ history: [Double], current: Double, width: Int) -> String {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        var data = Array(history.suffix(width))
        while data.count < width {
            data.insert(0, at: 0)
        }
        let maxValue = max(data.max() ?? 0, current, 0.1)
        return data.map { value in
            let level = max(0, min(Int((value / maxValue) * Double(blocks.count - 1)), blocks.count - 1))
            return blocks[level]
        }.joined()
    }

    private static func bytes(_ value: UInt64) -> String {
        compactBytes(value)
    }

    private static func shortBytes(_ value: UInt64) -> String {
        shortUnitBytes(value)
    }

    private static func rate(_ value: Double) -> String {
        formatRate(value)
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        let mb = max(0, bytesPerSecond) / 1_000_000
        if mb < 0.01 {
            return "0 MB/s"
        }
        if mb < 1 {
            return String(format: "%.2f MB/s", mb)
        }
        if mb < 10 {
            return String(format: "%.1f MB/s", mb)
        }
        return String(format: "%.0f MB/s", mb)
    }

    private static func formatRateCompact(_ bytesPerSecond: Double) -> String {
        let mb = max(0, bytesPerSecond) / 1_000_000
        if mb < 0.01 {
            return "0"
        }
        if mb < 10 {
            return String(format: "%.1f", mb)
        }
        return String(format: "%.0f", mb)
    }

    private static func processMemoryText(_ process: TopProcess) -> String {
        if process.memoryBytes > 0 {
            return compactUnitBytes(process.memoryBytes)
        }
        if process.memoryPercent >= 10 {
            return String(format: "M%.0f%%", process.memoryPercent)
        }
        return ""
    }

    private static func batteryHealthLabel(_ battery: BatteryMetrics) -> String {
        if let cycles = battery.cycleCount, cycles > 900 || battery.healthPercent < 60 {
            return "Service Soon"
        }
        if let cycles = battery.cycleCount, cycles > 800 || battery.healthPercent < 80 {
            return "Fair"
        }
        return "Healthy"
    }

    private enum UptimeSeverity {
        case ok
        case warn
        case danger
    }

    private static func uptimeSeverity(_ uptime: String) -> UptimeSeverity {
        guard let dayText = uptime.split(separator: "d").first,
              let days = Int(dayText.trimmingCharacters(in: .whitespaces)) else {
            return .ok
        }
        if days > 14 {
            return .danger
        }
        if days > 7 {
            return .warn
        }
        return .ok
    }

    private static func uptimeStatusText(_ uptime: String) -> String {
        switch uptimeSeverity(uptime) {
        case .danger:
            return "up \(uptime) ↻"
        case .warn, .ok:
            return "up \(uptime)"
        }
    }

    private static func colorUptime(_ uptime: String, in output: NSMutableAttributedString, severity: UptimeSeverity) {
        let full = output.string as NSString
        let range = full.range(of: uptime)
        guard range.location != NSNotFound else {
            return
        }

        let color: NSColor
        switch severity {
        case .danger:
            color = Palette.red
        case .warn:
            color = Palette.yellow
        case .ok:
            color = Palette.muted
        }
        output.addAttribute(.foregroundColor, value: color, range: range)
    }

    private static func colorWords(_ words: [String], in output: NSMutableAttributedString, color: NSColor) {
        let full = output.string as NSString
        for word in words {
            var searchRange = NSRange(location: 0, length: full.length)
            while searchRange.location < full.length {
                let range = full.range(of: word, options: [], range: searchRange)
                if range.location == NSNotFound {
                    break
                }
                output.addAttribute(.foregroundColor, value: color, range: range)
                let next = range.location + range.length
                searchRange = NSRange(location: next, length: full.length - next)
            }
        }
    }

    private static func colorCharacters(_ characters: [String], in output: NSMutableAttributedString, color: NSColor) {
        let full = output.string as NSString
        for character in characters {
            var searchRange = NSRange(location: 0, length: full.length)
            while searchRange.location < full.length {
                let range = full.range(of: character, options: [], range: searchRange)
                if range.location == NSNotFound {
                    break
                }
                output.addAttribute(.foregroundColor, value: color, range: range)
                let next = range.location + range.length
                searchRange = NSRange(location: next, length: full.length - next)
            }
        }
    }

    @MainActor
    private static func emphasizeTitles(in output: NSMutableAttributedString) {
        let full = output.string as NSString
        applyTitleWord("Status", in: output, full: full)

        let titles = ["◉ CPU", "◫ Memory", "▥ Disk", "◪ Power", "❊ Processes", "⇅ Network", "◎ Codex", "✳ Claude"]

        for title in titles {
            var searchRange = NSRange(location: 0, length: full.length)
            while searchRange.location < full.length {
                let titleRange = full.range(of: title, options: [], range: searchRange)
                if titleRange.location == NSNotFound {
                    break
                }
                let iconRange = NSRange(location: titleRange.location, length: 1)
                output.addAttributes(
                    [
                        .font: Fonts.panelIcon,
                        .foregroundColor: Palette.purple,
                        .baselineOffset: 0
                    ],
                    range: iconRange
                )
                let labelRange = NSRange(location: titleRange.location + 2, length: titleRange.length - 2)
                output.addAttributes(
                    [
                        .font: Fonts.panelTitle,
                        .foregroundColor: Palette.purple,
                        .baselineOffset: 0
                    ],
                    range: labelRange
                )
                let next = titleRange.location + titleRange.length
                searchRange = NSRange(location: next, length: full.length - next)
            }
        }
    }

    @MainActor
    private static func applyTitleWord(_ title: String, in output: NSMutableAttributedString, full: NSString) {
        var searchRange = NSRange(location: 0, length: full.length)
        while searchRange.location < full.length {
            let range = full.range(of: title, options: [], range: searchRange)
            if range.location == NSNotFound {
                break
            }
            output.addAttributes(
                [
                    .font: Fonts.panelTitle,
                    .foregroundColor: Palette.purple,
                    .baselineOffset: 0
                ],
                range: range
            )
            let next = range.location + range.length
            searchRange = NSRange(location: next, length: full.length - next)
        }
    }

    private static func colorBars(in output: NSMutableAttributedString) {
        let full = output.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "[█░▮▯]{3,}") else {
            return
        }

        let fullRange = NSRange(location: 0, length: full.length)
        for match in regex.matches(in: output.string, range: fullRange) {
            let bar = full.substring(with: match.range)
            let filled = bar.filter { $0 == "█" || $0 == "▮" || $0 == "▁" || $0 == "▂" || $0 == "▃" || $0 == "▄" || $0 == "▅" || $0 == "▆" || $0 == "▇" }.count
            guard filled > 0 else {
                continue
            }

            let ratio = Double(filled) / Double(bar.count)
            let lineRange = full.lineRange(for: match.range)
            let prefixLength = max(0, match.range.location - lineRange.location)
            let prefix = full.substring(with: NSRange(location: lineRange.location, length: prefixLength))
            let color = barColor(ratio: ratio, prefix: prefix)
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func colorTemperatures(in output: NSMutableAttributedString) {
        let full = output.string as NSString
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)°C"#) else {
            return
        }

        let range = NSRange(location: 0, length: full.length)
        for match in regex.matches(in: output.string, range: range) {
            guard let temperature = Double(full.substring(with: match.range(at: 1))) else {
                continue
            }
            let color: NSColor
            if temperature >= 85 {
                color = Palette.red
            } else if temperature >= 65 {
                color = Palette.yellow
            } else {
                color = Palette.green
            }
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func applyHeaderSpacing(in output: NSMutableAttributedString) {
        let full = output.string as NSString
        guard full.length > 0 else {
            return
        }
        let range = full.lineRange(for: NSRange(location: 0, length: 0))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        style.paragraphSpacing = 4
        output.addAttribute(.paragraphStyle, value: style, range: range)
    }

    private static func barColor(ratio: Double, prefix: String) -> NSColor {
        let percent = ratio * 100
        let lowerIsBad = prefix.contains("Free")
            || prefix.contains("Level")
            || prefix.contains("Health")
            || prefix.contains("5h")
            || prefix.contains("1w")
            || prefix.contains("7d")
        if lowerIsBad {
            return Palette.capacityColor(percent)
        }
        return Palette.loadColor(percent)
    }
}

private extension String {
    func padded(to length: Int) -> String {
        if count >= length {
            return String(prefix(length))
        }
        return self + String(repeating: " ", count: length - count)
    }

    func columnPadded(to length: Int) -> String {
        fit(to: length).padded(to: length)
    }

    func fit(to length: Int) -> String {
        guard length > 0 else {
            return ""
        }
        if count <= length {
            return self
        }
        if length == 1 {
            return String(prefix(1))
        }
        return String(prefix(length - 1)) + "…"
    }
}

private struct MetricsSnapshot {
    let hardware: HardwareInfo
    let osVersion: String
    let uptime: String
    let healthScore: Int
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let disk: DiskMetrics
    let battery: BatteryMetrics?
    let network: NetworkMetrics
    let processes: [TopProcess]
    let quota: QuotaSnapshot
}

private struct HardwareInfo {
    let modelName: String
    let modelIdentifier: String
    let chipName: String
    let coreCount: Int
    let gpuCoreCount: Int?
    let memoryBytes: UInt64
    let displayRefreshHz: Double?

    func summary(diskTotal: UInt64) -> String {
        let chip = chipName.replacingOccurrences(of: "Apple ", with: "")
        var output = "\(modelName) · \(chip)"
        if let gpuCoreCount {
            output += ",\(gpuCoreCount)GPU"
        } else {
            output += ",\(coreCount)CPU"
        }

        output += " · \(fixedGigabytesCompact(memoryBytes))/\(fixedGigabytesCompact(diskTotal))"
        if let displayRefreshHz, displayRefreshHz > 0 {
            output += " · \(formatHz(displayRefreshHz))"
        }
        return output
    }
}

private struct CPUMetrics {
    let totalUsage: Double
    let coreUsages: [Double]
    let coreCount: Int
    let loadAverage: String
}

private struct MemoryMetrics {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64

    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
    var freePercent: Double { total == 0 ? 0 : Double(free) / Double(total) * 100 }
    var swapPercent: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) * 100 }
}

private struct DiskMetrics {
    let total: UInt64
    let used: UInt64
    let free: UInt64
    let filesystem: String
    let readRate: Double
    let writeRate: Double

    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
    var freePercent: Double { total == 0 ? 0 : Double(free) / Double(total) * 100 }
}

private struct BatteryMetrics {
    let percent: Double
    let healthPercent: Double
    let condition: String?
    let source: PowerSource
    let isCharging: Bool
    let timeText: String
    let watts: Double?
    let systemWatts: Double?
    let inputWatts: Double?
    let cycleCount: Int?
    let temperatureC: Double?
}

private enum PowerSource {
    case ac
    case battery
}

private struct NetworkMetrics {
    let downRate: Double
    let upRate: Double
    let downHistory: [Double]
    let upHistory: [Double]
    let proxy: String
}

private struct TopProcess {
    let name: String
    let cpuPercent: Double
    let memoryPercent: Double
    let memoryBytes: UInt64
}

private struct QuotaSnapshot {
    let codex: QuotaServiceStatus
    let claude: QuotaServiceStatus
}

private struct QuotaServiceStatus {
    enum State {
        case available
        case stale
        case waiting
        case notConnected
        case unavailable
        case noData
    }

    let state: State
    let windows: [QuotaWindow]
    let detail: String
    let updatedAt: Date?
}

private struct QuotaWindow {
    let label: String
    let remainingPercent: Double?
    let resetAt: Date?
}

private final class QuotaMonitor: @unchecked Sendable {
    static let shared = QuotaMonitor()
    private static let sessionFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let isoFormatter = ISO8601DateFormatter()
    private var codexStatus = QuotaServiceStatus(state: .noData, windows: [], detail: "No quota data", updatedAt: nil)
    private var lastCodexScan = Date.distantPast
    private var claudeAvailable = ClaudeBridgeManager.shared.isClaudeAvailable
    private var claudeConnected = ClaudeBridgeManager.shared.isConnected
    private var claudeWindows: [QuotaWindow] = []
    private var claudePlan: String?
    private var claudeReceivedAt: Date?

    func snapshot() -> QuotaSnapshot {
        scanCodexIfNeeded()
        lock.lock()
        let snapshot = QuotaSnapshot(codex: codexStatus, claude: claudeStatusLocked(now: Date()))
        lock.unlock()
        return snapshot
    }

    func setClaudeBridge(available: Bool, connected: Bool) {
        lock.lock()
        claudeAvailable = available
        claudeConnected = connected
        lock.unlock()
    }

    func updateClaude(from userInfo: [AnyHashable: Any]?) {
        var windows: [QuotaWindow] = []
        if let percent = optionalDouble(userInfo?["five_hour_percent"]) {
            windows.append(QuotaWindow(label: "5h", remainingPercent: percent, resetAt: dateFromEpoch(userInfo?["five_hour_reset"])))
        }
        if let percent = optionalDouble(userInfo?["seven_day_percent"]) {
            windows.append(QuotaWindow(label: "7d", remainingPercent: percent, resetAt: dateFromEpoch(userInfo?["seven_day_reset"])))
        }

        lock.lock()
        if !windows.isEmpty {
            claudeWindows = windows
            claudeReceivedAt = Date()
            claudeConnected = true
        }
        claudePlan = userInfo?["plan"] as? String
        lock.unlock()
    }

    private func scanCodexIfNeeded() {
        let now = Date()
        lock.lock()
        let shouldScan = now.timeIntervalSince(lastCodexScan) >= 60
        if shouldScan {
            lastCodexScan = now
        }
        lock.unlock()

        guard shouldScan else {
            return
        }

        let status = scanCodexStatus(now: now)
        lock.lock()
        codexStatus = status
        lock.unlock()
    }

    private func claudeStatusLocked(now: Date) -> QuotaServiceStatus {
        if !claudeAvailable {
            return QuotaServiceStatus(state: .unavailable, windows: [], detail: "Claude not found", updatedAt: nil)
        }
        if !claudeConnected {
            return QuotaServiceStatus(state: .notConnected, windows: [], detail: "Not connected", updatedAt: nil)
        }
        guard !claudeWindows.isEmpty, let claudeReceivedAt else {
            return QuotaServiceStatus(state: .waiting, windows: [], detail: "Waiting for Claude", updatedAt: nil)
        }

        let isExpired = claudeWindows
            .compactMap(\.resetAt)
            .allSatisfy { $0 <= now }
        let isOld = now.timeIntervalSince(claudeReceivedAt) > 600
        let state: QuotaServiceStatus.State = (isExpired || isOld) ? .stale : .available
        return QuotaServiceStatus(
            state: state,
            windows: claudeWindows,
            detail: claudePlan ?? (state == .stale ? "Stale" : "Connected"),
            updatedAt: claudeReceivedAt
        )
    }

    private func scanCodexStatus(now: Date) -> QuotaServiceStatus {
        guard let candidate = latestCodexRateLimit() else {
            return QuotaServiceStatus(state: .noData, windows: [], detail: "No quota data", updatedAt: nil)
        }

        let isExpired = candidate.windows
            .compactMap(\.resetAt)
            .allSatisfy { $0 <= now }
        return QuotaServiceStatus(
            state: isExpired ? .stale : .available,
            windows: candidate.windows,
            detail: candidate.detail,
            updatedAt: candidate.date
        )
    }

    private struct CodexRateCandidate {
        let date: Date
        let windows: [QuotaWindow]
        let detail: String
    }

    private func latestCodexRateLimit() -> CodexRateCandidate? {
        let files = latestJSONLFiles(in: codexSessionsDirectory(), limit: 80)
        for file in files {
            if let candidate = autoreleasepool(invoking: { latestCodexRateLimit(in: file) }) {
                return candidate
            }
        }
        return nil
    }

    private func latestCodexRateLimit(in file: URL) -> CodexRateCandidate? {
        guard let data = tailData(from: file, maxBytes: 128 * 1024) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let root = object as? [String: Any],
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            guard rateLimits["limit_id"] as? String == "codex" else {
                continue
            }

            let windows = codexWindows(from: rateLimits)
            guard !windows.isEmpty else {
                continue
            }
            let timestamp = root["timestamp"] as? String
            let date = timestamp.flatMap { isoFormatter.date(from: $0) }
                ?? fileModificationDate(file)
                ?? Date.distantPast
            let plan = rateLimits["plan_type"] as? String
            let detail = plan.map { "Codex \($0)" } ?? "Codex"
            return CodexRateCandidate(date: date, windows: windows, detail: detail)
        }
        return nil
    }

    private func codexWindows(from rateLimits: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            guard let value = rateLimits[key] as? [String: Any],
                  let minutes = optionalDouble(value["window_minutes"]),
                  let label = codexWindowLabel(minutes: minutes) else {
                continue
            }
            windows.append(
                QuotaWindow(
                    label: label,
                    remainingPercent: remainingPercent(from: value),
                    resetAt: dateFromEpoch(value["resets_at"])
                )
            )
        }
        return windows.sorted { quotaWindowRank($0.label) < quotaWindowRank($1.label) }
    }

    private func codexWindowLabel(minutes: Double) -> String? {
        if abs(minutes - 300) < 1 {
            return "5h"
        }
        if abs(minutes - 10080) < 1 {
            return "1w"
        }
        return nil
    }

    private func quotaWindowRank(_ label: String) -> Int {
        switch label {
        case "5h":
            return 0
        case "7d", "1w":
            return 1
        default:
            return 9
        }
    }

    private func latestJSONLFiles(in directory: URL, limit: Int) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, date: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            files.append((url, codexSessionDate(from: url) ?? values.contentModificationDate ?? Date.distantPast))
        }
        return files
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    private func codexSessionDate(from url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-"), name.count >= 27 else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: 8)
        let end = name.index(start, offsetBy: 19, limitedBy: name.endIndex) ?? name.endIndex
        let raw = String(name[start..<end])
        guard raw.count == 19 else {
            return nil
        }
        let timestamp = raw.replacingOccurrences(of: #"T([0-9]{2})-([0-9]{2})-([0-9]{2})"#, with: "T$1:$2:$3", options: .regularExpression)
        return Self.sessionFilenameFormatter.date(from: timestamp)
    }

    private func codexSessionsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["LUTOP_CODEX_SESSIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private func tailData(from url: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private final class SystemMonitor {
    private let hardware = SystemMonitor.collectHardware()
    private let osVersion = SystemMonitor.collectOSVersion()
    private let startedAt = Date()
    private var previousCPU: CPUSample?
    private var previousDisk: DiskIOSample?
    private var previousNetwork: NetworkSample?
    private var downHistory: [Double] = []
    private var upHistory: [Double] = []
    private var cachedProcesses: [TopProcess] = []
    private var lastProcessRefresh = Date.distantPast
    private var cachedStartupDisk: StartupDiskSample?
    private var cachedPowerProfile: PowerProfile?

    func snapshot() -> MetricsSnapshot {
        let cpu = collectCPU()
        let memory = collectMemory()
        let disk = collectDisk()
        let battery = collectBattery()
        let network = collectNetwork()
        let processes = collectProcessesIfNeeded()
        let quota = QuotaMonitor.shared.snapshot()
        let uptimeSeconds = Self.collectUptimeSeconds()
        let health = healthScore(cpu: cpu, memory: memory, disk: disk, battery: battery, uptimeSeconds: uptimeSeconds)

        return MetricsSnapshot(
            hardware: hardware,
            osVersion: osVersion,
            uptime: Self.formatUptime(uptimeSeconds),
            healthScore: health,
            cpu: cpu,
            memory: memory,
            disk: disk,
            battery: battery,
            network: network,
            processes: processes,
            quota: quota
        )
    }

    private func collectCPU() -> CPUMetrics {
        let sample = Self.readCPUSample()
        defer { previousCPU = sample }

        let usages: [Double]
        if let previousCPU, previousCPU.cores.count == sample.cores.count {
            usages = zip(previousCPU.cores, sample.cores).map { previous, current in
                let total = Double(current.total - previous.total)
                guard total > 0 else {
                    return 0
                }
                let idle = Double(current.idle - previous.idle)
                return max(0, min(100, (1 - idle / total) * 100))
            }
        } else {
            usages = Array(repeating: 0, count: sample.cores.count)
        }

        let total = usages.isEmpty ? 0 : usages.reduce(0, +) / Double(usages.count)
        return CPUMetrics(
            totalUsage: total,
            coreUsages: usages,
            coreCount: hardware.coreCount,
            loadAverage: Self.loadAverage()
        )
    }

    private func collectMemory() -> MemoryMetrics {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else {
            return MemoryMetrics(total: total, used: 0, free: total, swapUsed: 0, swapTotal: 0)
        }

        let usedPages = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count)
        let used = min(total, usedPages * UInt64(pageSize))
        let free = total > used ? total - used : 0
        let swap = Self.collectSwap()
        return MemoryMetrics(total: total, used: used, free: free, swapUsed: swap.used, swapTotal: swap.total)
    }

    private func collectDisk() -> DiskMetrics {
        let attrs = (try? FileManager.default.attributesOfFileSystem(forPath: "/")) ?? [:]
        var total = UInt64((attrs[.systemSize] as? NSNumber)?.int64Value ?? 0)
        var free = UInt64((attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
        if let startupDisk = collectStartupDiskIfNeeded() {
            total = startupDisk.total
            free = startupDisk.free
        }
        let used = total > free ? total - free : 0
        let filesystem = Self.fileSystemName()

        let sample = Self.readDiskIOSample()
        let readRate: Double
        let writeRate: Double
        if let previousDisk {
            let elapsed = sample.date.timeIntervalSince(previousDisk.date)
            if elapsed > 0 {
                readRate = Double(sample.bytesRead.saturatingSubtract(previousDisk.bytesRead)) / elapsed
                writeRate = Double(sample.bytesWritten.saturatingSubtract(previousDisk.bytesWritten)) / elapsed
            } else {
                readRate = 0
                writeRate = 0
            }
        } else {
            readRate = 0
            writeRate = 0
        }
        previousDisk = sample

        return DiskMetrics(
            total: total,
            used: used,
            free: free,
            filesystem: filesystem,
            readRate: readRate,
            writeRate: writeRate
        )
    }

    private func collectStartupDiskIfNeeded() -> StartupDiskSample? {
        if let cachedStartupDisk, Date().timeIntervalSince(cachedStartupDisk.date) < 120 {
            return cachedStartupDisk
        }

        do {
            let url = URL(fileURLWithPath: "/")
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            guard let totalValue = values.volumeTotalCapacity,
                  let freeValue = values.volumeAvailableCapacityForImportantUsage,
                  totalValue > 0,
                  freeValue > 0,
                  freeValue <= totalValue else {
                return cachedStartupDisk
            }
            let sample = StartupDiskSample(free: UInt64(freeValue), total: UInt64(totalValue), date: Date())
            cachedStartupDisk = sample
            return sample
        } catch {
            return cachedStartupDisk
        }
    }

    private func collectBattery() -> BatteryMetrics? {
        guard let sourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(sourceInfo)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(sourceInfo, source)?.takeUnretainedValue() as? [String: Any] else {
            return Self.collectSmartBatteryFallback()
        }

        let current = double(description[kIOPSCurrentCapacityKey as String])
        let maxCapacity = double(description[kIOPSMaxCapacityKey as String])
        let percent = maxCapacity > 0 ? current / maxCapacity * 100 : 0
        let isCharging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
        let powerSource = Self.powerSource(from: description[kIOPSPowerSourceStateKey as String] as? String, isCharging: isCharging)
        let timeToFull = int(description[kIOPSTimeToFullChargeKey as String])
        let timeToEmpty = int(description[kIOPSTimeToEmptyKey as String])

        let smart = Self.smartBatteryDetails()
        let profile = collectPowerProfileIfNeeded()
        return BatteryMetrics(
            percent: percent,
            healthPercent: profile.maximumCapacityPercent.map(Double.init) ?? smart.healthPercent ?? 100,
            condition: profile.condition,
            source: powerSource,
            isCharging: isCharging,
            timeText: Self.timeText(isCharging: isCharging, fullMinutes: timeToFull, emptyMinutes: timeToEmpty),
            watts: smart.watts,
            systemWatts: smart.systemWatts,
            inputWatts: profile.adapterWatts.map(Double.init) ?? smart.inputWatts,
            cycleCount: profile.cycleCount ?? smart.cycleCount,
            temperatureC: smart.temperatureC
        )
    }

    private func collectPowerProfileIfNeeded() -> PowerProfile {
        if let cachedPowerProfile, Date().timeIntervalSince(cachedPowerProfile.date) < 600 {
            return cachedPowerProfile
        }

        let output = Self.commandOutput("/usr/sbin/system_profiler", ["SPPowerDataType"])
        let profile = Self.parsePowerProfile(output)
        cachedPowerProfile = profile
        return profile
    }

    private func collectNetwork() -> NetworkMetrics {
        let sample = Self.readNetworkSample()
        let downRate: Double
        let upRate: Double
        if let previousNetwork {
            let elapsed = sample.date.timeIntervalSince(previousNetwork.date)
            if elapsed > 0 {
                downRate = Double(sample.bytesIn.saturatingSubtract(previousNetwork.bytesIn)) / elapsed
                upRate = Double(sample.bytesOut.saturatingSubtract(previousNetwork.bytesOut)) / elapsed
            } else {
                downRate = 0
                upRate = 0
            }
        } else {
            downRate = 0
            upRate = 0
        }
        previousNetwork = sample
        downHistory = Self.appendHistory(downRate, to: downHistory)
        upHistory = Self.appendHistory(upRate, to: upHistory)
        return NetworkMetrics(
            downRate: downRate,
            upRate: upRate,
            downHistory: downHistory,
            upHistory: upHistory,
            proxy: Self.proxySummary()
        )
    }

    private func collectProcessesIfNeeded() -> [TopProcess] {
        guard Date().timeIntervalSince(lastProcessRefresh) > 15 else {
            return cachedProcesses
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-arcwwwxo", "comm,pcpu,pmem,rss"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            cachedProcesses = output
                .split(separator: "\n")
                .dropFirst()
                .compactMap(Self.parseProcessLine)
                .filter { $0.cpuPercent > 0 }
                .prefix(3)
                .map { $0 }
            lastProcessRefresh = Date()
        } catch {
            cachedProcesses = []
        }

        return cachedProcesses
    }

    private static func appendHistory(_ value: Double, to history: [Double]) -> [Double] {
        var output = history
        output.append(value)
        if output.count > 24 {
            output.removeFirst(output.count - 24)
        }
        return output
    }

    private func healthScore(
        cpu: CPUMetrics,
        memory: MemoryMetrics,
        disk: DiskMetrics,
        battery: BatteryMetrics?,
        uptimeSeconds: Int
    ) -> Int {
        var score = 100.0

        if cpu.totalUsage > 50 {
            if cpu.totalUsage > 85 {
                score -= 30 * (cpu.totalUsage - 50) / 85
            } else {
                score -= 15 * (cpu.totalUsage - 50) / 35
            }
        }

        if memory.usedPercent > 70 {
            if memory.usedPercent > 88 {
                score -= 25 * (memory.usedPercent - 70) / 70
            } else {
                score -= 12.5 * (memory.usedPercent - 70) / 18
            }
        }

        if disk.usedPercent > 80 {
            if disk.usedPercent > 93 {
                score -= 20 * (disk.usedPercent - 80) / 20
            } else {
                score -= 10 * (disk.usedPercent - 80) / 13
            }
        }

        let diskIOMB = (disk.readRate + disk.writeRate) / 1_000_000
        if diskIOMB > 50 {
            if diskIOMB > 150 {
                score -= 10
            } else {
                score -= 10 * (diskIOMB - 50) / 100
            }
        }

        if let battery {
            if battery.healthPercent < 60 {
                score -= 5
            } else if battery.healthPercent < 80 {
                score -= 2
            }
            if let cycles = battery.cycleCount, cycles > 900 {
                score -= 5
            } else if let cycles = battery.cycleCount, cycles > 800 {
                score -= 2
            }
        }

        if uptimeSeconds > 14 * 86_400 {
            score -= 10
        } else if uptimeSeconds > 7 * 86_400 {
            score -= 3
        }

        return max(1, min(100, Int(score.rounded())))
    }

    private static func collectHardware() -> HardwareInfo {
        let hardwareOutput = commandOutput("/usr/sbin/system_profiler", ["SPHardwareDataType"])
        let displayOutput = commandOutput("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
        let modelIdentifier = sysctlString("hw.model") ?? "Mac"
        let modelName = profilerValue("Model Name", in: hardwareOutput) ?? friendlyModelName(from: modelIdentifier)
        let chipName = profilerValue("Chip", in: hardwareOutput)
            ?? sysctlString("machdep.cpu.brand_string")
            ?? "Apple Silicon"

        return HardwareInfo(
            modelName: modelName,
            modelIdentifier: modelIdentifier,
            chipName: chipName,
            coreCount: max(1, intSysctl("hw.ncpu") ?? ProcessInfo.processInfo.processorCount),
            gpuCoreCount: firstIntegerValue("Total Number of Cores", in: displayOutput),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            displayRefreshHz: refreshRate(in: displayOutput)
        )
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func parsePowerProfile(_ output: String) -> PowerProfile {
        var condition: String?
        var cycleCount: Int?
        var maximumCapacityPercent: Int?
        var adapterWatts: Int?

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Condition:") {
                condition = trimmed.dropFirst("Condition:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Cycle Count:") {
                cycleCount = Int(trimmed.dropFirst("Cycle Count:".count).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("Maximum Capacity:") {
                let value = trimmed
                    .dropFirst("Maximum Capacity:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "%"))
                maximumCapacityPercent = Int(value)
            } else if trimmed.hasPrefix("Wattage (W):") {
                adapterWatts = Int(trimmed.dropFirst("Wattage (W):".count).trimmingCharacters(in: .whitespaces))
            }
        }

        return PowerProfile(
            condition: condition,
            cycleCount: cycleCount,
            maximumCapacityPercent: maximumCapacityPercent,
            adapterWatts: adapterWatts,
            date: Date()
        )
    }

    private static func profilerValue(_ key: String, in output: String) -> String? {
        let prefix = "\(key):"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func firstIntegerValue(_ key: String, in output: String) -> Int? {
        guard let value = profilerValue(key, in: output) else {
            return nil
        }
        return Int(value.split(separator: " ").first ?? "")
    }

    private static func refreshRate(in output: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"@\s*([0-9]+(?:\.[0-9]+)?)Hz"#) else {
            return nil
        }

        let nsOutput = output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        return regex.matches(in: output, range: range)
            .compactMap { match in
                Double(nsOutput.substring(with: match.range(at: 1)))
            }
            .max()
    }

    private static func friendlyModelName(from identifier: String) -> String {
        if identifier == "Mac17,9" || identifier.hasPrefix("MacBookPro") {
            return "MacBook Pro"
        }
        if identifier.hasPrefix("MacBookAir") {
            return "MacBook Air"
        }
        if identifier.hasPrefix("Macmini") {
            return "Mac mini"
        }
        if identifier.hasPrefix("iMac") {
            return "iMac"
        }
        if identifier.hasPrefix("MacStudio") {
            return "Mac Studio"
        }
        if identifier.hasPrefix("MacPro") {
            return "Mac Pro"
        }
        if identifier.hasPrefix("Mac") {
            return "Mac"
        }
        return identifier
    }

    private static func collectOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func collectUptimeSeconds() -> Int {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let result = sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0)
        guard result == 0, bootTime.tv_sec > 0 else {
            return 0
        }

        return Int(Date().timeIntervalSince1970) - bootTime.tv_sec
    }

    private static func formatUptime(_ uptime: Int) -> String {
        let days = uptime / 86_400
        let hours = (uptime % 86_400) / 3_600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        let minutes = (uptime % 3_600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static func readCPUSample() -> CPUSample {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else {
            return CPUSample(cores: [], date: Date())
        }

        defer {
            let size = vm_size_t(Int(processorInfoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: processorInfo)), size)
        }

        var cores: [CPUCoreSample] = []
        for index in 0..<Int(processorCount) {
            let offset = index * Int(CPU_STATE_MAX)
            let user = UInt64(processorInfo[offset + Int(CPU_STATE_USER)])
            let system = UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            let idle = UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)])
            cores.append(CPUCoreSample(user: user, system: system, nice: nice, idle: idle))
        }

        return CPUSample(cores: cores, date: Date())
    }

    private static func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        guard count == 3 else {
            return "0.00 / 0.00 / 0.00"
        }
        return String(format: "%.2f / %.2f / %.2f", loads[0], loads[1], loads[2])
    }

    private static func collectSwap() -> (used: UInt64, total: UInt64) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard result == 0 else {
            return (0, 0)
        }
        return (swap.xsu_used, swap.xsu_total)
    }

    private static func fileSystemName() -> String {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else {
            return "FS"
        }
        return withUnsafePointer(to: stats.f_fstypename) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: stats.f_fstypename)) {
                String(cString: $0).uppercased()
            }
        }
    }

    private static func readDiskIOSample() -> DiskIOSample {
        var iterator: io_iterator_t = 0
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0

        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 {
                    break
                }
                defer { IOObjectRelease(service) }

                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dict = properties?.takeRetainedValue() as? [String: Any],
                      let stats = dict["Statistics"] as? [String: Any] else {
                    continue
                }

                bytesRead += uint64(stats["Bytes (Read)"])
                bytesWritten += uint64(stats["Bytes (Write)"])
            }
        }

        return DiskIOSample(bytesRead: bytesRead, bytesWritten: bytesWritten, date: Date())
    }

    private static func collectSmartBatteryFallback() -> BatteryMetrics? {
        let smart = smartBatteryDetails()
        guard smart.percent != nil || smart.cycleCount != nil else {
            return nil
        }
        return BatteryMetrics(
            percent: smart.percent ?? 0,
            healthPercent: smart.healthPercent ?? 100,
            condition: nil,
            source: smart.isCharging == true ? .ac : .battery,
            isCharging: smart.isCharging ?? false,
            timeText: "--",
            watts: smart.watts,
            systemWatts: smart.systemWatts,
            inputWatts: smart.inputWatts,
            cycleCount: smart.cycleCount,
            temperatureC: smart.temperatureC
        )
    }

    private static func smartBatteryDetails() -> SmartBatteryDetails {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery"))
        guard service != 0 else {
            return SmartBatteryDetails()
        }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return SmartBatteryDetails()
        }

        let current = double(dict["CurrentCapacity"])
        let max = double(dict["MaxCapacity"])
        let rawMax = double(dict["AppleRawMaxCapacity"])
        let nominal = double(dict["NominalChargeCapacity"])
        let design = double(dict["DesignCapacity"])
        let voltage = double(dict["Voltage"])
        let amperage = signedDouble(dict["Amperage"])
        let watts = voltage > 0 && amperage != 0 ? abs(voltage * amperage) / 1_000_000 : nil
        let telemetry = dict["PowerTelemetryData"] as? [String: Any]
        let systemPowerIn = signedDouble(telemetry?["SystemPowerIn"])
        let systemPowerFallback = signedDouble(dict["SystemPower"])
        let systemWatts = [systemPowerIn, systemPowerFallback]
            .first { $0 > 0 && $0 < 1_000_000 }
            .map { $0 / 1_000 }
        let inputWatts = double(dict["AdapterPower"])
        let rawTemperature = double(dict["Temperature"])
        let temperature: Double? = if rawTemperature > 20_000 {
            rawTemperature / 100 - 273.15
        } else if rawTemperature > 1_000 {
            rawTemperature / 100
        } else {
            nil
        }
        let effectiveMax = [nominal, rawMax, max].first { $0 > 100 } ?? 0

        return SmartBatteryDetails(
            percent: max > 0 ? current / max * 100 : nil,
            healthPercent: design > 0 && effectiveMax > 0 ? min(100, (effectiveMax / design * 100).rounded()) : nil,
            isCharging: dict["IsCharging"] as? Bool,
            watts: watts,
            systemWatts: systemWatts,
            inputWatts: inputWatts > 0 ? inputWatts : nil,
            cycleCount: int(dict["CycleCount"]),
            temperatureC: temperature
        )
    }

    private static func timeText(isCharging: Bool, fullMinutes: Int, emptyMinutes: Int) -> String {
        let minutes = isCharging ? fullMinutes : emptyMinutes
        guard minutes > 0 && minutes < 10_000 else {
            return "--"
        }
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    private static func powerSource(from value: String?, isCharging: Bool) -> PowerSource {
        if value == kIOPSACPowerValue {
            return .ac
        }
        if value == kIOPSBatteryPowerValue {
            return .battery
        }
        return isCharging ? .ac : .battery
    }

    private static func readNetworkSample() -> NetworkSample {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return NetworkSample(bytesIn: 0, bytesOut: 0, date: Date())
        }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = current.pointee.ifa_data else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            if name == "lo0" {
                continue
            }

            let flags = Int32(current.pointee.ifa_flags)
            if flags & IFF_UP == 0 {
                continue
            }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(networkData.ifi_ibytes)
            bytesOut += UInt64(networkData.ifi_obytes)
        }

        return NetworkSample(bytesIn: bytesIn, bytesOut: bytesOut, date: Date())
    }

    private static func proxySummary() -> String {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return "Off"
        }

        if int(settings["SOCKSEnable"]) == 1, let host = settings["SOCKSProxy"] as? String {
            return "SOCKS · \(host)"
        }
        if int(settings["HTTPEnable"]) == 1, let host = settings["HTTPProxy"] as? String {
            return "HTTP · \(host)"
        }
        if int(settings["HTTPSEnable"]) == 1, let host = settings["HTTPSProxy"] as? String {
            return "HTTPS · \(host)"
        }
        return "Off"
    }

    private static func parseProcessLine(_ line: Substring) -> TopProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 4,
              let rssKB = UInt64(parts[parts.count - 1]),
              let memory = Double(parts[parts.count - 2]),
              let cpu = Double(parts[parts.count - 3]) else {
            return nil
        }

        let name = parts.dropLast(3).joined(separator: " ")
        return TopProcess(
            name: name.isEmpty ? "process" : name,
            cpuPercent: cpu,
            memoryPercent: memory,
            memoryBytes: rssKB * 1024
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intSysctl(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }
}

private struct CPUCoreSample {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64

    var total: UInt64 {
        user + system + nice + idle
    }
}

private struct CPUSample {
    let cores: [CPUCoreSample]
    let date: Date
}

private struct DiskIOSample {
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let date: Date
}

private struct NetworkSample {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let date: Date
}

private struct StartupDiskSample {
    let free: UInt64
    let total: UInt64
    let date: Date
}

private struct PowerProfile {
    var condition: String?
    var cycleCount: Int?
    var maximumCapacityPercent: Int?
    var adapterWatts: Int?
    var date: Date
}

private struct SmartBatteryDetails {
    var percent: Double?
    var healthPercent: Double?
    var isCharging: Bool?
    var watts: Double?
    var systemWatts: Double?
    var inputWatts: Double?
    var cycleCount: Int?
    var temperatureC: Double?
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func optionalDouble(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? UInt64 {
        return Double(value)
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}

private func remainingPercent(from dictionary: [String: Any]) -> Double? {
    if let remaining = optionalDouble(dictionary["remaining_percentage"])
        ?? optionalDouble(dictionary["remaining_percent"])
        ?? optionalDouble(dictionary["left_percentage"])
        ?? optionalDouble(dictionary["left_percent"])
        ?? optionalDouble(dictionary["percent_remaining"]) {
        return clampedPercent(remaining)
    }
    if let used = optionalDouble(dictionary["used_percentage"])
        ?? optionalDouble(dictionary["used_percent"]) {
        return clampedPercent(100 - used)
    }
    if let ambiguous = optionalDouble(dictionary["percentage"])
        ?? optionalDouble(dictionary["percent"]) {
        return clampedPercent(ambiguous)
    }
    return nil
}

private func clampedPercent(_ value: Double) -> Double {
    max(0, min(100, value))
}

private func resetEpoch(from dictionary: [String: Any]) -> Double? {
    optionalDouble(dictionary["resets_at"])
        ?? optionalDouble(dictionary["reset_at"])
        ?? optionalDouble(dictionary["resetAt"])
}

private func dateFromEpoch(_ value: Any?) -> Date? {
    if let seconds = optionalDouble(value), seconds > 0 {
        return Date(timeIntervalSince1970: seconds)
    }
    if let string = value as? String {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }
    return nil
}

private func int(_ value: Any?) -> Int {
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let integer = value as? Int {
        return integer
    }
    if let string = value as? String {
        return Int(string) ?? 0
    }
    return 0
}

private func double(_ value: Any?) -> Double {
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let double = value as? Double {
        return double
    }
    if let integer = value as? Int {
        return Double(integer)
    }
    if let string = value as? String {
        return Double(string) ?? 0
    }
    return 0
}

private func signedDouble(_ value: Any?) -> Double {
    if let number = value as? NSNumber {
        return Double(Int64(bitPattern: number.uint64Value))
    }
    if let integer = value as? Int {
        return Double(integer)
    }
    if let string = value as? String {
        return Double(string) ?? 0
    }
    return 0
}

private func uint64(_ value: Any?) -> UInt64 {
    if let number = value as? NSNumber {
        return number.uint64Value
    }
    if let value = value as? UInt64 {
        return value
    }
    if let value = value as? Int {
        return UInt64(max(0, value))
    }
    return 0
}

private func compactBytes(_ value: UInt64) -> String {
    if value == 0 {
        return "0 B"
    }

    let units = ["B", "KB", "MB", "GB", "TB"]
    var amount = Double(value)
    var unitIndex = 0
    while amount >= 1_024, unitIndex < units.count - 1 {
        amount /= 1_024
        unitIndex += 1
    }

    if unitIndex == 0 {
        return "\(value) B"
    }
    if unitIndex >= 3 {
        return String(format: "%.1f %@", amount, units[unitIndex])
    }
    if amount >= 100 {
        return String(format: "%.0f %@", amount, units[unitIndex])
    }
    if amount >= 10 {
        return String(format: "%.1f %@", amount, units[unitIndex])
    }
    return String(format: "%.2f %@", amount, units[unitIndex])
}

private func fixedGigabytes(_ value: UInt64) -> String {
    String(format: "%.1f GB", Double(value) / pow(1024, 3))
}

private func fixedGigabytesCompact(_ value: UInt64) -> String {
    String(format: "%.1fGB", Double(value) / pow(1024, 3))
}

private func shortUnitBytes(_ value: UInt64) -> String {
    if value >= UInt64(1) << 40 {
        return String(format: "%.0fT", Double(value) / pow(1024, 4))
    }
    if value >= UInt64(1) << 30 {
        return String(format: "%.0fG", Double(value) / pow(1024, 3))
    }
    if value >= UInt64(1) << 20 {
        return String(format: "%.0fM", Double(value) / pow(1024, 2))
    }
    if value >= UInt64(1) << 10 {
        return String(format: "%.0fK", Double(value) / 1024)
    }
    return "\(value)"
}

private func compactUnitBytes(_ value: UInt64) -> String {
    if value >= UInt64(1) << 40 {
        return String(format: "%.1fT", Double(value) / pow(1024, 4))
    }
    if value >= UInt64(1) << 30 {
        return String(format: "%.1fG", Double(value) / pow(1024, 3))
    }
    if value >= UInt64(1) << 20 {
        return String(format: "%.1fM", Double(value) / pow(1024, 2))
    }
    if value >= UInt64(1) << 10 {
        return String(format: "%.1fK", Double(value) / 1024)
    }
    return "\(value)"
}

private func formatHz(_ value: Double) -> String {
    if abs(value.rounded() - value) < 0.01 {
        return "\(Int(value.rounded()))Hz"
    }
    return String(format: "%.1fHz", value)
}
