import AppKit
import ApplicationServices

struct TextSelectionContext: Sendable, Equatable {
    let targetPID: pid_t
    let selectedText: String
}

@MainActor
enum TextInserter {
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

    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Captures the text explicitly selected in whichever app currently owns
    /// keyboard focus. Speak to Edit intentionally requires an explicit
    /// selection so a failed focus restore can never rewrite unrelated text.
    static func captureSelection(promptForAccessibility: Bool) -> TextSelectionContext? {
        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            return nil
        }

        guard let element = systemFocusedElement() else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        guard let selectedText = stringAttribute("AXSelectedText", from: element),
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return TextSelectionContext(targetPID: pid, selectedText: selectedText)
    }

    /// Replaces the selection captured when Speak to Edit started.
    ///
    /// The direct Accessibility write is preferred. If the host exposes the
    /// selected text but does not allow setting AXSelectedText, Cmd+V is used as
    /// a fallback. Before either path, the current selection must still match
    /// the captured source text; otherwise the generated result is left on the
    /// clipboard rather than risking replacement at the wrong caret position.
    static func replaceSelection(
        with text: String,
        context: TextSelectionContext,
        promptForAccessibility: Bool
    ) async -> Bool {
        guard !text.isEmpty else { return false }
        copy(text)

        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            return false
        }

        await activateApplication(pid: context.targetPID)

        guard let element = focusedElement(for: context.targetPID),
              let currentSelection = stringAttribute("AXSelectedText", from: element),
              currentSelection == context.selectedText
        else {
            return false
        }

        let setStatus = AXUIElementSetAttributeValue(
            element,
            "AXSelectedText" as CFString,
            text as CFString
        )
        if setStatus == .success {
            return true
        }

        return postPasteShortcut()
    }

    /// Copies text first, then synthesizes Cmd+V into the app that was active
    /// when dictation started. If Accessibility is unavailable, the text stays
    /// safely on the clipboard for a manual paste.
    static func insert(
        _ text: String,
        into targetPID: pid_t?,
        promptForAccessibility: Bool
    ) async -> Bool {
        guard !text.isEmpty else { return false }
        copy(text)

        guard isAccessibilityTrusted(prompt: promptForAccessibility) else {
            return false
        }

        if let targetPID {
            await activateApplication(pid: targetPID)
        }

        return postPasteShortcut()
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

    private static func activateApplication(pid: pid_t) async {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return
        }

        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 160_000_000)
    }

    private static func postPasteShortcut() -> Bool {
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
}
