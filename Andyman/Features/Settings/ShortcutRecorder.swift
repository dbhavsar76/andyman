import AppKit
import SwiftUI

/// A button that records a global shortcut: click, then press the keys. Esc cancels and
/// Delete clears.
struct ShortcutRecorder: View {
    @State private var shortcut = GlobalHotKey.shared.shortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(label)
                        .monospacedDigit()
                        .frame(minWidth: 90)
                }
                .accessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut: \(shortcut?.displayName ?? "none")")
                .accessibilityHint(isRecording ? "Type a key combination, or press Escape to cancel" : "Records a new shortcut")

                if shortcut != nil, !isRecording {
                    Button {
                        GlobalHotKey.shared.setShortcut(nil)
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Shortcut")
                    .accessibilityLabel("Clear Shortcut")
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return "Type Shortcut…" }
        return shortcut?.displayName ?? "Record Shortcut"
    }

    private func startRecording() {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stopRecording()
            case 51 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: // Delete
                GlobalHotKey.shared.setShortcut(nil)
                shortcut = nil
                stopRecording()
            default:
                guard let recorded = KeyboardShortcutSpec(event: event) else {
                    message = "Include ⌘, ⌥ or ⌃ in the shortcut."
                    return nil
                }
                if GlobalHotKey.shared.setShortcut(recorded) {
                    shortcut = recorded
                    message = nil
                } else {
                    message = "\(recorded.displayName) is already in use."
                }
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
