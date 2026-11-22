import Foundation
import AppKit
import CoreGraphics
import QuartzCore
import os

final class SmoothScrollEngine: NSObject, @unchecked Sendable {
    private struct PhysicsState {
        var remainingX: Double = 0
        var remainingY: Double = 0
        var residualX: Double = 0
        var residualY: Double = 0
        var activeFlags: CGEventFlags = []
        var duration: Double = 0.28
        var isActive: Bool = false
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: PhysicsState())
    private let monitorCollector: ScrollMonitorCollector
    private var displayLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?

    init(monitorCollector: ScrollMonitorCollector) {
        self.monitorCollector = monitorCollector
        super.init()
        DispatchQueue.main.async { [weak self] in
            self?.setupDisplayLink()
            self?.observeScreenChanges()
        }
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        displayLink?.invalidate()
    }

    func enqueue(deltaX: Double, deltaY: Double, duration: Double, flags: CGEventFlags) {
        let shouldWake = stateLock.withLock { state -> Bool in
            // 反向滚动时立即清零旧惯性，保持跟手
            if (state.remainingY > 0 && deltaY < 0) || (state.remainingY < 0 && deltaY > 0) {
                state.remainingY = 0
                state.residualY = 0
            }
            if (state.remainingX > 0 && deltaX < 0) || (state.remainingX < 0 && deltaX > 0) {
                state.remainingX = 0
                state.residualX = 0
            }

            state.remainingX += deltaX
            state.remainingY += deltaY
            state.duration = max(0.05, min(1.5, duration))
            state.activeFlags = flags

            let wasActive = state.isActive
            state.isActive = true
            return !wasActive
        }

        if shouldWake {
            DispatchQueue.main.async { [weak self] in
                self?.displayLink?.isPaused = false
            }
        }
    }

    func stopImmediately() {
        stateLock.withLock { state in
            state.remainingX = 0
            state.remainingY = 0
            state.residualX = 0
            state.residualY = 0
            state.isActive = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.isPaused = true
        }
    }

    private func setupDisplayLink() {
        displayLink?.invalidate()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        // 使用 macOS 14+ 原生 CADisplayLink，面向 ProMotion 120Hz+ 与未来 macOS 28
        let link = screen.displayLink(target: self, selector: #selector(onDisplayFrame(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setupDisplayLink()
        }
    }

    @objc private func onDisplayFrame(_ link: CADisplayLink) {
        let rawDt = link.targetTimestamp - link.timestamp
        let dt = max(1.0 / 240.0, min(1.0 / 24.0, rawDt > 0 ? rawDt : (1.0 / 60.0)))

        let stepResult: (Int32, Int32, CGEventFlags, Bool) = stateLock.withLock { state in
            guard state.isActive else { return (0, 0, [], true) }

            let decayRate = 4.6 / state.duration
            let factor = 1.0 - exp(-decayRate * dt)

            let stepX = state.remainingX * factor
            let stepY = state.remainingY * factor

            state.remainingX -= stepX
            state.remainingY -= stepY

            let totalX = stepX + state.residualX
            let totalY = stepY + state.residualY

            let emitX = Int32(totalX.rounded(.towardZero))
            let emitY = Int32(totalY.rounded(.towardZero))

            state.residualX = totalX - Double(emitX)
            state.residualY = totalY - Double(emitY)

            let done = abs(state.remainingX) < 0.35 && abs(state.remainingY) < 0.35
            if done {
                state.remainingX = 0
                state.remainingY = 0
                state.residualX = 0
                state.residualY = 0
                state.isActive = false
            }

            return (emitX, emitY, state.activeFlags, done)
        }

        if stepResult.0 != 0 || stepResult.1 != 0 {
            postPixelScroll(dx: stepResult.0, dy: stepResult.1, flags: stepResult.2)
            monitorCollector.record(
                kind: .smoothOutput,
                deltaX: Double(stepResult.0),
                deltaY: Double(stepResult.1)
            )
        }

        if stepResult.3 {
            link.isPaused = true
        }
    }

    private func postPixelScroll(dx: Int32, dy: Int32, flags: CGEventFlags) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }

        event.setIntegerValueField(.eventSourceUserData, value: RatConstants.eventTag)
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
