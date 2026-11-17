# CI : compilation et envoi sur TestFlight

Deux workflows GitHub Actions, dans `.github/workflows/` :

| Workflow | Quand | Ce qu'il fait |
| --- | --- | --- |
| `ios-build` | chaque PR, chaque push sur `main` | Résout les paquets SPM (avec cache) et compile l'app pour le simulateur, sans signature. |
| `testflight` | chaque push sur `main` (donc chaque PR fusionnée), et à la main | Archive l'app, la signe automatiquement avec une clé d'API App Store Connect, puis l'envoie sur App Store Connect, d'où elle part dans TestFlight. |

Les deux tournent sur l'image GitHub `xcode-27` (macOS 27, arm64) avec **Xcode 27.2**, épinglé
par `xcode-select` (SDK iOS 27.2) : la même version qu'en local. Leurs étapes communes (Xcode,
`Secrets.xcconfig`, paquets SPM) sont dans l'action locale `.github/actions/setup-ios`.

Cette image est encore en **préversion publique**
([annonce](https://github.com/actions/runner-images/issues/14404)) : files d'attente
possibles, et son label changera sans doute à son passage en version stable (un job qui
reste « Queued » indéfiniment en est le signe). Repli possible : l'image stable `macos-26`
avec Xcode 26.6. Pour changer, modifier `xcode-version` dans
`.github/actions/setup-ios/action.yml` et `runs-on` dans les deux workflows ; les versions
installées par image sont dans
[actions/runner-images](https://github.com/actions/runner-images/tree/main/images/macos).
Le dépôt étant public, les runners macOS sont gratuits.

Le numéro de build envoyé est `github.run_number` du workflow `testflight` ; la version
affichée (`MARKETING_VERSION`, 0.1 aujourd'hui) se règle dans le projet Xcode.

## Ce qu'il reste à faire, dans l'ordre

### 1. Abonnement Apple Developer

S'inscrire à l'[Apple Developer Program](https://developer.apple.com/programs/enroll/)
(abonnement annuel payant). Sans lui, ni TestFlight ni clé d'API.

### 2. Ajouter une icône d'app (bloquant)

L'app n'a pas encore d'icône : le catalogue `ios/ReadingTracker/Resources/Assets.xcassets` ne
contient qu'`AccentColor`. Apple l'exige pour toute distribution par l'App Store
([Configuring your app icon](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)),
et l'envoi sera refusé à la validation tant qu'elle manque. Il faut ajouter un ensemble
`AppIcon` avec une image 1024 × 1024 px, et `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`
dans les réglages de la cible.

### 3. Enregistrer le bundle id

Sur [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) :
**Identifiers** → **+** → **App IDs** → **App**, puis :

- Description : `reading-tracker` ;
- Bundle ID : **Explicit**, `fr.dachet.readingtracker` ;
- aucune capability à cocher (la caméra ne demande qu'un texte d'usage, déjà présent).

### 4. Créer la fiche App Store Connect

Sur [App Store Connect](https://appstoreconnect.apple.com/apps) : **Apps** → **+** →
**New App** :

- Platforms : iOS ;
- Name : un nom provisoire (il doit être libre sur l'App Store ; il reste modifiable jusqu'à
  la soumission d'une version) ;
- Primary Language : French ;
- Bundle ID : `fr.dachet.readingtracker` ;
- SKU : un identifiant interne libre, par exemple `reading-tracker` ;
- User Access : Full Access.

### 5. Créer la clé d'API App Store Connect

1. Si c'est la première clé du compte, le titulaire du compte (Account Holder) demande
   l'accès à l'API : **Users and Access** → **Integrations** → **Request Access**.
   Apple valide la demande au cas par cas.
2. **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys** →
   **Generate API Key** (ou **+**).
3. Name : `GitHub Actions`. Access : **Admin**.
4. **Download** : le fichier `AuthKey_XXXXXXXXXX.p8` ne se télécharge qu'une fois. Le garder
   hors du dépôt.
5. Noter le **Key ID** (colonne de la clé) et l'**Issuer ID** (au-dessus du tableau).

Pourquoi **Admin** : la signature automatique en CI crée les certificats et profils de
distribution. D'après le
[tableau des rôles Apple](https://developer.apple.com/help/account/access/roles/), seuls
Account Holder et Admin ont ces droits d'office ; App Manager ne les a que par une
autorisation donnée à un utilisateur, qu'une clé d'API ne peut pas recevoir, et Developer ne
les a pas. Le rôle d'une clé ne se modifie pas : pour en changer, révoquer la clé et en
générer une autre.

### 6. Trouver le Team ID

Sur [developer.apple.com/account](https://developer.apple.com/account), section
**Membership details** : **Team ID**, 10 caractères.

### 7. Poser les six secrets GitHub

Depuis la racine du dépôt, avec `gh` connecté au compte qui possède le dépôt. Chaque valeur
est saisie sans écho et passe par l'entrée standard, jamais en argument de commande :

```bash
for name in ASC_KEY_ID ASC_ISSUER_ID APPLE_TEAM_ID; do printf '%s : ' "$name"; read -rs value; echo; printf '%s' "$value" | gh secret set "$name"; done; unset value
```

La clé `.p8`, encodée en base64 (commande macOS ; adapter le chemin du fichier téléchargé) :

```bash
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8_BASE64
```

Les deux secrets Supabase, en saisie masquée :

```bash
for name in SUPABASE_HOST SUPABASE_PUBLISHABLE_KEY; do printf '%s : ' "$name"; read -rs value; echo; printf '%s' "$value" | gh secret set "$name"; done; unset value
```

Ou, plus simple, en les reprenant du `ios/Config/Secrets.xcconfig` local (à lancer depuis le
dossier où ce fichier existe) :

```bash
for name in SUPABASE_HOST SUPABASE_PUBLISHABLE_KEY; do value=$(sed -n "s/^$name *= *//p" ios/Config/Secrets.xcconfig | tr -d '[:space:]'); if [ -n "$value" ]; then printf '%s' "$value" | gh secret set "$name"; else echo "$name absent de ios/Config/Secrets.xcconfig"; fi; done; unset value
```

La boucle refuse de poser un secret vide, ce que `gh secret set` accepterait sans rien dire.

`SUPABASE_HOST` est l'hôte seul (`abcd.supabase.co`), sans `https://`. Vérifier que les six
noms sont présents :

```bash
gh secret list
```

Le fichier `.p8` peut ensuite être rangé dans un gestionnaire de mots de passe et supprimé de
`~/Downloads`.

### 8. Lancer le premier build

Le workflow `testflight` part tout seul à chaque fusion sur `main`. Pour le lancer à la main
(une fois les workflows présents sur `main` ; il refuse toute autre branche) :

```bash
gh workflow run testflight --ref main
```

```bash
gh run watch
```

Si un secret manque, le job **Vérifier les secrets** le nomme. En lancement manuel il échoue ;
sur un push sur `main`, il saute l'envoi avec un avertissement, pour que `main` reste vert
tant que le compte Apple n'est pas prêt.

### 9. Retrouver l'app dans TestFlight

App Store Connect → **Apps** → l'app → onglet **TestFlight**. Le build apparaît sous
**iOS Builds** avec le statut *Processing*, puis devient disponible après le traitement par
Apple (de quelques minutes à une heure environ ; un email l'annonce).

Pour l'installer : créer un groupe sous **Internal Testing**, s'y ajouter (les testeurs
internes sont des membres de l'équipe App Store Connect), puis ouvrir l'app TestFlight sur
l'iPhone avec le même identifiant Apple. Les testeurs externes demandent en plus une revue
de la bêta par Apple et des informations de test.

## Conformité

### Chiffrement

`ios/Config/Info.plist` déclare `ITSAppUsesNonExemptEncryption = NO`. Apple demande `NO`
quand l'app, bibliothèques tierces comprises, n'utilise pas de chiffrement ou seulement un
chiffrement exempté, et cite comme exemple typique les connexions HTTPS faites avec
`URLSession`
([ITSAppUsesNonExemptEncryption](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption),
[Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)).
C'est le cas ici : l'app ne fait que du HTTPS vers Supabase et les sources de livres, et
`supabase-swift` (2.55.7) n'utilise `swift-crypto` que pour le hachage SHA-256 du PKCE.
Avec cette clé, App Store Connect ne pose plus le questionnaire d'export à chaque build.
C'est une déclaration légale : à revoir si une dépendance ajoute un chiffrement propre.

### Confidentialité

- **Privacy manifest** : pas nécessaire aujourd'hui. Apple refuse les envois qui utilisent
  une API « required reason » sans la déclarer
  ([Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)).
  Dans l'app, la seule est `UserDefaults`, dans `AppConfig.demoReading`, sous `#if DEBUG` :
  elle n'existe pas dans le build Release envoyé. Les sources des paquets SPM résolus ne les
  appellent pas, et `swift-crypto` et `swift-asn1` livrent leur propre manifest. Si du code
  Release se met à utiliser `UserDefaults` ou `@AppStorage`, ajouter un
  `PrivacyInfo.xcprivacy` avec `NSPrivacyAccessedAPICategoryUserDefaults` et la raison
  `CA92.1` (données lues et écrites par l'app seule).
- **App Privacy** (fiche App Store Connect) : à remplir avant la soumission sur l'App Store.
  L'app collecte un email, un nom d'utilisateur et des données de lecture, liés au compte.
- **Suppression de compte** : l'App Store exige qu'une app qui permet de créer un compte
  permette aussi de le supprimer depuis l'app. À prévoir avant la soumission, pas pour
  TestFlight en interne.

## Points d'attention

- **Relancer un run déjà envoyé échoue** : le numéro de build `github.run_number` reste le
  même et App Store Connect refuse un numéro déjà utilisé. Lancer un nouveau run à la place.
- **Certificats** : la signature automatique crée au besoin des certificats sur le compte.
  Si Xcode signale un nombre maximal de certificats atteint, révoquer les anciens dans
  Certificates, Identifiers & Profiles.
- **Secrets et logs** : GitHub masque la valeur des secrets dans les logs, et aucune étape ne
  les affiche. La clé `.p8` est décodée dans `$RUNNER_TEMP` puis supprimée en fin de job,
  même en cas d'échec.
- **PR venant d'un fork** : les secrets n'y sont pas transmis ; `ios-build` compile alors
  avec des valeurs Supabase factices. `testflight` ne tourne jamais sur une PR.
