import AuthenticationServices
import Foundation
import Observation
import StoreKit
import UIKit

@MainActor
final class CloudLoginFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    func signIn(configuration: CloudConfiguration) async throws -> (code: String, verifier: String) {
        guard webSession == nil else { throw ContextAnalysisError.busy }
        let pkce = try CloudPKCE()
        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: pkce.loginURL(configuration: configuration), callbackURLScheme: configuration.callbackURL.scheme) { [weak self] url, error in
                Task { @MainActor in
                    self?.webSession = nil
                    guard error == nil, let url else { continuation.resume(throwing: CancellationError()); return }
                    do { continuation.resume(returning: try pkce.code(from: url, configuration: configuration)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true
            webSession = session
            if !session.start() { webSession = nil; continuation.resume(throwing: CloudAPIError(code: "SIGN_IN_REQUIRED")) }
        }
        return (code, pkce.verifier)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
}

@MainActor
final class CloudAppleReauthentication: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?
    private var controller: ASAuthorizationController?
    func code() async throws -> String {
        guard continuation == nil else { throw ContextAnalysisError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self; controller.presentationContextProvider = self
            self.controller = controller; controller.performRequests()
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil; self.controller = nil }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let bytes = credential.authorizationCode, let code = String(data: bytes, encoding: .utf8) else {
            continuation?.resume(throwing: CloudAPIError(code: "SIGN_IN_REQUIRED")); return
        }
        continuation?.resume(returning: code)
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error); continuation = nil; self.controller = nil
    }
}

struct CloudEntitlements: Decodable, Sendable {
    struct Allowance: Decodable, Sendable { let limit: Int; let used: Int; let remaining: Int; let reset_at: Int }
    let schema_version: Int
    let subscription_access: String
    let policy_version: String
    let allowance: [String: Allowance]?
}

struct CloudProductCatalog: Decodable, Sendable {
    struct Offer: Decodable, Sendable, Identifiable { let id: String; let translations: Int; let alignments: Int }
    let schema_version: Int
    let products: [Offer]
    let purchases_enabled: Bool
}

struct CloudPurchaseProof: Sendable {
    let productID: String
    let appAccountToken: UUID?
    let environment: String
    let signedTransaction: String
}

enum CloudPurchaseActivation {
    static func activate(_ proof: CloudPurchaseProof, configuration: CloudConfiguration, session: CloudSession,
                         finish: @Sendable () async -> Void) async throws -> CloudEntitlements {
        guard configuration.productIDs.contains(proof.productID), proof.environment == configuration.environment else {
            throw CloudAPIError(code: "WRONG_APPLE_APPLICATION")
        }
        let lease = try await session.lease()
        guard lease.scopeID == configuration.scopeID, let account = await session.current(),
              account.appAccountToken == proof.appAccountToken else { throw CloudAPIError(code: "PURCHASE_ACCOUNT_CONFLICT") }
        let body = try JSONSerialization.data(withJSONObject: ["signed_transaction": proof.signedTransaction])
        let data = try await session.send("v1/billing/apple/sync", method: "POST", body: body, expected: lease)
        let access = try JSONDecoder().decode(CloudEntitlements.self, from: data)
        guard access.schema_version == 1 else { throw ContextAnalysisError.invalidOutput }
        try await session.validate(lease)
        await finish()
        try await session.validate(lease)
        return access
    }
}

@MainActor @Observable
final class CloudAccountModel {
    static let shared = CloudAccountModel()
    private(set) var signedIn = false
    private(set) var products: [Product] = []
    private(set) var catalog: CloudProductCatalog?
    private(set) var entitlements: CloudEntitlements?
    private(set) var busy = false
    private(set) var activationPending = false
    private(set) var recoveryReady = false
    private(set) var hasVerifiedPurchase = false
    private(set) var manualRevocationRequired = false
    private var identityUpdates: Task<Void,Never>?
    var message: String?
    private let session = CloudSession.shared
    private let login = CloudLoginFlow()
    private let reauthentication = CloudAppleReauthentication()
    private var updates: Task<Void, Never>?
    private var processing: Set<UInt64> = []
    var configuration: CloudConfiguration? { .bundled }

