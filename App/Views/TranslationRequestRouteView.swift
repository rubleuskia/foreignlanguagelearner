import SwiftUI

struct TranslationRequestRouteView: View {
    let settings: TranslationRequestSettings
    var body: some View {
        Label {
            Text("\(AppLanguage.text(settings.routeTitle)) · \(settings.model.displayName) · \(settings.reasoningEffort)")
        } icon: { Image(systemName: settings.routeIcon) }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("translation.request-route")
    }
}
