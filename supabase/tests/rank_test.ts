// Tests du classement texte de search-books (supabase/functions/search-books/rank.ts).
//
//     node --test supabase/tests/rank_test.ts      (Node ≥ 22.18, types retirés à la volée)
//     deno test supabase/tests/rank_test.ts
//
// Données inspirées de vraies réponses de Google Books et de Hardcover.
import assert from "node:assert/strict";
import { test } from "node:test";
import { fold, type Hit, rankText, type Rankable } from "../functions/search-books/rank.ts";

type Book = Rankable & { id: string };

function book(id: string, title: string, authors: string[], extra: Partial<Book> = {}): Book {
  return {
    id, title, authors, isbn13: null, subtitle: null, language: null, cover_url: null, ...extra,
  };
}

const google = (b: Book, categories: string[] = [], ratings = 0): Hit<Book> => ({
  candidate: b,
  signals: { categories, ratings },
});
const hardcover = (b: Book, genres: string[] = [], readers = 0): Hit<Book> => ({
  candidate: b,
  signals: { genres, readers },
});
const fr = { language: "fr", cover_url: "https://x/c.jpg" };

test("fold retire accents, casse et ponctuation", () => {
  assert.equal(fold("L'Étranger !"), "l etranger");
});

test("« dune » : le roman de Frank Herbert passe devant les suites et les homonymes", () => {
  const ranked = rankText({
    google: [
      google(book("g-heretiques", "Dune - Tome 5 Les Hérétiques de Dune", ["Frank Herbert"],
        { ...fr, isbn13: "9782221000001" }), ["Fiction"]),
      google(book("g-golf", "Dune", ["Golf de Belle Dune"], { language: "fr" })),
      google(book("g-dune-fr", "Dune", ["Frank Herbert"], { ...fr, isbn13: "9782221000002" }),
        ["Fiction"]),
      google(book("g-dune-en", "Dune", ["Frank Herbert"],
        { language: "en", cover_url: "https://x/en.jpg", isbn13: "9780441000003" }), ["Fiction"]),
    ],
    hardcover: [
      hardcover(book("h-dune", "Dune", ["Frank Herbert"], { cover_url: "https://x/h.jpg" }),
        ["Science fiction", "Classics"], 40000),
      hardcover(book("h-messiah", "Dune Messiah", ["Frank Herbert"], { cover_url: "https://x/m.jpg" }),
        ["Science fiction"], 15000),
    ],
  }, "dune");
  assert.equal(ranked[0].best.id, "g-dune-fr", "édition française retenue pour l'œuvre");
  assert.deepEqual(ranked[0].items.map((b) => b.id).sort(), ["g-dune-en", "g-dune-fr", "h-dune"]);
  assert.ok(ranked.findIndex((g) => g.best.id === "g-golf") > 1);
});

test("« l'étranger » : Camus devant la fiche de lecture et l'étude critique", () => {
  const ranked = rankText({
    google: [
      google(book("g-fiche", "Fiche de lecture illustrée - L'Étranger, d'Albert Camus",
        ["Frédéric Lippold"], { ...fr, isbn13: "9782000000001" })),
      google(book("g-critique", "L'Étranger", ["Pierre-Louis Rey"], { ...fr, isbn13: "9782000000002" }),
        ["Literary Criticism"]),
      google(book("g-camus", "L'étranger", ["Albert Camus"], { ...fr, isbn13: "9782070360024" }),
        ["Fiction"]),
    ],
    hardcover: [hardcover(book("h-camus", "L'Étranger", ["Albert Camus"]), ["Fiction", "Classics"], 900)],
  }, "l'étranger");
  assert.equal(ranked[0].best.id, "g-camus");
  assert.equal(ranked.at(-1)?.best.id, "g-fiche");
});

test("une analyse cherchée explicitement n'est pas pénalisée", () => {
  const ranked = rankText({
    google: [
      google(book("g-camus", "L'étranger", ["Albert Camus"], fr), ["Fiction"]),
      google(book("g-analyse", "Analyse de L'étranger", ["Jean Dupont"], fr)),
    ],
    hardcover: [],
  }, "analyse l'étranger");
  assert.equal(ranked[0].best.id, "g-analyse");
});

test("auteur seul : ses romans, sans le livre consacré à l'auteur en tête", () => {
  const ranked = rankText({
    google: [
      google(book("g-mystere", "Le mystère Fred Vargas", ["Guillaume Lebeau"], fr), ["Literary Criticism"]),
      google(book("g-pack", "Pack collector Fred Vargas", ["Fred Vargas"], fr), ["Fiction"]),
      google(book("g-pars", "Pars vite et reviens tard", ["Fred Vargas"], fr), ["Fiction"]),
    ],
    hardcover: [
      hardcover(book("h-pars", "Pars vite et reviens tard", ["Fred Vargas"]), ["Mystery", "Crime"], 1200),
    ],
  }, "fred vargas");
  assert.equal(ranked[0].best.id, "g-pars");
  assert.equal(ranked.at(-1)?.best.id, "g-mystere");
});

