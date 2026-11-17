// search-books — recherche de livres pour l'app (contrat : docs/CONTRAT.md)
//
// POST { "query": "camus etranger" } ou { "isbn": "9782070360024" }
// → { "results": BookCandidate[] }, 20 au maximum, sans doublon d'ISBN-13.
//
// Sources interrogées en parallèle, chacune avec son propre délai, puis
// fusionnées par ISBN-13 avec la priorité Google > BnF > Open Library :
//   - Google Books, seulement si le secret GOOGLE_BOOKS_API_KEY existe ;
//   - BnF SRU en Dublin Core ;
//   - Open Library.
// Une source en panne ou trop lente est simplement ignorée.

type Source = "google" | "bnf" | "openlibrary";

interface BookCandidate {
  isbn13: string | null;
  isbn10: string | null;
  title: string;
  subtitle: string | null;
  authors: string[];
  publisher: string | null;
  published_date: string | null;
  page_count: number | null;
  description: string | null;
  language: string | null;
  cover_url: string | null;
  source: Source;
  source_id: string | null;
}

type SearchInput = { kind: "isbn"; isbn13: string; isbn10: string | null } | {
  kind: "query";
  query: string;
};

const MAX_RESULTS = 20;
const SOURCE_TIMEOUT_MS = 6000;
const PRIORITY: Source[] = ["google", "bnf", "openlibrary"];

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ---------------------------------------------------------------------------
// Entrée HTTP
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Méthode non autorisée, utiliser POST." }, 405);
  }
  if (!(await isSignedInUser(req))) {
    return json({ error: "Session utilisateur requise." }, 401);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Corps JSON invalide." }, 400);
  }

  const input = parseInput(body);
  if ("error" in input) {
    return json({ error: input.error }, 400);
  }

  const googleKey = Deno.env.get("GOOGLE_BOOKS_API_KEY")?.trim();
  const tasks: Promise<BookCandidate[]>[] = [
    googleKey ? withSource("google", (s) => searchGoogle(input, googleKey, s)) : Promise.resolve([]),
    withSource("bnf", (s) => searchBnf(input, s)),
    withSource("openlibrary", (s) => searchOpenLibrary(input, s)),
  ];
  const [google, bnf, openlibrary] = await Promise.all(tasks);

  const results = merge({ google, bnf, openlibrary });
  return json({ results });
});

// verify_jwt laisse passer la clé publishable (rôle anon) : on exige en plus
// un jeton de session, validé par Supabase Auth.
async function isSignedInUser(req: Request): Promise<boolean> {
  const token = req.headers.get("Authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
  if (!token || token.split(".").length !== 3) return false;
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const apikey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !apikey) return false;
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      return false;
    }
    const user = await res.json() as { id?: string; role?: string };
    return !!user.id && user.role === "authenticated";
  } catch (error) {
    console.warn("search-books: vérification de session impossible", String(error));
    return false;
  }
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json; charset=utf-8" },
  });
}

function parseInput(body: unknown): SearchInput | { error: string } {
  if (!body || typeof body !== "object") {
    return { error: "Attendu : { \"query\": \"…\" } ou { \"isbn\": \"…\" }." };
  }
  const { query, isbn } = body as { query?: unknown; isbn?: unknown };

  if (typeof isbn === "string" && isbn.trim() !== "") {
    const normalized = normalizeIsbn(isbn);
    if (!normalized) return { error: "ISBN invalide." };
    return { kind: "isbn", ...normalized };
  }
  if (typeof query === "string") {
    const q = query.replace(/\s+/g, " ").trim();
    if (q.length < 2) return { error: "La recherche doit faire au moins 2 caractères." };
    if (q.length > 200) return { error: "La recherche est trop longue (200 caractères max)." };
    return { kind: "query", query: q };
  }
  return { error: "Attendu : { \"query\": \"…\" } ou { \"isbn\": \"…\" }." };
}

