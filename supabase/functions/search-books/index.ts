// search-books — recherche de livres pour l'app (contrat : docs/CONTRAT.md)
//
// POST { "query": "camus etranger" } ou { "isbn": "9782070360024" }
// → { "results": BookCandidate[] }, 20 au maximum, sans doublon d'ISBN-13.
//
// Sources interrogées en parallèle, chacune avec son propre délai :
//   - Google Books, seulement si le secret GOOGLE_BOOKS_API_KEY existe ;
//   - Hardcover (GraphQL), seulement si le secret HARDCOVER_API_TOKEN existe ;
//   - BnF SRU en Dublin Core, par ISBN seulement ;
//   - Open Library, par ISBN seulement (et couverture de secours par URL).
// Une source en panne ou trop lente est simplement ignorée.
//
// Par ISBN, les résultats sont fusionnés par ISBN-13 avec la priorité
// Google > Hardcover > BnF > Open Library. En texte, Google et Hardcover seuls,
// avec un délai court, et un score (rank.ts) : roman ou fiction, popularité,
// français, couverture, ISBN, correspondance avec la requête, guides et
// analyses relégués ; les éditions d'une même œuvre sont regroupées.
//
// Cache (docs/CONTRAT.md) :
//   - ISBN : la table books fait foi. Une fiche complète est renvoyée sans
//     appeler les sources ; sinon on les interroge, au plus une fois par
//     30 jours (search_cache « isbn:… »), et on enregistre le résultat avec
//     upsert_book.
//   - Texte : les résultats sont gardés 30 jours dans search_cache (« q:… »).
//   - book_id est posé sur chaque résultat déjà présent dans books.
//
// Limites de débit (docs/CONTRAT.md), comptées dans Postgres :
//   - par utilisateur : chaque appel prend une petite part (cost_cached), un
//     appel qui interroge les sources prend le complément jusqu'à
//     cost_external ; au-delà, HTTP 429 avec Retry-After ;
//   - Hardcover : plafond global d'appels sortants ; une fois atteint, la
//     recherche continue sans Hardcover, et son résultat n'est gardé qu'un jour
//     en cache.

import { fold, type Hit, rankText, type Signals } from "./rank.ts";

type Source = "google" | "hardcover" | "bnf" | "openlibrary";

interface BookCandidate {
  book_id?: string | null;
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
  source: Source | "manual";
  source_id: string | null;
}

type SearchInput = { kind: "isbn"; isbn13: string; isbn10: string | null } | {
  kind: "query";
  query: string;
};

const MAX_RESULTS = 20;
// Par ISBN, on attend les sources lentes (BnF, Open Library) : un scan doit
// trouver le livre. En texte, Google et Hardcover répondent en moins d'une
// seconde d'habitude ; on renvoie ce qui est arrivé à temps.
const ISBN_TIMEOUT_MS = 6000;
const QUERY_TIMEOUT_MS = 3000;
// Candidats demandés à Google en texte : plus que MAX_RESULTS, car les
// éditions d'une même œuvre sont ensuite regroupées.
const GOOGLE_QUERY_RESULTS = 30;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Expose-Headers": "Retry-After",
};

// Verdict de la limite par utilisateur : retryAfter = 0 si l'appel continue,
// sinon le délai Retry-After et la fenêtre pleine.
type RateVerdict = { retryAfter: number; window: "minute" | "day" };
const ALLOWED: RateVerdict = { retryAfter: 0, window: "minute" };

// Limite par utilisateur dépassée : la recherche s'arrête, réponse 429.
class RateLimited extends Error {
  constructor(readonly verdict: RateVerdict) {
    super(`limite de débit (${verdict.window}), réessayer dans ${verdict.retryAfter} s`);
  }
}

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
  const user = await signedInUser(req);
  if (!user) {
    return json({ error: "Session utilisateur requise." }, 401);
  }
  const db = new Db(user, req.headers.get("apikey"));

  // Chaque appel compte, même invalide ou servi par le cache.
  const verdict = await db.rateLimit("request");
  if (verdict.retryAfter > 0) return tooManyRequests(verdict);

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

  try {
    const results = input.kind === "isbn"
      ? await searchByIsbn(input, db)
      : await searchByQuery(input, db);
    return json({ results });
  } catch (error) {
    if (error instanceof RateLimited) return tooManyRequests(error.verdict);
    throw error;
  }
});

