import XCTest
@testable import ForeignLanguageLearner

final class PolishWiktionaryTests: XCTestCase {
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

    private func response(title: String = "dom", content: String) -> String {
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
