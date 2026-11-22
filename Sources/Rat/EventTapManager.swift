import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import os

final class EventTapManager: @unchecked Sendable {
    private let configBridge: SharedConfigBridge
    private let engine: SmoothScrollEngine
    private let monitorCollector: ScrollMonitorCollector

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct CursorAppCache {
        var lastPoint: CGPoint = .zero
        var lastTimestamp: TimeInterval = 0
        var bundleID: String?
        var appName: String = "未知应用"
    }

    private let cacheLock = OSAllocatedUnfairLock(initialState: CursorAppCache())
    private let systemWideElement = AXUIElementCreateSystemWide()

    init(
        configBridge: SharedConfigBridge,
        engine: SmoothScrollEngine,
        monitorCollector: ScrollMonitorCollector
    ) {
        self.configBridge = configBridge
        self.engine = engine
        self.monitorCollector = monitorCollector
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let eventMask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        engine.stopImmediately()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == RatConstants.eventTag {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .scrollWheel:
            return handleScrollEvent(event)
        case .otherMouseDown:
            return handleOtherMouse(event, isDown: true)
        case .otherMouseUp:
            return handleOtherMouse(event, isDown: false)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleScrollEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        let targetApp = appUnderCursor(at: event.location)

        if isContinuous || scrollPhase != 0 || momentumPhase != 0 {
            engine.stopImmediately()
            let tpY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let tpX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if tpX != 0 || tpY != 0 {
                monitorCollector.record(
                    kind: .trackpadPassthrough,
                    deltaX: tpX / 12.0,
                    deltaY: tpY / 12.0,
                    targetApp: targetApp.name,
                    note: "原样放行"
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let config = configBridge.current
        let effective = config.effectiveSettings(for: targetApp.bundleID)

        var rawY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        var rawX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if rawY == 0 {
            rawY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        }
        if rawX == 0 {
            rawX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        }
        if rawX == 0 && rawY == 0 {
            return Unmanaged.passUnretained(event)
        }

        let hiResState = configBridge.activeHiResInfo
        let isFractionalStep = (abs(rawY) > 0 && abs(rawY) < 0.95) || (abs(rawX) > 0 && abs(rawX) < 0.95)
        let isHiResEvent = hiResState.enabled || isFractionalStep

        let flags = event.flags
        let isDash = config.dashKey.matches(flags)
        let isForceHorizontal = config.horizontalKey.matches(flags)
        let isTempDisabled = config.disableSmoothKey.matches(flags)

        if effective.reverseY && !(hiResState.enabled && config.logitechInvertHardware) {
            rawY = -rawY
        }
        if effective.reverseX {
            rawX = -rawX
        }

        var forwardedFlags = flags
        if isForceHorizontal {
            rawX += rawY
            rawY = 0
            forwardedFlags.subtract(config.horizontalKey.flagMask)
        }
        if isDash {
            forwardedFlags.subtract(config.dashKey.flagMask)
        }

        var noteParts: [String] = []
        if isHiResEvent {
            noteParts.append("HiRes \(hiResState.multiplier)x")
        }
        if isDash { noteParts.append("加速") }
        if isForceHorizontal { noteParts.append("转水平") }
        if !effective.smooth || isTempDisabled { noteParts.append("直通") }

        monitorCollector.record(
            kind: isHiResEvent ? .rawHiRes : .rawMouse,
            deltaX: rawX,
            deltaY: rawY,
            targetApp: targetApp.name,
            note: noteParts.joined(separator: " · ")
        )

        if !effective.smooth || isTempDisabled {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: rawY)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: rawX)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(rawY.rounded()))
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(rawX.rounded()))
            event.flags = forwardedFlags
            return Unmanaged.passUnretained(event)
        }

        let hiResScale = isHiResEvent ? config.logitechHiResSensitivity : 1.0
        let speed = config.speedMultiplier * hiResScale * (isDash ? config.dashMultiplier : 1.0)
        let effectiveDuration = isHiResEvent ? max(0.08, config.duration * 0.72) : config.duration

        let pixelDeltaX = rawX * config.stepSize * speed
        let pixelDeltaY = rawY * config.stepSize * speed

        engine.enqueue(
            deltaX: pixelDeltaX,
            deltaY: pixelDeltaY,
            duration: effectiveDuration,
            flags: forwardedFlags
        )

        return nil
    }

    private func handleOtherMouse(_ event: CGEvent, isDown: Bool) -> Unmanaged<CGEvent>? {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let action = configBridge.current.action(for: buttonNumber)
        guard action != .none else {
            return Unmanaged.passUnretained(event)
        }

        if isDown {
            DispatchQueue.main.async {
                ButtonActionExecutor.execute(action)
            }
        }
        return nil
    }

    private func appUnderCursor(at point: CGPoint) -> (bundleID: String?, name: String) {
        let now = ProcessInfo.processInfo.systemUptime

        if let cached = cacheLock.withLock({ cache -> (String?, String)? in
            let dx = abs(point.x - cache.lastPoint.x)
            let dy = abs(point.y - cache.lastPoint.y)
            if dx < 8 && dy < 8 && (now - cache.lastTimestamp) < 0.15 {
                return (cache.bundleID, cache.appName)
            }
            return nil
        }) {
            return cached
        }

        var element: AXUIElement?
        var resolvedBundleID: String?
        var resolvedName: String = "未知应用"

        let err = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &element
        )
        if err == .success, let axElement = element {
            var pid: pid_t = 0
            if AXUIElementGetPid(axElement, &pid) == .success,
               let app = NSRunningApplication(processIdentifier: pid) {
                resolvedBundleID = app.bundleIdentifier
                resolvedName = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
            }
        }

        if resolvedBundleID == nil, let front = NSWorkspace.shared.frontmostApplication {
            resolvedBundleID = front.bundleIdentifier
            resolvedName = front.localizedName ?? front.bundleIdentifier ?? "前台应用"
        }

        cacheLock.withLock { cache in
            cache.lastPoint = point
            cache.lastTimestamp = now
            cache.bundleID = resolvedBundleID
            cache.appName = resolvedName
        }

        return (resolvedBundleID, resolvedName)
    }
}
