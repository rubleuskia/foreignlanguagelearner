import SwiftUI
import UIKit

struct CopyButton: View {
    let value: String
    let label: String
    let identifier: String
    @State private var confirmationToken: UUID?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                copy()
            } label: {
                Label(label, systemImage: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            if confirmationToken != nil {
                Text("Copied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Copied")
                    .transition(.opacity)
            }
        }
        .onDisappear { resetTask?.cancel() }
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
