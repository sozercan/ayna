//
//  AynaComplicationWidget.swift
//  Ayna Watch Complication
//
//  Widget extension entry point for the watch complication.
//  This file should be added to the Widget Extension target (not the main watch app target).
//
//  To set up the Widget Extension in Xcode:
//  1. File > New > Target
//  2. Choose "Widget Extension" under watchOS
//  3. Name: "Ayna Complication"
//  4. Uncheck "Include Configuration App Intent" (using static configuration)
//  5. Add this file to the new target (remove from main watch app target)
//  6. Add AynaComplication.swift to the new target
//  7. Add WatchDataModels.swift to the new target (for WatchConversation decoding)
//  8. Set the Bundle Identifier to: com.sertacozercan.ayna.watchkitapp.complication
//  9. In the widget extension's Info.plist, ensure NSExtension > NSExtensionPointIdentifier
//     is set to "com.apple.widgetkit-extension"
//  10. Add "AYNA_COMPLICATION_EXTENSION" to the Swift Compiler - Custom Flags > Active
//      Compilation Conditions for the widget extension target
//

#if os(watchOS) && AYNA_COMPLICATION_EXTENSION

    import SwiftUI
    import WidgetKit

    @main
    struct AynaComplicationBundle: WidgetBundle {
        var body: some Widget {
            AynaComplication()
        }
    }

#endif
