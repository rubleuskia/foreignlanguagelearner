import SwiftUI

enum ReaderTextLayout: String, CaseIterable {
    case pages
    case vertical

    var title: String {
        switch self {
        case .pages: "Book pages"
        case .vertical: "Vertical scrolling"
        }
    }
}

/// Both layouts retain the original document offsets, so changing presentation
/// can restore the same passage without changing selections or audio timing.
struct ReaderLayoutView: View {
    let reader: TranscriptTextView
    var onFollowAudio: (() -> Void)?
    @AppStorage("reader.text-layout") private var layout = ReaderTextLayout.pages.rawValue
    @State private var offset: Int?

    private var configuredReader: TranscriptTextView {
        var result = reader
        result.initialReadingOffset = offset ?? reader.initialReadingOffset
        result.onReadingOffsetChanged = { value in
            offset = value
            reader.onReadingOffsetChanged?(value)
        }
        return result
    }

    var body: some View {
        if layout == ReaderTextLayout.vertical.rawValue {
            VStack(spacing: 0) {
                configuredReader
                if let onFollowAudio, reader.document.segments.contains(where: { $0.start != nil }) {
                    Button("Follow audio", systemImage: "arrow.down.to.line", action: onFollowAudio)
                        .nativeSecondaryAction()
                        .opacity(reader.following ? 0 : 1)
                        .allowsHitTesting(!reader.following)
                        .accessibilityHidden(reader.following)
                        .frame(height: 44)
                }
            }
        } else {
            BookPagedTranscriptView(reader: configuredReader, onFollowAudio: onFollowAudio)
        }
    }
}
