import Foundation
import AppKit
import CoreGraphics

/// 基于纯 CoreGraphics 的 60fps 双通道滚轮示波器视图（零宏、零第三方依赖）
final class ScrollWaveformView: NSView {
    var samples: [ScrollSample] = []
    var nowTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    var windowDuration: Double = 4.0
    var useHorizontal: Bool = false
    var showRaw: Bool = true
    var showSmooth: Bool = true

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let midY = rect.height / 2.0
        let leftMargin: CGFloat = 46
        let plotWidth = max(1, rect.width - leftMargin - 10)
        let plotRect = CGRect(x: leftMargin, y: 10, width: plotWidth, height: max(1, rect.height - 20))

        // 1. 深色示波器背景与边框
        let bgPath = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.94).cgColor)
        ctx.fillPath()

        ctx.addPath(bgPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // 2. 筛选时间窗样本并自适应纵向刻度
        let startTime = nowTimestamp - windowDuration
        let visible = samples.filter { $0.timestamp >= startTime && $0.timestamp <= nowTimestamp }

        var maxAbsValue: Double = 24.0
        for s in visible {
            let rawVal = useHorizontal ? s.deltaX : s.deltaY
            let scaled = (s.kind == .smoothOutput) ? rawVal : (rawVal * 12.0)
            maxAbsValue = max(maxAbsValue, abs(scaled) * 1.15)
        }
        let scaleY = (plotRect.height * 0.45) / maxAbsValue

        // 3. 网格线
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1)
        let gridSteps = max(1, Int(windowDuration))
        for i in 1...gridSteps {
            let ratio = CGFloat(Double(i) / windowDuration)
            let x = plotRect.maxX - ratio * plotRect.width
            ctx.move(to: CGPoint(x: x, y: plotRect.minY))
            ctx.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        }
        for frac in [-0.5, 0.5] {
            let y = midY - CGFloat(frac) * (plotRect.height * 0.9)
            ctx.move(to: CGPoint(x: plotRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        }
        ctx.strokePath()

        // 零轴虚线
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: CGPoint(x: plotRect.minX, y: midY))
        ctx.addLine(to: CGPoint(x: plotRect.maxX, y: midY))
        ctx.strokePath()
        ctx.restoreGState()

        // Y 轴刻度标签
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.systemGray
        ]
        (String(format: "+%.0f", maxAbsValue) as NSString).draw(at: CGPoint(x: 8, y: plotRect.minY), withAttributes: labelAttrs)
        ("0" as NSString).draw(at: CGPoint(x: 20, y: midY - 6), withAttributes: labelAttrs)
        (String(format: "-%.0f", maxAbsValue) as NSString).draw(at: CGPoint(x: 8, y: plotRect.maxY - 12), withAttributes: labelAttrs)

        func xPos(for t: TimeInterval) -> CGFloat {
            let progress = (t - startTime) / windowDuration
            return plotRect.minX + CGFloat(progress) * plotRect.width
        }

        func yPos(for v: Double) -> CGFloat {
            let clamped = max(-maxAbsValue, min(maxAbsValue, v))
            return midY - CGFloat(clamped * scaleY)
        }

        // 4. 绘制原始滚轮输入脉冲棒
        if showRaw {
            ctx.saveGState()
            ctx.setLineWidth(2.2)
            for s in visible where s.kind != .smoothOutput {
                let v = (useHorizontal ? s.deltaX : s.deltaY) * 12.0
                let x = xPos(for: s.timestamp)
                let y = yPos(for: v)

                let nsColor: NSColor
                switch s.kind {
                case .rawHiRes: nsColor = .systemPurple
                case .trackpadPassthrough: nsColor = .systemGreen
                default: nsColor = .systemOrange
                }

                ctx.setStrokeColor(nsColor.withAlphaComponent(0.88).cgColor)
                ctx.move(to: CGPoint(x: x, y: midY))
                ctx.addLine(to: CGPoint(x: x, y: y))
                ctx.strokePath()

                ctx.setFillColor(nsColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5))
            }
            ctx.restoreGState()
        }

        // 5. 绘制平滑输出连续曲线
        if showSmooth {
            let smoothSamples = visible.filter { $0.kind == .smoothOutput }
            if !smoothSamples.isEmpty {
                let linePath = CGMutablePath()
                let fillPath = CGMutablePath()
                var lastTime: TimeInterval?

                for s in smoothSamples {
                    let v = useHorizontal ? s.deltaX : s.deltaY
                    let x = xPos(for: s.timestamp)
                    let y = yPos(for: v)

                    if let prev = lastTime, (s.timestamp - prev) > 0.06 {
                        let prevEndX = xPos(for: prev)
                        linePath.addLine(to: CGPoint(x: prevEndX, y: midY))
                        fillPath.addLine(to: CGPoint(x: prevEndX, y: midY))
                        fillPath.closeSubpath()

                        linePath.move(to: CGPoint(x: x, y: midY))
                        linePath.addLine(to: CGPoint(x: x, y: y))
                        fillPath.move(to: CGPoint(x: x, y: midY))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    } else if lastTime == nil {
                        linePath.move(to: CGPoint(x: x, y: midY))
                        linePath.addLine(to: CGPoint(x: x, y: y))
                        fillPath.move(to: CGPoint(x: x, y: midY))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        linePath.addLine(to: CGPoint(x: x, y: y))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    }
                    lastTime = s.timestamp
                }

                if let last = lastTime {
                    let endX = xPos(for: last)
                    fillPath.addLine(to: CGPoint(x: endX, y: midY))
                    fillPath.closeSubpath()
                }

                ctx.saveGState()
                ctx.addPath(fillPath)
                ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.22).cgColor)
                ctx.fillPath()

                ctx.addPath(linePath)
                ctx.setStrokeColor(NSColor.systemCyan.cgColor)
                ctx.setLineWidth(2.0)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }
}

