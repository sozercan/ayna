//
//  NotchPositioningService.swift
//  ayna
//
//  Created on 11/12/25.
//

import Foundation
import AppKit

class NotchPositioningService {
    static let shared = NotchPositioningService()
    
    private init() {}
    
    // MARK: - Notch Detection
    
    /// Check if the current screen has a notch
    func hasNotch(screen: NSScreen) -> Bool {
        return screen.safeAreaInsets.top > 0
    }
    
    /// Get the first screen with a notch, or the main screen if none found
    func getNotchScreen() -> NSScreen {
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    
    // MARK: - Size Calculation
    
    /// Calculate the notch size (collapsed state)
    func getCollapsedNotchSize(screen: NSScreen) -> NSSize {
        if hasNotch(screen: screen) {
            // Device has a notch - use notch dimensions
            let notchHeight = screen.safeAreaInsets.top
            let notchWidth = calculateNotchWidth(screen: screen)
            // Match the actual notch size more closely
            return NSSize(width: min(notchWidth - 10, 250), height: notchHeight)
        } else {
            // Fallback for non-notch devices - small bar at menu bar center
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            return NSSize(width: 250, height: min(menuBarHeight, 40))
        }
    }
    
    /// Calculate the expanded notch size
    func getExpandedNotchSize(screen: NSScreen) -> NSSize {
        return NSSize(width: 640, height: 400)
    }
    
    /// Calculate notch width using auxiliary areas
    private func calculateNotchWidth(screen: NSScreen) -> CGFloat {
        // Get the space on either side of the notch
        let topLeftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let topRightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        
        // Calculate notch width: screen width minus the two side areas, plus small overlap
        let notchWidth = screen.frame.width - topLeftWidth - topRightWidth + 4
        
        return notchWidth
    }
    
    // MARK: - Positioning
    
    /// Get the position for the notch window (centered at notch or menu bar)
    func getNotchWindowPosition(screen: NSScreen, windowSize: NSSize) -> NSPoint {
        let screenFrame = screen.frame
        
        // Center horizontally at the exact center of the screen
        let x = screenFrame.origin.x + (screenFrame.width / 2) - (windowSize.width / 2)
        
        // Position at the very top of screen (y origin is at bottom in macOS coordinates)
        let y = screenFrame.origin.y + screenFrame.height - windowSize.height
        
        return NSPoint(x: x, y: y)
    }
    
    // MARK: - Screen Change Notifications
    
    /// Setup observer for screen configuration changes
    func observeScreenChanges(callback: @escaping () -> Void) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("🖥️ Screen configuration changed")
            callback()
        }
    }
}
