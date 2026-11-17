// Classement de la recherche texte de search-books (docs/CONTRAT.md).
//
// Chaque candidat reçoit un score fait de signaux simples, aux poids ci-dessous.
// Les éditions d'une même œuvre sont d'abord regroupées : on n'en garde qu'une,
// de préférence française, avec couverture et ISBN, et l'œuvre profite des
// signaux de toutes ses éditions (genre, popularité, présence dans les deux
// sources).
//
// Module sans dépendance ni syntaxe propre à Deno : il se teste avec Node
// (supabase/tests/rank_test.ts).

export const WEIGHTS = {
  // Correspondance avec la requête (titre et auteurs, sans accents ni casse).
  titleExact: 30, //       titre = requête (« dune », « la peste »)
  titlePrefix: 18, //      titre qui commence par la requête (« Dune Messiah »)
  titleAllWords: 10, //    tous les mots de la requête dans le titre
  wordCoverage: 20, //     × part des mots de la requête trouvés dans titre + auteurs
  authorAllWords: 12, //   requête = un auteur (« fred vargas »)
  // Nature du livre.
  fiction: 15, //          roman ou fiction (catégories Google, genres Hardcover)
  guide: -45, //           fiche de lecture, analyse, résumé, étude critique…
  boxSet: -20, //          coffret, pack, intégrale, compilation
  noAuthor: -10, //        fiche sans auteur
  editionMention: -6, //   mention d'édition dans le titre (« (Movie Tie-In) », « (French Edition) »)
  // Popularité : log10 du nombre de lecteurs, plafonnée.
  popularity: 15, //       × min(1, log10(1 + lecteurs Hardcover) / 4) : 10 000 lecteurs = plein
  ratings: 8, //           × min(1, log10(1 + notes Google) / 3) : 1 000 notes = plein
  bothSources: 5, //       œuvre trouvée par Google et par Hardcover
  // Fiche.
  french: 12, //           édition en français
  otherLanguage: -4, //    ni français, ni anglais, ni inconnue
  cover: 5,
  isbn: 4,
  sourceRank: 4, //        × (1 − rang dans la source / 20) : la pertinence propre à la source
};

export type TextSource = "google" | "hardcover";

// Champs du candidat utiles au classement (BookCandidate dans index.ts).
export interface Rankable {
  isbn13: string | null;
  title: string;
  subtitle: string | null;
  authors: string[];
  language: string | null;
  cover_url: string | null;
}

// Signaux propres à une source, absents du candidat renvoyé à l'app.
export interface Signals {
  categories?: string[]; // Google volumeInfo.categories
  genres?: string[]; //     Hardcover genres et tags
  readers?: number; //      Hardcover users_count
  ratings?: number; //      Google ratingsCount
  compilation?: boolean; // Hardcover compilation
  altTitles?: string[]; //  Hardcover alternative_titles (titres traduits)
}

export interface Hit<C extends Rankable> {
  candidate: C;
  signals: Signals;
}

// Minuscules, sans accents, ponctuation remplacée par des espaces.
export function fold(s: string): string {
  return s.toLowerCase().normalize("NFKD").replace(/\p{M}/gu, "")
    .replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

const STOPWORDS = new Set([
  "l", "le", "la", "les", "un", "une", "des", "de", "du", "d", "et", "a", "au", "aux", "en",
  "the", "an", "of", "and",
]);

// Guides, analyses et résumés scolaires, en français et en anglais (texte replié).
const GUIDE = new RegExp(
  "\\b(" + [
    "fiches? de lecture",
    "analyses?",
    "etudes?",
    "commentaires?",
    "profil d une oeuvre",
    "resumes?",
    "bac",
    "dossiers? pedagogiques?",
    "lectures? analytiques?",
    "explications? de texte",
    "study guides?",
    "summary",
    "summaries",
    "analysis",
    "sparknotes",
    "cliffsnotes",
  ].join("|") + ")\\b",
);
// Catégories Google qui désignent une étude ou un manuel, pas l'œuvre.
const GUIDE_CATEGORY = /literary criticism|study aids|education|critique litteraire/;
const BOX_SET = /\b(coffret|pack|box set|boxed set|integrale|lot de)\b/;
// Roman ou fiction. « nonfiction » est écarté avant.
const FICTION = new RegExp(
  "\\b(" + [
    "fiction", "novels?", "romans?", "fantasy", "fantastique", "science fiction",
    "classics?", "mystery", "thriller", "polar", "romance", "horror", "young adult",
    "dystopi\\w*", "adventure", "crime", "literature", "litterature",
  ].join("|") + ")\\b",
);
const NON_FICTION = /\bnon ?fiction\b/;

// « Literary Criticism » ou « Nonfiction » ne comptent pas comme fiction.
function isFiction(labels: string[]): boolean {
  return labels.some((l) => {
    const f = fold(l);
    return !NON_FICTION.test(f) && !GUIDE_CATEGORY.test(f) && FICTION.test(f);
  });
}

// Titre replié, sans les mentions d'édition entre parenthèses ou crochets ni
// l'éditeur collé au titre (« L'Etranger (Collection Folio, 2) (French
// Edition) Publisher: Gallimard » → « l etranger »).
function foldTitle(title: string): string {
  return fold(
    title.replace(/\([^()]*\)|\[[^\]]*\]/g, " ").replace(/\bpublisher\s*:.*$/i, ""),
  ) || fold(title);
}

function words(s: string): string[] {
  return s.split(" ").filter((w) => w.length > 0);
}

