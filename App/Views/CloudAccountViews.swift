import SwiftUI
import StoreKit

struct CloudAccountSection: View {
    @State private var account = CloudAccountModel.shared
    @State private var confirmDeletion = false
    @AppStorage(CloudProviderMode.key) private var providerMode = CloudProviderMode.personalKey.rawValue
    @AppStorage(ContextAnalysisSettings.cloudAnalysisEnabledKey) private var analysisEnabled = false
    var body: some View {
        Section {
            if let configuration = account.configuration {
                if account.signedIn {
                    LabeledContent(AppLanguage.text("Subscription"), value: AppLanguage.text(account.entitlements?.subscription_access == "active" ? "Active" : "Check subscription"))
                    if let allowance = account.entitlements?.allowance?["translations"] {
                        Text(AppLanguage.format("Available translations: %d of %d", allowance.remaining, allowance.limit))
                        Text(AppLanguage.text("Allowance resets") + ": " + Date(timeIntervalSince1970: TimeInterval(allowance.reset_at)).formatted(date: .abbreviated, time: .omitted)).font(.caption)
                    }
                    if account.entitlements?.subscription_access == "active" {
                        Button("Use subscription for translations") { providerMode = CloudProviderMode.subscription.rawValue; analysisEnabled = true }
                    }
                    if account.activationPending {
                        Text(AppLanguage.text("Your purchase is waiting for activation. Retry activation or restore purchases; do not buy again."))
                            .font(.caption).foregroundStyle(.orange)
                        Button("Retry activation") { Task { await account.retryActivation() } }
                    }
                    ForEach(account.products, id: \.id) { product in
                        Button { Task { await account.purchase(product) } } label: {
                            VStack(alignment: .leading) {
                                Text(product.displayName)
                                Text(product.description).font(.caption).foregroundStyle(.secondary)
                                Text(product.displayPrice + period(product)).font(.subheadline)
                                if let offer=account.catalog?.products.first(where: { $0.id == product.id }) {
                                    Text(AppLanguage.format("Monthly translation allowance: %d",offer.translations)).font(.caption)
                                }
                            }
                        }
                        .disabled(!account.recoveryReady || account.hasVerifiedPurchase || account.activationPending || account.entitlements?.subscription_access == "active")
                    }
                    if account.catalog?.purchases_enabled == false {
                        Text(AppLanguage.text("New subscriptions are currently unavailable. You can still restore purchases and recover existing results.")).font(.caption)
                    }
                    Button("Restore purchases") { Task { await account.restore() } }
                    Button("Refresh subscription") { Task { await account.refresh() } }
                    NavigationLink("Cloud requests") { CloudRequestsView() }
                    Link("Manage Apple subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    Button("Sign out") { Task { await account.signOut() } }
                    Button("Delete cloud account", role: .destructive) { confirmDeletion = true }
                } else {
                    Button("Sign in with Apple") { Task { await account.signIn() } }
                }
                Text(AppLanguage.text("Subscriptions provide contextual translations and word explanations. Your local library and personal API key remain separate. Payment and automatic renewal are handled by Apple until you cancel in subscription settings. Allowance resets at the start of each UTC month, including annual plans, and includes requests currently processing."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Privacy", destination: configuration.privacyURL)
                    Link("Terms", destination: configuration.termsURL)
                    Link("Support", destination: configuration.supportURL)
                }.font(.caption)
            } else {
                Text(AppLanguage.text("Cloud subscriptions are not configured in this build.")).accessibilityIdentifier("cloud.not-configured")
            }
            if account.manualRevocationRequired {
                Link("Revoke Apple sign-in manually", destination: URL(string:"https://support.apple.com/102571")!)
            }
            if let message = account.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if account.busy { ProgressView() }
        } header: { Text(AppLanguage.text("Cloud account")) }
        .disabled(account.busy)
        .task { account.start(); await account.refresh() }
        .confirmationDialog(AppLanguage.text("Delete cloud account?"), isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Delete and confirm with Apple", role: .destructive) { Task { await account.deleteAccount() } }
            Button("Delete and revoke Apple access manually", role: .destructive) { Task { await account.deleteAccount(manual:true) } }
        } message: {
            Text(AppLanguage.text("Your local books and saved dictionary stay on this device. This does not cancel your Apple subscription. Confirm with Apple to revoke sign-in consent, or delete cloud data and revoke access manually using the provided instructions."))
        }
    }
    private func period(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: AppLanguage.current)
        formatter.calendar = calendar
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = period.value; formatter.allowedUnits = .day
        case .week: components.weekOfMonth = period.value; formatter.allowedUnits = .weekOfMonth
        case .month: components.month = period.value; formatter.allowedUnits = .month
        case .year: components.year = period.value; formatter.allowedUnits = .year
        @unknown default: return ""
        }
        return formatter.string(from: components).map { " / " + $0 } ?? ""

    }
}

