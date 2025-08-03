#!/bin/bash
# === 🚀 Lanzador de IA con Control Dinámico de Memoria ===
# Este script aplica una heurística matemática para gestionar la memoria de contexto de un LLM local.
# Se basa en la distancia de Levenshtein, las conjeturas de Collatz y Goldbach y una
# versión operacional de la hipótesis de Riemann.  El objetivo es expandir o contraer la
# memoria de la conversación de forma inteligente para que un modelo de lenguaje local mantenga el
# contexto sin desbordar su ventana de prompt.

# -----------------------------------------------------------------------------
# Seguridad y manejo de errores
# Se sale al producirse errores, variables indefinidas y fallos en tuberías.  Una función de limpieza
# siempre se llama al salir para eliminar archivos temporales.
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 Configuración
# Ajusta estas rutas si tu instalación difiere.  El modelo debe estar en
# formato GGUF y ser compatible con llama-cli.
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# Archivos de trabajo
PROMPT_FILE="memoria/indicacion.txt"
MEMORY_FILE="memoria/memoria.txt"
LOG_FILE="registros/sistema_memoria.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# Parámetros heurísticos
TOKENS_MAX=4096            # maximum context length for llama-cli
FRAGMENT_SIZE=800         # size in bytes for splitting when selecting fragments

# Marcadores de archivos temporales (inicializados en execute())
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 Ayudante de registro
# Escribe un mensaje informativo en el registro con una marca de tiempo.  Los mensajes son
# simultáneamente enviados a stdout para visibilidad del usuario y añadidos al archivo de registro.
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ Validación del entorno
# Asegura que todos los archivos, permisos y comandos externos necesarios están presentes.
validate() {
  log_info "Validando el entorno y las dependencias…"

  # # Check prompt and memory files exist; if they do not, create them with
  # # appropriate comments to avoid breaking the script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "Creando archivo faltante: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] Permisos de lectura/escritura insuficientes en $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # # Check llama-cli binary
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] Binario llama-cli no encontrado o no ejecutable en $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Check model file readability
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] El archivo del modelo no es legible: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Verify required external commands are available
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] Comando requerido no encontrado: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "Validación del entorno completada correctamente."
}

# -----------------------------------------------------------------------------
# 🧠 Selección de fragmentos (Levenshtein simplificada)
# Dado un archivo de texto de entrada, crea dos archivos que contienen los fragmentos más únicos y más
# comunes.  Por simplicidad esta implementación no calcula una verdadera
# distancia de Levenshtein – elige el primer y el último fragmento después de dividir.
# Parámetros: $1 – archivo de entrada a analizar
# $2 – archivo de salida para el fragmento único
# $3 – archivo de salida para el fragmento común
levenshtein_fragment_selector() {
  local input_file="$1"
  local output_unique="$2"
  local output_common="$3"

  # # If the input file is missing or empty, create empty outputs and return
  if [[ ! -s "$input_file" ]]; then
    : > "$output_unique"
    : > "$output_common"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  # # Split the input into binary fragments of FRAGMENT_SIZE bytes
  split -b "$FRAGMENT_SIZE" "$input_file" "$tmp_dir/frag_" || true

  # # Determine the lexicographically first and last fragment names
  local first_fragment last_fragment
  first_fragment=$(ls "$tmp_dir" | sort | head -n1 || true)
  last_fragment=$(ls "$tmp_dir" | sort | tail -n1 || true)

  # # Copy the first fragment to the unique output
  if [[ -n "$first_fragment" ]]; then
    cat "$tmp_dir/$first_fragment" > "$output_unique"
  else
    : > "$output_unique"
  fi

  # # Copy the last fragment to the common output (if different)
  if [[ -n "$last_fragment" && "$last_fragment" != "$first_fragment" ]]; then
    cat "$tmp_dir/$last_fragment" > "$output_common"
  else
    : > "$output_common"
  fi

  rm -rf "$tmp_dir"
}

