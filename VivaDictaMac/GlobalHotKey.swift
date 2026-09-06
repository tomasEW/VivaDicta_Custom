import AppKit
import Carbon.HIToolbox
import Foundation

struct GlobalHotKeyRegistrationState: Equatable, Sendable {
    let dictationStatus: OSStatus
    let speakToEditStatus: OSStatus

    var dictationIsRegistered: Bool { dictationStatus == noErr }
    var speakToEditIsRegistered: Bool { speakToEditStatus == noErr }
}

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
    private var registrationStateDidChange: (@MainActor (GlobalHotKeyRegistrationState) -> Void)?

    private(set) var registrationState = GlobalHotKeyRegistrationState(
        dictationStatus: -1,
        speakToEditStatus: -1
    )

    var dictationIsRegistered: Bool { registrationState.dictationIsRegistered }
    var speakToEditIsRegistered: Bool { registrationState.speakToEditIsRegistered }

    var isRegistered: Bool {
        dictationIsRegistered && speakToEditIsRegistered
    }

    init(
        dictationCallback: @escaping @MainActor () -> Void,
        speakToEditCallback: @escaping @MainActor () -> Void,
        registrationStateDidChange: @escaping @MainActor (GlobalHotKeyRegistrationState) -> Void
    ) {
        self.dictationCallback = dictationCallback
        self.speakToEditCallback = speakToEditCallback
        self.registrationStateDidChange = registrationStateDidChange

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

    func retryRegistration() {
        registerHotKeys()
    }

    private func registerHotKeys() {
        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            publishRegistrationState(
                GlobalHotKeyRegistrationState(
                    dictationStatus: handlerStatus,
                    speakToEditStatus: handlerStatus
                )
            )
            return
        }

        if let applicationDidFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(applicationDidFinishLaunchingObserver)
            self.applicationDidFinishLaunchingObserver = nil
        }

        unregisterHotKeys()

        let dictationID = EventHotKeyID(signature: Self.signature, id: HotKeyID.dictation.rawValue)
        let dictationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            dictationID,
            GetApplicationEventTarget(),
            0,
            &dictationHotKeyRef
        )

        let speakToEditID = EventHotKeyID(signature: Self.signature, id: HotKeyID.speakToEdit.rawValue)
        let speakToEditStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            speakToEditID,
            GetApplicationEventTarget(),
            0,
            &speakToEditHotKeyRef
        )

        publishRegistrationState(
            GlobalHotKeyRegistrationState(
                dictationStatus: dictationStatus,
                speakToEditStatus: speakToEditStatus
            )
        )
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        if eventHandlerRef != nil {
            return noErr
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        return InstallEventHandler(
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

    }

    private func unregisterHotKeys() {
        if let dictationHotKeyRef {
            UnregisterEventHotKey(dictationHotKeyRef)
            self.dictationHotKeyRef = nil
        }
        if let speakToEditHotKeyRef {
            UnregisterEventHotKey(speakToEditHotKeyRef)
            self.speakToEditHotKeyRef = nil
        }
    }

    private func publishRegistrationState(_ state: GlobalHotKeyRegistrationState) {
        registrationState = state
        let callback = registrationStateDidChange
        Task { @MainActor in
            callback?(state)
        }
    }

    deinit {
        if let applicationDidFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(applicationDidFinishLaunchingObserver)
        }
        unregisterHotKeys()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