final class ScrollMonitorWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let collector: ScrollMonitorCollector
    private var samples: [ScrollSample] = []
    private var recentEvents: [ScrollSample] = []

    private var refreshTimer: Timer?
    private var isPaused: Bool = false
    private var totalRawCount: Int = 0
    private var totalSmoothFrames: Int = 0
    private var lastActiveApp: String = "等待滚轮事件..."
    private var lastSourceLabel: String = "空闲"

    private let statusLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let axisControl = NSSegmentedControl(labels: ["垂直 (Y)", "水平 (X)"], trackingMode: .selectOne, target: nil, action: nil)
    private let topCheckbox = NSButton(checkboxWithTitle: "置顶", target: nil, action: nil)
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let rawCheckbox = NSButton(checkboxWithTitle: "原始滚轮脉冲 (橙/紫)", target: nil, action: nil)
    private let smoothCheckbox = NSButton(checkboxWithTitle: "平滑输出曲线 (青)", target: nil, action: nil)
    private let windowSlider = NSSlider(value: 4.0, minValue: 2.0, maxValue: 6.0, target: nil, action: nil)
    private let windowDurationLabel = NSTextField(labelWithString: "时间窗：4s")
    private let waveformView = ScrollWaveformView()
    private let tableView = NSTableView()

    init(collector: ScrollMonitorCollector) {
        self.collector = collector
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Rat 实时滚动监控"
        win.minSize = NSSize(width: 620, height: 420)
        win.level = .floating
        win.center()
        super.init(window: win)
        win.delegate = self
        setupUI()
        updateHeaderText()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showMonitor() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        collector.setEnabled(true)
        collector.setPaused(isPaused)
        startTimer()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        collector.setEnabled(false)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 10
        rootStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])

        // 顶部状态栏
        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleCol = NSStackView(views: [statusLabel, subtitleLabel])
        titleCol.orientation = .vertical
        titleCol.alignment = .leading
        titleCol.spacing = 2

        axisControl.selectedSegment = 0
        axisControl.target = self
        axisControl.action = #selector(onAxisChanged(_:))

        topCheckbox.state = .on
        topCheckbox.target = self
        topCheckbox.action = #selector(onAlwaysOnTopChanged(_:))

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(onTogglePause(_:))

        let clearButton = NSButton(title: "清空", target: self, action: #selector(onClear(_:)))
        clearButton.bezelStyle = .rounded

        let spacer1 = NSView()
        spacer1.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [titleCol, spacer1, axisControl, topCheckbox, pauseButton, clearButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        rootStack.addArrangedSubview(headerRow)

        // 曲线控制行
        rawCheckbox.state = .on
        rawCheckbox.target = self
        rawCheckbox.action = #selector(onSeriesToggleChanged(_:))

        smoothCheckbox.state = .on
        smoothCheckbox.target = self
        smoothCheckbox.action = #selector(onSeriesToggleChanged(_:))

        windowDurationLabel.font = NSFont.systemFont(ofSize: 11)
        windowDurationLabel.textColor = .secondaryLabelColor

        windowSlider.numberOfTickMarks = 5
        windowSlider.allowsTickMarkValuesOnly = true
        windowSlider.target = self
        windowSlider.action = #selector(onWindowDurationChanged(_:))
        windowSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let spacer2 = NSView()
        spacer2.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let legendRow = NSStackView(views: [rawCheckbox, smoothCheckbox, spacer2, windowDurationLabel, windowSlider])
        legendRow.orientation = .horizontal
        legendRow.alignment = .centerY
        legendRow.spacing = 12
        rootStack.addArrangedSubview(legendRow)

        // 示波器画布
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        rootStack.addArrangedSubview(waveformView)

        // 底部事件列表
        let tableTitle = NSTextField(labelWithString: "最近原始滚轮事件（正值向上 / 负值向下）")
        tableTitle.font = NSFont.boldSystemFont(ofSize: 11)
        tableTitle.textColor = .secondaryLabelColor
        rootStack.addArrangedSubview(tableTitle)

        let columns: [(String, String, CGFloat)] = [
            ("kind", "事件来源", 115),
            ("dy", "垂直 dY", 78),
            ("dx", "水平 dX", 78),
            ("app", "目标应用", 160),
            ("note", "标记", 160)
        ]
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            tableView.addTableColumn(col)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        rootStack.addArrangedSubview(scrollView)
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func tick() {
        if isPaused { return }
        let now = ProcessInfo.processInfo.systemUptime
        let incoming = collector.drainPending()
        var tableNeedsReload = false

        if !incoming.isEmpty {
            samples.append(contentsOf: incoming)
            var notable: [ScrollSample] = []
            for item in incoming {
                if item.kind == .smoothOutput {
                    totalSmoothFrames += 1
                } else {
                    totalRawCount += 1
                    lastActiveApp = item.targetApp
                    lastSourceLabel = item.kind.rawValue
                    notable.append(item)
                }
            }
            if !notable.isEmpty {
                recentEvents.insert(contentsOf: notable.reversed(), at: 0)
                if recentEvents.count > 60 {
                    recentEvents.removeLast(recentEvents.count - 60)
                }
                tableNeedsReload = true
            }
            updateHeaderText()
        }

        let cutoff = now - max(waveformView.windowDuration + 2.0, 6.0)
        if let firstValid = samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValid > 0 {
                samples.removeFirst(firstValid)
            }
        } else if !samples.isEmpty {
            samples.removeAll(keepingCapacity: true)
        }

        waveformView.samples = samples
        waveformView.nowTimestamp = now
        waveformView.needsDisplay = true

        if tableNeedsReload {
            tableView.reloadData()
        }
    }

    private func updateHeaderText() {
        let dot = isPaused ? "🟠 已暂停" : "🟢 实时监控中"
        statusLabel.stringValue = "\(dot) · \(lastSourceLabel)"
        subtitleLabel.stringValue = "目标应用：\(lastActiveApp)  |  原始输入：\(totalRawCount)  |  平滑帧：\(totalSmoothFrames)"
    }

    @objc private func onAxisChanged(_ sender: NSSegmentedControl) {
        waveformView.useHorizontal = (sender.selectedSegment == 1)
        waveformView.needsDisplay = true
    }

    @objc private func onAlwaysOnTopChanged(_ sender: NSButton) {
        window?.level = (sender.state == .on) ? .floating : .normal
    }

    @objc private func onTogglePause(_ sender: NSButton) {
        isPaused.toggle()
        collector.setPaused(isPaused)
        pauseButton.title = isPaused ? "继续" : "暂停"
        updateHeaderText()
    }

    @objc private func onClear(_ sender: NSButton) {
        samples.removeAll()
        recentEvents.removeAll()
        totalRawCount = 0
        totalSmoothFrames = 0
        lastSourceLabel = "已清空"
        updateHeaderText()
        waveformView.samples = []
        waveformView.needsDisplay = true
        tableView.reloadData()
    }

    @objc private func onSeriesToggleChanged(_ sender: NSButton) {
        waveformView.showRaw = (rawCheckbox.state == .on)
        waveformView.showSmooth = (smoothCheckbox.state == .on)
        waveformView.needsDisplay = true
    }

    @objc private func onWindowDurationChanged(_ sender: NSSlider) {
        let sec = round(sender.doubleValue)
        waveformView.windowDuration = sec
        windowDurationLabel.stringValue = "时间窗：\(Int(sec))s"
        waveformView.needsDisplay = true
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return recentEvents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < recentEvents.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let item = recentEvents[row]
        let cellID = NSUserInterfaceItemIdentifier("MonitorCell_\(colID)")
        let field: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = cellID
            field.lineBreakMode = .byTruncatingTail
        }

        switch colID {
        case "kind":
            field.stringValue = item.kind.rawValue
            field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            switch item.kind {
            case .rawMouse: field.textColor = .systemOrange
            case .rawHiRes: field.textColor = .systemPurple
            case .trackpadPassthrough: field.textColor = .systemGreen
            case .smoothOutput: field.textColor = .systemCyan
            }
        case "dy":
            field.stringValue = String(format: "%+6.2f", item.deltaY)
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .labelColor
        case "dx":
            field.stringValue = String(format: "%+6.2f", item.deltaX)
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
        case "app":
            field.stringValue = item.targetApp
            field.font = NSFont.systemFont(ofSize: 11)
            field.textColor = .labelColor
        case "note":
            field.stringValue = item.note
            field.font = NSFont.systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
        default:
            break
        }
        return field
    }
}
