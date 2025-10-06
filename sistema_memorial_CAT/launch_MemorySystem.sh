#!/bin/bash
# === 🚀 Llançador d'IA amb Control Dinàmic de Memòria ===
# Aquest script aplica una heurística matemàtica per gestionar la memòria de context d'un LLM local.
# Es basa en la distància de Levenshtein, les conjectures de Collatz i Goldbach i una
# versió operacional de la hipòtesi de Riemann. L'objectiu és expandir o contraure la
# memòria de conversa intel·ligentment perquè un model de llenguatge local pugui mantenir el context
# rellevant sense desbordar la seva finestra de prompt.

# -----------------------------------------------------------------------------
# Seguretat i gestió d'errors
# Sortim en cas d'error, variables no definides i fallades en pipelines. Una funció de neteja
# sempre s'executa en sortir per eliminar fitxers temporals.
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 Configuració
# Ajusta aquests camins si la teva instal·lació difereix. El model ha d'estar en
# format GGUF i ser compatible amb llama-cli.
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# Fitxers de treball
PROMPT_FILE="memory/prompt.txt"
MEMORY_FILE="memory/memory.txt"
LOG_FILE="logs/memory_system.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# Paràmetres heurístics
TOKENS_MAX=4096            # longitud màxima de context per llama-cli
FRAGMENT_SIZE=800         # mida en bytes per dividir quan se seleccionen fragments

# Marcadors de fitxers temporals (inicialitzats a execute())
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 Ajudant de registre
# Escriu un missatge informatiu al registre amb marca de temps. Els missatges són
# simultàniament enviats a stdout per visibilitat de l'usuari i afegits al fitxer de registre.
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ Validació d'entorn
# Assegura que tots els fitxers, permisos i comandes externes requerits estan presents.
validate() {
  log_info "Validant entorn i dependències…"

  # Comprova que els fitxers de prompt i memòria existeixen; si no, crea'ls amb
  # comentaris apropiats per evitar trencar l'script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "Creant fitxer absent: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] Permisos de lectura/escriptura insuficients a $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # Assegura que el directori de registres existeix
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Comprova el binari llama-cli
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] Binari llama-cli no trobat o no executable a $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Comprova la llegibilitat del fitxer de model
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] El fitxer de model no és llegible: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Verifica que les comandes externes requerides estan disponibles
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] Comanda requerida no trobada: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "Validació d'entorn completada amb èxit."
}

# -----------------------------------------------------------------------------
# 🧠 Selecció de fragments (Levenshtein simplificat)
# Donat un fitxer de text d'entrada, crea dos fitxers que contenen els fragments més únics i més
# comuns. Per simplicitat aquesta implementació no calcula una distància de Levenshtein real –
# tria els primers i últims fragments després de dividir.
# Paràmetres: $1 – fitxer d'entrada a analitzar
#             $2 – fitxer de sortida pel fragment únic
#             $3 – fitxer de sortida pel fragment comú
levenshtein_fragment_selector() {
  local input_file="$1"
  local output_unique="$2"
  local output_common="$3"

  # Si el fitxer d'entrada està absent o buit, crea sortides buides i retorna
  if [[ ! -s "$input_file" ]]; then
    : > "$output_unique"
    : > "$output_common"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Divideix l'entrada en fragments binaris de FRAGMENT_SIZE bytes
  split -b "$FRAGMENT_SIZE" "$input_file" "$tmp_dir/frag_" || true

  # Determina els noms dels fragments lexicogràficament primers i últims
  local first_fragment last_fragment
  first_fragment=$(ls "$tmp_dir" | sort | head -n1 || true)
  last_fragment=$(ls "$tmp_dir" | sort | tail -n1 || true)

  # Copia el primer fragment a la sortida única
  if [[ -n "$first_fragment" ]]; then
    cat "$tmp_dir/$first_fragment" > "$output_unique"
  else
    : > "$output_unique"
  fi

  # Copia l'últim fragment a la sortida comuna (si és diferent)
  if [[ -n "$last_fragment" && "$last_fragment" != "$first_fragment" ]]; then
    cat "$tmp_dir/$last_fragment" > "$output_common"
  else
    : > "$output_common"
  fi

  rm -rf "$tmp_dir"
}

