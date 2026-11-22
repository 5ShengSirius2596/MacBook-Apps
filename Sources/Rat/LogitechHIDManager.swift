import Foundation
import IOKit
import IOKit.hid

struct LogitechDeviceInfo: Hashable, Sendable {
    let id: String
    var productName: String
    var productID: Int
    var transport: String
    var deviceIndex: UInt8
    var protocolVersion: String
    var hiResFeatureIndex: UInt8?
    var hiResFeatureID: UInt16?
    var hiResMultiplier: Int
    var hiResActive: Bool
    var smartShiftFeatureIndex: UInt8?
    var smartShiftMode: SmartShiftMode
    var batteryPercent: Int?
    var statusMessage: String
}

private final class HIDDeviceContext {
    let id: String
    let device: IOHIDDevice
    let productName: String
    let productID: Int
    let transport: String
    let reportBuffer: UnsafeMutablePointer<UInt8>
    let reportBufferSize: Int = 64

    var activeDeviceIndex: UInt8 = 0xFF
    var hiResFeatureIndex: UInt8?
    var hiResFeatureID: UInt16?
    var smartShiftFeatureIndex: UInt8?
    var batteryFeatureIndex: UInt8?

    init(id: String, device: IOHIDDevice, productName: String, productID: Int, transport: String) {
        self.id = id
        self.device = device
        self.productName = productName
        self.productID = productID
        self.transport = transport
        self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
        self.reportBuffer.initialize(repeating: 0, count: reportBufferSize)
    }

    deinit {
        reportBuffer.deallocate()
    }
}

/// 基于公开 IOKit IOHIDManager 的罗技 HID++ 2.0 驱动模块
final class LogitechHIDManager {
    static let logitechVendorID: Int = 0x046D

    private static let shortReportID: UInt8 = 0x10
    private static let shortReportLength: Int = 7
    private static let longReportID: UInt8 = 0x11
    private static let longReportLength: Int = 20

    private enum SoftwareTag: UInt8 {
        case ping = 0x01
        case queryHiResWheel = 0x02      // 0x2121
        case queryHiResScrolling = 0x03  // 0x2120
        case querySmartShift = 0x04      // 0x2111
        case queryBattery = 0x05         // 0x1004
        case command = 0x0A
    }

    private static let featureHiResWheel: UInt16 = 0x2121
    private static let featureHiResScrolling: UInt16 = 0x2120
    private static let featureSmartShift: UInt16 = 0x2111
    private static let featureUnifiedBattery: UInt16 = 0x1004

    var devices: [LogitechDeviceInfo] = [] { didSet { onDevicesChanged?() } }
    var managerStatus: String = "未启动" { didSet { onDevicesChanged?() } }
    var isRunning: Bool = false
    var onDevicesChanged: (() -> Void)?

    private var hidManager: IOHIDManager?
    private var deviceContexts: [ObjectIdentifier: HIDDeviceContext] = [:]
    private let configBridge: SharedConfigBridge

    init(configBridge: SharedConfigBridge) {
        self.configBridge = configBridge
    }

    func start() {
        guard hidManager == nil else { return }
        guard configBridge.current.logitechHIDEnabled else {
            managerStatus = "已在设置中关闭"
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matchingCriteria: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: Self.logitechVendorID,
                kIOHIDPrimaryUsagePageKey as String: 0xFF00
            ],
            [
                kIOHIDVendorIDKey as String: Self.logitechVendorID,
                kIOHIDPrimaryUsagePageKey as String: 0xFF43
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingCriteria as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            let mgr = Unmanaged<LogitechHIDManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.onDeviceMatched(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            let mgr = Unmanaged<LogitechHIDManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.onDeviceRemoved(device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            self.hidManager = manager
            self.isRunning = true
            self.managerStatus = "正在监听罗技 HID++ 设备"
        } else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            self.isRunning = false
            self.managerStatus = "打开 IOHIDManager 失败（需要“输入监控”权限，错误码：\(openResult)）"
        }
    }

    func stop() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        deviceContexts.removeAll()
        devices.removeAll()
        isRunning = false
        managerStatus = "已停止"
        syncHiResStateToBridge()
    }