// Chaque source a son propre délai ; une erreur ou un dépassement donne [].
async function withSource(
  name: Source,
  run: (signal: AbortSignal) => Promise<BookCandidate[]>,
): Promise<BookCandidate[]> {
  const signal = AbortSignal.timeout(SOURCE_TIMEOUT_MS);
  try {
    return await run(signal);
  } catch (error) {
    console.warn(`search-books: source ${name} ignorée`, String(error));
    return [];
  }
}

async function fetchJson(url: string, signal: AbortSignal): Promise<unknown | null> {
  const res = await fetch(url, { signal, headers: { Accept: "application/json" } });
  if (res.status === 404) {
    await res.body?.cancel();
    return null;
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} sur ${new URL(url).host}`);
  return await res.json();
}

// ---------------------------------------------------------------------------
// ISBN
// ---------------------------------------------------------------------------

function normalizeIsbn(raw: string): { isbn13: string; isbn10: string | null } | null {
  const s = raw.toUpperCase().replace(/[^0-9X]/g, "");
  if (/^\d{13}$/.test(s)) {
    if (isbn13CheckDigit(s.slice(0, 12)) !== s[12]) return null;
    return { isbn13: s, isbn10: isbn13To10(s) };
  }
  if (/^\d{9}[\dX]$/.test(s)) {
    if (isbn10CheckDigit(s.slice(0, 9)) !== s[9]) return null;
    return { isbn13: isbn10To13(s), isbn10: s };
  }
  return null;
}

function isbn13CheckDigit(first12: string): string {
  let sum = 0;
  for (let i = 0; i < 12; i++) sum += Number(first12[i]) * (i % 2 === 0 ? 1 : 3);
  return String((10 - (sum % 10)) % 10);
}

function isbn10CheckDigit(first9: string): string {
  let sum = 0;
  for (let i = 0; i < 9; i++) sum += Number(first9[i]) * (10 - i);
  const check = (11 - (sum % 11)) % 11;
  return check === 10 ? "X" : String(check);
}

function isbn10To13(isbn10: string): string {
  const first12 = "978" + isbn10.slice(0, 9);
  return first12 + isbn13CheckDigit(first12);
}

function isbn13To10(isbn13: string): string | null {
  if (!isbn13.startsWith("978")) return null;
  const first9 = isbn13.slice(3, 12);
  return first9 + isbn10CheckDigit(first9);
}

// Extrait les ISBN valides d'une liste de chaînes, ISBN-13 en premier.
function pickIsbns(values: string[]): { isbn13: string | null; isbn10: string | null } {
  let isbn13: string | null = null;
  let isbn10: string | null = null;
  for (const value of values) {
    const n = normalizeIsbn(value);
    if (!n) continue;
    const digits = value.toUpperCase().replace(/[^0-9X]/g, "");
    if (digits.length === 13) {
      isbn13 ??= n.isbn13;
      isbn10 ??= n.isbn10;
    } else {
      isbn10 ??= n.isbn10;
      isbn13 ??= n.isbn13;
    }
  }
  return { isbn13, isbn10 };
}

// ---------------------------------------------------------------------------
// Nettoyage commun
// ---------------------------------------------------------------------------

function clean(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const s = value.replace(/\s+/g, " ").trim();
  return s === "" ? null : s;
}

function toHttps(url: string | null | undefined): string | null {
  if (!url) return null;
  if (url.startsWith("https://")) return url;
  if (url.startsWith("http://")) return "https://" + url.slice("http://".length);
  if (url.startsWith("//")) return "https:" + url;
  return null;
}

function openLibraryCover(isbn13: string): string {
  return `https://covers.openlibrary.org/b/isbn/${isbn13}-L.jpg?default=false`;
}

const LANGUAGES: Record<string, string> = {
  fre: "fr", fra: "fr", eng: "en", ger: "de", deu: "de", spa: "es", ita: "it",
  por: "pt", dut: "nl", nld: "nl", rus: "ru", jpn: "ja", chi: "zh", zho: "zh",
  ara: "ar", lat: "la", gre: "el", ell: "el", pol: "pl", swe: "sv", dan: "da",
  nor: "no", fin: "fi", cze: "cs", ces: "cs", hun: "hu", rum: "ro", ron: "ro",
  tur: "tr", heb: "he", kor: "ko", cat: "ca", bre: "br", baq: "eu", eus: "eu",
};

