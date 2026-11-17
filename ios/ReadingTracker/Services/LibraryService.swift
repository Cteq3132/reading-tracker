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
      if let bookId = candidate.bookId, item.bookId == bookId { return true }
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
      update.setStatus(status, from: existing, today: PostgresDate.today())
      return try await save(id: existing.id, update: update)
    }

    if AppConfig.isDemo {
      let book = DemoData.book(from: candidate)
      let insert = UserBookInsert(bookId: book.id, status: status, today: PostgresDate.today())
      let item = UserBook(
        userId: userId, book: book, status: status, startedAt: insert.startedAt, finishedAt: insert.finishedAt,
        updatedAt: ISO8601DateFormatter().string(from: .now)
      )
      items.insert(item, at: 0)
      return item
    }

    let bookId: UUID
    if let known = candidate.bookId {
      bookId = known
    } else {
      bookId = try await supabase
        .rpc("upsert_book", params: ["book": candidate])
        .execute()
        .value
    }

    let item: UserBook = try await supabase.from("user_books")
      .insert(UserBookInsert(bookId: bookId, status: status, today: PostgresDate.today()))
      .select(Self.selectWithBook)
      .single()
      .execute()
      .value
    items.insert(item, at: 0)
    return item
  }

  /// Enregistre `update` de façon optimiste : la bibliothèque change tout de suite, et revient
  /// à l'état précédent si le backend refuse (l'erreur est relancée pour être affichée).
  @discardableResult
  func save(id: UUID, update: UserBookUpdate) async throws -> UserBook {
    guard let index = items.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
    let previous = items[index]
    let optimistic = previous.applying(update, today: PostgresDate.today())
    items[index] = optimistic

    if AppConfig.isDemo { return optimistic }

    do {
      let saved: UserBook = try await supabase.from("user_books")
        .update(update)
        .eq("id", value: id)
        .select(Self.selectWithBook)
        .single()
        .execute()
        .value
      replace(id: id, with: saved, ifStillEqualTo: optimistic)
      return saved
    } catch {
      replace(id: id, with: previous, ifStillEqualTo: optimistic)
      throw error
    }
  }

  /// Remplace la ligne, sauf si un autre enregistrement l'a modifiée entre-temps.
  private func replace(id: UUID, with item: UserBook, ifStillEqualTo expected: UserBook) {
    guard let index = items.firstIndex(where: { $0.id == id }), items[index] == expected else { return }
    items[index] = item
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

  var readThisMonth: Int {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM"
    let month = f.string(from: .now)
    return items.filter { $0.status == .read && ($0.finishedAt ?? "").hasPrefix(month) }.count
  }

  /// Lectures en cours, la plus récemment mise à jour d'abord.
  var currentlyReading: [UserBook] {
    items(with: .reading).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
  }

  var toReadCount: Int { items(with: .toRead).count }
  var readingCount: Int { items(with: .reading).count }
}
