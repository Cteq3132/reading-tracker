import Foundation
import Observation
import Supabase

/// Recherche de livres via l'Edge Function `search-books`.
@MainActor
@Observable
final class BookSearchService {
  private struct Body: Encodable {
    var query: String?
    var isbn: String?
  }

  func search(query: String) async throws -> [BookCandidate] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if let isbn = Self.normalizedISBN(trimmed) { return try await search(isbn: isbn) }
    if AppConfig.isDemo { return DemoData.search(query: trimmed) }
    return try await invoke(Body(query: trimmed))
  }

  func search(isbn: String) async throws -> [BookCandidate] {
    if AppConfig.isDemo { return DemoData.search(isbn: isbn) }
    return try await invoke(Body(isbn: isbn))
  }

  private func invoke(_ body: Body) async throws -> [BookCandidate] {
    let response: SearchBooksResponse = try await supabase.functions.invoke(
      "search-books",
      options: FunctionInvokeOptions(body: body)
    )
    return response.results
  }

  /// Renvoie l'ISBN (10 ou 13 chiffres, tirets et espaces retirés) si la saisie en est un.
  static func normalizedISBN(_ text: String) -> String? {
    let compact = text.uppercased().filter { $0.isNumber || $0 == "X" }
    let stripped = text.filter { !$0.isWhitespace && $0 != "-" }
    guard stripped.count == compact.count else { return nil }
    if compact.count == 13, compact.hasPrefix("978") || compact.hasPrefix("979"), compact.allSatisfy(\.isNumber) {
      return compact
    }
    if compact.count == 10, compact.dropLast().allSatisfy(\.isNumber) { return compact }
    return nil
  }
}
