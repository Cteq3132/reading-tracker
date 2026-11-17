import Foundation

/// Fiche du cache partagé `books` (lecture seule côté client).
struct Book: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  var isbn13: String?
  var isbn10: String?
  var title: String
  var subtitle: String?
  var authors: [String]
  var publisher: String?
  var publishedDate: String?
  var pageCount: Int?
  var description: String?
  var language: String?
  var coverUrl: String?
  var source: String
  var sourceId: String?

  enum CodingKeys: String, CodingKey {
    case id, isbn13, isbn10, title, subtitle, authors, publisher
    case publishedDate = "published_date"
    case pageCount = "page_count"
    case description, language
    case coverUrl = "cover_url"
    case source
    case sourceId = "source_id"
  }

  var authorsLine: String { authors.joined(separator: ", ") }
  var coverURL: URL? { coverUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
  var year: String? { publishedDate.map { String($0.prefix(4)) } }
}

/// Candidat renvoyé par l'Edge Function `search-books`, et accepté tel quel par la RPC `upsert_book`.
struct BookCandidate: Codable, Hashable, Identifiable, Sendable {
  /// Id de la fiche si elle est déjà dans `books` (renvoyé par `search-books`) : on peut alors
  /// créer le `user_books` sans passer par `upsert_book`. Lu seulement, jamais renvoyé au serveur.
  var bookId: UUID?
  var isbn13: String?
  var isbn10: String?
  var title: String
  var subtitle: String?
  var authors: [String]
  var publisher: String?
  var publishedDate: String?
  var pageCount: Int?
  var description: String?
  var language: String?
  var coverUrl: String?
  var source: String
  var sourceId: String?

  enum CodingKeys: String, CodingKey {
    case isbn13, isbn10, title, subtitle, authors, publisher
    case publishedDate = "published_date"
    case pageCount = "page_count"
    case description, language
    case coverUrl = "cover_url"
    case source
    case sourceId = "source_id"
  }

  init(
    isbn13: String? = nil, isbn10: String? = nil, title: String, subtitle: String? = nil,
    authors: [String] = [], publisher: String? = nil, publishedDate: String? = nil,
    pageCount: Int? = nil, description: String? = nil, language: String? = nil,
    coverUrl: String? = nil, source: String = "manual", sourceId: String? = nil
  ) {
    self.isbn13 = isbn13
    self.isbn10 = isbn10
    self.title = title
    self.subtitle = subtitle
    self.authors = authors
    self.publisher = publisher
    self.publishedDate = publishedDate
    self.pageCount = pageCount
    self.description = description
    self.language = language
    self.coverUrl = coverUrl
    self.source = source
    self.sourceId = sourceId
  }

  private enum ExtraKeys: String, CodingKey {
    case bookId = "book_id"
  }

  init(from decoder: Decoder) throws {
    let extra = try decoder.container(keyedBy: ExtraKeys.self)
    bookId = try? extra.decodeIfPresent(UUID.self, forKey: .bookId)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    isbn13 = try c.decodeIfPresent(String.self, forKey: .isbn13)
    isbn10 = try c.decodeIfPresent(String.self, forKey: .isbn10)
    title = try c.decode(String.self, forKey: .title)
    subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
    authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
    publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
    publishedDate = try c.decodeIfPresent(String.self, forKey: .publishedDate)
    pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    language = try c.decodeIfPresent(String.self, forKey: .language)
    coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
    source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
    sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
  }

  /// Identifiant stable pour les listes : ISBN-13 d'abord, sinon la paire source / id source.
  var id: String { isbn13 ?? "\(source):\(sourceId ?? title)" }
  var authorsLine: String { authors.joined(separator: ", ") }
  var coverURL: URL? { coverUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
  var year: String? { publishedDate.map { String($0.prefix(4)) } }
}

extension BookCandidate {
  /// Champs utiles à la page de détail encore vides (le sous-titre et l'ISBN-10 manquent souvent
  /// pour de bon, ils ne comptent pas) : une recherche par ISBN peut les compléter.
  var isMissingDetails: Bool {
    [description, publisher, publishedDate, language, coverUrl].contains { $0?.isEmpty ?? true }
      || pageCount == nil || authors.isEmpty
  }

  /// Le candidat complété par `other` (même livre, trouvé par ISBN) : seuls les champs vides
  /// sont remplis, ceux déjà connus ne bougent pas (la couverture affichée reste la même), sauf
  /// la date de parution quand `other` la précise.
  func completed(with other: BookCandidate) -> BookCandidate {
    func pick(_ current: String?, _ new: String?) -> String? {
      if let current, !current.isEmpty { return current }
      return new.flatMap { $0.isEmpty ? nil : $0 } ?? current
    }
    var merged = self
    merged.bookId = bookId ?? other.bookId
    merged.isbn10 = pick(isbn10, other.isbn10)
    merged.subtitle = pick(subtitle, other.subtitle)
    if authors.isEmpty { merged.authors = other.authors }
    merged.publisher = pick(publisher, other.publisher)
    // Une date plus précise de la même année (« 1985 » → « 1985-03-12 ») remplace la date connue.
    if let current = publishedDate, let precise = other.publishedDate,
       precise.count > current.count, precise.hasPrefix(current) {
      merged.publishedDate = precise
    } else {
      merged.publishedDate = pick(publishedDate, other.publishedDate)
    }
    merged.pageCount = pageCount ?? other.pageCount
    merged.description = pick(description, other.description)
    merged.language = pick(language, other.language)
    merged.coverUrl = pick(coverUrl, other.coverUrl)
    return merged
  }
}

struct SearchBooksResponse: Decodable, Sendable {
  let results: [BookCandidate]
}
