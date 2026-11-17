import Foundation
import Testing
@testable import ReadingTracker

/// Complément d'un résultat de recherche par une recherche ISBN, et affichage de ses dates.
struct BookCandidateTests {
  private let textResult = BookCandidate(
    isbn13: "9782070322886", title: "Le Mythe de Sisyphe", authors: ["Albert Camus"], publisher: "Gallimard",
    publishedDate: "1985", coverUrl: "https://example.com/a.jpg", source: "google", sourceId: "g1"
  )

  @Test func completingFillsOnlyMissingFields() {
    var byISBN = BookCandidate(
      isbn13: "9782070322886", isbn10: "2070322882", title: "Mythe de Sisyphe (Le)", subtitle: "Essai",
      authors: ["A. Camus"], publisher: "Folio", publishedDate: "1985-03-12", pageCount: 192,
      description: "Un essai.", language: "fr", coverUrl: "https://example.com/b.jpg", source: "bnf"
    )
    byISBN.bookId = UUID()

    let merged = textResult.completed(with: byISBN)

    #expect(merged.title == "Le Mythe de Sisyphe")
    #expect(merged.authors == ["Albert Camus"])
    #expect(merged.publisher == "Gallimard")
    // Même année, date plus précise : elle remplace l'année seule.
    #expect(merged.publishedDate == "1985-03-12")
    #expect(merged.coverUrl == "https://example.com/a.jpg")
    #expect(merged.source == "google")
    #expect(merged.sourceId == "g1")
    #expect(merged.description == "Un essai.")
    #expect(merged.pageCount == 192)
    #expect(merged.language == "fr")
    #expect(merged.subtitle == "Essai")
    #expect(merged.isbn10 == "2070322882")
    #expect(merged.bookId == byISBN.bookId)
  }

  @Test func differentDateIsKept() {
    let merged = textResult.completed(with: BookCandidate(title: "x", publishedDate: "2010-01-01"))
    #expect(merged.publishedDate == "1985")
  }

  @Test func emptyStringsCountAsMissing() {
    var withBlanks = textResult
    withBlanks.description = ""
    let merged = withBlanks.completed(with: BookCandidate(title: "x", description: "Résumé"))
    #expect(merged.description == "Résumé")
  }

  @Test func missingDetails() {
    #expect(textResult.isMissingDetails)
    var complete = textResult
    complete.description = "Résumé"
    complete.pageCount = 192
    complete.language = "fr"
    #expect(!complete.isMissingDetails)
    // Le sous-titre et l'ISBN-10 manquent souvent pour de bon : ils ne déclenchent pas de recherche.
    #expect(complete.subtitle == nil && complete.isbn10 == nil)
  }

  @Test func publishedDateAndLanguageFormatting() {
    func date(_ raw: String) -> String? { BookCandidate(title: "x", publishedDate: raw).formattedPublishedDate }
    #expect(date("1985-03-12") == "12 mars 1985")
    #expect(date("2021-03") == "mars 2021")
    #expect(date("1972") == "1972")
    #expect(date("") == nil)
    #expect(BookCandidate(title: "x", language: "fr").languageName == "Français")
    #expect(BookCandidate(title: "x").languageName == nil)
  }
}