struct CloudRequestsView: View {
    @State private var entries: [CloudRequestLedger.Entry] = []
    @State private var selected: CloudRequestLedger.Entry?
    @State private var result: CloudRequestEnvelope?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmForget = false
    var body: some View {
        List {
            Text(AppLanguage.text("Waiting can be stopped without cancelling provider work. Refresh resumes the existing request. Results remain available for 24 hours. Starting a new request may use allowance again."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(entries) { entry in
                Button { selected = entry; Task { await resume(entry) } } label: {
                    VStack(alignment: .leading) {
                        Text(AppLanguage.text(entry.kind == "context" ? "Contextual translation" : "Word explanation"))
                        Text(entry.createdAt, style: .date).font(.caption)
                    }
                }
            }
            if let selected {
                Section {
                    if let result {
                        Text(AppLanguage.text(result.state)).font(.headline)
                        if let value = result.result {
                            if let text = value.phrase_translation { Text(text).textSelection(.enabled) }
                            if let words = value.word_explanations { Text(words.map { "\($0.source_word) — \($0.lemma) — \($0.meaning)" }.joined(separator: "\n")).textSelection(.enabled) }
                            if let definition = value.definition { Text(definition).textSelection(.enabled) }
                            if let meaning = value.meaningInContext { Text(meaning) }
                            if let examples = value.examples { ForEach(Array(examples.enumerated()), id: \.offset) { _, example in Text(example.phrase + "\n" + example.translation) } }
                        }
                        if result.state == "accepted" {
                            Button("Cancel before processing", role: .destructive) { Task { await cancel(selected) } }
                        }
                    }
                    Button("Refresh request") { Task { await resume(selected) } }
                    Button("Allow a new request", role: .destructive) { confirmForget = true }
                        .disabled(result.map { ["accepted", "running"].contains($0.state) } ?? false)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            if busy { ProgressView() }
        }
        .navigationTitle(AppLanguage.text("Cloud requests"))
        .task { await reload() }
        .confirmationDialog(AppLanguage.text("Allow a new request?"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Allow a new request", role: .destructive) { Task { await forget() } }
        } message: { Text(AppLanguage.text("The next translation of this text will be a new request and may use allowance again. Existing saved dictionary content is unchanged.")) }
    }
    private func reload() async { entries = (try? await CloudRemoteRequestClient.shared.entries()) ?? [] }
    private func resume(_ entry: CloudRequestLedger.Entry) async {
        guard !busy else { return }; busy = true; message = nil; result = nil; defer { busy = false }
        do { result = try await CloudRemoteRequestClient.shared.resume(entry) }
        catch { message = error.localizedDescription }
    }
    private func cancel(_ entry: CloudRequestLedger.Entry) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { result = try await CloudRemoteRequestClient.shared.cancel(entry) }
        catch { message = error.localizedDescription }
    }
    private func forget() async {
        guard let selected, !busy else { return }; busy = true; defer { busy = false }
        do { try await CloudRemoteRequestClient.shared.forget(selected); self.selected = nil; result = nil; await reload() }
        catch { message = error.localizedDescription }
    }
}