// Score d'un candidat seul : correspondance, nature, fiche. La popularité et la
// présence dans les deux sources se calculent sur l'œuvre (groupScore).
function candidateScore<C extends Rankable>(
  hit: Hit<C>,
  rank: number,
  query: { folded: string; words: string[]; guide: boolean },
): number {
  const c = hit.candidate;
  const s = hit.signals;
  const title = foldTitle(c.title);
  const titleWords = new Set(words(title));
  const authorWords = new Set(c.authors.flatMap((a) => words(fold(a))));
  const W = WEIGHTS;
  let score = 0;

  if (title === query.folded) score += W.titleExact;
  else if (title.startsWith(query.folded + " ")) score += W.titlePrefix;
  else if (query.words.every((w) => titleWords.has(w))) score += W.titleAllWords;

  const found = query.words.filter((w) => titleWords.has(w) || authorWords.has(w)).length;
  score += W.wordCoverage * (found / query.words.length);
  if (query.words.every((w) => authorWords.has(w))) score += W.authorAllWords;

  const labels = [...(s.categories ?? []), ...(s.genres ?? [])];
  if (isFiction(labels)) score += W.fiction;

  // Pas de pénalité si l'on cherche justement une analyse (« analyse l'étranger »).
  const text = fold(`${c.title} ${c.subtitle ?? ""}`);
  const guide = GUIDE.test(text) ||
    (s.categories ?? []).some((cat) => GUIDE_CATEGORY.test(fold(cat)));
  if (guide && !query.guide) score += W.guide;
  if (BOX_SET.test(text) || s.compilation) score += W.boxSet;

  if (c.authors.length === 0) score += W.noAuthor;
  if (title !== fold(c.title)) score += W.editionMention;
  if (c.language === "fr") score += W.french;
  else if (c.language && c.language !== "en") score += W.otherLanguage;
  if (c.cover_url) score += W.cover;
  if (c.isbn13) score += W.isbn;
  score += W.sourceRank * Math.max(0, 1 - rank / 20);
  return score;
}

// Clés d'œuvre : titre (et titres traduits connus de Hardcover) avec le nom du
// premier auteur, repliés. Sans auteur, pas de regroupement par titre (trop
// d'homonymes).
function workKeys(c: Rankable, altTitles: string[] = []): string[] {
  const author = c.authors[0] ? words(fold(c.authors[0])) : [];
  if (author.length === 0) return [];
  const surname = author[author.length - 1];
  return [c.title, ...altTitles].map(foldTitle).filter((t) => t).map((t) => `${t}|${surname}`);
}

export interface RankedGroup<C extends Rankable> {
  best: C; //       l'édition retenue
  items: C[]; //    toutes les éditions du groupe, la retenue en premier
  score: number;
}

// Classe les résultats texte des sources. Les candidats de même ISBN-13 ou de
// même œuvre (titre + auteur) forment un groupe ; on renvoie les groupes du
// meilleur au moins bon score.
export function rankText<C extends Rankable>(
  bySource: Record<TextSource, Hit<C>[]>,
  rawQuery: string,
): RankedGroup<C>[] {
  const folded = fold(rawQuery);
  const all = words(folded);
  const significant = all.filter((w) => !STOPWORDS.has(w));
  const query = {
    folded,
    words: significant.length ? significant : all,
    guide: GUIDE.test(folded),
  };

  type Entry = { hit: Hit<C>; source: TextSource; score: number };
  const entries: Entry[] = [];
  (Object.keys(bySource) as TextSource[]).forEach((source) => {
    bySource[source].forEach((hit, rank) => {
      entries.push({ hit, source, score: candidateScore(hit, rank, query) });
    });
  });

  // Union-find sur les clés partagées (ISBN-13, œuvre).
  const parent = entries.map((_, i) => i);
  const find = (i: number): number => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  const owner = new Map<string, number>();
  entries.forEach((e, i) => {
    const c = e.hit.candidate;
    const keys = [...(c.isbn13 ? [`isbn:${c.isbn13}`] : []), ...workKeys(c, e.hit.signals.altTitles)];
    for (const key of keys) {
      const j = owner.get(key);
      if (j === undefined) owner.set(key, i);
      else parent[find(i)] = find(j);
    }
  });
  const groups = new Map<number, Entry[]>();
  entries.forEach((e, i) => {
    const root = find(i);
    groups.set(root, [...(groups.get(root) ?? []), e]);
  });

  const W = WEIGHTS;
  return [...groups.values()].map((members) => {
    // L'édition retenue est celle qui a le meilleur score propre : à
    // correspondance égale, française, avec couverture et ISBN.
    members.sort((a, b) => b.score - a.score);
    const signals = members.map((m) => m.hit.signals);
    const readers = Math.max(0, ...signals.map((s) => s.readers ?? 0));
    const ratings = Math.max(0, ...signals.map((s) => s.ratings ?? 0));
    let score = members[0].score;
    score += W.popularity * Math.min(1, Math.log10(1 + readers) / 4);
    score += W.ratings * Math.min(1, Math.log10(1 + ratings) / 3);
    if (new Set(members.map((m) => m.source)).size > 1) score += W.bothSources;
    // Le genre d'une autre édition vaut pour l'œuvre (Hardcover connaît le
    // genre, Google a l'édition française).
    const labels = signals.flatMap((s) => [...(s.categories ?? []), ...(s.genres ?? [])]);
    const bestLabels = [...(signals[0].categories ?? []), ...(signals[0].genres ?? [])];
    if (isFiction(labels) && !isFiction(bestLabels)) score += W.fiction;
    return { best: members[0].hit.candidate, items: members.map((m) => m.hit.candidate), score };
  }).sort((a, b) => b.score - a.score);
}
