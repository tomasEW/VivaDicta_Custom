import AppKit
import ApplicationServices

struct TextSelectionContext: Sendable, Equatable {
    let targetPID: pid_t
    let selectedText: String
    let selectionLocation: Int?
    let selectionLength: Int?
}

@MainActor
enum TextInserter {
    private static let antigravityBundleIdentifier = "com.google.antigravity"

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        // Using the SDK's kAXTrustedCheckOptionPrompt global directly triggers
        // Swift 6 strict-concurrency diagnostics because it is imported as
        // shared mutable state. The Accessibility API key is a stable CFString
        // value, so construct the options dictionary with its documented value.
        let options = [
            "AXTrustedCheckOptionPrompt": prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Deliberately copies text for an explicit user action such as the Copy
    /// button. Automatic insertion uses a temporary pasteboard write instead.
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        write(text, to: .general)
    }

    /// Captures the text explicitly selected in whichever app currently owns
    /// keyboard focus. Speak to Edit intentionally requires an explicit
    /// selection so a failed focus restore can never rewrite unrelated text.
    static func captureSelection(promptForAccessibility: Bool) -> TextSelectionContext? {
        guard isAccessibilityTrusted(prompt: promptForAccessibility),
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        let targetPID = frontmost.processIdentifier
        guard let element = focusedElement(for: targetPID) ?? systemFocusedElement() else {
            return nil
        }

        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(element, &focusedPID) == .success,
              focusedPID == targetPID,
              let selectedText = stringAttribute("AXSelectedText", from: element),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let range = selectedTextRange(from: element)
        return TextSelectionContext(
            targetPID: targetPID,
            selectedText: selectedText,
            selectionLocation: range?.location,
            selectionLength: range?.length
        )
    }

    /// Replaces the selection captured when Speak to Edit started.
    ///
    /// The direct Accessibility write is preferred and does not modify the
    /// clipboard. Cmd+V is a fallback for hosts that expose selected text but
    /// reject an AXSelectedText write. If selection validation fails, the
    /// generated result is intentionally left on the clipboard for recovery.
    static func replaceSelection(
        with text: String,
        context: TextSelectionContext,
        promptForAccessibility: Bool
    ) async -> Bool {
        guard !text.isEmpty else { return false }

        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            copy(text)
            return false
        }

        await activateApplication(pid: context.targetPID)

        guard let element = focusedElement(for: context.targetPID),
              selectionStillMatches(context, in: element)
        else {
            copy(text)
            return false
        }

        // Chromium/Electron accessibility bridges can report a successful
        // AXSelectedText write without updating the web editor's actual
        // value. Anti-Gravity is one of those hosts, so use the same paste
        // path a user uses and leave the result available for recovery.
        let antiGravityTarget = isAntiGravity(pid: context.targetPID)
        if !antiGravityTarget {
            let setStatus = AXUIElementSetAttributeValue(
                element,
                "AXSelectedText" as CFString,
                text as CFString
            )
            if setStatus == .success {
                return true
            }
        }

        return await pasteTemporarily(
            text,
            targetPID: antiGravityTarget ? context.targetPID : nil,
            restoreClipboard: !antiGravityTarget
        )
    }

    /// Inserts text into the app that owned focus when dictation started.
    /// Direct Accessibility insertion is attempted first; the clipboard is
    /// used only as a compatibility fallback.
    static func insert(
        _ text: String,
        into targetPID: pid_t?,
        promptForAccessibility: Bool
    ) async -> Bool {
        guard !text.isEmpty else { return false }

        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            copy(text)
            return false
        }

        if let targetPID {
            await activateApplication(pid: targetPID)
            let antiGravityTarget = isAntiGravity(pid: targetPID)

            // Anti-Gravity's Chromium accessibility layer can return
            // AXError.success for AXSelectedText while dropping the write.
            // Use a real Cmd+V for that host and verify its AXValue changed.
            if antiGravityTarget {
                return await pasteTemporarily(
                    text,
                    targetPID: targetPID,
                    restoreClipboard: false
                )
            }

            if let element = focusedElement(for: targetPID),
               AXUIElementSetAttributeValue(
                   element,
                   "AXSelectedText" as CFString,
                   text as CFString
               ) == .success {
                return true
            }
        } else if let element = systemFocusedElement(),
                  AXUIElementSetAttributeValue(
                      element,
                      "AXSelectedText" as CFString,
                      text as CFString
                  ) == .success {
            return true
        }

        return await pasteTemporarily(text)
    }

    private static func selectionStillMatches(
        _ context: TextSelectionContext,
        in element: AXUIElement
    ) -> Bool {
        guard stringAttribute("AXSelectedText", from: element) == context.selectedText else {
            return false
        }

        guard let selectionLocation = context.selectionLocation,
              let selectionLength = context.selectionLength
        else {
            return true
        }

        guard let currentRange = selectedTextRange(from: element) else {
            return false
        }
        return currentRange.location == selectionLocation && currentRange.length == selectionLength
    }

    private static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            "AXFocusedUIElement" as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func focusedElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        // Chromium/Electron apps may not expose their inner accessibility tree
        // until manual accessibility is enabled. Unsupported hosts simply ignore
        // this attribute.
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            "AXFocusedUIElement" as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success
        else {
            return nil
        }
        return value as? String
    }

    private static func selectedTextRange(from element: AXUIElement) -> (location: Int, length: Int)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextRange" as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return (location: range.location, length: range.length)
    }

    private static func activateApplication(pid: pid_t) async {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(160))
    }

    private static func pasteTemporarily(
        _ text: String,
        targetPID: pid_t? = nil,
        restoreClipboard: Bool = true
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        write(text, to: pasteboard)
        let toolChangeCount = pasteboard.changeCount

        guard await postPasteShortcut() else {
            if restoreClipboard {
                snapshot.restore(to: pasteboard, ifChangeCountIs: toolChangeCount)
            }
            return false
        }

        // Electron hosts need a little longer for the web editor to reflect
        // the native paste. Verify the value when a target PID is available;
        // this prevents AXSelectedText/CGEvent success from being reported as
        // a visible insertion when the web input ignored it.
        try? await Task.sleep(for: .milliseconds(300))

        let inserted = targetPID.map { pid in
            guard let element = focusedElement(for: pid),
                  let value = stringAttribute("AXValue", from: element)
            else {
                return false
            }
            return value.contains(text)
        } ?? true

        if restoreClipboard {
            // Restore only if nobody has changed the pasteboard since our
            // temporary write. If verification failed, the caller still gets
            // an accurate false result instead of a false "貼入" status.
            snapshot.restore(to: pasteboard, ifChangeCountIs: toolChangeCount)
        }
        return inserted
    }

    private static func isAntiGravity(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == antigravityBundleIdentifier
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postPasteShortcut() async -> Bool {
        await waitForHotKeyModifiersToRelease()

        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(9), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(9), keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func waitForHotKeyModifiersToRelease() async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        let hotKeyModifiers: NSEvent.ModifierFlags = [.control, .option]

        while !NSEvent.modifierFlags.intersection(hotKeyModifiers).isEmpty,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

private struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expectedChangeCount: Int) {
        guard pasteboard.changeCount == expectedChangeCount else { return }
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
