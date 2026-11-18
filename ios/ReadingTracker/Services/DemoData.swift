import Foundation

/// Données d'exemple du mode démo (`-demo`, Debug uniquement) : permettent de vérifier le rendu sans backend.
enum DemoData {
  /// Mon profil. Le défi a démarré il y a quatre mois ; `-demo-challenge off` le laisse à démarrer,
  /// `-demo-game off` masque le jeu.
  static let me = Profile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    username: "louis", displayName: "Louis",
    gamificationEnabled: AppConfig.demoGame != "off",
    gamificationStartedAt: AppConfig.demoChallenge == "off" ? nil : iso(gameStart)
  )

  /// Démarrage du défi : le 1er du mois situé quatre mois avant le mois en cours.
  static var gameStart: Date { monthDay(1, monthsAgo: 4) }

  static func day(_ daysAgo: Int) -> String {
    PostgresDate.day(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now)
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
    BookCandidate(isbn13: "9782253004226", title: "Germinal", authors: ["Émile Zola"], publisher: "Le Livre de Poche",
                  publishedDate: "2000", pageCount: 592, language: "fr", source: "bnf", sourceId: "demo-1"),
    BookCandidate(title: "Le Rouge et le Noir", authors: ["Stendhal"], publisher: "Folio", publishedDate: "2000",
                  pageCount: 576, language: "fr", source: "bnf", sourceId: "demo-2"),
    BookCandidate(title: "Bel-Ami", authors: ["Guy de Maupassant"], publisher: "Le Livre de Poche",
                  publishedDate: "1983", pageCount: 432, language: "fr", source: "bnf", sourceId: "demo-3"),
    BookCandidate(title: "L'Écume des jours", authors: ["Boris Vian"], publisher: "Le Livre de Poche",
                  publishedDate: "1997", pageCount: 320, language: "fr", source: "bnf", sourceId: "demo-4"),
    BookCandidate(title: "La Horde du Contrevent", authors: ["Alain Damasio"], publisher: "Folio SF",
                  publishedDate: "2015", pageCount: 736, language: "fr", source: "google", sourceId: "demo-5"),
    BookCandidate(title: "Belle du Seigneur", authors: ["Albert Cohen"], publisher: "Folio", publishedDate: "1998",
                  pageCount: 1110, language: "fr", source: "bnf", sourceId: "demo-6"),
    BookCandidate(title: "Les Choses", authors: ["Georges Perec"], publisher: "J'ai lu", publishedDate: "2006",
                  pageCount: 160, language: "fr", source: "bnf", sourceId: "demo-7"),
    BookCandidate(title: "Yoga", authors: ["Emmanuel Carrère"], publisher: "P.O.L", publishedDate: "2020",
                  pageCount: 400, language: "fr", source: "google", sourceId: "demo-8"),
    BookCandidate(title: "Veiller sur elle", authors: ["Jean-Baptiste Andrea"], publisher: "L'Iconoclaste",
                  publishedDate: "2023", pageCount: 592, language: "fr", source: "google", sourceId: "demo-9"),
    BookCandidate(title: "La Vie devant soi", authors: ["Romain Gary"], publisher: "Folio", publishedDate: "1982",
                  pageCount: 274, language: "fr", source: "bnf", sourceId: "demo-10"),
    BookCandidate(title: "Da Vinci Code", authors: ["Dan Brown"], publisher: "Pocket", publishedDate: "2005",
                  pageCount: 574, language: "fr", source: "google", sourceId: "demo-11"),
    BookCandidate(isbn13: "9782070322886", title: "Le Mythe de Sisyphe", authors: ["Albert Camus"],
                  publisher: "Gallimard", publishedDate: "1985", language: "fr",
                  coverUrl: cover("9782070322886"), source: "google", sourceId: "demo-15"),
    BookCandidate(title: "La Chute", authors: ["Albert Camus"], publisher: "Folio", publishedDate: "1972",
                  pageCount: 153, language: "fr", source: "bnf", sourceId: "demo-12"),
    BookCandidate(title: "Noces suivi de L'Été", authors: ["Albert Camus"], publisher: "Folio", publishedDate: "1972",
                  pageCount: 186, language: "fr", source: "bnf", sourceId: "demo-13"),
    BookCandidate(title: "L'Alchimiste", authors: ["Paulo Coelho"], publisher: "J'ai lu", publishedDate: "2007",
                  pageCount: 192, language: "fr", source: "google", sourceId: "demo-14"),
  ]

  static func book(from candidate: BookCandidate) -> Book {
    Book(
      id: UUID(), isbn13: candidate.isbn13, isbn10: candidate.isbn10, title: candidate.title,
      subtitle: candidate.subtitle, authors: candidate.authors, publisher: candidate.publisher,
      publishedDate: candidate.publishedDate, pageCount: candidate.pageCount, description: candidate.description,
      language: candidate.language, coverUrl: candidate.coverUrl, source: candidate.source, sourceId: candidate.sourceId
    )
  }

  private static let books: [String: Book] = Dictionary(
    uniqueKeysWithValues: candidates.map { ($0.title, book(from: $0)) }
  )

  private static func book(_ title: String) -> Book { books[title]! }

  // MARK: Dates de la démo

  /// Jour `day` du mois en cours, à 10 h, jamais dans le futur : le bilan du mois reste le même
  /// quel que soit le jour où l'on lance la démo.
  private static func thisMonth(_ day: Int) -> Date {
    min(monthDay(day, monthsAgo: 0), Date.now.addingTimeInterval(-60))
  }

  /// Jour `day` du mois précédent, à 10 h.
  private static func lastMonth(_ day: Int) -> Date {
    monthDay(day, monthsAgo: 1)
  }

  /// Jour `day` à 10 h, heure locale, du mois situé `monthsAgo` mois avant le mois en cours.
  private static func monthDay(_ day: Int, monthsAgo: Int) -> Date {
    let calendar = PostgresDate.localCalendar
    var components = calendar.dateComponents([.year, .month], from: .now)
    components.month = (components.month ?? 1) - monthsAgo
    components.day = day
    components.hour = 10
    return calendar.date(from: components) ?? .now
  }

  private static func ago(days: Int = 0, months: Int = 0, years: Int = 0) -> Date {
    let calendar = PostgresDate.localCalendar
    let components = DateComponents(year: -years, month: -months, day: -days)
    return calendar.date(byAdding: components, to: .now) ?? .now
  }

  private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  // MARK: Objectif

  /// Objectif PAL (14 livres quand il a été fixé, 8 visés d'ici la fin de l'année), sauf avec `-demo-goal none`.
  static var goal: PALGoal? {
    guard AppConfig.demoGoal != "none" else { return nil }
    let year = PostgresDate.localCalendar.component(.year, from: .now)
    return PALGoal(target: 8, deadline: "\(year)-12-31", startSize: 14, setAt: iso(lastMonth(1)))
  }

  // MARK: Bibliothèque

  /// Bibliothèque de démo, ajustée selon `-demo-reading` et `-demo-pal` pour vérifier les états de l'Accueil.
  static var library: [UserBook] {
    let reading = fullLibrary.filter { $0.status == .reading }
    var items: [UserBook]
    switch AppConfig.demoReading {
    case "none": items = fullLibrary.filter { $0.status != .reading }
    case "one": items = fullLibrary.filter { $0.status != .reading || $0.id == reading.first?.id }
    default: items = fullLibrary
    }
    if AppConfig.demoPAL == "empty" { items.removeAll { $0.status == .toRead } }
    return items
  }

  private static func item(
    _ title: String, _ status: ReadingStatus, since: Date, currentPage: Int? = nil, startedAt: String? = nil,
    finishedAt: String? = nil, rating: Int? = nil, review: String? = nil, isFavorite: Bool = false, hoursAgo: Double
  ) -> UserBook {
    UserBook(
      userId: me.id, book: book(title), status: status, statusChangedAt: iso(since), currentPage: currentPage,
      startedAt: startedAt, finishedAt: finishedAt, rating: rating, review: review, isFavorite: isFavorite,
      updatedAt: timestamp(hoursAgo: hoursAgo)
    )
  }

  private static let fullLibrary: [UserBook] = [
    // En cours : La Peste et Le Mage du Kremlin sont sortis de la PAL ce mois-ci.
    item("La Peste", .reading, since: thisMonth(8), currentPage: 124, startedAt: PostgresDate.day(from: thisMonth(8)),
         hoursAgo: 3),
    item("Dune", .reading, since: lastMonth(20), currentPage: 612, startedAt: PostgresDate.day(from: lastMonth(20)),
         isFavorite: true, hoursAgo: 26),
    item("Le Mage du Kremlin", .reading, since: thisMonth(15), currentPage: 40,
         startedAt: PostgresDate.day(from: thisMonth(15)), hoursAgo: 50),
    // PAL : onze livres, de quelques jours à quatre ans d'ancienneté.
    item("L'Écume des jours", .toRead, since: thisMonth(3), hoursAgo: 60),
    item("Germinal", .toRead, since: thisMonth(9), hoursAgo: 70),
    item("Les Choses", .toRead, since: lastMonth(13), hoursAgo: 80),
    item("Bel-Ami", .toRead, since: ago(months: 3), hoursAgo: 90),
    item("La Horde du Contrevent", .toRead, since: ago(months: 6), hoursAgo: 100),
    item("Sapiens", .toRead, since: ago(months: 8), hoursAgo: 110),
    item("L'Homme révolté", .toRead, since: ago(months: 14), hoursAgo: 120),
    item("1984", .toRead, since: ago(years: 2), hoursAgo: 130),
    item("Belle du Seigneur", .toRead, since: ago(months: 5, years: 2), hoursAgo: 140),
    item("Les Misérables", .toRead, since: ago(years: 3), hoursAgo: 150),
    item("Le Rouge et le Noir", .toRead, since: ago(years: 4), hoursAgo: 160),
    // Envies.
    item("Veiller sur elle", .wishlist, since: thisMonth(11), hoursAgo: 40),
    item("Yoga", .wishlist, since: ago(months: 2), hoursAgo: 170),
    item("La Vie devant soi", .wishlist, since: ago(months: 7), hoursAgo: 180),
    // Lus, abandonné, libérés.
    item("L'Étranger", .read, since: lastMonth(4), startedAt: PostgresDate.day(from: monthDay(10, monthsAgo: 2)),
         finishedAt: PostgresDate.day(from: lastMonth(4)), rating: 5,
         review: "Une écriture sèche et lumineuse. À relire.", isFavorite: true, hoursAgo: 200),
    item("Le Petit Prince", .read, since: thisMonth(14), finishedAt: PostgresDate.day(from: thisMonth(14)), rating: 4,
         hoursAgo: 30),
    item("Madame Bovary", .abandoned, since: monthDay(5, monthsAgo: 3), currentPage: 140, hoursAgo: 400),
    item("Da Vinci Code", .released, since: thisMonth(5), hoursAgo: 20),
    item("L'Alchimiste", .released, since: thisMonth(12), hoursAgo: 10),
  ]

  private static func libraryItem(_ title: String) -> UserBook {
    fullLibrary.first { $0.book?.title == title }!
  }

  // MARK: Historique de la PAL

  private static func event(
    _ id: Int64, user: UUID = me.id, _ item: UserBook?, _ from: ReadingStatus?, _ to: ReadingStatus?, _ at: Date
  ) -> UserBookEvent {
    UserBookEvent(
      id: id, userId: user, userBookId: item?.id, bookId: item?.bookId ?? UUID(),
      fromStatus: from, toStatus: to, occurredAt: iso(at)
    )
  }

  /// Mon historique complet. Les entrées anciennes donnent l'ancienneté des livres dans la PAL ; le jeu
  /// compte à partir de `gameStart` :
  /// - il y a 4 mois : 4 sorties, dont Madame Bovary, plus vieux livre de la PAL (5 ans) → au vert ;
  /// - il y a 3 mois : 1 sortie, 1 entrée → pas au vert (avec `-demo-places overflow`, 5 entrées de plus) ;
  /// - il y a 2 mois : 3 sorties, 1 entrée ; le mois dernier : 2 sorties, 1 entrée → au vert ;
  /// - ce mois-ci : 2 entrées, 5 sorties (dont une suppression), et deux changements hors PAL : « +2 · −5 · −3 ».
  /// Soit 15 sorties et 5 entrées : ⌊15 ÷ 2⌋ − 5 = 2 places libres, encore 1 sortie pour la prochaine, et une
  /// série de 3 mois au vert. Avec `-demo-places overflow` : 10 entrées, PAL en débord de 3.
  static var events: [UserBookEvent] {
    var id: Int64 = 0
    func e(_ title: String?, _ from: ReadingStatus?, _ to: ReadingStatus?, _ at: Date) -> UserBookEvent {
      id += 1
      return event(id, title.map(libraryItem), from, to, at)
    }
    var history = [
      // Entrées dans la PAL avant le début du jeu.
      e("Madame Bovary", nil, .toRead, ago(years: 5)),
      e("Le Rouge et le Noir", nil, .toRead, ago(years: 4)),
      e("Les Misérables", nil, .toRead, ago(years: 3)),
      e("Belle du Seigneur", nil, .toRead, ago(months: 5, years: 2)),
      e("1984", nil, .toRead, ago(years: 2)),
      e("L'Homme révolté", nil, .toRead, ago(months: 14)),
      e("Dune", nil, .toRead, ago(years: 1)),
      e("Da Vinci Code", nil, .toRead, ago(months: 11)),
      e("La Peste", nil, .toRead, ago(months: 10)),
      e("Le Mage du Kremlin", nil, .toRead, ago(months: 9)),
      e("Sapiens", nil, .toRead, ago(months: 8)),
      e("L'Alchimiste", nil, .toRead, ago(months: 7)),
      e("La Horde du Contrevent", nil, .toRead, ago(months: 6)),
      e("Germinal", nil, .wishlist, ago(months: 5)),
      // Il y a 4 mois.
      e("Madame Bovary", .toRead, .reading, monthDay(18, monthsAgo: 4)),
      e(nil, .toRead, .released, monthDay(20, monthsAgo: 4)),
      e(nil, .toRead, .released, monthDay(22, monthsAgo: 4)),
      e(nil, .toRead, .read, monthDay(25, monthsAgo: 4)),
      // Il y a 3 mois.
      e("Madame Bovary", .reading, .abandoned, monthDay(5, monthsAgo: 3)),
      e(nil, .toRead, .reading, monthDay(10, monthsAgo: 3)),
      e("Bel-Ami", nil, .toRead, ago(months: 3)),
      // Il y a 2 mois.
      e("L'Étranger", nil, .toRead, monthDay(2, monthsAgo: 2)),
      e("L'Étranger", .toRead, .reading, monthDay(10, monthsAgo: 2)),
      e(nil, .toRead, .released, monthDay(14, monthsAgo: 2)),
      e(nil, .toRead, .released, monthDay(25, monthsAgo: 2)),
      // Le mois dernier.
      e("L'Étranger", .reading, .read, lastMonth(4)),
      e("Les Choses", nil, .toRead, lastMonth(13)),
      e("Dune", .toRead, .reading, lastMonth(20)),
      e(nil, .toRead, .released, lastMonth(25)),
      // Ce mois-ci.
      e("L'Écume des jours", nil, .toRead, thisMonth(3)),
      e("Da Vinci Code", .toRead, .released, thisMonth(5)),
      e(nil, .toRead, nil, thisMonth(6)),
      e("La Peste", .toRead, .reading, thisMonth(8)),
      e("Germinal", .wishlist, .toRead, thisMonth(9)),
      e("Veiller sur elle", nil, .wishlist, thisMonth(11)),
      e("L'Alchimiste", .toRead, .released, thisMonth(12)),
      e("Le Petit Prince", .reading, .read, thisMonth(14)),
      e("Le Mage du Kremlin", .toRead, .reading, thisMonth(15)),
    ]
    if AppConfig.demoPlaces == "overflow" {
      history += (20...24).map { day in e(nil, nil, .toRead, monthDay(day, monthsAgo: 3)) }
    }
    return history
  }

  // MARK: Jeu

  /// Badges déjà enregistrés : ceux que l'historique de la démo fait obtenir. Restent à obtenir : Grand
  /// ménage, Pavé, Moitié moins, Objectif atteint et Coup de dé (que « Piocher dans ma PAL » fait gagner).
  static var earnedBadges: [UserBadge] {
    // Défi non démarré : aucun badge encore.
    guard AppConfig.demoChallenge != "off" else { return [] }
    let bovary = libraryItem("Madame Bovary").id
    func badge(_ badge: Badge, _ at: Date, _ book: UUID? = nil) -> UserBadge {
      UserBadge(userId: me.id, badgeId: badge.rawValue, earnedAt: iso(at), userBookId: book)
    }
    return [
      badge(.firstExit, monthDay(18, monthsAgo: 4), bovary),
      badge(.bottomOfPile, monthDay(18, monthsAgo: 4), bovary),
      badge(.archaeologist, monthDay(18, monthsAgo: 4), bovary),
      badge(.greenMonth, monthDay(18, monthsAgo: 4)),
      badge(.tenOut, lastMonth(25)),
      badge(.greenStreak3, thisMonth(6)),
    ]
  }

  /// Badges des amis. Tom a masqué le jeu : son profil n'en montre aucun.
  static var friendBadges: [UUID: [UserBadge]] {
    func badges(_ user: Profile, _ list: [(Badge, Int)]) -> [UserBadge] {
      list.map { badge, daysAgo in
        UserBadge(userId: user.id, badgeId: badge.rawValue, earnedAt: iso(ago(days: daysAgo)))
      }
    }
    return [
      lea.id: badges(lea, [(.firstExit, 120), (.greenMonth, 95), (.tenOut, 40), (.bigCleanup, 12), (.brick, 3)]),
      nina.id: badges(nina, [(.firstExit, 30), (.pickAccepted, 9)]),
    ]
  }

  static let lea = Profile(username: "lea_lit", displayName: "Léa Martin")
  static let tom = Profile(username: "tom", displayName: "Tom Durand", gamificationEnabled: false)
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

  /// Mouvements de PAL des amis ce mois-ci : Léa −4, Nina −2, Tom +2 (qui n'est pas mis en avant).
  static var friendEvents: [UserBookEvent] {
    var id: Int64 = 100
    func moves(_ user: Profile, exits: Int, entries: Int) -> [UserBookEvent] {
      let out = (0..<exits).map { i -> UserBookEvent in
        id += 1
        return event(id, user: user.id, nil, .toRead, i.isMultiple(of: 2) ? .reading : .released, thisMonth(2 + i * 2))
      }
      let into = (0..<entries).map { i -> UserBookEvent in
        id += 1
        return event(id, user: user.id, nil, nil, .toRead, thisMonth(4 + i * 3))
      }
      return out + into
    }
    return moves(lea, exits: 5, entries: 1) + moves(nina, exits: 2, entries: 0) + moves(tom, exits: 1, entries: 3)
  }

  static func search(query: String) -> [BookCandidate] {
    let q = query.lowercased().folding(options: .diacriticInsensitive, locale: .current)
    let words = q.split(separator: " ")
    return candidates.filter { c in
      let haystack = (c.title + " " + c.authorsLine).lowercased().folding(options: .diacriticInsensitive, locale: .current)
      return words.allSatisfy { haystack.contains($0) }
    }
  }

  /// Recherche par ISBN : comme en vrai, elle renvoie une fiche plus complète que la recherche texte
  /// (résumé, date précise, pages), ce qui permet de voir la page de détail se compléter.
  static func search(isbn: String) -> [BookCandidate] {
    candidates.filter { $0.isbn13 == isbn || $0.isbn10 == isbn }.map { candidate in
      guard let isbn13 = candidate.isbn13, let extra = isbnDetails[isbn13] else { return candidate }
      return candidate.completed(with: extra)
    }
  }

  private static let isbnDetails: [String: BookCandidate] = [
    "9782070322886": BookCandidate(
      title: "Le Mythe de Sisyphe", subtitle: "Essai sur l'absurde", publishedDate: "1985-03-12", pageCount: 192,
      description: """
        Il n'y a qu'un problème philosophique vraiment sérieux : juger si la vie vaut ou ne vaut pas la peine \
        d'être vécue. Camus part de ce constat pour décrire le sentiment de l'absurde, ce divorce entre \
        l'homme qui cherche un sens et un monde qui se tait.

        Plutôt que de fuir dans l'espoir ou dans le suicide, il propose de tenir les deux bouts : la lucidité \
        et la révolte. Don Juan, le comédien, le conquérant et le créateur sont autant de figures d'une vie \
        vécue sans appel, tout entière tournée vers le présent.

        L'essai se clôt sur Sisyphe, condamné à rouler éternellement son rocher. Conscient de son sort, il \
        le dépasse : « Il faut imaginer Sisyphe heureux. » Un texte court et dense, écrit en 1942, qui forme \
        avec L'Étranger et Caligula le cycle de l'absurde.
        """
    ),
    // Sans couverture en recherche texte : la recherche par ISBN en trouve une.
    "9782072958632": BookCandidate(title: "Le Mage du Kremlin", coverUrl: cover("9782072958632")),
    "9782070360024": BookCandidate(
      title: "L'Étranger", publishedDate: "1972-01-05",
      description: """
        « Aujourd'hui, maman est morte. » Meursault, employé de bureau à Alger, enterre sa mère sans larmes, \
        puis reprend sa vie au soleil. Un après-midi sur la plage, il tue un homme. Son procès juge moins son \
        geste que son indifférence.
        """
    ),
  ]
}
