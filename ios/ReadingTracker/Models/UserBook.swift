import Foundation

enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case reading
  case toRead = "to_read"
  case read
  case abandoned

  var id: String { rawValue }

  /// Libellé court, pour le filtre de la bibliothèque.
  var label: String {
    switch self {
    case .reading: "En cours"
    case .toRead: "PAL"
    case .read: "Lus"
    case .abandoned: "Abandonnés"
    }
  }

  /// Libellé d'un livre dans ce statut.
  var singularLabel: String {
    switch self {
    case .reading: "En cours"
    case .toRead: "Pile à lire"
    case .read: "Lu"
    case .abandoned: "Abandonné"
    }
  }

  var systemImage: String {
    switch self {
    case .reading: "book"
    case .toRead: "books.vertical"
    case .read: "checkmark.circle"
    case .abandoned: "xmark.circle"
    }
  }
}

/// Ligne de `user_books`, avec la fiche `books` embarquée (`select("*, book:books(*)")`).
struct UserBook: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  var userId: UUID
  var bookId: UUID
  var status: ReadingStatus
  var currentPage: Int?
  var startedAt: String?
  var finishedAt: String?
  var rating: Int?
  var review: String?
  var isFavorite: Bool
  var createdAt: String?
  var updatedAt: String?
  var book: Book?

  enum CodingKeys: String, CodingKey {
    case id
    case userId = "user_id"
    case bookId = "book_id"
    case status
    case currentPage = "current_page"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case rating, review
    case isFavorite = "is_favorite"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case book
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    userId = try c.decode(UUID.self, forKey: .userId)
    bookId = try c.decode(UUID.self, forKey: .bookId)
    status = try c.decode(ReadingStatus.self, forKey: .status)
    currentPage = try c.decodeIfPresent(Int.self, forKey: .currentPage)
    startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
    finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
    rating = try c.decodeIfPresent(Int.self, forKey: .rating)
    review = try c.decodeIfPresent(String.self, forKey: .review)
    isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    book = try c.decodeIfPresent(Book.self, forKey: .book)
  }

  init(
    id: UUID = UUID(), userId: UUID, book: Book, status: ReadingStatus, currentPage: Int? = nil,
    startedAt: String? = nil, finishedAt: String? = nil, rating: Int? = nil, review: String? = nil,
    isFavorite: Bool = false, updatedAt: String? = nil
  ) {
    self.id = id
    self.userId = userId
    self.bookId = book.id
    self.book = book
    self.status = status
    self.currentPage = currentPage
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.rating = rating
    self.review = review
    self.isFavorite = isFavorite
    self.createdAt = updatedAt
    self.updatedAt = updatedAt
  }

  /// Progression entre 0 et 1, si le nombre de pages est connu.
  var progress: Double? {
    guard let total = book?.pageCount, total > 0, let page = currentPage else { return nil }
    return min(max(Double(page) / Double(total), 0), 1)
  }
}

/// Champs modifiables depuis la fiche livre. Les `nil` sont envoyés en `null` pour pouvoir effacer une valeur.
struct UserBookUpdate: Encodable, Equatable, Sendable {
  var status: ReadingStatus
  var currentPage: Int?
  var rating: Int?
  var review: String?
  var isFavorite: Bool

  init(_ userBook: UserBook) {
    status = userBook.status
    currentPage = userBook.currentPage
    rating = userBook.rating
    review = userBook.review
    isFavorite = userBook.isFavorite
  }

  enum CodingKeys: String, CodingKey {
    case status
    case currentPage = "current_page"
    case rating, review
    case isFavorite = "is_favorite"
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(status, forKey: .status)
    try c.encode(currentPage, forKey: .currentPage)
    try c.encode(rating, forKey: .rating)
    let trimmed = review?.trimmingCharacters(in: .whitespacesAndNewlines)
    try c.encode(trimmed?.isEmpty == false ? trimmed : nil, forKey: .review)
    try c.encode(isFavorite, forKey: .isFavorite)
  }
}

struct UserBookInsert: Encodable, Sendable {
  let bookId: UUID
  let status: ReadingStatus

  enum CodingKeys: String, CodingKey {
    case bookId = "book_id"
    case status
  }
}