    func start() {
        guard configuration != nil, updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do { try await self.activate(update) }
                catch { self.activationPending = true; self.message = self.userMessage(error) }
            }
        }
        identityUpdates = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ASAuthorizationAppleIDProvider.credentialRevokedNotification) {
                await self?.checkIdentity()
            }
        }
        Task { await checkIdentity(); await refresh(); await recoverPurchases() }
    }
    func refresh() async {
        guard let configuration else { return }
        signedIn = await session.current() != nil
        do {
            if signedIn {
                let data = try await session.send("v1/me/entitlements")
                entitlements = try JSONDecoder().decode(CloudEntitlements.self, from: data)
            } else { entitlements = nil }
            if signedIn {
                let data=try await session.send("v1/products")
                let catalog=try JSONDecoder().decode(CloudProductCatalog.self,from:data)
                guard catalog.schema_version == 1 else { throw ContextAnalysisError.invalidOutput }
                self.catalog=catalog
                let offered=catalog.purchases_enabled ? catalog.products.filter { $0.translations>0 && configuration.productIDs.contains($0.id) }.map(\.id) : []
                products=offered.isEmpty ? [] : try await Product.products(for:offered).filter { $0.type == .autoRenewable }.sorted { $0.price < $1.price }
            } else { catalog=nil; products=[] }

        } catch { products=[]; catalog=nil; message = userMessage(error); signedIn = await session.current() != nil }
    }
    func signIn() async {
        guard !busy, let configuration else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            let result = try await login.signIn(configuration: configuration)
            try await session.exchange(code: result.code, verifier: result.verifier)
            await refresh()
            await recoverPurchases()
        } catch is CancellationError {} catch { message = userMessage(error) }
    }
    func signOut() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await session.signOut(); message = nil } catch { message = userMessage(error) }
        signedIn = await session.current() != nil; entitlements = nil
    }
    func purchase(_ product: Product) async {
        guard !busy, signedIn, !activationPending, !hasVerifiedPurchase, recoveryReady, catalog?.purchases_enabled == true else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            guard let account = await session.current() else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
            let lease = try await session.lease()
            let current=try await session.send("v1/products",expected:lease)
            let offered=try JSONDecoder().decode(CloudProductCatalog.self,from:current)
            guard offered.purchases_enabled, offered.products.contains(where: { $0.id == product.id && $0.translations>0 }) else {
                catalog=offered; products=[]; throw CloudAPIError(code:"PURCHASES_UNAVAILABLE")
            }
            let result = try await product.purchase(options: [.appAccountToken(account.appAccountToken)])
            try await session.validate(lease)
            switch result {
            case .success(let transaction): try await activate(transaction)
            case .pending: activationPending = true; message = CloudAPIError(code: "PURCHASE_PENDING").localizedDescription
            case .userCancelled: break
            @unknown default: throw CloudAPIError(code: "ACTIVATION_PENDING")
            }
        } catch { message = userMessage(error) }
    }
    func restore() async {
        guard !busy, signedIn else { return }; busy = true; message = nil; defer { busy = false }
        do {
            try await AppStore.sync()
            await recoverPurchases(); await refresh()
        } catch { message = userMessage(error) }
    }
    func retryActivation() async {
        guard !busy, signedIn else { return }; busy = true; defer { busy = false }
        await recoverPurchases(); await refresh()
    }
    private func recoverPurchases() async {
        defer { recoveryReady = true }
        guard await session.current() != nil else { return }
        var failed = false; var seen: Set<UInt64> = []; hasVerifiedPurchase = false
        for await transaction in Transaction.currentEntitlements {
            if case .verified(let value) = transaction, configuration?.productIDs.contains(value.productID) == true {
                hasVerifiedPurchase = true; seen.insert(value.id)
            }
            do { try await activate(transaction) } catch { failed = true; message = userMessage(error) }
        }
        for await transaction in Transaction.unfinished {
            if case .verified(let value) = transaction, seen.contains(value.id) { continue }
            do { try await activate(transaction) } catch { failed = true; message = userMessage(error) }
        }
        activationPending = failed
    }
    private func activate(_ verification: VerificationResult<Transaction>) async throws {
        guard case .verified(let transaction) = verification else { throw CloudAPIError(code: "UNVERIFIED_PURCHASE") }
        guard let configuration, configuration.productIDs.contains(transaction.productID) else { return }
        if transaction.revocationDate == nil, let expiry = transaction.expirationDate, expiry > Date() { hasVerifiedPurchase = true }
        guard !processing.contains(transaction.id) else { return }
        processing.insert(transaction.id); defer { processing.remove(transaction.id) }
        activationPending = true
        guard let account = await session.current() else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
        guard transaction.appAccountToken == account.appAccountToken else { throw CloudAPIError(code: "PURCHASE_ACCOUNT_CONFLICT") }
        let environment = transaction.environment == .production ? "Production" : transaction.environment == .sandbox ? "Sandbox" : "Xcode"
        guard environment == configuration.environment else { throw CloudAPIError(code: "WRONG_APPLE_APPLICATION") }
        do {
            let proof = CloudPurchaseProof(productID: transaction.productID, appAccountToken: transaction.appAccountToken,
                environment: environment, signedTransaction: verification.jwsRepresentation)
            let access = try await CloudPurchaseActivation.activate(proof, configuration: configuration, session: session) {
                await transaction.finish()
            }
            entitlements = access; activationPending = false; message = nil
        } catch { activationPending = true; throw error }
    }

    func checkIdentity() async {
        guard let subject = await session.current()?.appleSubject else { return }
        do {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: subject)
            if state != .authorized {
                try? await session.signOut(); signedIn = false; entitlements = nil
                message = CloudAPIError(code: "SIGN_IN_REQUIRED").localizedDescription
            }
        } catch { /* A transient state-check failure does not grant server access; API authorization still applies. */ }
    }
    func deleteAccount(manual: Bool = false) async {
        guard !busy, signedIn else { return }; busy = true; message = nil; defer { busy = false }
        do {
            let lease = try await session.lease()
            let body: Data
            if manual { body = try JSONSerialization.data(withJSONObject: ["manual_revocation":true]) }
            else {
                let code = try await reauthentication.code()
                try await session.validate(lease)
                body = try JSONSerialization.data(withJSONObject: ["authorization_code":code])
            }
            let data = try await session.send("v1/me", method: "DELETE", body: body, expected: lease)
            struct Deletion: Decodable { let deleted: Bool; let apple_revocation: String }
            let deletion = try JSONDecoder().decode(Deletion.self,from:data)
            guard deletion.deleted else { throw CloudAPIError(code:"SERVICE_UNAVAILABLE") }
            manualRevocationRequired = deletion.apple_revocation != "revoked"
            try? await session.signOut(); signedIn = false; entitlements = nil
            message = manualRevocationRequired ? AppLanguage.text("Your cloud account was deleted. Use the Apple instructions below to revoke sign-in access manually.") : nil
        } catch { message = userMessage(error) }
    }
    private func userMessage(_ error: Error) -> String {
        if let error = error as? CloudAPIError { return error.localizedDescription }
        if let error = error as? ContextAnalysisError { return AppLanguage.text(error.userMessage) }
        return AppLanguage.text("The cloud service is temporarily unavailable. Try again later.")
    }
}
