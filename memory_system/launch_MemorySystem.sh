#!/bin/bash
# === 🚀 AI Launcher with Dynamic Memory Control ===
# This script applies a mathematical heuristic to manage the context memory of a local LLM.
# It is based on the Levenshtein distance, the Collatz and Goldbach conjectures and an
# operational version of the Riemann hypothesis.  The goal is to expand or contract the
# conversation memory intelligently so that a local language model can maintain relevant
# context without overflowing its prompt window.

# -----------------------------------------------------------------------------
# Safety and error handling
# We exit on error, undefined variables and pipeline failures.  A cleanup
# function is always called on exit to remove temporary files.
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 Configuration
# Adjust these paths if your installation differs.  The model must be in
# GGUF format and compatible with llama-cli.
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# Working files
PROMPT_FILE="memory/prompt.txt"
MEMORY_FILE="memory/memory.txt"
LOG_FILE="logs/memory_system.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# Heuristic parameters
TOKENS_MAX=4096            # maximum context length for llama-cli
FRAGMENT_SIZE=800         # size in bytes for splitting when selecting fragments

# Temporary file placeholders (initialised in execute())
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 Logging helper
# Writes an informational message to the log with a timestamp.  Messages are
# simultaneously sent to stdout for user visibility and appended to the log file.
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ Environment validation
# Ensures all required files, permissions and external commands are present.
validate() {
  log_info "Validating environment and dependencies…"

  # Check prompt and memory files exist; if they do not, create them with
  # appropriate comments to avoid breaking the script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "Creating missing file: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] Insufficient read/write permissions on $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Check llama-cli binary
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] llama-cli binary not found or not executable at $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Check model file readability
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] Model file is not readable: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Verify required external commands are available
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] Required command not found: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "Environment validation completed successfully."
}

# -----------------------------------------------------------------------------
# 🧠 Fragment selection (simplified Levenshtein)
# Given an input text file, creates two files containing the most unique and most
# common fragments.  For simplicity this implementation does not compute a real
# Levenshtein distance – it picks the first and last fragments after splitting.
# Parameters: $1 – input file to analyse
#             $2 – output file for the unique fragment
#             $3 – output file for the common fragment
levenshtein_fragment_selector() {
  local input_file="$1"
  local output_unique="$2"
  local output_common="$3"

  # If the input file is missing or empty, create empty outputs and return
  if [[ ! -s "$input_file" ]]; then
    : > "$output_unique"
    : > "$output_common"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Split the input into binary fragments of FRAGMENT_SIZE bytes
  split -b "$FRAGMENT_SIZE" "$input_file" "$tmp_dir/frag_" || true

  # Determine the lexicographically first and last fragment names
  local first_fragment last_fragment
  first_fragment=$(ls "$tmp_dir" | sort | head -n1 || true)
  last_fragment=$(ls "$tmp_dir" | sort | tail -n1 || true)

  # Copy the first fragment to the unique output
  if [[ -n "$first_fragment" ]]; then
    cat "$tmp_dir/$first_fragment" > "$output_unique"
  else
    : > "$output_unique"
  fi

  # Copy the last fragment to the common output (if different)
  if [[ -n "$last_fragment" && "$last_fragment" != "$first_fragment" ]]; then
    cat "$tmp_dir/$last_fragment" > "$output_common"
  else
    : > "$output_common"
  fi

  rm -rf "$tmp_dir"
}

# -----------------------------------------------------------------------------
# 📈 Collatz memory control
# Expands or contracts the memory file based on an even/odd total.  If the
# total is even, the last 4 lines are kept.  If odd, only the most recent
# half of the lines are retained.
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Collatz step: even total → expanding memory (keeping last 4 interactions)"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Collatz step: odd total → contracting memory (keeping last $lines_to_keep lines)"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 Prime check
# Returns 0 if the provided number is prime, 1 otherwise.  Used by Goldbach.
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 Goldbach split
# Splits the memory file into two prime‑length chunks whose lengths add up to
# the total number of lines.  The fragment corresponding to the larger prime is
# retained.
goldbach_split() {
  local memory_file="$1"
  local total_lines
  total_lines=$(wc -l < "$memory_file" || echo 0)

  # If there are fewer than 2 lines, nothing to do
  if (( total_lines < 2 )); then
    return
  fi

  for (( i=2; i<total_lines; i++ )); do
    local j=$(( total_lines - i ))
    if is_prime "$i" && is_prime "$j"; then
      if (( j > i )); then
        log_info "Goldbach step: keeping the last $j lines (larger prime)"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Goldbach step: keeping the first $i lines (larger prime)"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Riemann expansion
# When the memory file collapses to a single line, recovers half of the
# previous message from a backup to provide additional context.  Conceptually
# the memory is still considered one unit.
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Riemann step: memory reduced to 1 line, recovering context from backup"
    if [[ -f "$backup_file" ]]; then
      # Append the previous line from the backup (second to last line)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 Model execution
# Builds a temporary prompt from the base prompt and selected fragments, runs
# llama-cli and updates the memory file.  It then applies the Collatz,
# Goldbach and Riemann heuristics to the memory.
execute() {
  log_info "Selecting semantic fragments from memory…"
  # Create temporary files for unique and common fragments
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # Generate the semantic fragments from the existing memory
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "Preparing temporary prompt…"
  # Combine the prompt with the selected fragments
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "Launching llama-cli…"
  local session_output
  session_output=$(mktemp)
  # Execute the model; append output to log and capture it to update memory
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

  log_info "Model execution completed. Updating memory…"
  # Record the last user input and assistant response for traceability
  local user_line ia_line
  user_line=$(tail -n 1 "$PROMPT_FILE" || echo "")
  ia_line=$(tail -n 1 "$session_output" || echo "")
  echo "User: $user_line" >> "$MEMORY_FILE"
  echo "Assistant: $ia_line" >> "$MEMORY_FILE"

  # Backup memory before modifications
  cp "$MEMORY_FILE" "$BACKUP_FILE" || true

  # Determine logical length: base input + response + flags indicating whether
  # the unique/common files are non‑empty
  local logical_length=2
  [[ -s "$UNIQUE_FILE" ]] && (( logical_length+=1 ))
  [[ -s "$COMMON_FILE" ]] && (( logical_length+=1 ))
  log_info "Logical length for Collatz = $logical_length"

  # Apply Collatz, Goldbach and Riemann heuristics
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "Session finished successfully."
  # Clean temporary files created within execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 Cleanup
# Removes any temporary files created during script execution.  This function
# will be triggered automatically on exit via the trap defined at the top.
cleanup() {
  # Remove temporary prompt and fragment files if they exist
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # Remove any stray temporary files left behind (best effort)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 Entry point
main() {
  validate
  execute
}

main "$@"
