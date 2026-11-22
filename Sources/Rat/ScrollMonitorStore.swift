import Foundation
import os

enum ScrollSampleKind: String, Sendable {
    case rawMouse = "鼠标原始输入"
    case rawHiRes = "罗技 HiRes 输入"
    case smoothOutput = "平滑输出帧"
    case trackpadPassthrough = "触控板放行"
}

struct ScrollSample: Sendable {
    let timestamp: TimeInterval
    let kind: ScrollSampleKind
    let deltaX: Double
    let deltaY: Double
    let targetApp: String
    let note: String
}

/// 高频事件线程无阻塞写入缓冲器；监控窗口关闭时自动停用，零后台开销
final class ScrollMonitorCollector: @unchecked Sendable {
    private struct BufferState {
        var isEnabled: Bool = false
        var isPaused: Bool = false
        var pending: [ScrollSample] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: BufferState())

    func setEnabled(_ enabled: Bool) {
        lock.withLock { state in
            state.isEnabled = enabled
            if !enabled {
                state.pending.removeAll(keepingCapacity: false)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        lock.withLock { state in
            state.isPaused = paused
        }
    }

    func record(
        kind: ScrollSampleKind,
        deltaX: Double,
        deltaY: Double,
        targetApp: String = "-",
        note: String = ""
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { state in
            guard state.isEnabled && !state.isPaused else { return }
            if state.pending.count > 1200 {
                state.pending.removeFirst(state.pending.count - 1000)
            }
            state.pending.append(
                ScrollSample(
                    timestamp: now,
                    kind: kind,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    targetApp: targetApp,
                    note: note
                )
            )
        }
    }

    func drainPending() -> [ScrollSample] {
        lock.withLock { state in
            guard !state.pending.isEmpty else { return [] }
            let batch = state.pending
            state.pending.removeAll(keepingCapacity: true)
            return batch
        }
    }
}
