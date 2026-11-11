#if os(macOS)
//
//  HotkeyRecorderView.swift
//  Ayna
//
//  Records a new global hotkey, warns about conflicts, and resets to the default.
//

import AppKit
import SwiftUI

struct HotkeyRecorderView: View {
    @State private var current = HotkeyCombination(string: AppPreferences.attachFromAppHotkey) ?? .default
    @State private var isRecording = false
    @State private var warning: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "Press a shortcut…" : current.displayString)
                        .font(Typography.code)
                        .frame(minWidth: 120)
                }
                .help(isRecording ? "Press the new shortcut, or Escape to cancel" : "Click to record a new shortcut")
                .accessibilityIdentifier("settings.attachFromApp.hotkeyRecorder")

                Button("Reset") {
                    apply(.default)
                }
                .disabled(current == .default && !isRecording)
                .help("Restore \(HotkeyCombination.default.displayString)")
                .accessibilityIdentifier("settings.attachFromApp.hotkeyReset")
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Theme.statusConnecting)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        warning = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let combination = HotkeyCombination(event: event)
            if combination.keyCode == 53, combination.modifiers == 0 { // Escape cancels
                stopRecording()
                return nil
            }
            guard combination.hasRequiredModifier else {
                warning = "Include ⌘, ⌃, or ⌥ so the shortcut doesn't interfere with typing."
                return nil
            }
            stopRecording()
            apply(combination)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func apply(_ combination: HotkeyCombination) {
        let previous = current
        if GlobalHotkeyService.shared.isRegistered {
            do {
                try GlobalHotkeyService.shared.replaceHotkey(with: combination, previous: previous)
            } catch {
                warning = "\(combination.displayString) couldn't be used: \(error.localizedDescription). Keeping \(previous.displayString)."
                return
            }
        }
        current = combination
        AppPreferences.attachFromAppHotkey = combination.displayString
        warning = combination.systemConflict.map {
            "\(combination.displayString) is also used by \($0); macOS may handle it first."
        }
    }
}
#endif
