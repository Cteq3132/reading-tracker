import Foundation

/// Ligne de `user_badges` : un badge obtenu. Déclarative, écrite par l'app (voir « Gamification » dans
/// `docs/CONTRAT.md`), visible des amis si le jeu du compte est affiché.
struct UserBadge: Codable, Hashable, Sendable {
  var userId: UUID
  var badgeId: String
  /// `timestamptz`, posé par défaut à l'insertion.
  var earnedAt: String?
  /// Le livre qui a déclenché le badge, s'il y en a un (`null` si sa ligne a été supprimée).
  var userBookId: UUID?

  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case badgeId = "badge_id"
    case earnedAt = "earned_at"
    case userBookId = "user_book_id"
  }

  /// Badge du catalogue ; `nil` pour un identifiant inconnu de cette version de l'app.
  var badge: Badge? { Badge(rawValue: badgeId) }

  var earnedDate: Date? { PostgresDate.parse(earnedAt) }

  /// Date d'obtention de chaque badge connu de l'app.
  static func dates(_ rows: [UserBadge]) -> [Badge: Date] {
    var result: [Badge: Date] = [:]
    for row in rows {
      if let badge = row.badge { result[badge] = row.earnedDate ?? .now }
    }
    return result
  }
}

/// Insertion d'un badge obtenu (`on conflict do nothing`), daté de l'événement qui l'a fait obtenir.
struct UserBadgeInsert: Encodable, Sendable {
  var userId: UUID
  var badgeId: String
  /// `timestamptz` ISO 8601.
  var earnedAt: String
  var userBookId: UUID?

  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case badgeId = "badge_id"
    case earnedAt = "earned_at"
    case userBookId = "user_book_id"
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(userId, forKey: .userId)
    try c.encode(badgeId, forKey: .badgeId)
    try c.encode(earnedAt, forKey: .earnedAt)
    try c.encode(userBookId, forKey: .userBookId)
  }
}
