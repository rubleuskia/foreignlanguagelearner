import SwiftUI
import UIKit

struct CopyButton: View {
    let value: String
    let label: String
    let identifier: String
    @State private var confirmationToken: UUID?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            copy()
        } label: {
            Label(label, systemImage: confirmationToken == nil ? "doc.on.doc" : "checkmark")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityValue(confirmationToken == nil ? "" : "Copied")
        .accessibilityIdentifier(identifier)
        .help(label)
        .onDisappear {
            resetTask?.cancel()
            confirmationToken = nil
        }
    }

    private func copy() {
        UIPasteboard.general.string = value
        UIAccessibility.post(notification: .announcement, argument: "Copied")
        let token = UUID()
        confirmationToken = token
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, confirmationToken == token else { return }
            withAnimation { confirmationToken = nil }
        }
    }
}

/// Keep copy actions inside the content row so Form cannot split them into separate rows.
struct CopyableContentRow<Content: View>: View {
    let value: String
    let label: String
    let identifier: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(value: value, label: label, identifier: identifier)
        }
    }
}

struct PlaybackRateMenu: View {
    let playback: PlaybackController

    var body: some View {
        Menu {
            ForEach(PlaybackRate.allCases) { rate in
                Button {
                    playback.setRate(rate)
                } label: {
                    if playback.selectedRate == rate {
                        Label(rate.title, systemImage: "checkmark")
                    } else {
                        Text(rate.title)
                    }
                }
            }
        } label: {
            Label(playback.selectedRate.title, systemImage: "speedometer")
                .frame(minHeight: 44)
        }
        .accessibilityLabel("Playback speed, \(playback.selectedRate.title)")
    }
}
