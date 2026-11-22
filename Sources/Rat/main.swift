import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

final class RatAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = RatSettingsStore()
    private let monitorCollector = ScrollMonitorCollector()
    private lazy var engine = SmoothScrollEngine(monitorCollector: monitorCollector)
    private lazy var tapManager = EventTapManager(
        configBridge: store.bridge,
        engine: engine,
        monitorCollector: monitorCollector
    )
    private lazy var logitechManager = LogitechHIDManager(configBridge: store.bridge)

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var settingsController: SettingsWindowController?
    private var monitorController: ScrollMonitorWindowController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯菜单栏常驻，不占用 Dock 图标
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusBar()

        store.addChangeListener { [weak self] in
            guard let self else { return }
            self.updateStatusIcon()
            self.logitechManager.applyCurrentConfigToAllDevices()
            self.settingsController?.refreshUI()
        }

        logitechManager.onDevicesChanged = { [weak self] in
            self?.settingsController?.refreshUI()
        }

        checkPermissionsAndStart(promptAccessibility: false)
        if store.config.logitechHIDEnabled {
            logitechManager.start()
        }
        startPermissionWatcher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        tapManager.stop()
        logitechManager.stop()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbolName = store.config.smoothEnabled ? "computermouse.fill" : "computermouse"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Rat") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Rat"
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        if !store.isAccessibilityGranted {
            let warn = NSMenuItem(title: "⚠️ 需要授予辅助功能权限...", action: #selector(onGrantAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let smoothItem = NSMenuItem(title: "平滑滚动", action: #selector(onToggleSmooth), keyEquivalent: "")
        smoothItem.target = self
        smoothItem.state = store.config.smoothEnabled ? .on : .off
        menu.addItem(smoothItem)

        let reverseItem = NSMenuItem(title: "翻转鼠标滚轮方向", action: #selector(onToggleReverse), keyEquivalent: "")
        reverseItem.target = self
        reverseItem.state = store.config.reverseVertical ? .on : .off
        menu.addItem(reverseItem)

        menu.addItem(.separator())

        let monitorItem = NSMenuItem(title: "实时滚动监控窗口...", action: #selector(onOpenMonitor), keyEquivalent: "m")
        monitorItem.target = self
        menu.addItem(monitorItem)

        let frontAppItem = NSMenuItem(title: "将当前激活应用加入/移出例外列表", action: #selector(onToggleFrontmostApp), keyEquivalent: "")
        frontAppItem.target = self
        menu.addItem(frontAppItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "偏好设置...", action: #selector(onOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出 Rat", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Permissions & Lifecycle

    private func checkPermissionsAndStart(promptAccessibility: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": promptAccessibility] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        store.isAccessibilityGranted = trusted
        store.isInputMonitoringGranted = CGPreflightListenEventAccess()

        if trusted {
            store.isTapRunning = tapManager.start()
        } else {
            tapManager.stop()
            store.isTapRunning = false
        }
    }

    private func requestInputMonitoringPermission() {
        let granted = CGRequestListenEventAccess()
        store.isInputMonitoringGranted = granted
        if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        } else if store.config.logitechHIDEnabled {
            logitechManager.stop()
            logitechManager.start()
        }
    }

    private func startPermissionWatcher() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let axTrusted = AXIsProcessTrusted()
            let inputGranted = CGPreflightListenEventAccess()

            if axTrusted != self.store.isAccessibilityGranted {
                self.checkPermissionsAndStart(promptAccessibility: false)
            }
            if inputGranted != self.store.isInputMonitoringGranted {
                self.store.isInputMonitoringGranted = inputGranted
                if inputGranted && self.store.config.logitechHIDEnabled && !self.logitechManager.isRunning {
                    self.logitechManager.start()
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func onGrantAccessibility() {
        checkPermissionsAndStart(promptAccessibility: true)
    }

    @objc private func onToggleSmooth() {
        store.config.smoothEnabled.toggle()
    }

    @objc private func onToggleReverse() {
        store.config.reverseVertical.toggle()
    }

    @objc private func onToggleFrontmostApp() {
        store.toggleRuleForFrontmostApp()
    }

    @objc private func onOpenMonitor() {
        if monitorController == nil {
            monitorController = ScrollMonitorWindowController(collector: monitorCollector)
        }
        monitorController?.showMonitor()
    }

    @objc private func onOpenSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                store: store,
                logitechManager: logitechManager,
                onRequestAccessibility: { [weak self] in
                    self?.checkPermissionsAndStart(promptAccessibility: true)
                },
                onRequestInputMonitoring: { [weak self] in
                    self?.requestInputMonitoringPermission()
                },
                onRestartTap: { [weak self] in
                    self?.tapManager.stop()
                    self?.checkPermissionsAndStart(promptAccessibility: true)
                },
                onOpenMonitor: { [weak self] in
                    self?.onOpenMonitor()
                }
            )
        }
        settingsController?.showSettings()
    }

    @objc private func onQuit() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = RatAppDelegate()
app.delegate = delegate
app.run()
