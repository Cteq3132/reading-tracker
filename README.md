# Unshelf

App iOS (SwiftUI, Liquid Glass) qui aide à faire baisser sa PAL (pile à lire) : suivre ce qui
entre et ce qui sort, piocher sa prochaine lecture, se fixer un objectif, et voir les progrès de
ses amis. Backend Supabase. Le dépôt garde le nom technique `reading-tracker`.

Le contrat entre le backend et l'app est dans [docs/CONTRAT.md](docs/CONTRAT.md).

## Lancer l'app

1. Copier `ios/Config/Secrets.example.xcconfig` en `ios/Config/Secrets.xcconfig`, puis y mettre
   l'hôte de votre projet Supabase et sa clé publishable.
2. Ouvrir `ios/ReadingTracker.xcodeproj` dans Xcode (iOS 26 minimum).
3. L'argument de lancement `-demo` affiche des données d'exemple, sans réseau.

## CI et TestFlight

Chaque PR est compilée par GitHub Actions ; chaque fusion sur `main` part sur TestFlight.
Mise en place côté Apple et secrets à poser : [docs/CI.md](docs/CI.md).

## Backend

Le schéma est dans `supabase/migrations/`, la fonction de recherche dans
`supabase/functions/search-books/`. `supabase/tests/verify_backend.py` rejoue les vérifications
contre un vrai projet ; il lit `SUPABASE_URL` et `SUPABASE_PUBLISHABLE_KEY` dans l'environnement
ou dans `.env.local`.

## Licence

[GNU AGPL v3](LICENSE).
