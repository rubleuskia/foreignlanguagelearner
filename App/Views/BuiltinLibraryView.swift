import SwiftUI

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
    private struct Archive: Identifiable { let id = UUID(); let url: URL }
    @State private var service = BuiltinLibraryService()
    @State private var books: [LibraryBook] = []
    @State private var selected: LibraryBook?
    @State private var loading = false
    @State private var error: String?
    @State private var archive: Archive?
    @State private var downloadedURL: URL?
    var body: some View {
        List {
            if loading { ProgressView("Loading catalog…") }
            if let error { Text(error).foregroundStyle(.red) }
            if !loading && books.isEmpty { Text("No books available. Check your library sign-in in Settings.") }
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.headline)
                    Text("\(book.language.uppercased()) · \(ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    if selected?.id == book.id {
                        ProgressView("Downloading and verifying…")
                        Button("Cancel", role: .cancel) { selected = nil }
                    } else {
                        Button("Download", systemImage: "arrow.down.circle") { selected = book }
                            .disabled(selected != nil)
                    }
                }
            }
        }
        .navigationTitle("Built-in library")
        .toolbar { Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading || selected != nil) }
        .task { await reload() }
        .task(id: selected?.id) {
            guard let book = selected else { return }
            error = nil
            do {
                let url = try await service.download(book)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                downloadedURL = url; archive = Archive(url: url); selected = nil
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self.error = error.localizedDescription; selected = nil }
            }
        }
        .sheet(item: $archive, onDismiss: {
            if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
            downloadedURL = nil
        }) { value in BookImportView(suppliedArchive: value.url) }
        .onDisappear { selected = nil }
    }
    private func reload() async {
        loading = true; error = nil
        defer { loading = false }
        do { books = try await service.books() }
        catch { self.error = error.localizedDescription }
    }
}