test("même ISBN-13 : un seul résultat", () => {
  const isbn13 = "9782818051382";
  const ranked = rankText({
    google: [
      google(book("g1", "Yoga", ["Emmanuel Carrère"], { ...fr, isbn13 })),
      google(book("g2", "Yoga (roman)", ["E. Carrère"], { ...fr, isbn13 })),
    ],
    hardcover: [],
  }, "yoga carrère");
  assert.equal(ranked.length, 1);
});

test("les mentions d'édition ne séparent pas une œuvre", () => {
  const ranked = rankText({
    google: [
      google(book("g-camus", "L'étranger", ["Albert Camus"], { ...fr, isbn13: "9782070360024" }), ["Fiction"]),
      google(book("g-fe", "L'Étranger (French Edition)", ["Albert Camus"], { ...fr, isbn13: "9782070360031" })),
    ],
    hardcover: [
      hardcover(book("h-folio", "L'Etranger (Collection Folio, 2) (French Edition) Publisher: Gallimard",
        ["Albert Camus"]), ["Fiction"], 50),
    ],
  }, "l'étranger");
  assert.equal(ranked.length, 1);
  assert.equal(ranked[0].best.id, "g-camus");
});

test("coffrets et fiches sans auteur passent après les romans", () => {
  const ranked = rankText({
    google: [
      google(book("g-pack", "Pack collector Fred Vargas - Les premières enquêtes", ["Fred Vargas"], fr), ["Fiction"]),
      google(book("g-dalle", "Sur la dalle", ["Fred Vargas"], fr), ["Fiction"]),
    ],
    hardcover: [hardcover(book("h-anon", "Fred Vargas", []), [], 0)],
  }, "fred vargas");
  assert.deepEqual(ranked.map((g) => g.best.id), ["g-dalle", "g-pack", "h-anon"]);
});

test("titre traduit connu de Hardcover : l'édition française profite de la popularité de l'œuvre", () => {
  const ranked = rankText({
    google: [
      google(book("g-chamber", "Harry Potter and the Chamber of Secrets", ["J.K. Rowling"],
        { language: "en", cover_url: "https://x/c.jpg", isbn13: "9780000000001" }), ["Juvenile Fiction"]),
      google(book("g-ecole", "Harry Potter à L'école des Sorciers", ["J.K. Rowling"],
        { ...fr, isbn13: "9782070000002" }), ["Juvenile Fiction"]),
    ],
    hardcover: [
      hardcover(book("h-chamber", "Harry Potter and the Chamber of Secrets", ["J.K. Rowling"]), ["Fantasy"], 30000),
      {
        candidate: book("h-stone", "Harry Potter and the Philosopher's Stone", ["J. K. Rowling"]),
        signals: { genres: ["Fantasy"], readers: 40000, altTitles: ["Harry Potter à l'école des sorciers"] },
      },
    ],
  }, "harry potter");
  assert.equal(ranked[0].best.id, "g-ecole");
});

test("mention d'édition : le titre propre est retenu", () => {
  const ranked = rankText({
    google: [
      google(book("g-tie", "Dune (Movie Tie-In)", ["Frank Herbert"],
        { language: "en", cover_url: "https://x/t.jpg", isbn13: "9780000000003" }), ["Fiction"]),
    ],
    hardcover: [hardcover(book("h-dune", "Dune", ["Frank Herbert"], { cover_url: "https://x/h.jpg" }), ["Fiction"], 40000)],
  }, "dune");
  assert.equal(ranked[0].best.id, "h-dune");
});

test("« profil d'une œuvre » est reconnu malgré la ligature", () => {
  assert.equal(fold("Profil d'une œuvre"), "profil d une oeuvre");
  const ranked = rankText({
    google: [
      google(book("g-profil", "L'Étranger - Profil d'une œuvre", ["Pierre-Louis Rey"], fr)),
      google(book("g-camus", "L'étranger", ["Albert Camus"], { language: "fr" })),
    ],
    hardcover: [],
  }, "l'étranger");
  assert.equal(ranked[0].best.id, "g-camus");
});

test("deux tomes ne fusionnent pas", () => {
  const ranked = rankText({
    google: [
      google(book("t1", "L'Arabe du futur (Tome 1)", ["Riad Sattouf"], fr)),
      google(book("t2", "L'Arabe du futur (Tome 2)", ["Riad Sattouf"], fr)),
    ],
    hardcover: [],
  }, "l'arabe du futur");
  assert.equal(ranked.length, 2);
});

test("un roman au titre ambigu n'est pas pris pour un guide", () => {
  const ranked = rankText({
    google: [
      google(book("g-etude", "Une étude en rouge", ["Arthur Conan Doyle"], fr), ["Fiction"]),
      google(book("g-jeunesse", "Le petit Nicolas", ["Sempé"], fr), ["Juvenile Fiction / School & Education"]),
      google(book("g-commentaire", "Sherlock Holmes : étude et commentaire", ["Jean Prof"], fr)),
    ],
    hardcover: [],
  }, "sherlock holmes");
  const score = (id: string) => ranked.find((g) => g.best.id === id)!.score;
  assert.ok(score("g-etude") > score("g-commentaire") + 20);
  assert.ok(score("g-jeunesse") > score("g-commentaire") + 20);
});
