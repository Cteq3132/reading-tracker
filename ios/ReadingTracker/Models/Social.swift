import Foundation

struct Profile: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  var username: String
  var displayName: String?
  var avatarUrl: String?
  var isPrivate: Bool
  var createdAt: String?
  /// Objectif PAL : taille visée et échéance (`yyyy-MM-dd`), écrites par l'app.
  var palGoalTarget: Int?
  var palGoalDeadline: String?
  /// Taille de la PAL et instant où l'objectif a été fixé : posés par trigger, jamais envoyés.
  var palGoalStartSize: Int?
  var palGoalSetAt: String?

  enum CodingKeys: String, CodingKey {
    case id, username
    case displayName = "display_name"
    case avatarUrl = "avatar_url"
    case isPrivate = "is_private"
    case createdAt = "created_at"
    case palGoalTarget = "pal_goal_target"
    case palGoalDeadline = "pal_goal_deadline"
    case palGoalStartSize = "pal_goal_start_size"
    case palGoalSetAt = "pal_goal_set_at"
  }

  init(id: UUID = UUID(), username: String, displayName: String? = nil, avatarUrl: String? = nil, isPrivate: Bool = false) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.avatarUrl = avatarUrl
    self.isPrivate = isPrivate
  }

  /// Objectif PAL en cours, s'il y en a un.
  var palGoal: PALGoal? {
    guard let palGoalTarget else { return nil }
    return PALGoal(target: palGoalTarget, deadline: palGoalDeadline, startSize: palGoalStartSize)
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    username = try c.decode(String.self, forKey: .username)
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
    isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    palGoalTarget = try c.decodeIfPresent(Int.self, forKey: .palGoalTarget)
    palGoalDeadline = try c.decodeIfPresent(String.self, forKey: .palGoalDeadline)
    palGoalStartSize = try c.decodeIfPresent(Int.self, forKey: .palGoalStartSize)
    palGoalSetAt = try c.decodeIfPresent(String.self, forKey: .palGoalSetAt)
  }

  var name: String {
    if let displayName, !displayName.trimmingCharacters(in: .whitespaces).isEmpty { return displayName }
    return username
  }
}

enum FollowStatus: String, Codable, Sendable {
  case pending
  case accepted
}

/// Ligne de `follows`. Le statut est posé par un trigger côté serveur.
struct Follow: Codable, Hashable, Sendable {
  let followerId: UUID
  let followingId: UUID
  var status: FollowStatus
  var createdAt: String?

  enum CodingKeys: String, CodingKey {
    case followerId = "follower_id"
    case followingId = "following_id"
    case status
    case createdAt = "created_at"
  }
}

struct FollowInsert: Encodable, Sendable {
  let followerId: UUID
  let followingId: UUID

  enum CodingKeys: String, CodingKey {
    case followerId = "follower_id"
    case followingId = "following_id"
  }
}

/// Demande d'abonnement reçue, avec le profil de son auteur.
struct FollowRequest: Identifiable, Hashable, Sendable {
  let follow: Follow
  let profile: Profile
  var id: UUID { follow.followerId }
}

/// Ligne de la vue `friends_activity`.
struct FriendActivity: Codable, Identifiable, Hashable, Sendable {
  let userBookId: UUID
  let userId: UUID
  var username: String
  var displayName: String?
  var avatarUrl: String?
  let bookId: UUID
  var title: String
  var authors: [String]
  var coverUrl: String?
  var status: ReadingStatus
  var currentPage: Int?
  var pageCount: Int?
  var rating: Int?
  var updatedAt: String?

  var id: UUID { userBookId }

  enum CodingKeys: String, CodingKey {
    case userBookId = "user_book_id"
    case userId = "user_id"
    case username
    case displayName = "display_name"
    case avatarUrl = "avatar_url"
    case bookId = "book_id"
    case title, authors
    case coverUrl = "cover_url"
    case status
    case currentPage = "current_page"
    case pageCount = "page_count"
    case rating
    case updatedAt = "updated_at"
  }

  init(
    userBookId: UUID = UUID(), userId: UUID, username: String, displayName: String?, bookId: UUID = UUID(),
    title: String, authors: [String], coverUrl: String?, status: ReadingStatus, currentPage: Int? = nil,
    pageCount: Int? = nil, rating: Int? = nil, updatedAt: String?
  ) {
    self.userBookId = userBookId
    self.userId = userId
    self.username = username
    self.displayName = displayName
    self.bookId = bookId
    self.title = title
    self.authors = authors
    self.coverUrl = coverUrl
    self.status = status
    self.currentPage = currentPage
    self.pageCount = pageCount
    self.rating = rating
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    userBookId = try c.decode(UUID.self, forKey: .userBookId)
    userId = try c.decode(UUID.self, forKey: .userId)
    username = try c.decode(String.self, forKey: .username)
    displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
    bookId = try c.decode(UUID.self, forKey: .bookId)
    title = try c.decode(String.self, forKey: .title)
    authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
    coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
    status = try c.decode(ReadingStatus.self, forKey: .status)
    currentPage = try c.decodeIfPresent(Int.self, forKey: .currentPage)
    pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
    rating = try c.decodeIfPresent(Int.self, forKey: .rating)
    updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
  }

  var name: String {
    if let displayName, !displayName.isEmpty { return displayName }
    return username
  }

  var coverURL: URL? { coverUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) } }

  /// Phrase d'activité : « a commencé », « a terminé »…
  var verb: String {
    switch status {
    case .reading: "lit"
    case .toRead: "a ajouté à sa PAL"
    case .read: "a terminé"
    case .abandoned: "a abandonné"
    case .wishlist: "a envie de lire"
    case .released: "a libéré de sa PAL"
    }
  }
}
