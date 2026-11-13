import SwiftUI
import SwiftData

struct OperatorLibrarySettingsSection: View {
    @State private var username = "operator"
    @State private var password = ""
    @State private var signedInAs: String?
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Section("Built-in library") {
            if let signedInAs {
                Text(AppLanguage.format("Signed in as %@", signedInAs))
                Button("Sign out", role: .destructive) {
                    working = true
                    Task {
                        defer { working = false; self.signedInAs = nil }
                        do { try await OperatorSession.shared.signOut(); message = nil }
                        catch { message = error.localizedDescription }
                    }
                }
            } else {
                TextField("Library username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                SecureField("Library password", text: $password).textContentType(.password)
                Button("Sign in") {
                    let submittedPassword = password; password = ""; working = true; message = nil
                    Task {
                        defer { working = false }
                        do {
                            try await OperatorSession.shared.signIn(username: username, password: submittedPassword)
                            signedInAs = try await OperatorSession.shared.username()
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
            if working { ProgressView() }
            Text("Sign in once with your library username and password. The session renews automatically; your password is not saved.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red) }
        }.disabled(working).task {
            do { signedInAs = try await OperatorSession.shared.username() }
            catch { message = error.localizedDescription }
        }
    }
}

struct BuiltinLibraryView: View {
    private struct Archive: Identifiable { let id = UUID(); let url: URL; let book: LibraryBook }
    @Environment(\.modelContext) private var context
    @Query private var items: [LearningItem]
    @State private var service = BuiltinLibraryService()
    @State private var books: [LibraryBook] = []
    @State private var selected: LibraryBook?
    @State private var loading = false
    @State private var error: String?
    @State private var archive: Archive?
    @State private var downloadedURL: URL?
    @State private var openingBook: LearningItem?
    var body: some View {
        List {
            if loading { ProgressView("Loading catalog…") }
            if let error { Text(error).foregroundStyle(.red) }
            if !loading && books.isEmpty { Text("No books available. Check your library sign-in in Settings.") }
            ForEach(books) { book in
                HStack(alignment: .top, spacing: 14) {
                    BookCoverImage(bundledName: book.metadata.coverName ?? "cover-books")
                        .frame(width: 76, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title).font(.headline).foregroundStyle(.white)
                        if let author = book.metadata.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                        Text(metadata(book)).font(.caption).foregroundStyle(.secondary)
                        if let biography = book.metadata.biography {
                            DisclosureGroup("About the author") {
                                Text(biography).font(.caption).foregroundStyle(.secondary)
                                if let url = book.metadata.sourceURL { Link("Source", destination: url).font(.caption) }
                            }.font(.caption)
                        }
                        if let existing = BuiltinLibraryIdentity.existing(bookID: book.id, items: items) {
                            Label("Already in library", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            Button("Open book") { openingBook = existing }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("builtin.open.\(book.id)")
                        } else if selected?.id == book.id {
                            ProgressView("Downloading and verifying…")
                            Button("Cancel", role: .cancel) { selected = nil }.buttonStyle(.borderless)
                        } else {
                            Button("Download", systemImage: "arrow.down.circle") { selected = book }
                                .buttonStyle(.borderless)
                                .disabled(selected != nil || archive != nil)
                                .accessibilityIdentifier("builtin.download.\(book.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 8).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(BookLibraryDesign.background).preferredColorScheme(.dark).tint(.blue)
        .navigationDestination(item: $openingBook) { BookDetailView(item: $0) }
        .navigationTitle("Built-in library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading || selected != nil) }
        .task { await reload() }
        .task(id: selected?.id) {
            guard let book = selected else { return }
            error = nil
            do {
                let url = try await service.download(book)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                downloadedURL = url; archive = Archive(url: url, book: book); selected = nil
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self.error = error.localizedDescription; selected = nil }
            }
        }
        .sheet(item: $archive, onDismiss: {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            downloadedURL = nil
        }) { value in BookImportView(suppliedArchive: value.url, libraryBook: value.book) }
        .onDisappear { selected = nil }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting"),
               ProcessInfo.processInfo.arguments.contains("--builtin-library-fixture") {
                items.first?.builtinLibraryID = "lalka"
                books = [.init(id: "lalka", title: "Lalka", language: "pl", bytes: 600_000_000, sha256: "fixture"),
                         .init(id: "carroll-alicja-w-krainie-czarow", title: "Alicja w Krainie Czarów", language: "pl", bytes: 90_000_000, sha256: "fixture")]
                return
            }
            #endif
            books = try await service.books()
            try await BuiltinLibraryIdentity.reconcile(books: books, items: items, context: context)
        }
        catch { self.error = error.localizedDescription }
    }
    private func metadata(_ book: LibraryBook) -> String {
        var values = [SourceLanguage.name(for: book.language)]
        if let chapters = book.metadata.chapterCount { values.append(AppLanguage.format("%d chapters", chapters)) }
        values.append(ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file))
        return values.joined(separator: " · ")
    }
}
