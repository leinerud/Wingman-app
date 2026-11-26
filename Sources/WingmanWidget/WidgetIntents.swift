import AppIntents
import WidgetKit

/// Pins or unpins a session straight from the desktop widget.
struct TogglePinIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin session"
    static let isDiscoverable = false

    @Parameter(title: "Session") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        // Update the widget's own copy right away, then leave a note for the app to make it permanent.
        WidgetSnapshot.togglePinInSnapshot(sessionID)
        WidgetActions.enqueueTogglePin(sessionID)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
        return .result()
    }
}
