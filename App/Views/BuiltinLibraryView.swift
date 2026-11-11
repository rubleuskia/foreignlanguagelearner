import SwiftUI

struct OperatorLibrarySettingsSection: View {
    @State private var token = ""
    @State private var saved = false
    @State private var message: String?
    var body: some View {
        Section("Встроенная библиотека") {
            SecureField("Access token operator Cognito", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(saved ? "Заменить токен" : "Сохранить токен") {
                do { try OperatorAccessTokenStore.save(token); token = ""; saved = true; message = nil }
                catch { message = error.localizedDescription }
            }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if saved {
                Text("Токен сохранён в Keychain").font(.caption)
                Button("Удалить токен", role: .destructive) {
                    do { try OperatorAccessTokenStore.delete(); saved = false; message = nil }
                    catch { message = error.localizedDescription }
                }
            }
            Text("Вставьте access token пользователя operator. После истечения срока действия получите новый токен и замените его здесь.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red) }
        }.onAppear {
            do { saved = try OperatorAccessTokenStore.load() != nil }
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
            if loading { ProgressView("Загрузка каталога…") }
            if let error { Text(error).foregroundStyle(.red) }
            if !loading && books.isEmpty { Text("Нет доступных книг. Проверьте токен в настройках.") }
            ForEach(books) { book in
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.headline)
                    Text("\(book.language.uppercased()) · \(ByteCountFormatter.string(fromByteCount: book.bytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    if selected?.id == book.id {
                        ProgressView("Скачивание и проверка…")
                        Button("Отменить", role: .cancel) { selected = nil }
                    } else {
                        Button("Скачать", systemImage: "arrow.down.circle") { selected = book }
                            .disabled(selected != nil)
                    }
                }
            }
        }
        .navigationTitle("Встроенная библиотека")
        .toolbar { Button("Обновить", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(loading || selected != nil) }
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
