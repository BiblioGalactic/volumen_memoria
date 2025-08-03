#!/bin/bash
# === 🚀 動的メモリ制御付き AI ランチャー ===
# このスクリプトは、数学的なヒューリスティックを適用してローカル LLM のコンテキストメモリを管理します。
# これはレーベンシュタイン距離、コラッツ予想とゴールドバッハ予想、および
# リーマン予想の運用版に基づいています。目的は会話メモリを拡張または縮小し、
# ローカル言語モデルが関連するコンテキストを維持できるようにすることです。
# プロンプトウィンドウをオーバーフローさせることなく。

# -----------------------------------------------------------------------------
# 安全性とエラー処理
# エラー、未定義変数、パイプラインの失敗時には終了します。終了時には
# 常にクリーンアップ関数が呼ばれ、一時ファイルを削除します。
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 設定
# インストール環境が異なる場合はこれらのパスを調整してください。モデルは
# GGUF 形式で llama-cli と互換性がある必要があります。
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# 作業ファイル
PROMPT_FILE="記憶/プロンプト.txt"
MEMORY_FILE="記憶/記憶.txt"
LOG_FILE="ログ/記憶システム.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# ヒューリスティックのパラメータ
TOKENS_MAX=4096            # maximum context length for llama-cli
FRAGMENT_SIZE=800         # size in bytes for splitting when selecting fragments

# 一時ファイルのプレースホルダー（execute() で初期化）
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 ログ出力ヘルパー
# タイムスタンプ付きで情報メッセージをログに書き込みます。メッセージは
# ユーザーへの可視化のために標準出力にも出力され、ログファイルにも追記されます。
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ 環境の検証
# 必要なファイル、権限、外部コマンドが揃っていることを確認します。
validate() {
  log_info "環境と依存関係を検証しています…"

  # # Check prompt and memory files exist; if they do not, create them with
  # # appropriate comments to avoid breaking the script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "欠落しているファイルを作成中: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] 読み書き権限が不足しています: $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # # Check llama-cli binary
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] llama-cli バイナリが見つからないか実行できません: $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Check model file readability
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] モデルファイルが読み取れません: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Verify required external commands are available
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] 必要なコマンドが見つかりません: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "環境の検証が正常に完了しました。"
}

# -----------------------------------------------------------------------------
# 🧠 フラグメント選択（簡易レーベンシュタイン）
# 入力テキストファイルから最もユニークな断片と最も共通する断片を含む 2 つのファイルを作成します。
# 簡略化のため、この実装は実際のレーベンシュタイン距離を計算せず、
# 分割後の最初と最後の断片を選択します。
# パラメータ: $1 – 解析する入力ファイル
# $2 – ユニークな断片の出力ファイル
# $3 – 共通断片の出力ファイル
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
# 📈 コラッツメモリ制御
# 偶数/奇数の合計に基づいてメモリファイルを拡張または縮小します。
# 合計が偶数の場合は最後の 4 行を保持します。奇数の場合は最新の
# 行の半分のみ保持します。
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "コラッツステップ: 合計が偶数 → メモリを拡張（最後の 4 つのやり取りを保持）"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "コラッツステップ: 合計が奇数 → メモリを縮小（最後の $lines_to_keep 行を保持）"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 素数チェック
# 与えられた数が素数なら 0 を、そうでなければ 1 を返します。ゴールドバッハで使用します。
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 ゴールドバッハ分割
# メモリファイルを 2 つの素数長のチャンクに分割し、それらの長さの和が
# 全体の行数になるようにします。大きい素数に対応する断片が
# 保持されます。
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
        log_info "ゴールドバッハステップ: 最後の $j 行を保持（大きい素数）"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "ゴールドバッハステップ: 最初の $i 行を保持（大きい素数）"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 リーマン展開
# メモリファイルが 1 行になると、バックアップから前のメッセージの半分を復元し、
# 追加のコンテキストを提供します。概念的には
# メモリはまだ 1 つのユニットと見なされます。
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "リーマンステップ: メモリが 1 行に縮小、バックアップからコンテキストを復元"
    if [[ -f "$backup_file" ]]; then
      # # Append the previous line from the backup (second to last line)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 モデル実行
# 基本プロンプトと選択された断片から一時的なプロンプトを作成し、
# llama-cli を実行してメモリファイルを更新します。その後コラッツ、
# ゴールドバッハ、リーマンのヒューリスティックをメモリに適用します。
execute() {
  log_info "メモリから意味的な断片を選択しています…"
  # # Create temporary files for unique and common fragments
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # # Generate the semantic fragments from the existing memory
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "一時プロンプトを準備しています…"
  # # Combine the prompt with the selected fragments
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "llama-cli を起動しています…"
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

  log_info "モデルの実行が完了しました。メモリを更新しています…"
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
  log_info "コラッツの論理長 = $logical_length"

  # # Apply Collatz, Goldbach and Riemann heuristics
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "セッションが正常に終了しました。"
  # # Clean temporary files created within execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 クリーンアップ
# スクリプト実行中に作成された一時ファイルを削除します。この関数は
# 冒頭で定義された trap により終了時に自動的に呼び出されます。
cleanup() {
  # # Remove temporary prompt and fragment files if they exist
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # # Remove any stray temporary files left behind (best effort)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 エントリーポイント
main() {
  validate
  execute
}

main "$@"
