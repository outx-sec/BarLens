import AppKit
import SwiftUI

/// A control that records a key combination.
///
/// Recording uses a *local* event monitor rather than making a view first
/// responder: while recording, every keystroke in the app is ours to look at
/// anyway, and a local monitor cannot be bypassed by focus moving around.
struct HotkeyRecorder: View {

    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording.toggle()
            } label: {
                Text(isRecording ? tr("按下组合键…", "Press shortcut…") : (hotkey?.display ?? tr("未设置", "Not Set")))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(isRecording ? .accentColor : nil)

            if hotkey != nil, !isRecording {
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("清除快捷键", "Clear Shortcut"))
            }
        }
        .onChange(of: isRecording) { _, recording in
            recording ? startMonitoring() : stopMonitoring()
        }
        .onDisappear(perform: stopMonitoring)
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape alone cancels rather than binding a shortcut to Escape.
            if event.keyCode == 53 {
                isRecording = false
                return nil
            }
            if let captured = Hotkey(event: event) {
                onChange(captured)
                isRecording = false
            }
            // Swallow either way: an unusable combination should not also be
            // typed into whatever is behind the window.
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
