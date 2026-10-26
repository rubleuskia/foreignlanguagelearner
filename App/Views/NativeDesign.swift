import SwiftUI
import UIKit

/// Shared hierarchy across library, forms and practice. System controls supply
/// Liquid Glass on iOS 26 and retain a native appearance on iOS 18.
enum NativeDesign {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let cornerRadius: CGFloat = 24
}

extension View {
    func nativePrimaryAction() -> some View { modifier(NativePrimaryAction()) }
    func nativeSecondaryAction() -> some View {
        font(.body.weight(.medium))
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }
    func nativeForm() -> some View {
        scrollContentBackground(.hidden)
            .background(NativeDesign.page)
            .navigationBarTitleDisplayMode(.inline)
    }
    func nativeFloatingSurface() -> some View { modifier(NativeFloatingSurface()) }
}

private struct NativePrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.font(.body.weight(.semibold))
                .controlSize(.large)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
        } else {
            content.font(.body.weight(.semibold))
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
    }
}

private struct NativeFloatingSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: NativeDesign.cornerRadius))
        }
    }
}

struct NativeBookCover: View {
    let item: LearningItem
    var large = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10))
            Image(systemName: item.mediaKind == "video" ? "play.rectangle" : "book.closed")
                .font(large ? .largeTitle : .title2)
                .foregroundStyle(.tint)
        }
        .frame(width: large ? 72 : 48, height: large ? 96 : 64)
        .accessibilityHidden(true)
    }
}

/// Serif typography is confined to reading; controls retain the system sans serif.
enum ReadingTypography {
    static func font(compatibleWith traits: UITraitCollection) -> UIFont {
        let descriptor = UIFont.systemFont(ofSize: 21).fontDescriptor.withDesign(.serif)
            ?? UIFont.systemFont(ofSize: 21).fontDescriptor
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(descriptor: descriptor, size: 21), compatibleWith: traits)
    }

    static func paragraph(compatibleWith traits: UITraitCollection) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let metrics = UIFontMetrics(forTextStyle: .body)
        paragraph.lineSpacing = metrics.scaledValue(for: 6, compatibleWith: traits)
        paragraph.paragraphSpacing = metrics.scaledValue(for: 14, compatibleWith: traits)
        return paragraph
    }
}

struct NativeTransportControls: View {
    let isPlaying: Bool
    let back: () -> Void
    let toggle: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 28) {
            Button(action: back) {
                Image(systemName: "gobackward.10").font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back 10 seconds")
            playButton
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button(action: forward) {
                Image(systemName: "goforward.10").font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Forward 10 seconds")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var playButton: some View {
        if #available(iOS 26.0, *) {
            Button(action: toggle) { playLabel }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
        } else {
            Button(action: toggle) { playLabel }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
        }
    }

    private var playLabel: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.title3.weight(.semibold))
            .frame(width: 40, height: 40)
    }
}
