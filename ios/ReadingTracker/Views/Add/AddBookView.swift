import SwiftUI

/// Recherche texte ou scan ISBN, puis ajout à la bibliothèque avec un statut.
struct AddBookView: View {
  @Environment(AuthService.self) private var auth
  @Environment(LibraryService.self) private var library
  @Environment(BookSearchService.self) private var search

  @State private var query = ""
  @State private var results: [BookCandidate] = []
  @State private var lastQuery: String?
  @State private var isSearching = false
  @State private var isScanning = false
  @State private var adding: String?
  @State private var errorMessage: String?
  @State private var confirmation: String?
  @State private var confirmationTask: Task<Void, Never>?
  @State private var searchTask: Task<Void, Never>?

  var body: some View {
    NavigationStack {
      List {
        ForEach(results) { candidate in
          CandidateRow(
            candidate: candidate,
            existingStatus: library.existing(for: candidate)?.status,
            isAdding: adding == candidate.id
          ) { status in
            Task { await add(candidate, status: status) }
          }
          .listSectionSeparator(.hidden, edges: .top)
        }
      }
      .listStyle(.plain)
      .overlay { overlay }
      .navigationTitle("Ajouter")
      .searchable(text: $query, prompt: "Titre, auteur ou ISBN")
      .onSubmit(of: .search) { runSearch(query) }
      .onChange(of: query) { _, value in
        if value.isEmpty {
          searchTask?.cancel()
          results = []
          lastQuery = nil
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            isScanning = true
          } label: {
            Label("Scanner", systemImage: "barcode.viewfinder")
          }
        }
      }
      .sheet(isPresented: $isScanning) {
        ISBNScannerSheet { isbn in
          isScanning = false
          query = isbn
          runSearch(isbn)
        }
      }
      .errorAlert($errorMessage)
      .overlay(alignment: .bottom) {
        if let confirmation {
          Label(confirmation, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: confirmation)
    }
  }

  @ViewBuilder
  private var overlay: some View {
    if isSearching && results.isEmpty {
      ProgressView("Recherche…")
    } else if results.isEmpty, let lastQuery {
      ContentUnavailableView.search(text: lastQuery)
    } else if results.isEmpty {
      ContentUnavailableView {
        Label("Trouve ton prochain livre", systemImage: "text.book.closed")
      } description: {
        Text("Cherche par titre, auteur ou ISBN, ou scanne le code-barres au dos du livre.")
      } actions: {
        Button {
          isScanning = true
        } label: {
          Label("Scanner un code-barres", systemImage: "barcode.viewfinder")
        }
        .buttonStyle(.glassProminent)
      }
    }
  }

  private func showConfirmation(_ message: String) {
    confirmationTask?.cancel()
    confirmation = message
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      confirmation = nil
    }
  }

  private func runSearch(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    searchTask?.cancel()
    searchTask = Task {
      isSearching = true
      defer { isSearching = false }
      do {
        let found = try await search.search(query: trimmed)
        guard !Task.isCancelled else { return }
        results = found
        lastQuery = trimmed
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = ErrorMessage.from(error)
      }
    }
  }

  private func add(_ candidate: BookCandidate, status: ReadingStatus) async {
    guard let userId = auth.userId else { return }
    adding = candidate.id
    defer { adding = nil }
    do {
      try await library.add(candidate, status: status, userId: userId)
      showConfirmation("Ajouté : \(status.singularLabel)")
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
  }
}

private struct CandidateRow: View {
  let candidate: BookCandidate
  let existingStatus: ReadingStatus?
  let isAdding: Bool
  let onAdd: (ReadingStatus) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      BookCover(url: candidate.coverURL, title: candidate.title, author: candidate.authorsLine, cornerRadius: 5)
        .frame(width: 52)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)

      VStack(alignment: .leading, spacing: 3) {
        Text(candidate.title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        if !candidate.authors.isEmpty {
          Text(candidate.authorsLine)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(details)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        if let existingStatus {
          HStack(spacing: 4) {
            Image(systemName: "checkmark")
            Text(existingStatus.singularLabel)
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(.tint)
          .padding(.top, 2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Menu {
        ForEach(ReadingStatus.allCases) { status in
          Button {
            onAdd(status)
          } label: {
            Label(status.singularLabel, systemImage: status.systemImage)
          }
          .disabled(status == existingStatus)
        }
      } label: {
        Group {
          if isAdding {
            ProgressView()
          } else {
            Image(systemName: existingStatus == nil ? "plus" : "arrow.triangle.2.circlepath")
              .font(.body.weight(.semibold))
          }
        }
        .frame(width: 22, height: 22)
      }
      .buttonStyle(.glass)
      .buttonBorderShape(.circle)
      .disabled(isAdding)
      .accessibilityLabel(existingStatus == nil ? "Ajouter" : "Changer le statut")
    }
    .padding(.vertical, 4)
  }

  private var details: String {
    [candidate.publisher, candidate.year, candidate.pageCount.map { "\($0) p." }]
      .compactMap { $0 }
      .joined(separator: " · ")
  }
}