# -----------------------------------------------------------------------------
# 📈 Control de memoria de Collatz
# Expande o contrae el archivo de memoria según si el total es par/impar.  Si el
# total es par, se conservan las últimas 4 líneas.  Si es impar, solo las más recientes
# mitad de las líneas se conservan.
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Paso de Collatz: total par → expandiendo la memoria (manteniendo las últimas 4 interacciones)"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Paso de Collatz: total impar → contrayendo la memoria (manteniendo las últimas $lines_to_keep líneas)"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 Comprobación de primos
# Devuelve 0 si el número proporcionado es primo, 1 en caso contrario.  Utilizado por Goldbach.
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 División de Goldbach
# Divide el archivo de memoria en dos fragmentos de longitud prima cuya suma es
# el número total de líneas.  El fragmento correspondiente al primo mayor es
# conservado.
goldbach_split() {
  local memory_file="$1"
  local total_lines
  total_lines=$(wc -l < "$memory_file" || echo 0)

  # # If there are fewer than 2 lines, nothing to do
  if (( total_lines < 2 )); then
    return
  fi

  for (( i=2; i<total_lines; i++ )); do
    local j=$(( total_lines - i ))
    if is_prime "$i" && is_prime "$j"; then
      if (( j > i )); then
        log_info "Paso de Goldbach: manteniendo las últimas $j líneas (primo mayor)"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Paso de Goldbach: manteniendo las primeras $i líneas (primo mayor)"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Expansión de Riemann
# Cuando el archivo de memoria se reduce a una sola línea, recupera la mitad de la
# mensaje anterior de la copia de seguridad para proporcionar contexto adicional.  Conceptualmente
# la memoria sigue considerándose una unidad.
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Paso de Riemann: memoria reducida a 1 línea, recuperando contexto de la copia de seguridad"
    if [[ -f "$backup_file" ]]; then
      # # Append the previous line from the backup (second to last line)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 Ejecución del modelo
# Construye un prompt temporal a partir del prompt base y los fragmentos seleccionados, ejecuta
# llama-cli y actualiza el archivo de memoria.  Luego aplica las heurísticas de Collatz,
# Goldbach y Riemann a la memoria.
execute() {
  log_info "Seleccionando fragmentos semánticos de la memoria…"
  # # Create temporary files for unique and common fragments
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # # Generate the semantic fragments from the existing memory
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "Preparando el prompt temporal…"
  # # Combine the prompt with the selected fragments
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "Lanzando llama-cli…"
  local session_output
  session_output=$(mktemp)
  # # Execute the model; append output to log and capture it to update memory
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

  log_info "Ejecución del modelo completada. Actualizando la memoria…"
  # # Record the last user input and assistant response for traceability
  local user_line ia_line
  user_line=$(tail -n 1 "$PROMPT_FILE" || echo "")
  ia_line=$(tail -n 1 "$session_output" || echo "")
  echo "User: $user_line" >> "$MEMORY_FILE"
  echo "Assistant: $ia_line" >> "$MEMORY_FILE"

  # # Backup memory before modifications
  cp "$MEMORY_FILE" "$BACKUP_FILE" || true

  # # Determine logical length: base input + response + flags indicating whether
  # # the unique/common files are non‑empty
  local logical_length=2
  [[ -s "$UNIQUE_FILE" ]] && (( logical_length+=1 ))
  [[ -s "$COMMON_FILE" ]] && (( logical_length+=1 ))
  log_info "Longitud lógica para Collatz = $logical_length"

  # # Apply Collatz, Goldbach and Riemann heuristics
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "Sesión finalizada con éxito."
  # # Clean temporary files created within execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 Limpieza
# Elimina cualquier archivo temporal creado durante la ejecución del script.  Esta función
# será invocada automáticamente al salir mediante el trap definido al inicio.
cleanup() {
  # # Remove temporary prompt and fragment files if they exist
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # # Remove any stray temporary files left behind (best effort)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 Punto de entrada
main() {
  validate
  execute
}

main "$@"
