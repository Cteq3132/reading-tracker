# Icône d'Unshelf

Sources de l'icône iOS 26 (Liquid Glass) de l'app.

- `concepts/gen.py` génère les calques SVG de chaque piste (canevas 1024 × 1024, formes blanches
  sur fond transparent, sans fond ni effet : Icon Composer s'en charge).
- `build.py <dossier-piste>` assemble un document Icon Composer (`AppIcon.icon` : `icon.json`
  et `Assets/`) puis le rend avec `ictool`, le moteur d'Icon Composer livré avec Xcode, dans
  `out/<piste>/` (clair, sombre, teinté, transparent en 1024 px ; clair et sombre en 180 et 60 px).
  `--install` copie aussi le `.icon` dans l'app.
- `out/` est un dossier de travail, ignoré par git.

Trois pistes ont été explorées (`pistes.png`, colonne « Teinté » rendue avec une teinte orange) :
A · L'étagère, B · Le U serre-livres, C · La pile. **A a été retenue.**

Pour la régénérer et la remettre dans l'app, depuis la racine du dépôt :

```bash
python3 design/icon/concepts/gen.py
python3 design/icon/build.py design/icon/concepts/a-etagere --install
```

L'icône de l'app est `ios/ReadingTracker/AppIcon.icon`, nommée par
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. La variante teintée est dérivée par le système.
