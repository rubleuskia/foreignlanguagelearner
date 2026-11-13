import XCTest
@testable import ForeignLanguageLearner

private final class MemoryCloudCredentials: CloudCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudCredentials?
    init(_ value: CloudCredentials?) { self.value = value }
    func load() throws -> CloudCredentials? { lock.withLock { value } }
    func save(_ value: CloudCredentials?) throws { lock.withLock { self.value = value } }
}

private struct FailingCloudCredentialDeletion: CloudCredentialStoring {
    let credentials: CloudCredentials
    func load() throws -> CloudCredentials? { credentials }
    func save(_ value: CloudCredentials?) throws { throw CloudAPIError(code:"KEYCHAIN_UNAVAILABLE") }
}

private actor CloudTestHTTP: ContextAnalysisHTTPClient {
    private(set) var requests: [URLRequest] = []
    let responder: @Sendable (URLRequest) async throws -> (Data, Int)
    init(_ responder: @escaping @Sendable (URLRequest) async throws -> (Data, Int)) { self.responder = responder }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (bytes, status) = try await responder(request)
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor CloudTestGate {
    private var entered = false
    private var operation: CheckedContinuation<Void, Never>?
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true; watchers.forEach { $0.resume() }; watchers = []
        await withCheckedContinuation { operation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { watchers.append($0) }
    }
    func release() { operation?.resume(); operation = nil }
}

private actor CloudFinishCounter {
    var count = 0
    func finish() { count += 1 }
}

@MainActor
final class CloudSubscriptionTests: XCTestCase {
    private func configuration(_ environment: String = "Sandbox") throws -> CloudConfiguration {
        try CloudConfiguration(info: ["CloudAPIBaseURL":"https://api.example.invalid", "CloudCognitoDomain":"https://login.example.invalid",
            "CloudClientID":"test-client", "CloudCallbackURL":"fll://auth", "CloudEnvironment":environment,
            "CloudProducts":["monthly"], "CloudPrivacyURL":"https://example.invalid/privacy",
            "CloudTermsURL":"https://example.invalid/terms", "CloudSupportURL":"https://example.invalid/support"])
    }
    private func credentials(_ config: CloudConfiguration, expired: Bool = false) -> CloudCredentials {
        .init(scopeID: config.scopeID, userID: "alice", appAccountToken: UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,
            accessToken: "old-access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expired ? -60 : 3600))
    }
    nonisolated private static func bytes(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    nonisolated private static var entitlement: Data { bytes(["schema_version":1,"subscription_access":"active","policy_version":"cloud-v1","allowance":NSNull()]) }

    func testConfigurationDefaultsClosedAndSeparatesEnvironments() throws {
        XCTAssertThrowsError(try CloudConfiguration(info: [:]))
        XCTAssertNotEqual(try configuration().scopeID, try configuration("Production").scopeID)
        let old = UserDefaults.standard.object(forKey: CloudProviderMode.key)
        defer { UserDefaults.standard.set(old, forKey: CloudProviderMode.key) }
        UserDefaults.standard.removeObject(forKey: CloudProviderMode.key)
        XCTAssertEqual(.personalKey, CloudProviderMode.current)
    }

    func testPKCECallbackRequiresExactOriginStateAndSingleCode() throws {
        let config = try configuration(); let pkce = try CloudPKCE()
        XCTAssertEqual(43, pkce.verifier.count); XCTAssertEqual(43, pkce.challenge.count)
        XCTAssertNotEqual(pkce.verifier, pkce.challenge)
        let query = URLComponents(url: pkce.loginURL(configuration: config), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual("S256", query.first(where: { $0.name == "code_challenge_method" })?.value)
        let valid = URL(string: "fll://auth?state=\(pkce.state)&code=test%2Bcode")!
        XCTAssertEqual("test+code", try pkce.code(from: valid, configuration: config))
        for url in ["fll://other?state=\(pkce.state)&code=x", "fll://auth?state=wrong&code=x",
                    "fll://auth?state=\(pkce.state)&code=x&code=y", "fll://auth?state=\(pkce.state)&code=x#fragment"] {
            XCTAssertThrowsError(try pkce.code(from: URL(string: url)!, configuration: config))
        }
    }

    func testWrongEnvironmentCredentialsAreNeverSent() async throws {
        let config = try configuration(); let stored = MemoryCloudCredentials(credentials(config))
        let http = CloudTestHTTP { _ in XCTFail("Wrong-environment credential must never leave the device"); return (Data(),500) }
        let session = CloudSession(configuration: try configuration("Production"), store: stored, client: http)
        do { _ = try await session.send("v1/me"); XCTFail("Expected sign-in requirement") }
        catch let error as CloudAPIError { XCTAssertEqual("SIGN_IN_REQUIRED",error.code) }
        let requests = await http.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testParallelCallsShareOneRefreshAndKeepRefreshToken() async throws {
        let config = try configuration(); let stored = MemoryCloudCredentials(credentials(config, expired: true))
        let http = CloudTestHTTP { request in
            if request.url!.path == "/oauth2/token" {
                return (Self.bytes(["access_token":"new-access","expires_in":3600]),200)
            }
            return (Self.entitlement,200)
        }
        let session = CloudSession(configuration: config, store: stored, client: http)
        async let first = session.send("v1/me/entitlements")
        async let second = session.send("v1/me/entitlements")
        _ = try await (first,second)
        let requests = await http.requests
        XCTAssertEqual(1, requests.filter { $0.url?.path == "/oauth2/token" }.count)
        XCTAssertTrue(requests.filter { $0.url?.host == "api.example.invalid" }.allSatisfy {
            $0.value(forHTTPHeaderField:"Authorization") == "Bearer new-access"
        })
        XCTAssertEqual("refresh",try stored.load()?.refreshToken)
    }

    func testSignOutDuringRefreshCannotRestoreOldSession() async throws {
        let config = try configuration(); let stored = MemoryCloudCredentials(credentials(config, expired: true)); let gate = CloudTestGate()
        let http = CloudTestHTTP { request in
            if request.url!.path == "/oauth2/token" {
                await gate.wait(); return (Self.bytes(["access_token":"new-access","expires_in":3600]),200)
            }
            return (Data("{}".utf8),200)
        }
        let session = CloudSession(configuration: config, store: stored, client: http)
        let request = Task { try await session.send("v1/me") }
        await gate.waitUntilEntered(); try await session.signOut(); await gate.release()
        do { _ = try await request.value; XCTFail("Must reject stale refresh") }
        catch let error as CloudAPIError { XCTAssertEqual("ACCOUNT_CHANGED",error.code) }
        XCTAssertNil(try stored.load())
        let current = await session.current(); XCTAssertNil(current)
    }

    func testSignOutRejectsLateResultAndUnauthorizedResponseClearsSession() async throws {
        let config = try configuration(); let stored = MemoryCloudCredentials(credentials(config)); let gate = CloudTestGate()
        let http = CloudTestHTTP { request in
            if request.url?.host == "api.example.invalid" { await gate.wait(); return (Self.entitlement,200) }
            return (Data("{}".utf8),200)
        }
        let session = CloudSession(configuration: config, store: stored, client: http)
        let request = Task { try await session.send("v1/me/entitlements") }
        await gate.waitUntilEntered(); try await session.signOut(); await gate.release()
        do { _ = try await request.value; XCTFail("Must discard late result") }
        catch let error as CloudAPIError { XCTAssertEqual("ACCOUNT_CHANGED",error.code) }
        let revokedStore = MemoryCloudCredentials(credentials(config))
        let revoked = CloudSession(configuration: config, store: revokedStore, client: CloudTestHTTP { _ in
            (Self.bytes(["error":["code":"SESSION_REVOKED"]]),401)
        })
        do { _ = try await revoked.send("v1/me"); XCTFail("Must reject revoked session") }
        catch let error as CloudAPIError { XCTAssertEqual("SESSION_REVOKED",error.code) }
        XCTAssertNil(try revokedStore.load())
    }

    func testKeychainDeletionFailureStillInvalidatesMemoryAndAttemptsRevocation() async throws {
        let config=try configuration(); let saved=credentials(config); let gate=CloudTestGate()
        let http=CloudTestHTTP { request in
            if request.url?.host=="api.example.invalid" { await gate.wait(); return (Self.entitlement,200) }
            return (Data("{}".utf8),200)
        }
        let session=CloudSession(configuration:config,store:FailingCloudCredentialDeletion(credentials:saved),client:http)
        let pending=Task { try await session.send("v1/me/entitlements") }
        await gate.waitUntilEntered()
        do { try await session.signOut(); XCTFail("Must report storage failure") }
        catch let error as CloudAPIError { XCTAssertEqual("KEYCHAIN_UNAVAILABLE",error.code) }
        await gate.release()
        do { _=try await pending.value; XCTFail("Late result must not publish") }
        catch let error as CloudAPIError { XCTAssertEqual("ACCOUNT_CHANGED",error.code) }
        let current=await session.current(); XCTAssertNil(current)
        let requests=await http.requests; XCTAssertTrue(requests.contains(where:{$0.url?.path=="/oauth2/revoke"}))
    }

    func testNewAccountLoginCannotReusePreviousAccountsInFlightRefresh() async throws {
        let config=try configuration(); let store=MemoryCloudCredentials(credentials(config,expired:true)); let gate=CloudTestGate()
        let http=CloudTestHTTP { request in
            if request.url?.path == "/oauth2/token" {
                let body=String(decoding:request.httpBody ?? Data(),as:UTF8.self)
                let fields=URLComponents(string:"https://example.invalid/?"+body)?.queryItems ?? []
                let grant=fields.first(where:{$0.name=="grant_type"})?.value
                if grant=="authorization_code" {
                    return (Self.bytes(["access_token":"bob-code","refresh_token":"bob-refresh","expires_in":1]),200)
                }
                if fields.first(where:{$0.name=="refresh_token"})?.value=="bob-refresh" {
                    return (Self.bytes(["access_token":"bob-fresh","expires_in":3600]),200)
                }
                await gate.wait(); return (Self.bytes(["access_token":"alice-fresh","expires_in":3600]),200)
            }
            if request.url?.path == "/v1/me" {
                return (Self.bytes(["user_id":"bob","app_account_token":"00000000-0000-0000-0000-000000000002","apple_subject":NSNull()]),200)
            }
            return (Self.entitlement,200)
        }
        let session=CloudSession(configuration:config,store:store,client:http)
        let old=Task { try await session.send("v1/me/entitlements") }
        await gate.waitUntilEntered()
        try await session.exchange(code:"new-code",verifier:"new-verifier")
        await gate.release()
        do { _=try await old.value; XCTFail("Old account must be invalidated") }
        catch let error as CloudAPIError { XCTAssertEqual("ACCOUNT_CHANGED",error.code) }
        _=try await session.send("v1/me/entitlements")
        let current=await session.current(); XCTAssertEqual("bob",current?.userID)
        let requests=await http.requests
        XCTAssertEqual("Bearer bob-fresh",requests.last?.value(forHTTPHeaderField:"Authorization"))
    }

    func testLedgerRelaunchPreservesKeyAndUnknownOutcomeAcrossPolicyChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let lease = CloudSession.Lease(userID:"alice",generation:1,scopeID:"dev")
        let ledger = CloudRequestLedger(file: file)
        let first = try await ledger.entry(lease, fingerprint:"input",kind:"context",policyVersion:"v1")
        let relaunched = CloudRequestLedger(file: file)
        let restored = try await relaunched.entry(lease, fingerprint:"input",kind:"context",policyVersion:"v2")
        XCTAssertEqual(first.idempotencyKey,restored.idempotencyKey)
        try await relaunched.mark(restored,state:"outcome_unknown",policyVersion:"v1")
        let unknown = try await relaunched.entry(lease,fingerprint:"input",kind:"context",policyVersion:"v3")
        XCTAssertEqual(first.idempotencyKey,unknown.idempotencyKey)
        let other = try await relaunched.entry(.init(userID:"bob",generation:1,scopeID:"dev"),fingerprint:"input",kind:"context")
        XCTAssertNotEqual(first.idempotencyKey,other.idempotencyKey)
        let own = try await relaunched.list(lease); XCTAssertEqual(1,own.count)
    }

    func testKnownSuccessCacheSeparatesEffectiveServerPolicy() async throws {
        let ledger=CloudRequestLedger(file:nil); let lease=CloudSession.Lease(userID:"alice",generation:1,scopeID:"dev")
        let first=try await ledger.entry(lease,fingerprint:"input",kind:"word",policyVersion:"v1")
        try await ledger.mark(first,state:"succeeded",policyVersion:"v1")
        let same=try await ledger.entry(lease,fingerprint:"input",kind:"word",policyVersion:"v1")
        let changed=try await ledger.entry(lease,fingerprint:"input",kind:"word",policyVersion:"v2")
        XCTAssertEqual(first.idempotencyKey,same.idempotencyKey); XCTAssertNotEqual(first.idempotencyKey,changed.idempotencyKey)
    }

    func testCorruptLedgerFailsClosedBeforeCreatingAnotherRequestKey() async throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        try Data("corrupt".utf8).write(to:file)
        let ledger=CloudRequestLedger(file:file)
        do { _=try await ledger.entry(.init(userID:"alice",generation:1,scopeID:"dev"),fingerprint:"input",kind:"context"); XCTFail("Must preserve unknown intent") }
        catch { XCTAssertEqual(.persistence,error as? ContextAnalysisError) }
    }

    func testPurchaseFinishesOnlyAfterServerAcknowledgesAndRejectsForeignOrSandboxProof() async throws {
        let config=try configuration(); let saved=credentials(config); let counter=CloudFinishCounter()
        let failed=CloudSession(configuration:config,store:MemoryCloudCredentials(saved),client:CloudTestHTTP { _ in (Data(),503) })
        let proof=CloudPurchaseProof(productID:"monthly",appAccountToken:saved.appAccountToken,environment:"Sandbox",signedTransaction:"signed-test-purchase")
        do { _=try await CloudPurchaseActivation.activate(proof,configuration:config,session:failed) { await counter.finish() }; XCTFail("Outage must leave unfinished") } catch {}
        var finished=await counter.count; XCTAssertEqual(0,finished)
        let good=CloudSession(configuration:config,store:MemoryCloudCredentials(saved),client:CloudTestHTTP { _ in (Self.entitlement,200) })
        _=try await CloudPurchaseActivation.activate(proof,configuration:config,session:good) { await counter.finish() }
        finished=await counter.count; XCTAssertEqual(1,finished)
        for invalid in [CloudPurchaseProof(productID:"monthly",appAccountToken:UUID(),environment:"Sandbox",signedTransaction:"foreign"),
                        CloudPurchaseProof(productID:"monthly",appAccountToken:saved.appAccountToken,environment:"Production",signedTransaction:"wrong-environment")] {
            do { _=try await CloudPurchaseActivation.activate(invalid,configuration:config,session:good) { await counter.finish() }; XCTFail("Must reject mismatched purchase") } catch {}
        }
        finished=await counter.count; XCTAssertEqual(1,finished)
    }

    func testLostAdmissionResponseReusesKeyAfterRelaunchAndPolicyChange() async throws {
        let previous=UserDefaults.standard.object(forKey:CloudProviderMode.key)
        UserDefaults.standard.set(CloudProviderMode.subscription.rawValue,forKey:CloudProviderMode.key)
        defer { UserDefaults.standard.set(previous,forKey:CloudProviderMode.key) }
        let config=try configuration(); let saved=credentials(config); let calls=CloudFinishCounter()
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("requests.json")
        let http=CloudTestHTTP { request in
            if request.httpMethod != "POST" { return (Self.bytes(["policy_version":"cloud-v2"]),200) }
            await calls.finish()
            if await calls.count == 1 { throw URLError(.networkConnectionLost) }
            return (Self.bytes(["schema_version":1,"request_id":"request-1","state":"succeeded","policy_version":"cloud-v1","kind":"context",
                "result":["phrase_translation":"Кот","word_explanations":[["source_word":"cat","lemma":"cat","meaning":"кот"]]]]),202)
        }
        let session=CloudSession(configuration:config,store:MemoryCloudCredentials(saved),client:http)
        let input=ContextAnalysisRequest(requestID:UUID(),subject:.preview(UUID()),revision:0,selectedText:"cat",contextFragment:"cat",
            selectionLocationUTF16:0,selectionLengthUTF16:3,contextWasReduced:false,sourceLanguage:"en",targetLanguage:"ru",promptVersion:"custom-local-prompt")
        let first=BackendContextAnalysisProvider(client:CloudRemoteRequestClient(session:session,ledger:CloudRequestLedger(file:file)))
        do { _=try await first.analyze(input); XCTFail("Expected lost response") }
        catch { XCTAssertEqual(.networkUnavailable,error as? ContextAnalysisError) }
        let relaunched=BackendContextAnalysisProvider(client:CloudRemoteRequestClient(session:session,ledger:CloudRequestLedger(file:file)))
        let result=try await relaunched.analyze(input)
        XCTAssertEqual("Кот",result.directTranslation)
        let requests=await http.requests
        let posts=requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(2,posts.count)
        XCTAssertEqual(posts.first?.value(forHTTPHeaderField:"Idempotency-Key"),posts.last?.value(forHTTPHeaderField:"Idempotency-Key"))
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.example.invalid" })
    }

    func testSubscriptionFailureHasNoPersonalKeyFallback() async throws {
        let previous = UserDefaults.standard.string(forKey: CloudProviderMode.key)
        UserDefaults.standard.set(CloudProviderMode.subscription.rawValue, forKey: CloudProviderMode.key)
        defer { UserDefaults.standard.set(previous, forKey: CloudProviderMode.key) }
        let config=try configuration()
        let http=CloudTestHTTP { request in
            if request.httpMethod == "POST" { return (Self.bytes(["error":["code":"SUBSCRIPTION_REQUIRED"]]),403) }
            return (Self.bytes(["policy_version":"cloud-v1"]),200)
        }
        let session=CloudSession(configuration:config,store:MemoryCloudCredentials(credentials(config)),client:http)
        let provider=BackendWordExplanationProvider(client:CloudRemoteRequestClient(session:session,ledger:CloudRequestLedger(file:nil)))
        let input=WordExplanationInput(sourceWord:"cat",lemma:"cat",context:"cat",selectionLocationUTF16:0,selectionLengthUTF16:3,sourceLanguage:"en",targetLanguage:"ru")
        do { _=try await provider.explain(input); XCTFail("Expected subscription failure") }
        catch { XCTAssertEqual(.subscriptionRequired,error as? ContextAnalysisError) }
        let requests=await http.requests
        XCTAssertEqual(2,requests.count); XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.example.invalid" })
    }

    func testModeChangeStopsBeforePaidBackendPOST() async throws {
        let previous = UserDefaults.standard.string(forKey: CloudProviderMode.key)
        UserDefaults.standard.set(CloudProviderMode.personalKey.rawValue, forKey: CloudProviderMode.key)
        defer { UserDefaults.standard.set(previous, forKey: CloudProviderMode.key) }
        let config = try configuration()
        let http = CloudTestHTTP { request in
            XCTAssertNotEqual(request.httpMethod, "POST")
            return (Self.bytes(["policy_version": "cloud-v1"]), 200)
        }
        let session = CloudSession(configuration: config, store: MemoryCloudCredentials(credentials(config)), client: http)
        let provider = BackendWordExplanationProvider(client: CloudRemoteRequestClient(session: session, ledger: CloudRequestLedger(file: nil)))
        let input = WordExplanationInput(sourceWord: "cat", lemma: "cat", context: "cat",
            selectionLocationUTF16: 0, selectionLengthUTF16: 3, sourceLanguage: "en", targetLanguage: "ru")
        do { _ = try await provider.explain(input); XCTFail("A mode change must stop submission") }
        catch { XCTAssertEqual(error as? ContextAnalysisError, .cancelled) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSubscriptionPayloadCarriesSettingsWithoutPersonalKeyOrPrompt() throws {
        let input=WordExplanationInput(sourceWord:"cat",lemma:"cat",context:"cat",selectionLocationUTF16:0,selectionLengthUTF16:3,sourceLanguage:"en",targetLanguage:"ru")
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(CloudTranslationPayload(input, settings: .init(mode: .subscription, model: .nano, reasoningEffort: "low")))) as? [String:Any])
        XCTAssertEqual("cat",object["selected_text"] as? String)
        XCTAssertEqual(object["model"] as? String, "gpt-5-nano"); XCTAssertEqual(object["reasoning_effort"] as? String, "low"); XCTAssertNil(object["api_key"]); XCTAssertNil(object["prompt"]); XCTAssertNil(object["words_to_explain"])
    }
}
