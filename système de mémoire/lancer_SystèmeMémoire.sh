#!/bin/bash
# === 🚀 Lanceur d'IA avec Contrôle Dynamique de Mémoire ===
# Ce script applique une heuristique mathématique pour gérer la mémoire de contexte d'un LLM local.
# Il se base sur la distance de Levenshtein, les conjectures de Collatz et Goldbach ainsi qu'une
# version opérationnelle de l'hypothèse de Riemann. L'objectif est d'élargir ou de réduire la
# mémoire de la conversation de manière intelligente pour qu'un modèle de langage local maintienne le
# contexte sans déborder sa fenêtre de prompt.

# -----------------------------------------------------------------------------
# Sécurité et gestion des erreurs
# Sort en cas d'erreurs, de variables indéfinies et d'échecs dans les pipelines. Une fonction de nettoyage
# est toujours appelée à la sortie pour supprimer les fichiers temporaires.
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 Configuration
# Ajustez ces chemins si votre installation diffère. Le modèle doit être au
# format GGUF et compatible avec llama-cli.
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/mistral-7b-instruct-v0.1.Q6_K.gguf"

# Fichiers de travail
PROMPT_FILE="mémoire/instruction.txt"
MEMORY_FILE="mémoire/mémoire.txt"
LOG_FILE="journaux/système_mémoire.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# Paramètres heuristiques
TOKENS_MAX=4096            # longueur maximale du contexte pour llama-cli
FRAGMENT_SIZE=800         # taille en octets pour découper lors de la sélection des fragments

# Marqueurs de fichiers temporaires (initialisés dans execute())
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 Assistant de journalisation
# Écrit un message informatif dans le journal avec un horodatage. Les messages sont
# simultanément envoyés à stdout pour la visibilité de l'utilisateur et ajoutés au fichier journal.
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ Validation de l'environnement
# Assure que tous les fichiers, permissions et commandes externes nécessaires sont présents.
validate() {
  log_info "Validation de l'environnement et des dépendances…"

  # Vérifier que les fichiers de prompt et de mémoire existent ; sinon, les créer avec
  # des commentaires appropriés pour éviter de casser le script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "Création du fichier manquant : $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERREUR] Permissions de lecture/écriture insuffisantes sur $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # S'assurer que le répertoire des journaux existe
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Vérifier le binaire llama-cli
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERREUR] Binaire llama-cli non trouvé ou non exécutable dans $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Vérifier la lisibilité du fichier modèle
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERREUR] Le fichier du modèle n'est pas lisible : $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Vérifier que les commandes externes requises sont disponibles
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERREUR] Commande requise non trouvée : $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "Validation de l'environnement terminée avec succès."
}

# -----------------------------------------------------------------------------
# 🧠 Sélection de fragments (Levenshtein simplifiée)
# Étant donné un fichier texte en entrée, crée deux fichiers contenant les fragments les plus uniques et les plus
# communs. Par simplicité, cette implémentation ne calcule pas une véritable
# distance de Levenshtein – elle choisit le premier et le dernier fragment après découpage.
# Paramètres : $1 – fichier d'entrée à analyser
# $2 – fichier de sortie pour le fragment unique
# $3 – fichier de sortie pour le fragment commun
levenshtein_fragment_selector() {
  local input_file="$1"
  local output_unique="$2"
  local output_common="$3"

  # Si le fichier d'entrée est manquant ou vide, créer des sorties vides et retourner
  if [[ ! -s "$input_file" ]]; then
    : > "$output_unique"
    : > "$output_common"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Découper l'entrée en fragments binaires de FRAGMENT_SIZE octets
  split -b "$FRAGMENT_SIZE" "$input_file" "$tmp_dir/frag_" || true

  # Déterminer les noms de fragments lexicographiquement premiers et derniers
  local first_fragment last_fragment
  first_fragment=$(ls "$tmp_dir" | sort | head -n1 || true)
  last_fragment=$(ls "$tmp_dir" | sort | tail -n1 || true)

  # Copier le premier fragment vers la sortie unique
  if [[ -n "$first_fragment" ]]; then
    cat "$tmp_dir/$first_fragment" > "$output_unique"
  else
    : > "$output_unique"
  fi

  # Copier le dernier fragment vers la sortie commune (si différent)
  if [[ -n "$last_fragment" && "$last_fragment" != "$first_fragment" ]]; then
    cat "$tmp_dir/$last_fragment" > "$output_common"
  else
    : > "$output_common"
  fi

  rm -rf "$tmp_dir"
}

