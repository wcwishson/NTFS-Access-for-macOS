import AppKit
import Foundation
import NTFSAccessShared
@preconcurrency import UserNotifications

private struct ServiceStateSnapshot: Sendable {
    let health: ServiceHealth
    let managedVolumeCount: Int
    let degradedVolumeCount: Int
    let lastError: String
    let notificationsEnabled: Bool
    let warningCount: Int
    let lastWarning: String

    init(dto: ServiceStateDTO) {
        self.health = dto.health
        self.managedVolumeCount = dto.managedVolumeCount
        self.degradedVolumeCount = dto.degradedVolumeCount
        self.lastError = dto.lastError
        self.notificationsEnabled = dto.notificationsEnabled
        self.warningCount = dto.warningCount
        self.lastWarning = dto.lastWarning
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let xpcClient = XPCClient()
    private var pollTimer: Timer?
    private var lastHealth: ServiceHealth?
    private var lastKnownNotificationsEnabled = true
    private var shouldShowDashboardOnNextActivation = false
    private lazy var dashboardWindowController = VolumeDashboardWindowController()

    private lazy var icons: [ServiceHealth: NSImage] = {
        var map: [ServiceHealth: NSImage] = [:]
        map[.healthy] = loadTemplateImage(named: "MenuBarIdle")
        map[.warning] = loadTemplateImage(named: "MenuBarDegraded")
        map[.degradedReadOnly] = loadTemplateImage(named: "MenuBarDegraded")
        map[.unavailable] = loadTemplateImage(named: "MenuBarError")
        map[.error] = loadTemplateImage(named: "MenuBarError")
        return map
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        configureStatusItem()
        startPolling()

        if shouldShowDashboardAfterLaunch() {
            showDashboardWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard shouldShowDashboardOnNextActivation,
              dashboardWindowController.window?.isVisible != true else {
            return
        }

        shouldShowDashboardOnNextActivation = false
        showDashboardWindow()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = nil
        statusItem = item

        guard let button = item.button else {
            return
        }

        button.image = icons[.unavailable]
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "NTFS Access"
        dashboardWindowController.onClose = { [weak self] in
            self?.dashboardDidClose()
        }
    }

    private func configureMenu() {
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func startPolling() {
        pollState()
        pollTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(handleTimerTick), userInfo: nil, repeats: true)
    }

    @objc private func handleTimerTick() {
        pollState()
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            showDashboardWindow()
            return
        }

        if event.type == .leftMouseUp {
            showDashboardWindow()
            return
        }

        guard event.type == .rightMouseUp else {
            showDashboardWindow()
            return
        }

        guard let statusItem, let button = statusItem.button else {
            return
        }

        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func showDashboardWindow() {
        shouldShowDashboardOnNextActivation = false
        NSApp.setActivationPolicy(.regular)
        dashboardWindowController.showWindow(nil)
        dashboardWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dashboardDidClose() {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shouldShowDashboardOnNextActivation = true
        showDashboardWindow()
        return true
    }

    private func shouldShowDashboardAfterLaunch() -> Bool {
        let serviceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        return !serviceName.hasSuffix("com.ntfsaccess.menu")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func pollState() {
        xpcClient.getServiceState { [weak self] result in
            switch result {
            case .success(let dto):
                let snapshot = ServiceStateSnapshot(dto: dto)
                Task { @MainActor [weak self] in
                    self?.applySnapshot(snapshot)
                }
            case .failure(let error):
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.applyUnavailable(errorMessage: message)
                }
            }
        }
    }

    private func applyUnavailable(errorMessage: String) {
        let snapshot = ServiceStateSnapshot(
            health: .unavailable,
            managedVolumeCount: 0,
            degradedVolumeCount: 0,
            lastError: errorMessage,
            notificationsEnabled: lastKnownNotificationsEnabled,
            warningCount: 0,
            lastWarning: ""
        )
        applySnapshot(snapshot)
    }

    private func applySnapshot(_ snapshot: ServiceStateSnapshot) {
        let health = snapshot.health
        lastKnownNotificationsEnabled = snapshot.notificationsEnabled
        statusItem?.button?.image = icons[health] ?? icons[.error]

        if health != lastHealth, snapshot.notificationsEnabled {
            notifyIfNeeded(health: health, snapshot: snapshot)
        }

        lastHealth = health
    }

    private func notifyIfNeeded(health: ServiceHealth, snapshot: ServiceStateSnapshot) {
        guard health != .healthy else {
            return
        }

        let body = notificationBody(for: health, snapshot: snapshot)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "NTFS Access"
            content.body = body
            content.sound = nil

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func notificationBody(for health: ServiceHealth, snapshot: ServiceStateSnapshot) -> String {
        switch health {
        case .warning:
            return snapshot.lastWarning.isEmpty
                ? "One or more NTFS volumes need normal eject or sync confirmation before unplugging."
                : snapshot.lastWarning
        case .degradedReadOnly:
            return "One or more NTFS volumes are mounted read-only for safety."
        case .unavailable:
            return "NTFS service is unavailable. \(snapshot.lastError)"
        case .error:
            return "NTFS service encountered an error. \(snapshot.lastError)"
        case .healthy:
            return "NTFS Access is healthy."
        }
    }

    private func loadTemplateImage(named name: String) -> NSImage {
        if let url = Bundle.module.url(forResource: name, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        let fallback = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "NTFS") ?? NSImage()
        fallback.isTemplate = true
        fallback.size = NSSize(width: 18, height: 18)
        return fallback
    }
}

private extension ServiceStateSnapshot {
    init(
        health: ServiceHealth,
        managedVolumeCount: Int,
        degradedVolumeCount: Int,
        lastError: String,
        notificationsEnabled: Bool,
        warningCount: Int,
        lastWarning: String
    ) {
        self.health = health
        self.managedVolumeCount = managedVolumeCount
        self.degradedVolumeCount = degradedVolumeCount
        self.lastError = lastError
        self.notificationsEnabled = notificationsEnabled
        self.warningCount = warningCount
        self.lastWarning = lastWarning
    }
}
