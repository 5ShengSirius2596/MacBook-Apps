import Foundation
import AppKit
import CoreGraphics

enum ButtonActionExecutor {
    static func execute(_ action: MouseButtonAction) {
        switch action {
        case .none:
            return
        case .missionControl:
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            } else {
                sendKeyCombo(keyCode: 126, flags: .maskControl)
            }
        case .spaceLeft:
            sendKeyCombo(keyCode: 123, flags: .maskControl)
        case .spaceRight:
            sendKeyCombo(keyCode: 124, flags: .maskControl)
        case .appExpose:
            sendKeyCombo(keyCode: 125, flags: .maskControl)
        case .browserBack:
            sendKeyCombo(keyCode: 33, flags: .maskCommand)
        case .browserForward:
            sendKeyCombo(keyCode: 30, flags: .maskCommand)
        case .copy:
            sendKeyCombo(keyCode: 8, flags: .maskCommand)
        case .paste:
            sendKeyCombo(keyCode: 9, flags: .maskCommand)
        }
    }

    private static func sendKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: RatConstants.eventTag)
        keyUp.setIntegerValueField(.eventSourceUserData, value: RatConstants.eventTag)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
