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