function tooManyRequests({ retryAfter, window }: RateVerdict): Response {
  const error = window === "minute"
    ? `Trop de recherches en peu de temps. Réessaie dans ${retryAfter} s.`
    : `Limite de recherches du jour atteinte. Réessaie dans ${formatDelay(retryAfter)}.`;
  console.log(`search-books: limite ${window} atteinte, Retry-After ${retryAfter} s`);
  return json({ error, retry_after: retryAfter }, 429, { "Retry-After": String(retryAfter) });
}

function formatDelay(seconds: number): string {
  if (seconds < 3600) return `${Math.ceil(seconds / 60)} min`;
  const h = Math.floor(seconds / 3600);
  const m = Math.ceil((seconds % 3600) / 60);
  return m === 0 || m === 60 ? `${h + (m === 60 ? 1 : 0)} h` : `${h} h ${m} min`;
}

const CACHE_TTL_MS = 30 * 24 * 3600 * 1000;
const CAPPED_CACHE_TTL_MS = 24 * 3600 * 1000;

async function searchByIsbn(
  input: Extract<SearchInput, { kind: "isbn" }>,
  db: Db,
): Promise<BookCandidate[]> {
  const row = await db.bookByIsbn(input.isbn13);
  if (row && isComplete(row)) {
    console.log("search-books: isbn → books (sans appel externe)");
    return [row];
  }

  // Fiche absente ou incomplète : sources interrogées au plus une fois par TTL.
  const key = `isbn:${input.isbn13}`;
  const cached = await db.readCache(key);
  if (cached !== null) {
    console.log("search-books: isbn → search_cache (sans appel externe)");
    return row ? [row] : await db.annotate(cached);
  }

  const external = await searchExternal(input, db);
  if (external.complete) await db.writeCache(key, external.results, external.cacheTtlMs);
  const found = external.results[0];
  if (!found) return row ? [row] : [];

  // Chaque scan peuple books ; on renvoie la fiche telle qu'enregistrée.
  const id = await db.upsertBook(found);
  const saved = id ? await db.bookById(id) : null;
  return saved ? [saved] : await db.annotate(external.results);
}

async function searchByQuery(
  input: Extract<SearchInput, { kind: "query" }>,
  db: Db,
): Promise<BookCandidate[]> {
  const key = `q:${normalizeQuery(input.query)}`;
  let results = await db.readCache(key);
  if (results !== null) {
    console.log("search-books: query → search_cache (sans appel externe)");
  } else {
    const external = await searchExternal(input, db);
    results = external.results;
    // Un résultat dégradé (source en panne ou trop lente) n'est pas mis en
    // cache. L'écriture se fait après la réponse.
    if (external.complete && results.length > 0) {
      inBackground(db.writeCache(key, results, external.cacheTtlMs));
    }
  }
  return await db.annotate(results);
}

// Laisse une tâche (qui ne lève jamais) se terminer après l'envoi de la
// réponse : EdgeRuntime.waitUntil sur Supabase empêche l'arrêt du worker avant.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

function inBackground(task: Promise<unknown>): void {
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(task);
}

// Clé de cache : minuscules sans accents ni ponctuation.
const normalizeQuery = fold;

function isComplete(b: BookCandidate): boolean {
  return !!b.title && b.authors.length > 0 && !!b.cover_url;
}