    func applyCurrentConfigToAllDevices() {
        let cfg = configBridge.current
        if !cfg.logitechHIDEnabled {
            stop()
            return
        }
        if !isRunning {
            start()
        }
        for ctx in deviceContexts.values {
            applyHiResSetting(for: ctx, enabled: cfg.logitechHiResEnabled, invert: cfg.logitechInvertHardware)
        }
    }

    func rescanDevices() {
        for ctx in deviceContexts.values {
            probeDevice(ctx)
        }
    }

    func setSmartShiftMode(deviceID: String, mode: SmartShiftMode) {
        guard let ctx = deviceContexts.values.first(where: { $0.id == deviceID }),
              let featureIndex = ctx.smartShiftFeatureIndex else { return }
        let wheelModeByte: UInt8 = (mode == .freespin) ? 0x01 : 0x02
        sendHIDPP(
            to: ctx,
            deviceIndex: ctx.activeDeviceIndex,
            featureIndex: featureIndex,
            functionID: 0x02,
            swTag: .command,
            params: [wheelModeByte, 0x00, 0x00]
        )
        updateDeviceInfo(id: deviceID) { info in
            info.smartShiftMode = mode
            info.statusMessage = "已切换至\(mode.rawValue)"
        }
    }

    private func onDeviceMatched(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        if deviceContexts[key] != nil { return }

        let productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "罗技 HID++ 设备"
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "USB/无线"
        let locationID = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int) ?? productID
        let id = "\(productID)-\(locationID)-\(Unmanaged.passUnretained(device).toOpaque())"

        let ctx = HIDDeviceContext(
            id: id,
            device: device,
            productName: productName,
            productID: productID,
            transport: transport
        )
        deviceContexts[key] = ctx

        let info = LogitechDeviceInfo(
            id: id,
            productName: productName,
            productID: productID,
            transport: transport,
            deviceIndex: 0xFF,
            protocolVersion: "探测中...",
            hiResFeatureIndex: nil,
            hiResFeatureID: nil,
            hiResMultiplier: 1,
            hiResActive: false,
            smartShiftFeatureIndex: nil,
            smartShiftMode: .ratchet,
            batteryPercent: nil,
            statusMessage: "正在握手 HID++ 2.0"
        )
        devices.append(info)

