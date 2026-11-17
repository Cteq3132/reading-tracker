-- Purge des recherches texte de search_cache (docs/CONTRAT.md).
--
-- La recherche texte de search-books change de sources (Google et Hardcover
-- seuls) et de classement (score : roman, popularité, français…). Les entrées
-- « q:… » gardent l'ancien classement jusqu'à 30 jours : on les supprime, elles
-- se reconstruisent à la prochaine recherche. Les entrées « isbn:… » restent :
-- la recherche par ISBN ne change pas.
--
-- À appliquer après le déploiement de la nouvelle fonction (sinon l'ancienne
-- peut remettre des entrées entre les deux).

delete from public.search_cache where query_key like 'q:%';
