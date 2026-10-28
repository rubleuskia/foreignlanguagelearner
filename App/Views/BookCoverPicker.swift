import SwiftUI

struct BookCoverPicker: View {
    @Binding var selection: String
    let customData: Data?
    let archiveURL: URL?
    let choosePhoto: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 82, maximum: 130), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BookCoverService.bundled, id: \.self) { name in
                    Button { selection = name } label: {
                        BookCoverImage(bundledName: name)
                            .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selection == name ? Color.blue : .clear, lineWidth: 3) }
                            .overlay(alignment: .topTrailing) {
                                if selection == name { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(6) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguage.text(Self.label(name)))
                    .accessibilityAddTraits(selection == name ? .isSelected : [])
                    .accessibilityIdentifier("import.cover.\(name)")
                }
            }
            if let archiveURL {
                Button { selection = "archive" } label: {
                    HStack {
                        BookCoverImage(stagedURL: archiveURL).frame(width: 44, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Cover found in ZIP")
                        Spacer()
                        if selection == "archive" { Image(systemName: "checkmark.circle.fill") }
                    }
                }.accessibilityIdentifier("import.cover.archive")
            }
            if let customData {
                Button { selection = "custom" } label: {
                    HStack {
                        BookCoverImage(data: customData).frame(width: 44, height: 52).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Uploaded cover")
                        Spacer()
                        if selection == "custom" { Image(systemName: "checkmark.circle.fill") }
                    }
                }
            }
            Button(action: choosePhoto) { Label("Upload cover", systemImage: "photo.badge.plus") }
                .accessibilityIdentifier("import.cover.upload")
        } header: { Text("Cover") } footer: {
            Text("Built-in covers work offline. Chapters use the book cover. ZIP images named cover are detected automatically.")
        }
    }

    private static func label(_ name: String) -> String {
        switch name {
        case "cover-white": "White book"
        case "cover-leather": "Leather books"
        case "cover-dark": "Dark book"
        case "cover-ornate": "Ornate cover"
        case "cover-yellow": "Yellow book"
        default: "Books on a table"
        }
    }
}
