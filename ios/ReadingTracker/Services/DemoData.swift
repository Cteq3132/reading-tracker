import Foundation

/// Données d'exemple du mode démo (`-demo`, Debug uniquement) : permettent de vérifier le rendu sans backend.
enum DemoData {
  static let me = Profile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    username: "louis", displayName: "Louis"
  )

  static func day(_ daysAgo: Int) -> String {
    let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f.string(from: date)
  }

  static func timestamp(hoursAgo: Double) -> String {
    ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-hoursAgo * 3600))
  }

  private static func cover(_ isbn: String) -> String {
    "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false"
  }

  static let candidates: [BookCandidate] = [
    BookCandidate(isbn13: "9782070360024", isbn10: "2070360024", title: "L'Étranger", authors: ["Albert Camus"],
                  publisher: "Gallimard", publishedDate: "1972", pageCount: 191, language: "fr",
                  coverUrl: cover("9782070360024"), source: "bnf", sourceId: "ark:/12148/cb35224436w"),
    BookCandidate(isbn13: "9782070360420", title: "La Peste", authors: ["Albert Camus"], publisher: "Gallimard",
                  publishedDate: "1972", pageCount: 352, language: "fr", coverUrl: cover("9782070360420"), source: "bnf"),
    BookCandidate(isbn13: "9782070612758", title: "Le Petit Prince", authors: ["Antoine de Saint-Exupéry"],
                  publisher: "Gallimard Jeunesse", publishedDate: "2007", pageCount: 96, language: "fr",
                  coverUrl: cover("9782070612758"), source: "openlibrary"),
    BookCandidate(isbn13: "9782266320481", title: "Dune", subtitle: "Tome 1", authors: ["Frank Herbert"],
                  publisher: "Pocket", publishedDate: "2021", pageCount: 928, language: "fr",
                  coverUrl: cover("9782266320481"), source: "openlibrary"),
    BookCandidate(isbn13: "9782070368228", title: "1984", authors: ["George Orwell"], publisher: "Gallimard",
                  publishedDate: "1972", pageCount: 438, language: "fr", coverUrl: cover("9782070368228"), source: "bnf"),
    BookCandidate(isbn13: "9782253096337", title: "Les Misérables", subtitle: "Tome 1", authors: ["Victor Hugo"],
                  publisher: "Le Livre de Poche", publishedDate: "1998", pageCount: 960, language: "fr",
                  coverUrl: nil, source: "bnf"),
    BookCandidate(isbn13: "9782070413119", title: "Madame Bovary", authors: ["Gustave Flaubert"],
                  publisher: "Gallimard", publishedDate: "2001", pageCount: 512, language: "fr",
                  coverUrl: cover("9782070413119"), source: "bnf"),
    BookCandidate(isbn13: "9782226257017", title: "Sapiens", subtitle: "Une brève histoire de l'humanité",
                  authors: ["Yuval Noah Harari"], publisher: "Albin Michel", publishedDate: "2015", pageCount: 501,
                  language: "fr", coverUrl: nil, source: "google"),
    BookCandidate(isbn13: "9782072958632", title: "Le Mage du Kremlin", authors: ["Giuliano da Empoli"],
                  publisher: "Gallimard", publishedDate: "2022", pageCount: 288, language: "fr",
                  coverUrl: nil, source: "bnf"),
    BookCandidate(isbn13: "9782070409341", title: "L'Homme révolté", authors: ["Albert Camus"],
                  publisher: "Gallimard", publishedDate: "1985", pageCount: 384, language: "fr",
                  coverUrl: nil, source: "bnf"),
  ]

  static func book(from candidate: BookCandidate) -> Book {
    Book(
      id: UUID(), isbn13: candidate.isbn13, isbn10: candidate.isbn10, title: candidate.title,
      subtitle: candidate.subtitle, authors: candidate.authors, publisher: candidate.publisher,
      publishedDate: candidate.publishedDate, pageCount: candidate.pageCount, description: candidate.description,
      language: candidate.language, coverUrl: candidate.coverUrl, source: candidate.source, sourceId: candidate.sourceId
    )
  }

  private static func book(_ title: String) -> Book {
    book(from: candidates.first { $0.title == title }!)
  }

  static let library: [UserBook] = [
    UserBook(userId: me.id, book: book("La Peste"), status: .reading, currentPage: 124, startedAt: day(9),
             updatedAt: timestamp(hoursAgo: 3)),
    UserBook(userId: me.id, book: book("Dune"), status: .reading, currentPage: 612, startedAt: day(30),
             isFavorite: true, updatedAt: timestamp(hoursAgo: 26)),
    UserBook(userId: me.id, book: book("Le Mage du Kremlin"), status: .reading, currentPage: 40, startedAt: day(2),
             updatedAt: timestamp(hoursAgo: 50)),
    UserBook(userId: me.id, book: book("1984"), status: .toRead, updatedAt: timestamp(hoursAgo: 80)),
    UserBook(userId: me.id, book: book("Les Misérables"), status: .toRead, updatedAt: timestamp(hoursAgo: 100)),
    UserBook(userId: me.id, book: book("Sapiens"), status: .toRead, updatedAt: timestamp(hoursAgo: 120)),
    UserBook(userId: me.id, book: book("L'Étranger"), status: .read, startedAt: day(60), finishedAt: day(45),
             rating: 5, review: "Une écriture sèche et lumineuse. À relire.", isFavorite: true,
             updatedAt: timestamp(hoursAgo: 200)),
    UserBook(userId: me.id, book: book("Le Petit Prince"), status: .read, finishedAt: day(20), rating: 4,
             updatedAt: timestamp(hoursAgo: 300)),
    UserBook(userId: me.id, book: book("Madame Bovary"), status: .abandoned, currentPage: 140,
             updatedAt: timestamp(hoursAgo: 400)),
  ]

  static let lea = Profile(username: "lea_lit", displayName: "Léa Martin")
  static let tom = Profile(username: "tom", displayName: "Tom Durand")
  static let nina = Profile(username: "nina_b", displayName: "Nina B.")
  static let camille = Profile(username: "camille_r", displayName: "Camille Roux", isPrivate: true)
  static let hugo = Profile(username: "hugo_lecteur", displayName: "Hugo", isPrivate: true)

  static let profiles: [Profile] = [lea, tom, nina, camille, hugo]

  static let outgoing: [UUID: FollowStatus] = [lea.id: .accepted, tom.id: .accepted, nina.id: .accepted, hugo.id: .pending]

  static let incoming: [FollowRequest] = [
    FollowRequest(follow: Follow(followerId: camille.id, followingId: me.id, status: .pending), profile: camille),
  ]

  static let activity: [FriendActivity] = [
    FriendActivity(userId: lea.id, username: lea.username, displayName: lea.displayName, title: "L'Étranger",
                   authors: ["Albert Camus"], coverUrl: cover("9782070360024"), status: .read, pageCount: 191,
                   rating: 4, updatedAt: timestamp(hoursAgo: 0.5)),
    FriendActivity(userId: tom.id, username: tom.username, displayName: tom.displayName, title: "Dune",
                   authors: ["Frank Herbert"], coverUrl: cover("9782266320481"), status: .reading, currentPage: 230,
                   pageCount: 928, updatedAt: timestamp(hoursAgo: 4)),
    FriendActivity(userId: nina.id, username: nina.username, displayName: nina.displayName, title: "Sapiens",
                   authors: ["Yuval Noah Harari"], coverUrl: nil, status: .toRead, pageCount: 501,
                   updatedAt: timestamp(hoursAgo: 20)),
    FriendActivity(userId: lea.id, username: lea.username, displayName: lea.displayName, title: "Madame Bovary",
                   authors: ["Gustave Flaubert"], coverUrl: cover("9782070413119"), status: .abandoned,
                   currentPage: 88, pageCount: 512, updatedAt: timestamp(hoursAgo: 52)),
    FriendActivity(userId: tom.id, username: tom.username, displayName: tom.displayName, title: "Le Petit Prince",
                   authors: ["Antoine de Saint-Exupéry"], coverUrl: cover("9782070612758"), status: .read,
                   pageCount: 96, rating: 5, updatedAt: timestamp(hoursAgo: 120)),
  ]

  static func search(query: String) -> [BookCandidate] {
    let q = query.lowercased().folding(options: .diacriticInsensitive, locale: .current)
    let words = q.split(separator: " ")
    return candidates.filter { c in
      let haystack = (c.title + " " + c.authorsLine).lowercased().folding(options: .diacriticInsensitive, locale: .current)
      return words.allSatisfy { haystack.contains($0) }
    }
  }

  static func search(isbn: String) -> [BookCandidate] {
    candidates.filter { $0.isbn13 == isbn || $0.isbn10 == isbn }
  }
}
