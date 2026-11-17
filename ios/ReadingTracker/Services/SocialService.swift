import Foundation
import Observation
import Supabase

/// Abonnements, demandes reçues et fil d'activité des amis.
@MainActor
@Observable
final class SocialService {
  private(set) var activity: [FriendActivity] = []
  /// Mes abonnements : `following_id` → statut.
  private(set) var outgoing: [UUID: FollowStatus] = [:]
  private(set) var followingProfiles: [Profile] = []
  private(set) var incoming: [FollowRequest] = []
  private(set) var followersCount = 0
  private(set) var hasLoaded = false
  private(set) var isLoading = false
  var errorMessage: String?

  // Données de démo modifiables pendant la session.
  private var demoProfiles = DemoData.profiles

  func refresh(userId: UUID) async {
    if AppConfig.isDemo {
      if !hasLoaded {
        activity = DemoData.activity
        outgoing = DemoData.outgoing
        incoming = DemoData.incoming
        followersCount = 3
        followingProfiles = demoProfiles.filter { outgoing[$0.id] != nil }
      }
      hasLoaded = true
      return
    }

    isLoading = true
    defer { isLoading = false }
    do {
      async let activityRows: [FriendActivity] = supabase.from("friends_activity")
        .select()
        .order("updated_at", ascending: false)
        .limit(50)
        .execute()
        .value
      async let outgoingRows: [Follow] = supabase.from("follows")
        .select()
        .eq("follower_id", value: userId)
        .execute()
        .value
      async let incomingRows: [Follow] = supabase.from("follows")
        .select()
        .eq("following_id", value: userId)
        .execute()
        .value

      let (fetchedActivity, fetchedOutgoing, fetchedIncoming) = try await (activityRows, outgoingRows, incomingRows)
      activity = fetchedActivity
      outgoing = Dictionary(uniqueKeysWithValues: fetchedOutgoing.map { ($0.followingId, $0.status) })
      followersCount = fetchedIncoming.filter { $0.status == .accepted }.count

      let pending = fetchedIncoming.filter { $0.status == .pending }
      let ids = Set(pending.map(\.followerId)).union(fetchedOutgoing.map(\.followingId))
      let profiles = try await fetchProfiles(ids: Array(ids))
      let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
      incoming = pending.compactMap { follow in byId[follow.followerId].map { FollowRequest(follow: follow, profile: $0) } }
      followingProfiles = fetchedOutgoing.compactMap { byId[$0.followingId] }.sorted { $0.username < $1.username }
      errorMessage = nil
    } catch {
      errorMessage = ErrorMessage.from(error)
    }
    hasLoaded = true
  }

  func searchProfiles(_ text: String, excluding userId: UUID) async throws -> [Profile] {
    let query = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
    guard !query.isEmpty else { return [] }

    if AppConfig.isDemo {
      return demoProfiles.filter { $0.username.contains(query) || $0.name.lowercased().contains(query) }
    }

    let escaped = query.replacingOccurrences(of: "_", with: "\\_")
    return try await supabase.from("profiles")
      .select()
      .ilike("username", pattern: "%\(escaped)%")
      .neq("id", value: userId)
      .order("username")
      .limit(20)
      .execute()
      .value
  }

  func follow(_ profile: Profile, userId: UUID) async throws {
    if AppConfig.isDemo {
      outgoing[profile.id] = profile.isPrivate ? .pending : .accepted
      followingProfiles.append(profile)
      return
    }
    let row: Follow = try await supabase.from("follows")
      .insert(FollowInsert(followerId: userId, followingId: profile.id))
      .select()
      .single()
      .execute()
      .value
    outgoing[profile.id] = row.status
    if !followingProfiles.contains(where: { $0.id == profile.id }) { followingProfiles.append(profile) }
    if row.status == .accepted { await reloadActivity() }
  }

  func unfollow(_ profileId: UUID, userId: UUID) async throws {
    if !AppConfig.isDemo {
      try await supabase.from("follows")
        .delete()
        .eq("follower_id", value: userId)
        .eq("following_id", value: profileId)
        .execute()
    }
    outgoing[profileId] = nil
    followingProfiles.removeAll { $0.id == profileId }
    activity.removeAll { $0.userId == profileId }
  }

  func accept(_ request: FollowRequest) async throws {
    if !AppConfig.isDemo {
      try await supabase.from("follows")
        .update(["status": FollowStatus.accepted.rawValue])
        .eq("follower_id", value: request.follow.followerId)
        .eq("following_id", value: request.follow.followingId)
        .execute()
    }
    incoming.removeAll { $0.id == request.id }
    followersCount += 1
  }

  func decline(_ request: FollowRequest) async throws {
    if !AppConfig.isDemo {
      try await supabase.from("follows")
        .delete()
        .eq("follower_id", value: request.follow.followerId)
        .eq("following_id", value: request.follow.followingId)
        .execute()
    }
    incoming.removeAll { $0.id == request.id }
  }

  func reset() {
    activity = []
    outgoing = [:]
    followingProfiles = []
    incoming = []
    followersCount = 0
    hasLoaded = false
    errorMessage = nil
    demoProfiles = DemoData.profiles
  }

  private func reloadActivity() async {
    if let rows: [FriendActivity] = try? await supabase.from("friends_activity")
      .select()
      .order("updated_at", ascending: false)
      .limit(50)
      .execute()
      .value {
      activity = rows
    }
  }

  private func fetchProfiles(ids: [UUID]) async throws -> [Profile] {
    guard !ids.isEmpty else { return [] }
    return try await supabase.from("profiles")
      .select()
      .in("id", values: ids.map(\.uuidString))
      .execute()
      .value
  }
}