// Interroge les sources, après avoir pris la part « externe » de la limite de
// l'utilisateur (RateLimited si elle est dépassée) : les quatre par ISBN,
// Google et Hardcover en texte.
// complete = aucune source activée n'a échoué ni dépassé son délai. Si le
// plafond Hardcover a écarté Hardcover, le résultat reste bon mais n'est gardé
// qu'un jour en cache, pour que Hardcover y figure dès que le plafond est rendu.
async function searchExternal(
  input: SearchInput,
  db: Db,
): Promise<{ results: BookCandidate[]; complete: boolean; cacheTtlMs: number }> {
  const verdict = await db.rateLimit("external");
  if (verdict.retryAfter > 0) throw new RateLimited(verdict);

  const timeout = input.kind === "isbn" ? ISBN_TIMEOUT_MS : QUERY_TIMEOUT_MS;
  const googleKey = Deno.env.get("GOOGLE_BOOKS_API_KEY")?.trim();
  const hardcoverToken = Deno.env.get("HARDCOVER_API_TOKEN")?.trim();
  let hardcoverCapped = false;
  const none = Promise.resolve([] as BookHit[]);
  const [google, hardcover, bnf, openlibrary] = await Promise.all([
    googleKey ? withSource("google", timeout, (s) => searchGoogle(input, googleKey, s)) : none,
    hardcoverToken
      ? db.takeHardcover().then((ok) => {
        if (ok) {
          return withSource("hardcover", timeout, (s) => searchHardcover(input, hardcoverToken, s));
        }
        hardcoverCapped = true;
        return [];
      })
      : none,
    input.kind === "isbn"
      ? withSource("bnf", timeout, (s) => searchBnf(input, s).then(withoutSignals))
      : none,
    input.kind === "isbn"
      ? withSource(
        "openlibrary",
        timeout,
        (s) => openLibraryByIsbn(input.isbn13, input.isbn10, s).then(withoutSignals),
      )
      : none,
  ]);
  const complete = [google, hardcover, bnf, openlibrary].every((r) => r !== null);

  let results: BookCandidate[];
  if (input.kind === "isbn") {
    // Par ISBN, seul le livre demandé compte : Google renvoie parfois des
    // volumes sans ISBN ou voisins pour une requête « isbn: ».
    const keep = (list: BookHit[] | null) =>
      (list ?? []).map((h) => h.candidate).filter((c) => c.isbn13 === input.isbn13);
    results = mergeEditions(
      [...keep(google), ...keep(hardcover), ...keep(bnf), ...keep(openlibrary)],
    );
  } else {
    results = rankText({ google: google ?? [], hardcover: hardcover ?? [] }, input.query)
      .slice(0, MAX_RESULTS)
      .map((group) => withFallbackCover(group.best));
  }
  const n = (r: BookHit[] | null) => (r === null ? "échec" : String(r.length));
  console.log(
    `search-books: ${input.kind} → sources google=${n(google)} ` +
      `hardcover=${hardcoverCapped ? "plafond" : n(hardcover)}` +
      (input.kind === "isbn" ? ` bnf=${n(bnf)} openlibrary=${n(openlibrary)}` : "") +
      ` → ${results.length}`,
  );
  return { results, complete, cacheTtlMs: hardcoverCapped ? CAPPED_CACHE_TTL_MS : CACHE_TTL_MS };
}

// ---------------------------------------------------------------------------
// Base Supabase (PostgREST) : books avec le jeton de l'utilisateur (RLS),
// search_cache et les limites de débit avec la clé service. Une panne de base
// ne bloque jamais la recherche : on se comporte comme sans cache et sans
// limite par utilisateur, mais sans Hardcover (son quota passe avant).
// ---------------------------------------------------------------------------

const BOOK_COLUMNS = "id,isbn13,isbn10,title,subtitle,authors,publisher,published_date," +
  "page_count,description,language,cover_url,source,source_id";

type BookRow = Omit<BookCandidate, "book_id"> & { id: string };

class Db {
  private readonly url = Deno.env.get("SUPABASE_URL") ?? "";
  private readonly serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  private readonly userToken: string;
  private readonly userId: string;
  private readonly anonKey: string;

  constructor(user: SignedInUser, apikey: string | null) {
    this.userToken = user.token;
    this.userId = user.id;
    this.anonKey = apikey ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  }

