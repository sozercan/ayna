//
//  NotchWindow.swift
//  ayna
//
//  Created on 11/12/25.
//

import AppKit
import SwiftUI

class NotchWindow: NSPanel {
    var allowKeyWindow = false
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Window appearance
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        hasShadow = false
        
        // Collection behaviors - critical for notch integration
        collectionBehavior = [
            .fullScreenAuxiliary,  // Appears above full-screen apps
            .stationary,           // Doesn't participate in Mission Control
            .canJoinAllSpaces,     // Visible on all Spaces/Desktops
            .ignoresCycle,         // Excluded from window cycling (Cmd+Tab)
        ]
        
        // Set window level above menu bar
        level = .mainMenu + 3
        
        print("🔌 NotchWindow initialized at level: \(level.rawValue)")
    }
    
    // Prevent window from becoming key (stealing focus) unless explicitly allowed
    override var canBecomeKey: Bool {
        return allowKeyWindow
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    // Allow temporary key window for text input
    func enableKeyWindow() {
        print("🔑 Enabling key window for input")
        allowKeyWindow = true
        makeKey()
    }
    
    func disableKeyWindow() {
        print("🔓 Disabling key window")
        allowKeyWindow = false
        resignKey()
    }
}