# -----------------------------------------------------------------------------
# 📈 Control de memòria Collatz
# Expandeix o contrau el fitxer de memòria basat en un total parell/senar. Si el
# total és parell, es mantenen les últimes 4 línies. Si és senar, només es reté
# la meitat més recent de les línies.
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Pas Collatz: total parell → expandint memòria (mantenint últimes 4 interaccions)"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Pas Collatz: total senar → contraient memòria (mantenint últimes $lines_to_keep línies)"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 Comprovació de primer
# Retorna 0 si el número proporcionat és primer, 1 altrament. Usat per Goldbach.
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 Divisió Goldbach
# Divideix el fitxer de memòria en dos trossos de longitud primera les longituds dels quals sumen
# el nombre total de línies. Es reté el fragment corresponent al primer més gran.
goldbach_split() {
  local memory_file="$1"
  local total_lines
  total_lines=$(wc -l < "$memory_file" || echo 0)

  # Si hi ha menys de 2 línies, no cal fer res
  if (( total_lines < 2 )); then
    return
  fi

  for (( i=2; i<total_lines; i++ )); do
    local j=$(( total_lines - i ))
    if is_prime "$i" && is_prime "$j"; then
      if (( j > i )); then
        log_info "Pas Goldbach: mantenint les últimes $j línies (primer més gran)"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Pas Goldbach: mantenint les primeres $i línies (primer més gran)"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Expansió Riemann
# Quan el fitxer de memòria col·lapsa a una sola línia, recupera la meitat del
# missatge anterior d'una còpia de seguretat per proporcionar context addicional. Conceptualment
# la memòria encara es considera una unitat.
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Pas Riemann: memòria reduïda a 1 línia, recuperant context de la còpia de seguretat"
    if [[ -f "$backup_file" ]]; then
      # Afegeix la línia anterior de la còpia de seguretat (penúltima línia)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 Execució del model
# Construeix un prompt temporal des del prompt base i fragments seleccionats, executa
# llama-cli i actualitza el fitxer de memòria. Després aplica les heurístiques de Collatz,
# Goldbach i Riemann a la memòria.
execute() {
  log_info "Seleccionant fragments semàntics de la memòria…"
  # Crea fitxers temporals per fragments únics i comuns
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # Genera els fragments semàntics de la memòria existent
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "Preparant prompt temporal…"
  # Combina el prompt amb els fragments seleccionats
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "Llançant llama-cli…"
  local session_output
  session_output=$(mktemp)
  # Executa el model; afegeix sortida al registre i captura-la per actualitzar memòria
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

  log_info "Execució del model completada. Actualitzant memòria…"
  # Registra l'última entrada de l'usuari i resposta de l'assistent per traçabilitat
  local user_line ia_line
  user_line=$(tail -n 1 "$PROMPT_FILE" || echo "")
  ia_line=$(tail -n 1 "$session_output" || echo "")
  echo "Usuari: $user_line" >> "$MEMORY_FILE"
  echo "Assistent: $ia_line" >> "$MEMORY_FILE"

  # Còpia de seguretat de la memòria abans de modificacions
  cp "$MEMORY_FILE" "$BACKUP_FILE" || true

  # Determina longitud lògica: entrada base + resposta + indicadors si els
  # fitxers únic/comú estan no-buits
  local logical_length=2
  [[ -s "$UNIQUE_FILE" ]] && (( logical_length+=1 ))
  [[ -s "$COMMON_FILE" ]] && (( logical_length+=1 ))
  log_info "Longitud lògica per Collatz = $logical_length"

  # Aplica heurístiques de Collatz, Goldbach i Riemann
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "Sessió finalitzada amb èxit."
  # Neteja fitxers temporals creats dins d'execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 Neteja
# Elimina qualsevol fitxer temporal creat durant l'execució de l'script. Aquesta funció
# s'activarà automàticament en sortir via el trap definit al principi.
cleanup() {
  # Elimina fitxers temporals de prompt i fragments si existeixen
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # Elimina qualsevol fitxer temporal extraviats (millor esforç)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 Punt d'entrada
main() {
  validate
  execute
}

main "$@"