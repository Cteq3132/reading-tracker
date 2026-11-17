import Foundation
import Observation
import Supabase

/// Bibliothèque (`user_books`) du compte connecté.
@MainActor
@Observable
final class LibraryService {
  private(set) var items: [UserBook] = []
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  var errorMessage: String?

  private static let selectWithBook = "*, book:books(*)"

  func items(with status: ReadingStatus) -> [UserBook] {
    items.filter { $0.status == status }
  }

  func item(id: UUID) -> UserBook? {
    items.first { $0.id == id }
  }

  /// Ligne existante pour ce candidat (même ISBN-13, ou même source).
  func existing(for candidate: BookCandidate) -> UserBook? {
    items.first { item in
      guard let book = item.book else { return false }
      if let isbn = candidate.isbn13, let other = book.isbn13 { return isbn == other }
      return book.source == candidate.source && book.sourceId != nil && book.sourceId == candidate.sourceId
    }
  }

  func load(userId: UUID) async {
    if AppConfig.isDemo {
      if !hasLoaded { items = DemoData.library }
      hasLoaded = true
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      // Filtre explicite : la RLS laisse aussi lire les bibliothèques publiques des autres.
      items = try await supabase.from("user_books")
        .select(Self.selectWithBook)
        .eq("user_id", value: userId)
        .order("updated_at", ascending: false)
        .execute()
        .value
      errorMessage = nil
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
    hasLoaded = true
  }

  /// Enregistre la fiche via `upsert_book`, puis l'ajoute à la bibliothèque (ou change son statut si elle y est déjà).
  @discardableResult
  func add(_ candidate: BookCandidate, status: ReadingStatus, userId: UUID) async throws -> UserBook {
    if let existing = existing(for: candidate) {
      var update = UserBookUpdate(existing)
      update.status = status
      return try await save(id: existing.id, update: update)
    }

    if AppConfig.isDemo {
      let book = DemoData.book(from: candidate)
      let item = UserBook(userId: userId, book: book, status: status, updatedAt: ISO8601DateFormatter().string(from: .now))
      items.insert(item, at: 0)
      return item
    }

    let bookId: UUID = try await supabase
      .rpc("upsert_book", params: ["book": candidate])
      .execute()
      .value

    let item: UserBook = try await supabase.from("user_books")
      .insert(UserBookInsert(bookId: bookId, status: status))
      .select(Self.selectWithBook)
      .single()
      .execute()
      .value
    items.insert(item, at: 0)
    return item
  }

  @discardableResult
  func save(id: UUID, update: UserBookUpdate) async throws -> UserBook {
    guard let index = items.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }

    if AppConfig.isDemo {
      var item = items[index]
      if update.status == .reading, item.startedAt == nil { item.startedAt = DemoData.day(0) }
      if update.status == .read, item.finishedAt == nil { item.finishedAt = DemoData.day(0) }
      item.status = update.status
      item.currentPage = update.currentPage
      item.rating = update.rating
      item.review = update.review
      item.isFavorite = update.isFavorite
      item.updatedAt = ISO8601DateFormatter().string(from: .now)
      items[index] = item
      return item
    }

    let item: UserBook = try await supabase.from("user_books")
      .update(update)
      .eq("id", value: id)
      .select(Self.selectWithBook)
      .single()
      .execute()
      .value
    items[index] = item
    return item
  }

  func remove(id: UUID) async throws {
    if !AppConfig.isDemo {
      try await supabase.from("user_books").delete().eq("id", value: id).execute()
    }
    items.removeAll { $0.id == id }
  }

  func reset() {
    items = []
    hasLoaded = false
    errorMessage = nil
  }

  // MARK: Statistiques du profil

  var readThisYear: Int {
    let year = String(Calendar.current.component(.year, from: .now))
    return items.filter { $0.status == .read && ($0.finishedAt ?? "").hasPrefix(year) }.count
  }

  var toReadCount: Int { items(with: .toRead).count }
  var readingCount: Int { items(with: .reading).count }
}
