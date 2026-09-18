import XCTest
@testable import ForeignLanguageLearner

final class PolishWiktionaryTests: XCTestCase {
    override func tearDown() {
        PolishWiktionaryURLProtocol.handler = nil
        super.tearDown()
    }

    func testBundledSGJPDatabaseResolvesInflectedAndAmbiguousForms() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PolishLemmaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = BundledPolishLemmaResolver(destinationDirectory: directory)

        let zostal = try await resolver.lemmas(for: "został")
        let zrobilem = try await resolver.lemmas(for: "ZROBIŁEM!")
        let mam = try await resolver.lemmas(for: "mam")

        XCTAssertEqual(zostal, ["zostać"])
        XCTAssertEqual(zrobilem, ["zrobić"])
        XCTAssertEqual(Set(mam), Set(["mama", "mamić", "mieć"]))
    }

    func testClientUsesOfflineLemmaWhenInflectedPageIsMissing() async throws {
        PolishWiktionaryURLProtocol.handler = { request in
            let title = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "titles" })?.value
            if title == "został" { return Data(Self.missingResponse(title: "został").utf8) }
            let content = "== zostać ({{język polski}}) ==\n{{znaczenia}}\n''czasownik''\n: (1.1) pozostać w miejscu\n{{odmiana}}"
            return Data(Self.response(title: "zostać", content: content).utf8)
        }
        let session = URLSession(configuration: Self.stubConfiguration)
        defer { session.invalidateAndCancel() }
        let client = PolishWiktionaryClient(
            session: session,
            lemmaResolver: StubLemmaResolver(lemmas: ["zostać"])
        )

        let result = try await client.lookup("został")

        XCTAssertEqual(result.headword, "zostać")
        XCTAssertEqual(result.resolvedFromForm, "został")
        XCTAssertEqual(result.meanings.first?.definition, "pozostać w miejscu")
    }

    func testClientRequiresSelectionWhenOfflineFormHasMultipleLemmas() async throws {
        PolishWiktionaryURLProtocol.handler = { _ in Data(Self.missingResponse(title: "mam").utf8) }
        let session = URLSession(configuration: Self.stubConfiguration)
        defer { session.invalidateAndCancel() }
        let client = PolishWiktionaryClient(
            session: session,
            lemmaResolver: StubLemmaResolver(lemmas: ["mama", "mamić", "mieć"])
        )

        do {
            _ = try await client.lookup("mam")
            XCTFail("Expected an explicit lemma choice")
        } catch {
            XCTAssertEqual(error as? PolishWiktionaryError,
                           .ambiguousLemmas(["mama", "mamić", "mieć"]))
        }
    }

    func testParserExtractsOnlyPolishMeaningsAndMatchesExamples() throws {
        let data = try XCTUnwrap(fixture.data(using: .utf8))
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let result = try PolishWiktionaryParser.parse(data: data, requestedWord: "dom", fetchedAt: fetchedAt)

        XCTAssertEqual(result.headword, "dom")
        XCTAssertEqual(result.revisionID, 8845683)
        XCTAssertEqual(result.partOfSpeech, "rzeczownik, rodzaj męskorzeczowy")
        XCTAssertEqual(result.meanings.count, 2)
        XCTAssertEqual(result.meanings[0].id, "1.1")
        XCTAssertEqual(result.meanings[0].definition, "oddzielny budynek mieszkalny")
        XCTAssertEqual(result.meanings[0].usageLabels, ["architektura", "urbanistyka"])
        XCTAssertEqual(result.meanings[0].examples, ["W mieście wyrosło wiele nowych domów."])
        XCTAssertEqual(result.meanings[1].definition, "pomieszczenie lub miejsce, które kojarzymy z domem rodzinnym")
        XCTAssertEqual(result.meanings[1].examples, ["Wróciłem do domu."])
        XCTAssertFalse(result.meanings.contains(where: { $0.definition == "katedra" }))
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testParserReportsMissingPolishSection() throws {
        let source = response(content: "== dom ({{język angielski}}) ==\n{{znaczenia}}\n: (1.1) house")
        XCTAssertThrowsError(try PolishWiktionaryParser.parse(data: Data(source.utf8), requestedWord: "dom")) {
            XCTAssertEqual($0 as? PolishWiktionaryError, .noPolishEntry)
        }
    }

    func testRequestURLPreservesPolishCharactersAndRequiredOptions() throws {
        let url = try PolishWiktionaryClient.requestURL(for: "żółć")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.host, "pl.wiktionary.org")
        XCTAssertEqual(values["titles"], "żółć")
        XCTAssertEqual(values["rvslots"], "main")
        XCTAssertEqual(values["redirects"], "1")
    }

    func testParserRecognizesExplicitPolishInflectedFormReference() throws {
        let content = "== domu ({{język polski}}) ==\n{{znaczenia}}\n''{{forma rzeczownika|pl}}''\n: (1.1) {{D}}, {{Ms}} {{lp}} ''od:'' [[dom]]\n{{odmiana}}"
        let source = response(title: "domu", content: content)
        let result = try PolishWiktionaryParser.parse(data: Data(source.utf8), requestedWord: "domu")

        XCTAssertEqual(result.headword, "domu")
        XCTAssertEqual(result.formOfLemma, "dom")
    }

    private static var stubConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolishWiktionaryURLProtocol.self]
        return configuration
    }

    private static func missingResponse(title: String) -> String {
        "{\"batchcomplete\":true,\"query\":{\"pages\":[{\"ns\":0,\"title\":\"\(title)\",\"missing\":true}]}}"
    }

    private static func response(title: String = "dom", content: String) -> String {
        let encoded = try! JSONSerialization.data(withJSONObject: [
            "batchcomplete": true,
            "query": ["pages": [[
                "pageid": 1,
                "title": title,
                "revisions": [["revid": 1, "slots": ["main": ["content": content]]]]
            ]]]
        ])
        return String(decoding: encoded, as: UTF8.self)
    }

    private func response(title: String = "dom", content: String) -> String {
        Self.response(title: title, content: content)
    }

    private let fixture = #"""
    {
      "batchcomplete": true,
      "query": {
        "pages": [{
          "pageid": 67,
          "title": "dom",
          "revisions": [{
            "revid": 8845683,
            "slots": {"main": {"content": "== dom ({{język polski}}) ==\n{{wymowa}}\n{{znaczenia}}\n''rzeczownik, rodzaj męskorzeczowy''\n: (1.1) {{archit}} {{urb}} [[oddzielny]] [[budynek]] [[mieszkalny]]\n: (1.2) [[pomieszczenie]] [[lub]] [[miejsce]], [[który|które]] [[kojarzyć|kojarzymy]] [[z]] [[dom rodziny|domem rodzinnym]]\n{{odmiana}}\n{{przykłady}}\n: (1.1) ''[[w|W]] [[miasto|mieście]] [[wyrosnąć|wyrosło]] [[wiele]] [[nowy]]ch [[dom]]ów.''\n: (1.2) ''[[wrócić|Wróciłem]] [[do]] [[dom]]u.''\n{{składnia}}\n== dom ({{język dolnołużycki}}) ==\n{{znaczenia}}\n: (1.1) [[katedra]]"}}
          }]
        }]
      }
    }
    """#
}

private struct StubLemmaResolver: PolishLemmaResolving {
    let lemmas: [String]
    func lemmas(for word: String) async throws -> [String] { lemmas }
}

private final class PolishWiktionaryURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let data = try Self.handler?(request) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
