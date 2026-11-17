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

  init(from decoder: Decoder) throws {
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

struct SearchBooksResponse: Decodable, Sendable {
  let results: [BookCandidate]
}
