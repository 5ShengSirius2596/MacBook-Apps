import Foundation
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: RatSettingsStore
    private let logitechManager: LogitechHIDManager
    private let onRequestAccessibility: () -> Void
    private let onRequestInputMonitoring: () -> Void
    private let onRestartTap: () -> Void
    private let onOpenMonitor: () -> Void

    // Tab 1: 通用
    private let smoothSwitch = NSSwitch()
    private let reverseYSwitch = NSSwitch()
    private let reverseXSwitch = NSSwitch()
    private let launchLoginSwitch = NSSwitch()
    private let axStatusLabel = NSTextField(labelWithString: "")
    private let axGrantButton = NSButton(title: "前往授权", target: nil, action: nil)
    private let inputStatusLabel = NSTextField(labelWithString: "")
    private let inputGrantButton = NSButton(title: "前往授权", target: nil, action: nil)
    private let engineStatusLabel = NSTextField(labelWithString: "")

    // Tab 2: 高级曲线
    private let stepSlider = NSSlider(value: 36, minValue: 10, maxValue: 120, target: nil, action: nil)
    private let stepValueLabel = NSTextField(labelWithString: "")
    private let speedSlider = NSSlider(value: 1.0, minValue: 0.3, maxValue: 3.0, target: nil, action: nil)
    private let speedValueLabel = NSTextField(labelWithString: "")
    private let durationSlider = NSSlider(value: 0.28, minValue: 0.08, maxValue: 0.80, target: nil, action: nil)
    private let durationValueLabel = NSTextField(labelWithString: "")
    private let dashMultSlider = NSSlider(value: 3.0, minValue: 1.5, maxValue: 6.0, target: nil, action: nil)
    private let dashMultValueLabel = NSTextField(labelWithString: "")
    private let dashKeyPopup = NSPopUpButton()
    private let horizontalKeyPopup = NSPopUpButton()
    private let disableKeyPopup = NSPopUpButton()

    // Tab 3: 例外应用
    private let exceptionModeControl = NSSegmentedControl(labels: ["黑名单（列表内禁用平滑）", "白名单（仅列表内启用）"], trackingMode: .selectOne, target: nil, action: nil)
    private let appRulesTable = NSTableView()

    // Tab 4: 按键映射
    private let middleBtnPopup = NSPopUpButton()
    private let btn4Popup = NSPopUpButton()
    private let btn5Popup = NSPopUpButton()

    // Tab 5: 罗技 HID++
    private let logiEnableSwitch = NSSwitch()
    private let logiHiResSwitch = NSSwitch()
    private let logiInvertSwitch = NSSwitch()
    private let logiSensSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 3.0, target: nil, action: nil)
    private let logiSensLabel = NSTextField(labelWithString: "")
    private let logiStatusLabel = NSTextField(labelWithString: "")
    private let logiDevicesTable = NSTableView()

    private var isRefreshingUI = false

    init(
        store: RatSettingsStore,
        logitechManager: LogitechHIDManager,
        onRequestAccessibility: @escaping () -> Void,
        onRequestInputMonitoring: @escaping () -> Void,
        onRestartTap: @escaping () -> Void,
        onOpenMonitor: @escaping () -> Void
    ) {
        self.store = store
        self.logitechManager = logitechManager
        self.onRequestAccessibility = onRequestAccessibility
        self.onRequestInputMonitoring = onRequestInputMonitoring
        self.onRestartTap = onRestartTap
        self.onOpenMonitor = onOpenMonitor

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Rat 偏好设置"
        win.center()
        super.init(window: win)

        buildTabs()
        refreshUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        refreshUI()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func refreshUI() {
        isRefreshingUI = true
        defer { isRefreshingUI = false }

        let cfg = store.config

        // Tab 1
        smoothSwitch.state = cfg.smoothEnabled ? .on : .off
        reverseYSwitch.state = cfg.reverseVertical ? .on : .off
        reverseXSwitch.state = cfg.reverseHorizontal ? .on : .off
        launchLoginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        axStatusLabel.stringValue = store.isAccessibilityGranted ? "✅ 已授权" : "⚠️ 未授权"
        axStatusLabel.textColor = store.isAccessibilityGranted ? .systemGreen : .systemOrange
        axGrantButton.isHidden = store.isAccessibilityGranted

        inputStatusLabel.stringValue = store.isInputMonitoringGranted ? "✅ 已授权" : "未授权"
        inputStatusLabel.textColor = store.isInputMonitoringGranted ? .systemGreen : .secondaryLabelColor
        inputGrantButton.isHidden = store.isInputMonitoringGranted

        engineStatusLabel.stringValue = store.isTapRunning ? "运行中" : "未启动"
        engineStatusLabel.textColor = store.isTapRunning ? .secondaryLabelColor : .systemRed

        // Tab 2
        stepSlider.doubleValue = cfg.stepSize
        stepValueLabel.stringValue = "\(Int(cfg.stepSize)) px"
        speedSlider.doubleValue = cfg.speedMultiplier
        speedValueLabel.stringValue = String(format: "%.2fx", cfg.speedMultiplier)
        durationSlider.doubleValue = cfg.duration
        durationValueLabel.stringValue = String(format: "%.2f s", cfg.duration)
        dashMultSlider.doubleValue = cfg.dashMultiplier
        dashMultValueLabel.stringValue = String(format: "%.1fx", cfg.dashMultiplier)

        dashKeyPopup.selectItem(withTitle: cfg.dashKey.rawValue)
        horizontalKeyPopup.selectItem(withTitle: cfg.horizontalKey.rawValue)
        disableKeyPopup.selectItem(withTitle: cfg.disableSmoothKey.rawValue)

        // Tab 3
        exceptionModeControl.selectedSegment = (cfg.exceptionMode == .blacklist) ? 0 : 1
        appRulesTable.reloadData()

        // Tab 4
        middleBtnPopup.selectItem(withTitle: cfg.middleButtonAction.rawValue)
        btn4Popup.selectItem(withTitle: cfg.button4Action.rawValue)
        btn5Popup.selectItem(withTitle: cfg.button5Action.rawValue)

        // Tab 5
        logiEnableSwitch.state = cfg.logitechHIDEnabled ? .on : .off
        logiHiResSwitch.state = cfg.logitechHiResEnabled ? .on : .off
        logiInvertSwitch.state = cfg.logitechInvertHardware ? .on : .off
        logiHiResSwitch.isEnabled = cfg.logitechHIDEnabled
        logiInvertSwitch.isEnabled = cfg.logitechHIDEnabled
        logiSensSlider.isEnabled = cfg.logitechHIDEnabled
        logiSensSlider.doubleValue = cfg.logitechHiResSensitivity
        logiSensLabel.stringValue = String(format: "%.2fx", cfg.logitechHiResSensitivity)
        logiStatusLabel.stringValue = "模块状态：\(logitechManager.managerStatus)"
        logiDevicesTable.reloadData()
    }

    // MARK: - Build Tabs

    private func buildTabs() {
        guard let contentView = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        ])

        tabView.addTabViewItem(makeTabItem(title: "通用", view: buildGeneralTab()))
        tabView.addTabViewItem(makeTabItem(title: "高级曲线", view: buildTuningTab()))
        tabView.addTabViewItem(makeTabItem(title: "例外应用", view: buildExceptionsTab()))
        tabView.addTabViewItem(makeTabItem(title: "按键映射", view: buildButtonsTab()))
        tabView.addTabViewItem(makeTabItem(title: "罗技 HID++", view: buildLogitechTab()))
    }

    private func makeTabItem(title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func makeVStack(spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        return label
    }

    private func makeRow(_ labelText: String, trailing: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: labelText)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return row
    }

    private func makeDivider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return box
    }

    private func buildGeneralTab() -> NSView {
        let stack = makeVStack(spacing: 12)

        smoothSwitch.target = self
        smoothSwitch.action = #selector(onGeneralSwitchChanged(_:))
        reverseYSwitch.target = self
        reverseYSwitch.action = #selector(onGeneralSwitchChanged(_:))
        reverseXSwitch.target = self
        reverseXSwitch.action = #selector(onGeneralSwitchChanged(_:))
        launchLoginSwitch.target = self
        launchLoginSwitch.action = #selector(onLaunchAtLoginChanged(_:))

        axGrantButton.bezelStyle = .rounded
        axGrantButton.target = self
        axGrantButton.action = #selector(onRequestAXClicked(_:))

        inputGrantButton.bezelStyle = .rounded
        inputGrantButton.target = self
        inputGrantButton.action = #selector(onRequestInputClicked(_:))

        let restartBtn = NSButton(title: "重启引擎", target: self, action: #selector(onRestartTapClicked(_:)))
        restartBtn.bezelStyle = .rounded
        restartBtn.controlSize = .small

        let monitorBtn = NSButton(title: "打开实时监控", target: self, action: #selector(onOpenMonitorClicked(_:)))
        monitorBtn.bezelStyle = .rounded
        monitorBtn.controlSize = .small

        stack.addArrangedSubview(makeSectionTitle("核心开关"))
        stack.addArrangedSubview(makeRow("启用平滑滚动（仅对鼠标生效，不影响触控板）", trailing: [smoothSwitch]))
        stack.addArrangedSubview(makeRow("翻转垂直滚轮方向（与触控板自然滚动分离）", trailing: [reverseYSwitch]))
        stack.addArrangedSubview(makeRow("翻转水平滚轮方向", trailing: [reverseXSwitch]))
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(makeSectionTitle("系统集成与权限"))
        stack.addArrangedSubview(makeRow("登录时自动启动 Rat（原生 SMAppService）", trailing: [launchLoginSwitch]))
        stack.addArrangedSubview(makeRow("辅助功能权限（平滑滚动必需）", trailing: [axStatusLabel, axGrantButton]))
        stack.addArrangedSubview(makeRow("输入监控权限（罗技 HID++ 可选）", trailing: [inputStatusLabel, inputGrantButton]))
        stack.addArrangedSubview(makeRow("事件拦截引擎", trailing: [engineStatusLabel, restartBtn, monitorBtn]))

        return stack
    }

    private func buildTuningTab() -> NSView {
        let stack = makeVStack(spacing: 12)

        for slider in [stepSlider, speedSlider, durationSlider, dashMultSlider] {
            slider.target = self
            slider.action = #selector(onTuningSliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 210).isActive = true
        }
        for lbl in [stepValueLabel, speedValueLabel, durationValueLabel, dashMultValueLabel] {
            lbl.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            lbl.alignment = .right
            lbl.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }

        let modTitles = ModifierChoice.allCases.map { $0.rawValue }
        for popup in [dashKeyPopup, horizontalKeyPopup, disableKeyPopup] {
            popup.addItems(withTitles: modTitles)
            popup.target = self
            popup.action = #selector(onModifierPopupChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }

        stack.addArrangedSubview(makeSectionTitle("物理惯性参数（CADisplayLink 帧率无关算法）"))
        stack.addArrangedSubview(makeRow("单格步长", trailing: [stepSlider, stepValueLabel]))
        stack.addArrangedSubview(makeRow("速度倍率", trailing: [speedSlider, speedValueLabel]))
        stack.addArrangedSubview(makeRow("惯性时长（越小越干脆，越大越绵长）", trailing: [durationSlider, durationValueLabel]))
        stack.addArrangedSubview(makeRow("加速键倍率", trailing: [dashMultSlider, dashMultValueLabel]))
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(makeSectionTitle("快捷键临时控制"))
        stack.addArrangedSubview(makeRow("加速滚动键", trailing: [dashKeyPopup]))
        stack.addArrangedSubview(makeRow("垂直转水平滚动键", trailing: [horizontalKeyPopup]))
        stack.addArrangedSubview(makeRow("临时禁用平滑键", trailing: [disableKeyPopup]))

        return stack
    }

    private func buildExceptionsTab() -> NSView {
        let stack = makeVStack(spacing: 12)

        exceptionModeControl.target = self
        exceptionModeControl.action = #selector(onExceptionModeChanged(_:))
        stack.addArrangedSubview(exceptionModeControl)

        let cols: [(String, String, CGFloat)] = [
            ("app", "应用名称", 260),
            ("smooth", "平滑", 64),
            ("reverse", "翻转", 64),
            ("delete", "操作", 70)
        ]
        for (id, title, w) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = w
            appRulesTable.addTableColumn(col)
        }
        appRulesTable.rowHeight = 32
        appRulesTable.usesAlternatingRowBackgroundColors = true
        appRulesTable.dataSource = self
        appRulesTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = appRulesTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 280).isActive = true
        stack.addArrangedSubview(scroll)

        let addBtn = NSButton(title: "添加应用...", target: self, action: #selector(onAddAppRuleClicked(_:)))
        addBtn.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "支持鼠标悬停后台窗口自动识别所属应用")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [addBtn, spacer, hint])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(footer)

        return stack
    }

    private func buildButtonsTab() -> NSView {
        let stack = makeVStack(spacing: 14)

        let actionTitles = MouseButtonAction.allCases.map { $0.rawValue }
        for popup in [middleBtnPopup, btn4Popup, btn5Popup] {
            popup.addItems(withTitles: actionTitles)
            popup.target = self
            popup.action = #selector(onButtonPopupChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        }

        stack.addArrangedSubview(makeSectionTitle("鼠标额外按键动作绑定"))
        stack.addArrangedSubview(makeRow("中键（滚轮按下）", trailing: [middleBtnPopup]))
        stack.addArrangedSubview(makeRow("侧键 4（通常为后退键）", trailing: [btn4Popup]))
        stack.addArrangedSubview(makeRow("侧键 5（通常为前进键）", trailing: [btn5Popup]))
        stack.addArrangedSubview(makeDivider())

        let note = NSTextField(wrappingLabelWithString: "说明：所有按键动作均通过 macOS 标准公共事件接口（CGEvent / NSWorkspace）触发，不依赖 Dock 或 WindowManager 私有接口，面向未来 macOS 28 长期兼容。")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(note)

        return stack
    }

    private func buildLogitechTab() -> NSView {
        let stack = makeVStack(spacing: 10)

        logiEnableSwitch.target = self
        logiEnableSwitch.action = #selector(onLogitechChanged(_:))
        logiHiResSwitch.target = self
        logiHiResSwitch.action = #selector(onLogitechChanged(_:))
        logiInvertSwitch.target = self
        logiInvertSwitch.action = #selector(onLogitechChanged(_:))
        logiSensSlider.target = self
        logiSensSlider.action = #selector(onLogitechChanged(_:))
        logiSensSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        logiSensLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        logiSensLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
        logiSensLabel.alignment = .right

        stack.addArrangedSubview(makeSectionTitle("IOKit IOHIDManager 罗技 HID++ 2.0 驱动模块"))
        stack.addArrangedSubview(makeRow("启用罗技 HID++ 硬件识别与控制", trailing: [logiEnableSwitch]))
        stack.addArrangedSubview(makeRow("自动开启高分辨率滚轮 (HiRes 0x2121 / 0x2120)", trailing: [logiHiResSwitch]))
        stack.addArrangedSubview(makeRow("使用鼠标硬件层滚轮方向翻转", trailing: [logiInvertSwitch]))
        stack.addArrangedSubview(makeRow("高分辨率滚轮灵敏度", trailing: [logiSensSlider, logiSensLabel]))
        stack.addArrangedSubview(makeDivider())

        logiStatusLabel.font = NSFont.systemFont(ofSize: 11)
        logiStatusLabel.textColor = .secondaryLabelColor
        let rescanBtn = NSButton(title: "重新探测设备", target: self, action: #selector(onRescanLogitech(_:)))
        rescanBtn.bezelStyle = .rounded
        rescanBtn.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [logiStatusLabel, spacer, rescanBtn])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.widthAnchor.constraint(equalToConstant: 540).isActive = true
        stack.addArrangedSubview(statusRow)

        let cols: [(String, String, CGFloat)] = [
            ("dev", "已连接的罗技设备", 390),
            ("smartshift", "滚轮模式 (SmartShift)", 130)
        ]
        for (id, title, w) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = w
            logiDevicesTable.addTableColumn(col)
        }
        logiDevicesTable.rowHeight = 40
        logiDevicesTable.usesAlternatingRowBackgroundColors = true
        logiDevicesTable.dataSource = self
        logiDevicesTable.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = logiDevicesTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 155).isActive = true
        stack.addArrangedSubview(scroll)

        return stack
    }

    // MARK: - Actions

    @objc private func onGeneralSwitchChanged(_ sender: NSSwitch) {
        if isRefreshingUI { return }
        store.config.smoothEnabled = (smoothSwitch.state == .on)
        store.config.reverseVertical = (reverseYSwitch.state == .on)
        store.config.reverseHorizontal = (reverseXSwitch.state == .on)
    }

    @objc private func onLaunchAtLoginChanged(_ sender: NSSwitch) {
        if isRefreshingUI { return }
        let enabled = (sender.state == .on)
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchLoginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func onRequestAXClicked(_ sender: NSButton) { onRequestAccessibility() }
    @objc private func onRequestInputClicked(_ sender: NSButton) { onRequestInputMonitoring() }
    @objc private func onRestartTapClicked(_ sender: NSButton) { onRestartTap() }
    @objc private func onOpenMonitorClicked(_ sender: NSButton) { onOpenMonitor() }

    @objc private func onTuningSliderChanged(_ sender: NSSlider) {
        if isRefreshingUI { return }
        store.config.stepSize = (stepSlider.doubleValue / 2.0).rounded() * 2.0
        store.config.speedMultiplier = (speedSlider.doubleValue * 20.0).rounded() / 20.0
        store.config.duration = (durationSlider.doubleValue * 50.0).rounded() / 50.0
        store.config.dashMultiplier = (dashMultSlider.doubleValue * 2.0).rounded() / 2.0
        refreshUI()
    }

    @objc private func onModifierPopupChanged(_ sender: NSPopUpButton) {
        if isRefreshingUI { return }
        if let title = dashKeyPopup.titleOfSelectedItem, let val = ModifierChoice(rawValue: title) {
            store.config.dashKey = val
        }
        if let title = horizontalKeyPopup.titleOfSelectedItem, let val = ModifierChoice(rawValue: title) {
            store.config.horizontalKey = val
        }
        if let title = disableKeyPopup.titleOfSelectedItem, let val = ModifierChoice(rawValue: title) {
            store.config.disableSmoothKey = val
        }
    }

    @objc private func onExceptionModeChanged(_ sender: NSSegmentedControl) {
        if isRefreshingUI { return }
        store.config.exceptionMode = (sender.selectedSegment == 0) ? .blacklist : .whitelist
    }

    @objc private func onAddAppRuleClicked(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.addAppRule(url: url)
            }
            appRulesTable.reloadData()
        }
    }

    @objc private func onRuleSmoothToggle(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < store.config.appRules.count else { return }
        store.config.appRules[row].smoothEnabled = (sender.state == .on)
    }

    @objc private func onRuleReverseToggle(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < store.config.appRules.count else { return }
        store.config.appRules[row].reverseEnabled = (sender.state == .on)
    }

    @objc private func onRuleDelete(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < store.config.appRules.count else { return }
        store.config.appRules.remove(at: row)
        appRulesTable.reloadData()
    }

    @objc private func onButtonPopupChanged(_ sender: NSPopUpButton) {
        if isRefreshingUI { return }
        if let t = middleBtnPopup.titleOfSelectedItem, let v = MouseButtonAction(rawValue: t) {
            store.config.middleButtonAction = v
        }
        if let t = btn4Popup.titleOfSelectedItem, let v = MouseButtonAction(rawValue: t) {
            store.config.button4Action = v
        }
        if let t = btn5Popup.titleOfSelectedItem, let v = MouseButtonAction(rawValue: t) {
            store.config.button5Action = v
        }
    }

    @objc private func onLogitechChanged(_ sender: Any) {
        if isRefreshingUI { return }
        store.config.logitechHIDEnabled = (logiEnableSwitch.state == .on)
        store.config.logitechHiResEnabled = (logiHiResSwitch.state == .on)
        store.config.logitechInvertHardware = (logiInvertSwitch.state == .on)
        store.config.logitechHiResSensitivity = (logiSensSlider.doubleValue * 20.0).rounded() / 20.0
        refreshUI()
    }

    @objc private func onRescanLogitech(_ sender: NSButton) {
        logitechManager.rescanDevices()
    }

    @objc private func onToggleSmartShift(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < logitechManager.devices.count else { return }
        let dev = logitechManager.devices[row]
        let next: SmartShiftMode = (dev.smartShiftMode == .ratchet) ? .freespin : .ratchet
        logitechManager.setSmartShiftMode(deviceID: dev.id, mode: next)
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === appRulesTable {
            return store.config.appRules.count
        }
        if tableView === logiDevicesTable {
            return logitechManager.devices.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colID = tableColumn?.identifier.rawValue else { return nil }

        if tableView === appRulesTable {
            guard row < store.config.appRules.count else { return nil }
            let rule = store.config.appRules[row]
            switch colID {
            case "app":
                let nameLabel = NSTextField(labelWithString: rule.displayName)
                nameLabel.font = NSFont.boldSystemFont(ofSize: 12)
                let idLabel = NSTextField(labelWithString: rule.bundleIdentifier)
                idLabel.font = NSFont.systemFont(ofSize: 10)
                idLabel.textColor = .secondaryLabelColor
                let stack = NSStackView(views: [nameLabel, idLabel])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 1
                return stack
            case "smooth":
                let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(onRuleSmoothToggle(_:)))
                cb.state = rule.smoothEnabled ? .on : .off
                cb.tag = row
                return cb
            case "reverse":
                let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(onRuleReverseToggle(_:)))
                cb.state = rule.reverseEnabled ? .on : .off
                cb.tag = row
                return cb
            case "delete":
                let btn = NSButton(title: "删除", target: self, action: #selector(onRuleDelete(_:)))
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.tag = row
                return btn
            default:
                return nil
            }
        }

        if tableView === logiDevicesTable {
            guard row < logitechManager.devices.count else { return nil }
            let dev = logitechManager.devices[row]
            switch colID {
            case "dev":
                let batteryText = dev.batteryPercent.map { " · 电量 \($0)%" } ?? ""
                let top = NSTextField(labelWithString: "\(dev.productName)  [\(dev.protocolVersion)\(batteryText)]")
                top.font = NSFont.boldSystemFont(ofSize: 12)
                let bottom = NSTextField(labelWithString: "PID: 0x\(String(format: "%04X", dev.productID)) · \(dev.transport) · \(dev.statusMessage)")
                bottom.font = NSFont.systemFont(ofSize: 10)
                bottom.textColor = .secondaryLabelColor
                let stack = NSStackView(views: [top, bottom])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 2
                return stack
            case "smartshift":
                if dev.smartShiftFeatureIndex != nil {
                    let title = (dev.smartShiftMode == .ratchet) ? "切至无极滚动" : "切至棘轮刻度"
                    let btn = NSButton(title: title, target: self, action: #selector(onToggleSmartShift(_:)))
                    btn.bezelStyle = .rounded
                    btn.controlSize = .small
                    btn.tag = row
                    return btn
                } else {
                    let lbl = NSTextField(labelWithString: "不支持")
                    lbl.font = NSFont.systemFont(ofSize: 11)
                    lbl.textColor = .tertiaryLabelColor
                    return lbl
                }
            default:
                return nil
            }
        }

        return nil
    }
}
