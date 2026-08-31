import AppKit
import ApplicationServices

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

        if let targetPID,
           targetPID != ProcessInfo.processInfo.processIdentifier,
           let app = NSRunningApplication(processIdentifier: targetPID) {
            app.activate(options: [.activateIgnoringOtherApps])
            try? await Task.sleep(nanoseconds: 160_000_000)
        }

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