        let managerPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            ctx.reportBuffer,
            ctx.reportBufferSize,
            { context, _, sender, _, reportID, report, reportLength in
                guard let context, let sender else { return }
                let mgr = Unmanaged<LogitechHIDManager>.fromOpaque(context).takeUnretainedValue()
                let hidDevice = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: Int(reportLength)))
                mgr.handleInputReport(device: hidDevice, reportID: reportID, bytes: bytes)
            },
            managerPtr
        )

        probeDevice(ctx)
    }

    private func onDeviceRemoved(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        guard let ctx = deviceContexts.removeValue(forKey: key) else { return }
        devices.removeAll { $0.id == ctx.id }
        syncHiResStateToBridge()
    }

    private func probeDevice(_ ctx: HIDDeviceContext) {
        let candidateIndices: [UInt8] = ctx.transport.lowercased().contains("bluetooth")
            ? [0xFF]
            : [0xFF, 0x01, 0x02, 0x03]

        for devIdx in candidateIndices {
            sendHIDPP(
                to: ctx,
                deviceIndex: devIdx,
                featureIndex: 0x00,
                functionID: 0x01,
                swTag: .ping,
                params: [0x00, 0x00, 0x5A]
            )
            queryFeatureIndex(for: ctx, deviceIndex: devIdx, featureID: Self.featureHiResWheel, tag: .queryHiResWheel)
            queryFeatureIndex(for: ctx, deviceIndex: devIdx, featureID: Self.featureHiResScrolling, tag: .queryHiResScrolling)
            queryFeatureIndex(for: ctx, deviceIndex: devIdx, featureID: Self.featureSmartShift, tag: .querySmartShift)
            queryFeatureIndex(for: ctx, deviceIndex: devIdx, featureID: Self.featureUnifiedBattery, tag: .queryBattery)
        }
    }

    private func queryFeatureIndex(
        for ctx: HIDDeviceContext,
        deviceIndex: UInt8,
        featureID: UInt16,
        tag: SoftwareTag
    ) {
        let hi = UInt8((featureID >> 8) & 0xFF)
        let lo = UInt8(featureID & 0xFF)
        sendHIDPP(
            to: ctx,
            deviceIndex: deviceIndex,
            featureIndex: 0x00,
            functionID: 0x00,
            swTag: tag,
            params: [hi, lo, 0x00]
        )
    }

    private func applyHiResSetting(for ctx: HIDDeviceContext, enabled: Bool, invert: Bool) {
        guard let featureIndex = ctx.hiResFeatureIndex else { return }
        var modeFlags: UInt8 = 0x00
        if enabled { modeFlags |= 0x02 }
        if invert { modeFlags |= 0x04 }

        sendHIDPP(
            to: ctx,
            deviceIndex: ctx.activeDeviceIndex,
            featureIndex: featureIndex,
            functionID: 0x02,
            swTag: .command,
            params: [0x00, modeFlags]
        )

        updateDeviceInfo(id: ctx.id) { info in
            info.hiResActive = enabled
            info.statusMessage = enabled
                ? "高分辨率滚轮已启用（\(info.hiResMultiplier)x 细分）"
                : "标准滚轮模式"
        }
        syncHiResStateToBridge()
    }

    @discardableResult
    private func sendHIDPP(
        to ctx: HIDDeviceContext,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        swTag: SoftwareTag,
        params: [UInt8]
    ) -> Bool {
        let funcAndSw = ((functionID & 0x0F) << 4) | (swTag.rawValue & 0x0F)

        var longPacket = [UInt8](repeating: 0, count: Self.longReportLength)
        longPacket[0] = Self.longReportID
        longPacket[1] = deviceIndex
        longPacket[2] = featureIndex
        longPacket[3] = funcAndSw
        for (i, byte) in params.prefix(Self.longReportLength - 4).enumerated() {
            longPacket[4 + i] = byte
        }

        let resLong = longPacket.withUnsafeBytes { rawPtr -> IOReturn in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                ctx.device,
                kIOHIDReportTypeOutput,
                CFIndex(Self.longReportID),
                base,
                longPacket.count
            )
        }
        if resLong == kIOReturnSuccess {
            return true
        }

        var shortPacket = [UInt8](repeating: 0, count: Self.shortReportLength)
        shortPacket[0] = Self.shortReportID
        shortPacket[1] = deviceIndex
        shortPacket[2] = featureIndex
        shortPacket[3] = funcAndSw
        for (i, byte) in params.prefix(Self.shortReportLength - 4).enumerated() {
            shortPacket[4 + i] = byte
        }

        let resShort = shortPacket.withUnsafeBytes { rawPtr -> IOReturn in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                ctx.device,
                kIOHIDReportTypeOutput,
                CFIndex(Self.shortReportID),
                base,
                shortPacket.count
            )
        }
        return resShort == kIOReturnSuccess
    }

    private func handleInputReport(device: IOHIDDevice, reportID: UInt32, bytes: [UInt8]) {
        guard let ctx = deviceContexts[ObjectIdentifier(device)], bytes.count >= 7 else { return }

        let payload: [UInt8]
        if bytes[0] == Self.shortReportID || bytes[0] == Self.longReportID {
            payload = bytes
        } else if reportID == UInt32(Self.shortReportID) || reportID == UInt32(Self.longReportID) {
            payload = [UInt8(reportID)] + bytes
        } else {
            return
        }
        guard payload.count >= 7 else { return }

        let devIdx = payload[1]
        let featureIdx = payload[2]
        let funcID = (payload[3] >> 4) & 0x0F
        let rawSwID = payload[3] & 0x0F

        if featureIdx == 0x8F || featureIdx == 0xFF {
            return
        }

        guard let tag = SoftwareTag(rawValue: rawSwID) else { return }

        if featureIdx == 0x00 {
            switch tag {
            case .ping where funcID == 0x01:
                let major = payload[4]
                let minor = payload[5]
                if major >= 2 {
                    ctx.activeDeviceIndex = devIdx
                    updateDeviceInfo(id: ctx.id) { info in
                        info.deviceIndex = devIdx
                        info.protocolVersion = "HID++ \(major).\(minor)"
                        info.statusMessage = "HID++ 握手成功"
                    }
                }
            case .queryHiResWheel where funcID == 0x00:
                let foundIdx = payload[4]
                if foundIdx != 0 {
                    registerHiResFeature(ctx: ctx, deviceIndex: devIdx, featureIndex: foundIdx, featureID: Self.featureHiResWheel)
                }
            case .queryHiResScrolling where funcID == 0x00:
                let foundIdx = payload[4]
                if foundIdx != 0 && ctx.hiResFeatureIndex == nil {
                    registerHiResFeature(ctx: ctx, deviceIndex: devIdx, featureIndex: foundIdx, featureID: Self.featureHiResScrolling)
                }
            case .querySmartShift where funcID == 0x00:
                let foundIdx = payload[4]
                if foundIdx != 0 {
                    ctx.activeDeviceIndex = devIdx
                    ctx.smartShiftFeatureIndex = foundIdx
                    updateDeviceInfo(id: ctx.id) { info in
                        info.smartShiftFeatureIndex = foundIdx
                    }
                }
            case .queryBattery where funcID == 0x00:
                let foundIdx = payload[4]
                if foundIdx != 0 {
                    ctx.activeDeviceIndex = devIdx
                    ctx.batteryFeatureIndex = foundIdx
                    sendHIDPP(
                        to: ctx,
                        deviceIndex: devIdx,
                        featureIndex: foundIdx,
                        functionID: 0x01,
                        swTag: .command,
                        params: []
                    )
                }
            default:
                break
            }
            return
        }

        if tag == .command, let hiResIdx = ctx.hiResFeatureIndex, featureIdx == hiResIdx, funcID == 0x00 {
            let multiplier = max(1, Int(payload[4]))
            updateDeviceInfo(id: ctx.id) { info in
                info.hiResMultiplier = multiplier
            }
            let cfg = configBridge.current
            applyHiResSetting(for: ctx, enabled: cfg.logitechHiResEnabled, invert: cfg.logitechInvertHardware)
            return
        }

        if tag == .command, let batIdx = ctx.batteryFeatureIndex, featureIdx == batIdx, funcID == 0x01 {
            let level = Int(payload[4])
            if (0...100).contains(level) {
                updateDeviceInfo(id: ctx.id) { info in
                    info.batteryPercent = level
                }
            }
        }
    }

    private func registerHiResFeature(
        ctx: HIDDeviceContext,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        featureID: UInt16
    ) {
        ctx.activeDeviceIndex = deviceIndex
        ctx.hiResFeatureIndex = featureIndex
        ctx.hiResFeatureID = featureID
        updateDeviceInfo(id: ctx.id) { info in
            info.hiResFeatureIndex = featureIndex
            info.hiResFeatureID = featureID
        }
        sendHIDPP(
            to: ctx,
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0x00,
            swTag: .command,
            params: []
        )
    }

    private func updateDeviceInfo(id: String, mutate: (inout LogitechDeviceInfo) -> Void) {
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            mutate(&devices[idx])
        }
    }

    private func syncHiResStateToBridge() {
        let activeHiResDevice = devices.first { $0.hiResActive && $0.hiResMultiplier > 1 }
        if let dev = activeHiResDevice {
            configBridge.updateLogitechHiResState(active: true, multiplier: dev.hiResMultiplier)
        } else {
            configBridge.updateLogitechHiResState(active: false, multiplier: 1)
        }
    }
}
