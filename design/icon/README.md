# Icône d'Unshelf

Sources de l'icône iOS 26 (Liquid Glass) de l'app.

- `concepts/gen.py` génère les calques SVG de chaque piste (canevas 1024 × 1024, formes blanches
  sur fond transparent, sans fond ni effet : Icon Composer s'en charge).
- `build.py <dossier-concept>` assemble un document Icon Composer (`AppIcon.icon` : `icon.json`
  et `Assets/`) puis le rend avec `ictool`, le moteur d'Icon Composer livré avec Xcode, dans
  `out/<concept>/` (clair, sombre, teinté, transparent ; 1024, 180 et 60 px).
- `out/` est un dossier de travail, ignoré par git.

```bash
python3 concepts/gen.py
python3 build.py concepts/a-etagere
```

Trois pistes ont été explorées (`pistes.png`) : A · L'étagère, B · Le U serre-livres, C · La pile.
**A a été retenue.** Pour la régénérer et la remettre dans l'app :

```bash
python3 concepts/gen.py
python3 build.py concepts/a-etagere
rm -r ../../ios/ReadingTracker/AppIcon.icon
cp -R out/a-etagere/AppIcon.icon ../../ios/ReadingTracker/AppIcon.icon
```

L'icône de l'app est `ios/ReadingTracker/AppIcon.icon`, nommée par
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Xcode en tire aussi les images des versions
d'iOS antérieures.
