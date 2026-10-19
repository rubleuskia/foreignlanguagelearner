import Foundation
import XCTest
@testable import ForeignLanguageLearner

/// Actual cached final Lalka track 001 alignment; no speech model runs in this test.
final class WordAudioTimingLalkaTests: XCTestCase {
    func testLalkaPhraseUsesOriginalWordTimesInsideSubtitleCue() throws {
        let text = #"""
        W początkach roku 1878, kiedy świat
        polityczny zajmował się pokojem
        """#
        let raw = TranscriptDocument(segments: [.init(start: 49.68, end: 55.44, text: text)])
        let file = try JSONDecoder().decode(WordAudioTimingFile.self, from: Data(#"""
        {"schemaVersion":1,"trackID":"001","audioSHA256":"4da233bb91b2237db4117ccba0f2bfdd77ff221f6c2ab3e8d6acfa4afbcce1cd","textSHA256":"4d1f4d825267f75b1d42906117e829b2f59741a1f3cd2088f6c7b03ff3b54229","words":[{"text":"W","start":49.68,"end":49.72},{"text":"początkach","start":49.76,"end":50.22},{"text":"roku","start":50.22,"end":50.52},{"text":"1878,","start":50.52,"end":52.8},{"text":"kiedy","start":52.8,"end":53.26},{"text":"świat","start":53.26,"end":53.62},{"text":"polityczny","start":53.62,"end":54.3},{"text":"zajmował","start":54.3,"end":54.74},{"text":"się","start":54.74,"end":54.94},{"text":"pokojem","start":55.02,"end":55.44}]}
        """#.utf8))
        let document = try file.applying(to: raw, trackID: "001", duration: 658.738639)
        let selection = (document.text as NSString).range(of: "polityczny zajmował")
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: document, duration: 658.738639), 53.62...54.74)
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: raw, duration: 658.738639), 49.68...55.44)
    }
}
