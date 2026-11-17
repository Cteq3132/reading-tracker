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
  /// Jours calendaires `yyyy-MM-dd` (voir `PostgresDate.day(from:)`).
  var startedAt: String?
  var finishedAt: String?
  var rating: Int?
  var review: String?
  var isFavorite: Bool

  init(_ userBook: UserBook) {
    status = userBook.status
    currentPage = userBook.currentPage
    startedAt = userBook.startedAt
    finishedAt = userBook.finishedAt
    rating = userBook.rating
    review = userBook.review
    isFavorite = userBook.isFavorite
  }

  enum CodingKeys: String, CodingKey {
    case status
    case currentPage = "current_page"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case rating, review
    case isFavorite = "is_favorite"
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(status, forKey: .status)
    try c.encode(currentPage, forKey: .currentPage)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(finishedAt, forKey: .finishedAt)
    try c.encode(rating, forKey: .rating)
    try c.encode(normalizedReview, forKey: .review)
    try c.encode(isFavorite, forKey: .isFavorite)
  }

  var normalizedReview: String? {
    let trimmed = review?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  /// Passe au statut `status` et propose les dates qui vont avec, à partir de la ligne enregistrée `saved` :
  /// - revenir au statut enregistré rend ses dates ;
  /// - une date masquée par le nouveau statut reprend sa valeur enregistrée ;
  /// - commencer un livre de la PAL ou en relire un déjà lu le date d'aujourd'hui, sauf date déjà modifiée ici ;
  /// - finir un livre le date d'aujourd'hui, l'ancienne date de fin d'une lecture précédente ne valant plus ;
  /// - reprendre un livre abandonné garde sa date de début.
  /// Les autres dates modifiées dans le brouillon sont gardées.
  mutating func setStatus(_ status: ReadingStatus, from saved: UserBook, today: String) {
    self.status = status
    guard status != saved.status else {
      startedAt = saved.startedAt
      finishedAt = saved.finishedAt
      return
    }
    switch status {
    case .toRead:
      startedAt = saved.startedAt
      finishedAt = saved.finishedAt
    case .reading:
      let restarts = saved.status == .toRead || saved.status == .read
      if startedAt == nil || (restarts && startedAt == saved.startedAt) { startedAt = today }
      finishedAt = saved.finishedAt
    case .read:
      if finishedAt == nil || finishedAt == saved.finishedAt { finishedAt = today }
    case .abandoned:
      finishedAt = saved.finishedAt
    }
  }

  /// La date de début est affichée pour un livre commencé.
  var showsStartDate: Bool { status != .toRead }
  /// La date de fin n'est affichée que pour un livre lu.
  var showsFinishDate: Bool { status == .read }
  /// Un livre en cours a toujours une date de début, un livre lu une date de fin : le trigger du backend
  /// remettrait la date du jour dans une date vidée. Les autres dates affichées peuvent être effacées.
  var canClearStartDate: Bool { status != .reading }
  var canClearFinishDate: Bool { status != .read }

  /// Message à afficher si les dates affichées sont incohérentes (dans le futur, ou fin avant début).
  /// Les jours `yyyy-MM-dd` se comparent dans l'ordre alphabétique.
  func dateProblem(today: String) -> String? {
    let started = showsStartDate ? startedAt : nil
    let finished = showsFinishDate ? finishedAt : nil
    if let started, started > today { return "La date de début ne peut pas être dans le futur." }
    if let finished, finished > today { return "La date de fin ne peut pas être dans le futur." }
    if let started, let finished, finished < started {
      return "La date de fin ne peut pas précéder la date de début."
    }
    return nil
  }
}

extension UserBook {
  /// Applique `update` localement, comme le ferait le backend (y compris son trigger de dates) :
  /// sert à la mise à jour optimiste et au mode démo.
  func applying(_ update: UserBookUpdate, today: String) -> UserBook {
    var item = self
    item.status = update.status
    item.currentPage = update.currentPage
    item.startedAt = update.startedAt
    item.finishedAt = update.finishedAt
    if item.status == .reading, item.startedAt == nil { item.startedAt = today }
    if item.status == .read, item.finishedAt == nil { item.finishedAt = today }
    item.rating = update.rating
    item.review = update.normalizedReview
    item.isFavorite = update.isFavorite
    item.updatedAt = ISO8601DateFormatter().string(from: .now)
    return item
  }
}

/// Ajout à la bibliothèque. Les dates du jour sont calculées dans le fuseau local : laissées vides,
/// le trigger du backend poserait `current_date`, qui est le jour UTC.
struct UserBookInsert: Encodable, Sendable {
  let bookId: UUID
  let status: ReadingStatus
  var startedAt: String?
  var finishedAt: String?

  init(bookId: UUID, status: ReadingStatus, today: String) {
    self.bookId = bookId
    self.status = status
    startedAt = status == .reading ? today : nil
    finishedAt = status == .read ? today : nil
  }

  enum CodingKeys: String, CodingKey {
    case bookId = "book_id"
    case status
    case startedAt = "started_at"
    case finishedAt = "finished_at"
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(bookId, forKey: .bookId)
    try c.encode(status, forKey: .status)
    try c.encodeIfPresent(startedAt, forKey: .startedAt)
    try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
  }
}
