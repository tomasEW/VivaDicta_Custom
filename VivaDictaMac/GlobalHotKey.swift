import AppKit
import Carbon.HIToolbox
import Foundation

/// Native Carbon hot keys that work even while another app is active.
///
/// - ⌃⌥Space: normal dictation
/// - ⌃⌥E: Speak to Edit for the currently selected text
final class GlobalHotKey: @unchecked Sendable {
    private enum HotKeyID: UInt32 {
        case dictation = 1
        case speakToEdit = 2
    }

    private static let signature = OSType(0x56444354) // "VDCT"

    private var dictationHotKeyRef: EventHotKeyRef?
    private var speakToEditHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var applicationDidFinishLaunchingObserver: NSObjectProtocol?
    private var dictationCallback: (@MainActor () -> Void)?
    private var speakToEditCallback: (@MainActor () -> Void)?

    private(set) var dictationIsRegistered = false
    private(set) var speakToEditIsRegistered = false

    var isRegistered: Bool {
        dictationIsRegistered && speakToEditIsRegistered
    }

    init(
        dictationCallback: @escaping @MainActor () -> Void,
        speakToEditCallback: @escaping @MainActor () -> Void
    ) {
        self.dictationCallback = dictationCallback
        self.speakToEditCallback = speakToEditCallback

        applicationDidFinishLaunchingObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerHotKeys()
        }

        // SwiftUI constructs AppModel before NSApplication has necessarily finished
        // launching. Carbon returns eventInternalErr if hot keys are registered that
        // early, so defer registration until the application event target is ready.
        if NSApplication.shared.isRunning {
            registerHotKeys()
        }
    }

    private func registerHotKeys() {
        if let applicationDidFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(applicationDidFinishLaunchingObserver)
            self.applicationDidFinishLaunchingObserver = nil
        }

        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var pressedID = EventHotKeyID(signature: 0, id: 0)
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard readStatus == noErr, pressedID.signature == GlobalHotKey.signature else {
                    return noErr
                }

                let hotKeyID = pressedID.id
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    switch hotKeyID {
                    case HotKeyID.dictation.rawValue:
                        instance.dictationCallback?()
                    case HotKeyID.speakToEdit.rawValue:
                        instance.speakToEditCallback?()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else { return }

        let dictationID = EventHotKeyID(signature: Self.signature, id: HotKeyID.dictation.rawValue)
        dictationIsRegistered = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            dictationID,
            GetApplicationEventTarget(),
            0,
            &dictationHotKeyRef
        ) == noErr

        let speakToEditID = EventHotKeyID(signature: Self.signature, id: HotKeyID.speakToEdit.rawValue)
        speakToEditIsRegistered = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            speakToEditID,
            GetApplicationEventTarget(),
            0,
            &speakToEditHotKeyRef
        ) == noErr
    }

    deinit {
        if let applicationDidFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(applicationDidFinishLaunchingObserver)
        }
        if let dictationHotKeyRef {
            UnregisterEventHotKey(dictationHotKeyRef)
        }
        if let speakToEditHotKeyRef {
            UnregisterEventHotKey(speakToEditHotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