function toIso6391(code: string | null | undefined): string | null {
  if (!code) return null;
  const c = code.toLowerCase().replace(/^\/languages\//, "").trim();
  if (/^[a-z]{2}$/.test(c)) return c;
  return LANGUAGES[c] ?? null;
}

// ---------------------------------------------------------------------------
// Google Books
// ---------------------------------------------------------------------------

async function searchGoogle(
  input: SearchInput,
  key: string,
  signal: AbortSignal,
): Promise<BookCandidate[]> {
  const q = input.kind === "isbn" ? `isbn:${input.isbn13}` : input.query;
  const url = new URL("https://www.googleapis.com/books/v1/volumes");
  url.searchParams.set("q", q);
  url.searchParams.set("maxResults", String(MAX_RESULTS));
  url.searchParams.set("printType", "books");
  url.searchParams.set("key", key);

  const data = await fetchJson(url.toString(), signal) as
    | { items?: GoogleVolume[] }
    | null;
  return (data?.items ?? []).flatMap((item) => {
    const c = googleToCandidate(item);
    return c ? [c] : [];
  });
}

interface GoogleVolume {
  id?: string;
  volumeInfo?: {
    title?: string;
    subtitle?: string;
    authors?: string[];
    publisher?: string;
    publishedDate?: string;
    pageCount?: number;
    description?: string;
    language?: string;
    industryIdentifiers?: { type?: string; identifier?: string }[];
    imageLinks?: Record<string, string>;
  };
}

function googleToCandidate(item: GoogleVolume): BookCandidate | null {
  const v = item.volumeInfo;
  const title = clean(v?.title);
  if (!v || !title) return null;

  const ids = v.industryIdentifiers ?? [];
  const { isbn13, isbn10 } = pickIsbns(
    ids.filter((i) => i.type === "ISBN_13" || i.type === "ISBN_10")
      .map((i) => i.identifier ?? ""),
  );

  const links = v.imageLinks ?? {};
  const rawCover = links.large ?? links.medium ?? links.thumbnail ?? links.smallThumbnail;
  const cover = rawCover ? toHttps(rawCover.replace(/&edge=curl/g, "")) : null;

  return {
    isbn13,
    isbn10,
    title,
    subtitle: clean(v.subtitle),
    authors: (v.authors ?? []).map(clean).filter((a): a is string => a !== null),
    publisher: clean(v.publisher),
    // Google renvoie parfois « 2012-02-03T00:00:00+01:00 » : on garde la date.
    published_date: clean(v.publishedDate?.replace(/^(\d{4}-\d{2}-\d{2})T.*$/, "$1")),
    page_count: typeof v.pageCount === "number" && v.pageCount > 0 ? v.pageCount : null,
    description: clean(v.description),
    language: toIso6391(v.language),
    cover_url: cover,
    source: "google",
    source_id: clean(item.id),
  };
}

// ---------------------------------------------------------------------------
// BnF SRU (Dublin Core)
// ---------------------------------------------------------------------------

async function searchBnf(input: SearchInput, signal: AbortSignal): Promise<BookCandidate[]> {
  // La BnF n'indexe souvent que l'ISBN-10 des livres anciens : on interroge
  // les deux formes dans une seule requête.
  const cql = input.kind === "isbn"
    ? [input.isbn13, input.isbn10].filter(Boolean).map((i) => `bib.isbn adj "${i}"`).join(" or ")
    : `bib.anywhere all "${input.query.replace(/["\\]/g, " ")}"`;

  const url = new URL("https://catalogue.bnf.fr/api/SRU");
  url.searchParams.set("version", "1.2");
  url.searchParams.set("operation", "searchRetrieve");
  url.searchParams.set("recordSchema", "dublincore");
  url.searchParams.set("maximumRecords", input.kind === "isbn" ? "5" : "30");
  url.searchParams.set("query", cql);

  const res = await fetch(url.toString(), { signal, headers: { Accept: "application/xml" } });
  if (!res.ok) throw new Error(`HTTP ${res.status} sur catalogue.bnf.fr`);
  const xml = await res.text();

  const records = xml.match(/<srw:record>[\s\S]*?<\/srw:record>/g) ?? [];
  return records.flatMap((record) => {
    const c = bnfToCandidate(record);
    return c ? [c] : [];
  });
}

function dcValues(record: string, tag: string): string[] {
  const re = new RegExp(`<dc:${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</dc:${tag}>`, "g");
  const values: string[] = [];
  for (const m of record.matchAll(re)) {
    const v = clean(decodeXml(m[1]));
    if (v) values.push(v);
  }
  return values;
}

function decodeXml(s: string): string {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function bnfToCandidate(record: string): BookCandidate | null {
  const types = dcValues(record, "type").map((t) => t.toLowerCase());
  if (!types.some((t) => t.includes("texte imprimé"))) return null;

  const rawTitle = dcValues(record, "title")[0];
  if (!rawTitle) return null;
  // « L'étranger / Albert Camus » → titre avant « / », sous-titre après « : ».
  const beforeSlash = rawTitle.split(" / ")[0].trim();
  const colon = beforeSlash.indexOf(" : ");
  const title = clean(colon > 0 ? beforeSlash.slice(0, colon) : beforeSlash);
  const subtitle = colon > 0 ? clean(beforeSlash.slice(colon + 3)) : null;
  if (!title) return null;

  const identifiers = dcValues(record, "identifier");
  const { isbn13, isbn10 } = pickIsbns(
    identifiers.filter((i) => /^ISBN\b/i.test(i)).map((i) => i.replace(/^ISBN\s*/i, "")),
  );
  const ark = identifiers.map((i) => i.match(/ark:\/12148\/[0-9a-z]+/i)?.[0]).find(Boolean) ??
    record.match(/<srw:recordIdentifier>(ark:\/12148\/[0-9a-z]+)<\/srw:recordIdentifier>/i)?.[1] ??
    null;

  const pages = dcValues(record, "format")
    .map((f) => f.match(/(\d+)\s*(?:p\b|p\.|pages)/i)?.[1])
    .find(Boolean);
  const pageCount = pages ? Number(pages) : null;

  const publisher = dcValues(record, "publisher")[0];

  return {
    isbn13,
    isbn10,
    title,
    subtitle,
    authors: dcValues(record, "creator").map(cleanBnfAuthor).filter((a): a is string => !!a),
    publisher: publisher ? cleanBnfPublisher(publisher) : null,
    published_date: clean(dcValues(record, "date")[0]),
    page_count: pageCount && pageCount > 0 ? pageCount : null,
    description: null, // dc:description ne contient que des notes de catalogage
    language: toIso6391(dcValues(record, "language")[0]),
    // Pas de couverture à la BnF : la fusion pose celle d'Open Library.
    cover_url: null,
    source: "bnf",
    source_id: ark,
  };
}

// « Camus, Albert (1913-1960). Auteur du texte » → « Albert Camus »
function cleanBnfAuthor(raw: string): string | null {
  let s = raw;
  // Rôle : après le dernier « . » suivi d'un mot en minuscules (Auteur, Traducteur…).
  s = s.replace(/\.\s+[A-ZÀ-Ý][a-zà-ÿ][^.]*$/, "");
  // Dates de vie : « (1913-1960) », « (1957-....) ».
  s = s.replace(/\s*\([^)]*\)\s*$/, "").trim();
  if (!s) return null;
  const comma = s.indexOf(", ");
  if (comma > 0) {
    s = `${s.slice(comma + 2).trim()} ${s.slice(0, comma).trim()}`;
  }
  return clean(s);
}

// « Gallimard (Paris) » → « Gallimard » ; « [Ray Moore] » → « Ray Moore »
function cleanBnfPublisher(raw: string): string | null {
  const s = raw.replace(/\s*\((?:[^()]|\([^()]*\))*\)\s*$/, "").replace(/^\[(.*)\]$/, "$1");
  return clean(s);
}

// ---------------------------------------------------------------------------
// Open Library
// ---------------------------------------------------------------------------

async function searchOpenLibrary(
  input: SearchInput,
  signal: AbortSignal,
): Promise<BookCandidate[]> {
  return input.kind === "isbn"
    ? await openLibraryByIsbn(input.isbn13, input.isbn10, signal)
    : await openLibraryByQuery(input.query, signal);
}

interface OlEdition {
  key?: string;
  title?: string;
  subtitle?: string;
  authors?: { key?: string }[];
  publishers?: string[];
  publish_date?: string;
  number_of_pages?: number;
  languages?: { key?: string }[];
  covers?: number[];
  isbn_13?: string[];
  isbn_10?: string[];
  description?: string | { value?: string };
}

async function openLibraryByIsbn(
  isbn13: string,
  isbn10: string | null,
  signal: AbortSignal,
): Promise<BookCandidate[]> {
  // La fiche d'édition ne porte souvent pas les noms d'auteurs : on les prend
  // dans la recherche par ISBN, lancée en parallèle.
  const [edition, search] = await Promise.all([
    fetchJson(`https://openlibrary.org/isbn/${isbn13}.json`, signal) as Promise<OlEdition | null>,
    fetchJson(
      `https://openlibrary.org/search.json?isbn=${isbn13}&fields=author_name&limit=1`,
      signal,
    ).catch(() => null) as Promise<{ docs?: { author_name?: string[] }[] } | null>,
  ]);
  const ed = edition ?? (isbn10
    ? await fetchJson(`https://openlibrary.org/isbn/${isbn10}.json`, signal) as OlEdition | null
    : null);
  if (!ed) return [];

  const title = clean(ed.title);
  if (!title) return [];
  const ids = pickIsbns([...(ed.isbn_13 ?? []), ...(ed.isbn_10 ?? [])]);
  const coverId = ed.covers?.find((c) => c > 0);
  const description = typeof ed.description === "string"
    ? ed.description
    : ed.description?.value;

  return [{
    isbn13: ids.isbn13 ?? isbn13,
    isbn10: ids.isbn10 ?? isbn10,
    title,
    subtitle: clean(ed.subtitle),
    authors: (search?.docs?.[0]?.author_name ?? []).map(clean).filter((a): a is string => !!a),
    publisher: clean(ed.publishers?.[0]),
    published_date: clean(ed.publish_date),
    page_count: typeof ed.number_of_pages === "number" && ed.number_of_pages > 0
      ? ed.number_of_pages
      : null,
    description: clean(description),
    language: toIso6391(ed.languages?.[0]?.key),
    cover_url: coverId
      ? `https://covers.openlibrary.org/b/id/${coverId}-L.jpg`
      : openLibraryCover(ids.isbn13 ?? isbn13),
    source: "openlibrary",
    source_id: clean(ed.key?.replace(/^\/books\//, "")),
  }];
}

interface OlSearchDoc {
  key?: string;
  title?: string;
  subtitle?: string;
  author_name?: string[];
  first_publish_year?: number;
  cover_i?: number;
  language?: string[];
  editions?: {
    docs?: {
      key?: string;
      title?: string;
      subtitle?: string;
      isbn?: string[];
      publisher?: string[];
      publish_date?: string[];
      language?: string[];
      cover_i?: number;
    }[];
  };
}

async function openLibraryByQuery(query: string, signal: AbortSignal): Promise<BookCandidate[]> {
  const url = new URL("https://openlibrary.org/search.json");
  url.searchParams.set("q", query);
  url.searchParams.set("limit", String(MAX_RESULTS));
  url.searchParams.set("lang", "fr");
  url.searchParams.set(
    "fields",
    [
      "key", "title", "subtitle", "author_name", "first_publish_year", "cover_i", "language",
      "editions", "editions.key", "editions.title", "editions.subtitle", "editions.isbn",
      "editions.publisher", "editions.publish_date", "editions.language", "editions.cover_i",
    ].join(","),
  );

  const data = await fetchJson(url.toString(), signal) as { docs?: OlSearchDoc[] } | null;
  return (data?.docs ?? []).flatMap((doc) => {
    // L'édition la plus pertinente renvoyée par Open Library, sinon l'œuvre.
    const ed = doc.editions?.docs?.[0];
    const title = clean(ed?.title) ?? clean(doc.title);
    if (!title) return [];
    const ids = pickIsbns(ed?.isbn ?? []);
    const coverId = ed?.cover_i ?? doc.cover_i;
    const cover = coverId && coverId > 0
      ? `https://covers.openlibrary.org/b/id/${coverId}-L.jpg`
      : ids.isbn13
      ? openLibraryCover(ids.isbn13)
      : null;
    const key = ed?.key ?? doc.key;

    return [{
      isbn13: ids.isbn13,
      isbn10: ids.isbn10,
      title: title.replace(/\.$/, ""),
      subtitle: clean(ed ? ed.subtitle : doc.subtitle),
      authors: (doc.author_name ?? []).map(clean).filter((a): a is string => !!a),
      publisher: clean(ed?.publisher?.[0]),
      published_date: clean(ed?.publish_date?.[0]) ??
        (doc.first_publish_year ? String(doc.first_publish_year) : null),
      page_count: null,
      description: null,
      language: toIso6391(ed?.language?.[0] ?? doc.language?.[0]),
      cover_url: cover,
      source: "openlibrary" as const,
      source_id: clean(key?.replace(/^\/(books|works)\//, "")),
    }];
  });
}

// ---------------------------------------------------------------------------
// Fusion
// ---------------------------------------------------------------------------

// Fusionne par ISBN-13. Pour chaque champ, la première source non vide dans
// l'ordre Google > BnF > Open Library l'emporte. L'ordre des résultats suit le
// meilleur rang obtenu dans l'une des sources ; à rang égal, la pertinence de
// Google puis d'Open Library passe avant celle de la BnF, plus faible en texte
// libre (elle classe les études critiques avant l'œuvre).
const RANKING: Record<Source, number> = { google: 0, openlibrary: 1, bnf: 2 };

function merge(bySource: Record<Source, BookCandidate[]>): BookCandidate[] {
  type Group = { rank: number; priority: number; items: BookCandidate[] };
  const groups = new Map<string, Group>();

  PRIORITY.forEach((source) => {
    const priority = RANKING[source];
    bySource[source].forEach((candidate, rank) => {
      const key = candidate.isbn13
        ? `isbn:${candidate.isbn13}`
        : `src:${candidate.source}:${candidate.source_id ?? `${rank}`}`;
      const group = groups.get(key);
      if (group) {
        group.items.push(candidate);
        if (rank < group.rank || (rank === group.rank && priority < group.priority)) {
          group.rank = rank;
          group.priority = priority;
        }
      } else {
        groups.set(key, { rank, priority, items: [candidate] });
      }
    });
  });

  return [...groups.values()]
    .sort((a, b) => a.rank - b.rank || a.priority - b.priority)
    .slice(0, MAX_RESULTS)
    .map(({ items }) => {
      // Les items sont déjà dans l'ordre de priorité des sources.
      const first = <K extends keyof BookCandidate>(field: K): BookCandidate[K] | null => {
        for (const item of items) {
          const v = item[field];
          if (v !== null && v !== undefined && !(Array.isArray(v) && v.length === 0)) return v;
        }
        return null;
      };
      const best = items[0];
      const isbn13 = first("isbn13");
      return {
        isbn13,
        isbn10: first("isbn10"),
        title: best.title,
        subtitle: first("subtitle"),
        authors: first("authors") ?? [],
        publisher: first("publisher"),
        published_date: first("published_date"),
        page_count: first("page_count"),
        description: first("description"),
        language: first("language"),
        cover_url: toHttps(first("cover_url")) ?? (isbn13 ? openLibraryCover(isbn13) : null),
        source: best.source,
        source_id: best.source_id,
      };
    });
}