  private async request(
    path: string,
    init: { method?: string; body?: unknown; service?: boolean; prefer?: string } = {},
  ): Promise<unknown> {
    const key = init.service ? this.serviceKey : this.anonKey;
    const headers: Record<string, string> = {
      apikey: key,
      Authorization: `Bearer ${init.service ? this.serviceKey : this.userToken}`,
      "Content-Type": "application/json",
    };
    if (init.prefer) headers.Prefer = init.prefer;
    const res = await fetch(`${this.url}${path}`, {
      method: init.method ?? "GET",
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`HTTP ${res.status} ${path.split("?")[0]} ${text.slice(0, 200)}`);
    }
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  private async safe<T>(label: string, fn: () => Promise<T>, fallback: T): Promise<T> {
    try {
      return await fn();
    } catch (error) {
      console.warn(`search-books: ${label} impossible`, String(error));
      return fallback;
    }
  }

  bookByIsbn(isbn13: string): Promise<BookCandidate | null> {
    return this.safe("lecture de books", async () => {
      const rows = await this.request(
        `/rest/v1/books?isbn13=eq.${isbn13}&select=${BOOK_COLUMNS}`,
      ) as BookRow[];
      return rows[0] ? rowToCandidate(rows[0]) : null;
    }, null);
  }

  bookById(id: string): Promise<BookCandidate | null> {
    return this.safe("lecture de books", async () => {
      const rows = await this.request(
        `/rest/v1/books?id=eq.${encodeURIComponent(id)}&select=${BOOK_COLUMNS}`,
      ) as BookRow[];
      return rows[0] ? rowToCandidate(rows[0]) : null;
    }, null);
  }

  upsertBook(candidate: BookCandidate): Promise<string | null> {
    return this.safe("upsert_book", async () => {
      const { book_id: _ignored, ...book } = candidate;
      const id = await this.request("/rest/v1/rpc/upsert_book", {
        method: "POST",
        body: { book },
      });
      return typeof id === "string" ? id : null;
    }, null);
  }

  // Pose book_id sur les candidats déjà présents dans books (par ISBN-13, sinon
  // par source et source_id).
  annotate(candidates: BookCandidate[]): Promise<BookCandidate[]> {
    const plain = candidates.map((c) => ({ ...c, book_id: null as string | null }));
    const isbns = [...new Set(plain.map((c) => c.isbn13).filter((i): i is string => !!i))];
    const sourceIds = [
      ...new Set(plain.map((c) => c.source_id).filter((i): i is string => !!i)),
    ];
    if (isbns.length === 0 && sourceIds.length === 0) return Promise.resolve(plain);

    return this.safe("annotation book_id", async () => {
      const quote = (v: string) => `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
      const filters = [];
      if (isbns.length) filters.push(`isbn13.in.(${isbns.map(quote).join(",")})`);
      if (sourceIds.length) filters.push(`source_id.in.(${sourceIds.map(quote).join(",")})`);
      const params = new URLSearchParams({
        select: "id,isbn13,source,source_id",
        or: `(${filters.join(",")})`,
      });
      const rows = await this.request(`/rest/v1/books?${params}`) as {
        id: string;
        isbn13: string | null;
        source: string;
        source_id: string | null;
      }[];
      const byIsbn = new Map(rows.filter((r) => r.isbn13).map((r) => [r.isbn13, r.id]));
      const bySource = new Map(
        rows.filter((r) => r.source_id).map((r) => [`${r.source}|${r.source_id}`, r.id]),
      );
      return plain.map((c) => ({
        ...c,
        book_id: (c.isbn13 ? byIsbn.get(c.isbn13) : undefined) ??
          bySource.get(`${c.source}|${c.source_id}`) ?? null,
      }));
    }, plain);
  }

  // Fonction interne de la base, appelée avec la clé service.
  private serviceRpc(name: string, args: Record<string, unknown>): Promise<unknown> {
    return this.request(`/rest/v1/rpc/${name}`, { method: "POST", service: true, body: args });
  }

  // Limite par utilisateur. Sans clé service (développement local) ou si la
  // base ne répond pas, l'appel passe.
  rateLimit(step: "request" | "external"): Promise<RateVerdict> {
    if (!this.serviceKey) return Promise.resolve(ALLOWED);
    return this.safe(`limite de débit (${step})`, async () => {
      const r = await this.serviceRpc("search_books_rate_limit", {
        p_user: this.userId,
        p_step: step,
      }) as { retry_after?: number; window?: string } | null;
      const retryAfter = typeof r?.retry_after === "number" ? r.retry_after : 0;
      return retryAfter > 0
        ? { retryAfter, window: r?.window === "day" ? "day" : "minute" }
        : ALLOWED;
    }, ALLOWED);
  }

  // Plafond global Hardcover : true si l'appel sortant peut partir (il est
  // alors compté). En cas de doute (base injoignable), on s'en passe.
  takeHardcover(): Promise<boolean> {
    if (!this.serviceKey) return Promise.resolve(true);
    return this.safe("plafond Hardcover", async () => {
      return await this.serviceRpc("hardcover_take", {}) === true;
    }, false);
  }

  readCache(key: string): Promise<BookCandidate[] | null> {
    if (!this.serviceKey) return Promise.resolve(null);
    return this.safe("lecture de search_cache", async () => {
      const since = new Date(Date.now() - CACHE_TTL_MS).toISOString();
      const params = new URLSearchParams({
        query_key: `eq.${key}`,
        created_at: `gte.${since}`,
        select: "results",
      });
      const rows = await this.request(`/rest/v1/search_cache?${params}`, {
        service: true,
      }) as { results: BookCandidate[] }[];
      return rows[0] ? rows[0].results : null;
    }, null);
  }

  // ttlMs < CACHE_TTL_MS : created_at est antidaté pour que l'entrée périme plus tôt.
  async writeCache(key: string, results: BookCandidate[], ttlMs = CACHE_TTL_MS): Promise<void> {
    if (!this.serviceKey) return;
    await this.safe("écriture de search_cache", async () => {
      await this.request("/rest/v1/search_cache", {
        method: "POST",
        service: true,
        prefer: "resolution=merge-duplicates,return=minimal",
        body: {
          query_key: key,
          results: results.map(({ book_id: _ignored, ...c }) => c),
          created_at: new Date(Date.now() - (CACHE_TTL_MS - ttlMs)).toISOString(),
        },
      });
    }, undefined);
  }
}

function rowToCandidate(row: BookRow): BookCandidate {
  const { id, ...book } = row;
  return { book_id: id, ...book };
}

type SignedInUser = { token: string; id: string };

// verify_jwt laisse passer la clé publishable (rôle anon) : on exige en plus
// un jeton de session, validé par Supabase Auth.
async function signedInUser(req: Request): Promise<SignedInUser | null> {
  const token = req.headers.get("Authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
  if (!token || token.split(".").length !== 3) return null;
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const apikey = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !apikey) return null;
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    const user = await res.json() as { id?: string; role?: string };
    return user.id && user.role === "authenticated" ? { token, id: user.id } : null;
  } catch (error) {
    console.warn("search-books: vérification de session impossible", String(error));
    return null;
  }
}

function json(payload: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json; charset=utf-8", ...headers },
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

// Un candidat et les signaux de classement que sa source fournit.
type BookHit = Hit<BookCandidate>;

const withoutSignals = (candidates: BookCandidate[]): BookHit[] =>
  candidates.map((candidate) => ({ candidate, signals: {} }));

// Chaque source a son propre délai ; une erreur ou un dépassement donne null.
async function withSource(
  name: Source,
  timeoutMs: number,
  run: (signal: AbortSignal) => Promise<BookHit[]>,
): Promise<BookHit[] | null> {
  const signal = AbortSignal.timeout(timeoutMs);
  try {
    return await run(signal);
  } catch (error) {
    console.warn(`search-books: source ${name} ignorée`, String(error));
    return null;
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

// Seuls les champs utiles sont demandés : la réponse est plus légère.
const GOOGLE_FIELDS = "items(id,volumeInfo(title,subtitle,authors,publisher,publishedDate," +
  "pageCount,description,language,industryIdentifiers,imageLinks,categories,ratingsCount))";

async function searchGoogle(
  input: SearchInput,
  key: string,
  signal: AbortSignal,
): Promise<BookHit[]> {
  const q = input.kind === "isbn" ? `isbn:${input.isbn13}` : input.query;
  const url = new URL("https://www.googleapis.com/books/v1/volumes");
  url.searchParams.set("q", q);
  url.searchParams.set(
    "maxResults",
    String(input.kind === "isbn" ? MAX_RESULTS : GOOGLE_QUERY_RESULTS),
  );
  url.searchParams.set("printType", "books");
  url.searchParams.set("fields", GOOGLE_FIELDS);
  url.searchParams.set("key", key);

  const data = await fetchJson(url.toString(), signal) as
    | { items?: GoogleVolume[] }
    | null;
  return (data?.items ?? []).flatMap((item) => {
    const candidate = googleToCandidate(item);
    if (!candidate) return [];
    const v = item.volumeInfo;
    const signals: Signals = {
      categories: v?.categories ?? [],
      ratings: typeof v?.ratingsCount === "number" ? v.ratingsCount : 0,
    };
    return [{ candidate, signals }];
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
    categories?: string[];
    ratingsCount?: number;
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
// Hardcover (GraphQL)
// ---------------------------------------------------------------------------
//
// Doc : github.com/hardcoverapp/hardcover-docs (api/Getting-Started.mdx,
// api/guides/Searching.mdx). Le jeton est personnel (scope suffisant :
// read:catalog:search), son quota est partagé par tous les utilisateurs de
// l'app (60 requêtes/min, 5 000/jour en offre gratuite) : chaque appel ne
// fait qu'une requête avec un seul champ racine, qui compte pour 1.

const HARDCOVER_URL = "https://api.hardcover.app/v1/graphql";

const HARDCOVER_EDITION_FIELDS = `
  id isbn_13 isbn_10 title subtitle pages release_date
  image { url }
  publisher { name }
  language { code2 }
  contributions { contribution author { name } }
  book {
    id title subtitle description
    contributions { contribution author { name } }
  }
`;

async function searchHardcover(
  input: SearchInput,
  token: string,
  signal: AbortSignal,
): Promise<BookHit[]> {
  if (input.kind === "isbn") {
    const where = input.isbn10
      ? "{ _or: [{ isbn_13: { _eq: $isbn13 } }, { isbn_10: { _eq: $isbn10 } }] }"
      : "{ isbn_13: { _eq: $isbn13 } }";
    const vars = input.isbn10 ? "$isbn13: String!, $isbn10: String!" : "$isbn13: String!";
    const data = await hardcoverQuery(
      `query EditionByIsbn(${vars}) {
        editions(where: ${where}, limit: 5) { ${HARDCOVER_EDITION_FIELDS} }
      }`,
      input.isbn10 ? { isbn13: input.isbn13, isbn10: input.isbn10 } : { isbn13: input.isbn13 },
      token,
      signal,
    ) as { editions?: HardcoverEdition[] } | null;
    return withoutSignals((data?.editions ?? []).flatMap((e) => {
      const c = hardcoverEditionToCandidate(e);
      return c ? [c] : [];
    }));
  }

  const data = await hardcoverQuery(
    `query SearchBooks($query: String!, $perPage: Int!) {
      search(query: $query, query_type: "Book", per_page: $perPage, page: 1) { results }
    }`,
    { query: input.query, perPage: MAX_RESULTS },
    token,
    signal,
  ) as { search?: { results?: { hits?: { document?: HardcoverSearchDoc }[] } } } | null;
  return (data?.search?.results?.hits ?? []).flatMap((hit) => {
    const d = hit.document;
    const candidate = d ? hardcoverDocToCandidate(d) : null;
    if (!d || !candidate) return [];
    const signals: Signals = {
      genres: [...labels(d.genres), ...labels(d.tags)],
      readers: typeof d.users_count === "number" ? d.users_count : 0,
      compilation: d.compilation === true,
      altTitles: labels(d.alternative_titles),
    };
    return [{ candidate, signals }];
  });
}

async function hardcoverQuery(
  query: string,
  variables: Record<string, unknown>,
  token: string,
  signal: AbortSignal,
): Promise<unknown> {
  const res = await fetch(HARDCOVER_URL, {
    method: "POST",
    signal,
    headers: {
      "Content-Type": "application/json",
      // Le jeton est parfois copié avec son préfixe « Bearer ».
      authorization: /^bearer\s/i.test(token) ? token : `Bearer ${token}`,
      "User-Agent": "reading-tracker search-books (Supabase Edge Function)",
    },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) {
    const remaining = res.headers.get("RateLimit") ?? res.headers.get("X-RateLimit-Remaining");
    await res.body?.cancel();
    throw new Error(`HTTP ${res.status} sur api.hardcover.app` + (remaining ? ` (RateLimit ${remaining})` : ""));
  }
  const payload = await res.json() as { data?: unknown; errors?: { message?: string }[] };
  if (payload.errors?.length) {
    throw new Error(`GraphQL Hardcover : ${payload.errors.map((e) => e.message).join(" ; ")}`);
  }
  return payload.data ?? null;
}

interface HardcoverContribution {
  contribution?: string | null;
  author?: { name?: string } | null;
}

interface HardcoverEdition {
  id?: number;
  isbn_13?: string | null;
  isbn_10?: string | null;
  title?: string | null;
  subtitle?: string | null;
  pages?: number | null;
  release_date?: string | null;
  image?: { url?: string | null } | null;
  publisher?: { name?: string | null } | null;
  language?: { code2?: string | null } | null;
  contributions?: HardcoverContribution[];
  book?: {
    id?: number;
    title?: string | null;
    subtitle?: string | null;
    description?: string | null;
    contributions?: HardcoverContribution[];
  } | null;
}

interface HardcoverSearchDoc {
  id?: number | string;
  title?: string;
  subtitle?: string | null;
  author_names?: string[];
  contributions?: HardcoverContribution[];
  description?: string | null;
  pages?: number | null;
  release_year?: number | null;
  image?: { url?: string | null } | null;
  // Signaux de classement (champs du document de recherche, doc Hardcover
  // api/guides/Searching.mdx) : genres et tags (les 5 premiers), nombre de
  // lecteurs qui ont enregistré le livre, recueil, titres traduits.
  genres?: unknown;
  tags?: unknown;
  users_count?: number | null;
  compilation?: boolean | null;
  alternative_titles?: unknown; // titres de l'œuvre dans d'autres langues
}

// genres et tags : des chaînes, ou des objets { tag } selon les documents.
function labels(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((v) => {
    if (typeof v === "string") return [v];
    const tag = (v as { tag?: unknown; name?: unknown } | null)?.tag ??
      (v as { name?: unknown } | null)?.name;
    return typeof tag === "string" ? [tag] : [];
  });
}

// Auteurs seulement : une contribution vide ou « Author » (pas les traducteurs,
// illustrateurs…).
function hardcoverAuthors(contributions: HardcoverContribution[] | undefined): string[] {
  return (contributions ?? [])
    .filter((c) => !c.contribution || /^author$/i.test(c.contribution))
    .map((c) => clean(c.author?.name))
    .filter((a): a is string => !!a);
}

function hardcoverEditionToCandidate(e: HardcoverEdition): BookCandidate | null {
  const title = clean(e.title) ?? clean(e.book?.title);
  if (!title) return null;
  const ids = pickIsbns([e.isbn_13 ?? "", e.isbn_10 ?? ""]);
  const authors = hardcoverAuthors(e.contributions);
  const language = toIso6391(e.language?.code2);
  return {
    isbn13: ids.isbn13,
    isbn10: ids.isbn10,
    title,
    // Pas de repli sur le sous-titre de l'œuvre : il vient souvent d'une autre
    // langue (L'Étranger : « The Original Unabridged and Complete Edition »).
    subtitle: clean(e.subtitle),
    authors: authors.length ? authors : hardcoverAuthors(e.book?.contributions),
    publisher: clean(e.publisher?.name),
    published_date: clean(e.release_date),
    page_count: typeof e.pages === "number" && e.pages > 0 ? e.pages : null,
    // La description appartient à l'œuvre, pas à l'édition, et sa langue varie
    // (Yoga, édition POL : description en portugais). On ne la garde que pour
    // une édition anglaise, langue habituelle des fiches Hardcover.
    description: language === "en" ? clean(e.book?.description) : null,
    language,
    cover_url: toHttps(e.image?.url),
    source: "hardcover",
    source_id: e.id ? `edition:${e.id}` : null,
  };
}

// Un résultat de recherche est une œuvre, pas une édition : ses ISBN mélangent
// toutes les éditions, on n'en retient donc aucun.
function hardcoverDocToCandidate(d: HardcoverSearchDoc): BookCandidate | null {
  const title = clean(d.title);
  if (!title) return null;
  const authors = hardcoverAuthors(d.contributions);
  return {
    isbn13: null,
    isbn10: null,
    title,
    subtitle: clean(d.subtitle),
    authors: authors.length
      ? authors
      : (d.author_names ?? []).map(clean).filter((a): a is string => !!a),
    publisher: null,
    published_date: d.release_year ? String(d.release_year) : null,
    page_count: typeof d.pages === "number" && d.pages > 0 ? d.pages : null,
    description: clean(d.description),
    language: null,
    cover_url: toHttps(d.image?.url),
    source: "hardcover",
    source_id: d.id !== undefined && d.id !== null ? `book:${d.id}` : null,
  };
}

// ---------------------------------------------------------------------------
// BnF SRU (Dublin Core)
// ---------------------------------------------------------------------------

// Par ISBN seulement : en texte libre, la BnF est lente (2 à 7 s) et classe
// mal (disques, études critiques avant l'œuvre).
async function searchBnf(
  input: Extract<SearchInput, { kind: "isbn" }>,
  signal: AbortSignal,
): Promise<BookCandidate[]> {
  // La BnF n'indexe souvent que l'ISBN-10 des livres anciens : on interroge
  // les deux formes dans une seule requête.
  const cql = [input.isbn13, input.isbn10].filter(Boolean)
    .map((i) => `bib.isbn adj "${i}"`).join(" or ");

  const url = new URL("https://catalogue.bnf.fr/api/SRU");
  url.searchParams.set("version", "1.2");
  url.searchParams.set("operation", "searchRetrieve");
  url.searchParams.set("recordSchema", "dublincore");
  url.searchParams.set("maximumRecords", "5");
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
// Open Library (par ISBN seulement : en texte, search.json met 2 à 60 s)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Fusion par ISBN
// ---------------------------------------------------------------------------

// Fusionne les fiches d'une même édition (même ISBN-13), données dans l'ordre
// de priorité Google > Hardcover > BnF > Open Library : pour chaque champ, la
// première source non vide l'emporte.
function mergeEditions(items: BookCandidate[]): BookCandidate[] {
  const best = items[0];
  if (!best) return [];
  const first = <K extends keyof BookCandidate>(field: K): BookCandidate[K] | null => {
    for (const item of items) {
      const v = item[field];
      if (v !== null && v !== undefined && !(Array.isArray(v) && v.length === 0)) return v;
    }
    return null;
  };
  return [withFallbackCover({
    isbn13: first("isbn13"),
    isbn10: first("isbn10"),
    title: best.title,
    subtitle: first("subtitle"),
    authors: first("authors") ?? [],
    publisher: first("publisher"),
    published_date: first("published_date"),
    page_count: first("page_count"),
    description: first("description"),
    language: first("language"),
    cover_url: first("cover_url"),
    source: best.source,
    source_id: best.source_id,
  })];
}

// Couverture en https, sinon celle d'Open Library par ISBN.
function withFallbackCover(c: BookCandidate): BookCandidate {
  return {
    ...c,
    cover_url: toHttps(c.cover_url) ?? (c.isbn13 ? openLibraryCover(c.isbn13) : null),
  };
}
