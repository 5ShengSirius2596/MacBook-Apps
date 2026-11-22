import Foundation
import AppKit
import CoreGraphics
import os

enum RatConstants {
    /// 标记 Rat 自身合成的滚动/按键事件，防止 CGEventTap 死循环
    static let eventTag: Int64 = 0x52415431 // "RAT1"
}

enum ModifierChoice: String, Codable, CaseIterable, Sendable {
    case none = "无"
    case shift = "Shift (⇧)"
    case option = "Option (⌥)"
    case control = "Control (⌃)"
    case command = "Command (⌘)"

    func matches(_ flags: CGEventFlags) -> Bool {
        switch self {
        case .none: return false
        case .shift: return flags.contains(.maskShift)
        case .option: return flags.contains(.maskAlternate)
        case .control: return flags.contains(.maskControl)
        case .command: return flags.contains(.maskCommand)
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .none: return []
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }
}

enum ExceptionMode: String, Codable, CaseIterable, Sendable {
    case blacklist = "黑名单（列表内应用禁用平滑）"
    case whitelist = "白名单（仅列表内应用启用平滑）"
}

struct AppRule: Codable, Hashable, Sendable {
    var bundleIdentifier: String
    var displayName: String
    var smoothEnabled: Bool
    var reverseEnabled: Bool
}

enum MouseButtonAction: String, Codable, CaseIterable, Sendable {
    case none = "保持系统默认"
    case missionControl = "调度中心 (Mission Control)"
    case spaceLeft = "向左切换桌面空间"
    case spaceRight = "向右切换桌面空间"
    case browserBack = "后退 (⌘[)"
    case browserForward = "前进 (⌘])"
    case appExpose = "应用程序窗口"
    case copy = "复制 (⌘C)"
    case paste = "粘贴 (⌘V)"
}

enum SmartShiftMode: String, Codable, CaseIterable, Sendable {
    case ratchet = "棘轮刻度模式"
    case freespin = "无极自由滚动"
}

struct RatConfigSnapshot: Codable, Sendable {
    var smoothEnabled: Bool = true
    var reverseVertical: Bool = true
    var reverseHorizontal: Bool = false

    // 物理滚动曲线参数（对齐 Mos 调校维度）
    var stepSize: Double = 36.0
    var speedMultiplier: Double = 1.0
    var duration: Double = 0.28
    var dashMultiplier: Double = 3.0

    // 修饰键映射
    var dashKey: ModifierChoice = .option
    var horizontalKey: ModifierChoice = .shift
    var disableSmoothKey: ModifierChoice = .control

    // 分应用例外
    var exceptionMode: ExceptionMode = .blacklist
    var appRules: [AppRule] = []

    // 鼠标按键映射（2=中键, 3=侧键4, 4=侧键5）
    var middleButtonAction: MouseButtonAction = .none
    var button4Action: MouseButtonAction = .none
    var button5Action: MouseButtonAction = .none

    // 罗技 HID++ 与高分辨率滚轮配置
    var logitechHIDEnabled: Bool = true
    var logitechHiResEnabled: Bool = true
    var logitechHiResSensitivity: Double = 1.0
    var logitechInvertHardware: Bool = false

    func effectiveSettings(for bundleID: String?) -> (smooth: Bool, reverseY: Bool, reverseX: Bool) {
        guard let bundleID, let rule = appRules.first(where: { $0.bundleIdentifier == bundleID }) else {
            let defaultSmooth = (exceptionMode == .blacklist) ? smoothEnabled : false
            return (defaultSmooth, reverseVertical, reverseHorizontal)
        }
        return (smoothEnabled && rule.smoothEnabled, rule.reverseEnabled, reverseHorizontal)
    }

    func action(for buttonNumber: Int64) -> MouseButtonAction {
        switch buttonNumber {
        case 2: return middleButtonAction
        case 3: return button4Action
        case 4: return button5Action
        default: return .none
        }
    }
}

final class SharedConfigBridge: @unchecked Sendable {
    private struct State {
        var config: RatConfigSnapshot = RatConfigSnapshot()
        var activeHiResMultiplier: Int = 1
        var hasActiveLogitechHiRes: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var current: RatConfigSnapshot {
        lock.withLock { $0.config }
    }

    var activeHiResInfo: (enabled: Bool, multiplier: Int) {
        lock.withLock { ($0.hasActiveLogitechHiRes, $0.activeHiResMultiplier) }
    }

    func update(_ snapshot: RatConfigSnapshot) {
        lock.withLock { $0.config = snapshot }
    }

    func updateLogitechHiResState(active: Bool, multiplier: Int) {
        lock.withLock { state in
            state.hasActiveLogitechHiRes = active
            state.activeHiResMultiplier = max(1, multiplier)
        }
    }
}

final class RatSettingsStore {
    private static let storageKey = "com.local.rat.config.v2"

    let bridge = SharedConfigBridge()
    var config: RatConfigSnapshot {
        didSet {
            bridge.update(config)
            save()
            notifyListeners()
        }
    }

    var isAccessibilityGranted: Bool = false { didSet { notifyListeners() } }
    var isInputMonitoringGranted: Bool = false { didSet { notifyListeners() } }
    var isTapRunning: Bool = false { didSet { notifyListeners() } }

    private var listeners: [() -> Void] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(RatConfigSnapshot.self, from: data) {
            self.config = decoded
        } else {
            self.config = RatConfigSnapshot()
        }
        bridge.update(config)
    }

    func addChangeListener(_ handler: @escaping () -> Void) {
        listeners.append(handler)
    }

    func notifyListeners() {
        for fn in listeners {
            fn()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func addAppRule(url: URL) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent

        if !config.appRules.contains(where: { $0.bundleIdentifier == bundleID }) {
            let defaultSmooth = (config.exceptionMode == .whitelist)
            config.appRules.append(
                AppRule(
                    bundleIdentifier: bundleID,
                    displayName: name,
                    smoothEnabled: defaultSmooth,
                    reverseEnabled: config.reverseVertical
                )
            )
        }
    }

    func toggleRuleForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }

        if let index = config.appRules.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
            config.appRules.remove(at: index)
        } else {
            let name = app.localizedName ?? bundleID
            let defaultSmooth = (config.exceptionMode == .whitelist)
            config.appRules.append(
                AppRule(
                    bundleIdentifier: bundleID,
                    displayName: name,
                    smoothEnabled: defaultSmooth,
                    reverseEnabled: config.reverseVertical
                )
            )
        }
    }
}