# -----------------------------------------------------------------------------
# 📈 Contrôle de mémoire de Collatz
# Élargit ou réduit le fichier de mémoire selon que le total est pair/impair. Si le
# total est pair, les 4 dernières lignes sont conservées. S'il est impair, seule la
# moitié la plus récente des lignes est conservée.
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Étape de Collatz : total pair → élargissement de la mémoire (conservation des 4 dernières interactions)"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Étape de Collatz : total impair → réduction de la mémoire (conservation des $lines_to_keep dernières lignes)"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 Vérification de nombres premiers
# Retourne 0 si le nombre fourni est premier, 1 sinon. Utilisé par Goldbach.
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 Division de Goldbach
# Divise le fichier de mémoire en deux fragments de longueur première dont la somme est
# le nombre total de lignes. Le fragment correspondant au plus grand premier est
# conservé.
goldbach_split() {
  local memory_file="$1"
  local total_lines
  total_lines=$(wc -l < "$memory_file" || echo 0)

  # S'il y a moins de 2 lignes, rien à faire
  if (( total_lines < 2 )); then
    return
  fi

  for (( i=2; i<total_lines; i++ )); do
    local j=$(( total_lines - i ))
    if is_prime "$i" && is_prime "$j"; then
      if (( j > i )); then
        log_info "Étape de Goldbach : conservation des $j dernières lignes (plus grand premier)"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Étape de Goldbach : conservation des $i premières lignes (plus grand premier)"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Expansion de Riemann
# Lorsque le fichier de mémoire est réduit à une seule ligne, récupère la moitié du
# message précédent depuis la sauvegarde pour fournir un contexte supplémentaire. Conceptuellement,
# la mémoire reste considérée comme une unité.
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Étape de Riemann : mémoire réduite à 1 ligne, récupération du contexte depuis la sauvegarde"
    if [[ -f "$backup_file" ]]; then
      # Ajouter la ligne précédente depuis la sauvegarde (avant-dernière ligne)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 Exécution du modèle
# Construit un prompt temporaire à partir du prompt de base et des fragments sélectionnés, exécute
# llama-cli et met à jour le fichier de mémoire. Applique ensuite les heuristiques de Collatz,
# Goldbach et Riemann à la mémoire.
execute() {
  log_info "Sélection des fragments sémantiques de la mémoire…"
  # Créer des fichiers temporaires pour les fragments uniques et communs
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # Générer les fragments sémantiques depuis la mémoire existante
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "Préparation du prompt temporaire…"
  # Combiner le prompt avec les fragments sélectionnés
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "Lancement de llama-cli…"
  local session_output
  session_output=$(mktemp)
  # Exécuter le modèle ; ajouter la sortie au journal et la capturer pour mettre à jour la mémoire
  "$LLAMA_CLI" --model "$MODEL_FILE" \
    --prompt-file "$TEMP_PROMPT" \
    --color \
    --temp 0.7 \
    --top-k 40 \
    --top-p 0.9 \
    --repeat-penalty 1.1 \
    --n-predict 200 \
    --ctx-size "$TOKENS_MAX" \
    2>&1 | tee -a "$LOG_FILE" | tee "$session_output" | tee >(tail -n 50 >> "$MEMORY_FILE") >/dev/null

  log_info "Exécution du modèle terminée. Mise à jour de la mémoire…"
  # Enregistrer la dernière entrée utilisateur et la réponse de l'assistant pour la traçabilité
  local user_line ia_line
  user_line=$(tail -n 1 "$PROMPT_FILE" || echo "")
  ia_line=$(tail -n 1 "$session_output" || echo "")
  echo "Utilisateur : $user_line" >> "$MEMORY_FILE"
  echo "Assistant : $ia_line" >> "$MEMORY_FILE"

  # Sauvegarder la mémoire avant modifications
  cp "$MEMORY_FILE" "$BACKUP_FILE" || true

  # Déterminer la longueur logique : entrée de base + réponse + indicateurs signalant si
  # les fichiers unique/commun sont non vides
  local logical_length=2
  [[ -s "$UNIQUE_FILE" ]] && (( logical_length+=1 ))
  [[ -s "$COMMON_FILE" ]] && (( logical_length+=1 ))
  log_info "Longueur logique pour Collatz = $logical_length"

  # Appliquer les heuristiques de Collatz, Goldbach et Riemann
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "Session terminée avec succès."
  # Nettoyer les fichiers temporaires créés dans execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 Nettoyage
# Supprime tous les fichiers temporaires créés pendant l'exécution du script. Cette fonction
# sera invoquée automatiquement à la sortie via le trap défini au début.
cleanup() {
  # Supprimer les fichiers de prompt temporaire et de fragments s'ils existent
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # Supprimer tous les fichiers temporaires égarés restants (meilleur effort)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 Point d'entrée
main() {
  validate
  execute
}

main "$@"
