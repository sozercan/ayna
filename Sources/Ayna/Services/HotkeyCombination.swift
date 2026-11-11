//
//  HotkeyCombination.swift
//  Ayna
//
//  A global hotkey as a key code plus Carbon modifiers, with its display string.
//

#if os(macOS)
    import AppKit
    import Carbon.HIToolbox

    struct HotkeyCombination: Equatable, Sendable {
        let keyCode: UInt32
        /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
        let modifiers: UInt32

        static let `default` = HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))

        /// Modifier symbols in the order macOS shows them.
        private static let modifierSymbols: [(mask: Int, symbol: String)] = [
            (controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")
        ]

        private static let keyNames: [UInt32: String] = {
            var names: [Int: String] = [
                kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Escape",
                kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete",
                kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
                kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
                kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
                kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`"
            ]
            let letters: [Int] = [
                kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z
            ]
            for (index, code) in letters.enumerated() {
                names[code] = String(UnicodeScalar(UInt8(65 + index)))
            }
            let digits: [Int] = [
                kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
            ]
            for (index, code) in digits.enumerated() {
                names[code] = "\(index)"
            }
            let functionKeys: [Int] = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
            ]
            for (index, code) in functionKeys.enumerated() {
                names[code] = "F\(index + 1)"
            }
            return Dictionary(uniqueKeysWithValues: names.map { (UInt32($0.key), $0.value) })
        }()

        /// System shortcuts that win over an app hotkey, so registering one silently does nothing.
        private static let systemShortcuts: [HotkeyCombination: String] = [
            HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)): "Spotlight",
            HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)): "Finder search",
            HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)): "input source switching",
            HotkeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | cmdKey)): "the emoji viewer",
            HotkeyCombination(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)): "the app switcher",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)): "screenshots",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)): "screenshots",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)): "screenshots",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)): "Quit",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)): "Close Window",
            HotkeyCombination(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey | cmdKey)): "Lock Screen"
        ]

        var keyName: String? {
            Self.keyNames[keyCode]
        }

        var displayString: String {
            let symbols = Self.modifierSymbols.filter { modifiers & UInt32($0.mask) != 0 }.map(\.symbol).joined()
            return symbols + (keyName ?? "Key \(keyCode)")
        }

        /// A global hotkey needs ⌘, ⌃, or ⌥; Shift alone would swallow ordinary typing.
        var hasRequiredModifier: Bool {
            modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        }

        /// The system feature that already uses this shortcut, if any.
        var systemConflict: String? {
            Self.systemShortcuts[self]
        }

        /// Parses strings like "⌘⇧Space", "⌃⌥K", or the older "cmd+shift+space".
        init?(string: String) {
            var modifiers: UInt32 = 0
            var remainder = string
            for (mask, symbol) in Self.modifierSymbols where remainder.contains(symbol) {
                modifiers |= UInt32(mask)
                remainder = remainder.replacingOccurrences(of: symbol, with: "")
            }
            var keyPart = ""
            for part in remainder.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                switch part {
                case "cmd", "command": modifiers |= UInt32(cmdKey)
                case "shift": modifiers |= UInt32(shiftKey)
                case "opt", "option", "alt": modifiers |= UInt32(optionKey)
                case "ctrl", "control": modifiers |= UInt32(controlKey)
                default: keyPart = part
                }
            }
            let aliases = ["enter": "return", "esc": "escape"]
            let target = aliases[keyPart] ?? keyPart
            guard let keyCode = Self.keyNames.first(where: { $0.value.lowercased() == target })?.key else {
                return nil
            }
            self.init(keyCode: keyCode, modifiers: modifiers)
        }

        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// The combination a key-down event represents.
        init(event: NSEvent) {
            var modifiers: UInt32 = 0
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        }
    }

    extension HotkeyCombination: Hashable {}
#endif
