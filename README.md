# reading-tracker

App iOS (SwiftUI, Liquid Glass) de suivi de lectures : lectures en cours, PAL, livres lus,
et un volet social pour suivre ses amis. Backend Supabase.

Le contrat entre le backend et l'app est dans [docs/CONTRAT.md](docs/CONTRAT.md).

## Lancer l'app

1. Copier `ios/Config/Secrets.example.xcconfig` en `ios/Config/Secrets.xcconfig`, puis y mettre
   l'hôte de votre projet Supabase et sa clé publishable.
2. Ouvrir `ios/ReadingTracker.xcodeproj` dans Xcode (iOS 26 minimum).
3. L'argument de lancement `-demo` affiche des données d'exemple, sans réseau.

## Backend

Le schéma est dans `supabase/migrations/`, la fonction de recherche dans
`supabase/functions/search-books/`. `supabase/tests/verify_backend.py` rejoue les vérifications
contre un vrai projet ; il lit `SUPABASE_URL` et `SUPABASE_PUBLISHABLE_KEY` dans l'environnement
ou dans `.env.local`.

## Licence

[GNU AGPL v3](LICENSE).
