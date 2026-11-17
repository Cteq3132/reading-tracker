#!/usr/bin/env bash
# Écrit ios/Config/Secrets.xcconfig à partir de SUPABASE_HOST et SUPABASE_PUBLISHABLE_KEY.
#
# Usage : .github/scripts/write-secrets-xcconfig.sh [--allow-placeholder]
#
# Avec --allow-placeholder, des valeurs factices remplacent les secrets absents (PR venant
# d'un fork, secrets pas encore posés) : l'app compile, mais ne pourra pas joindre Supabase.
# Sans cette option, un secret absent arrête le job avec un message explicite.
#
# Les valeurs ne sont jamais affichées.
set -euo pipefail

out="ios/Config/Secrets.xcconfig"
host="${SUPABASE_HOST:-}"
key="${SUPABASE_PUBLISHABLE_KEY:-}"

if [[ -z "$host" || -z "$key" ]]; then
  if [[ "${1:-}" == "--allow-placeholder" ]]; then
    echo "::notice::Secrets Supabase absents : compilation avec des valeurs factices."
    host="ci-placeholder.supabase.co"
    key="sb_publishable_ci_placeholder"
  else
    [[ -n "$host" ]] || echo "::error::Secret SUPABASE_HOST manquant (voir docs/CI.md)."
    [[ -n "$key" ]] || echo "::error::Secret SUPABASE_PUBLISHABLE_KEY manquant (voir docs/CI.md)."
    exit 1
  fi
fi

# Dans un .xcconfig, « // » ouvre un commentaire : l'hôte doit être nu, sans schéma ni chemin.
if [[ "$host" == */* || "$host" =~ [[:space:]] ]]; then
  echo "::error::SUPABASE_HOST doit être un hôte nu (ex. abcd.supabase.co), sans https://, chemin ni espace."
  exit 1
fi
if [[ "$key" == */* || "$key" =~ [[:space:]] ]]; then
  echo "::error::SUPABASE_PUBLISHABLE_KEY contient un « / » ou un espace : vérifier la valeur du secret."
  exit 1
fi

printf 'SUPABASE_HOST = %s\nSUPABASE_PUBLISHABLE_KEY = %s\n' "$host" "$key" > "$out"
echo "$out écrit."
