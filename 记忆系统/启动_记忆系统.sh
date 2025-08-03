#!/bin/bash
# === 🚀 动态内存控制的 AI 启动器 ===
# 此脚本应用数学启发式来管理本地 LLM 的上下文记忆。
# 它基于莱文斯坦距离、Collatz 和 Goldbach 猜想以及
# 里曼假设的操作版本。目标是智能地扩展或收缩
# 会话记忆，使本地语言模型能够保持相关
# 上下文而不会溢出其提示窗口。

# -----------------------------------------------------------------------------
# 安全性与错误处理
# 我们在出现错误、未定义变量或管道失败时退出。
# 退出时始终调用 cleanup 函数以删除临时文件。
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 配置
# 如果你的安装路径不同，请调整这些路径。模型必须是
# GGUF 格式并与 llama-cli 兼容。
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# 工作文件
PROMPT_FILE="记忆/提示.txt"
MEMORY_FILE="记忆/记忆.txt"
LOG_FILE="日志/记忆系统.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# 启发式参数
TOKENS_MAX=4096            # maximum context length for llama-cli
FRAGMENT_SIZE=800         # size in bytes for splitting when selecting fragments

# 临时文件占位符（在 execute() 中初始化）
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 日志助手
# 写入带时间戳的日志信息。消息同时
# 输出到标准输出供用户查看，并追加到日志文件。
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ 环境验证
# 确保所有必需的文件、权限和外部命令都存在。
validate() {
  log_info "正在验证环境和依赖项…"

  # # Check prompt and memory files exist; if they do not, create them with
  # # appropriate comments to avoid breaking the script.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "正在创建缺失的文件: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] 读/写权限不足: $f" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # # Check llama-cli binary
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] 在指定路径未找到或不可执行 llama-cli 二进制文件: $LLAMA_CLI" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Check model file readability
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] 模型文件不可读取: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # # Verify required external commands are available
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] 未找到所需命令: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "环境验证成功完成。"
}

# -----------------------------------------------------------------------------
# 🧠 片段选择（简化莱文斯坦）
# 给定一个输入文本文件，创建包含最独特和最常见片段的两个文件。
# 为简单起见，此实现不计算真正的莱文斯坦距离，
# 而是在分割后选择第一个和最后一个片段。
# 参数：$1 – 要分析的输入文件
# $2 – 唯一片段的输出文件
# $3 – 常见片段的输出文件
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
# 📈 Collatz 内存控制
# 根据总数的奇偶扩展或收缩内存文件。
# 如果总数为偶数，保留最后 4 行；如果为奇数，
# 仅保留最近一半的行。
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Collatz 步骤：总数为偶数 → 扩展内存（保留最后 4 次互动）"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Collatz 步骤：总数为奇数 → 收缩内存（保留最后 $lines_to_keep 行）"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 素数检查
# 如果提供的数字是素数，则返回 0，否则返回 1。用于 Goldbach。
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 Goldbach 拆分
# 将内存文件拆分为两个素数长度的块，它们的长度之和为
# 总行数。保留对应较大素数的片段。
# 
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
        log_info "Goldbach 步骤：保留最后 $j 行（较大素数）"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Goldbach 步骤：保留最前面的 $i 行（较大素数）"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Riemann 扩展
# 当内存文件减少到一行时，从备份中恢复上一条消息的一半，
# 以提供额外的上下文。从概念上讲
# 内存仍然被视为一个单元。
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Riemann 步骤：内存减少到 1 行，从备份恢复上下文"
    if [[ -f "$backup_file" ]]; then
      # # Append the previous line from the backup (second to last line)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 模型执行
# 从基础提示和选定片段构建临时提示，运行
# llama-cli 并更新内存文件。然后应用 Collatz、
# Goldbach 和 Riemann 启发式方法到内存。
execute() {
  log_info "从记忆中选择语义片段…"
  # # Create temporary files for unique and common fragments
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # # Generate the semantic fragments from the existing memory
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "准备临时提示…"
  # # Combine the prompt with the selected fragments
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "启动 llama-cli…"
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

  log_info "模型执行完成。正在更新内存…"
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
  log_info "Collatz 的逻辑长度 = $logical_length"

  # # Apply Collatz, Goldbach and Riemann heuristics
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "会话成功结束。"
  # # Clean temporary files created within execute()
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 清理
# 删除脚本执行期间创建的任何临时文件。
# 此函数将在退出时由顶部定义的 trap 自动触发。
cleanup() {
  # # Remove temporary prompt and fragment files if they exist
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # # Remove any stray temporary files left behind (best effort)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 入口点
main() {
  validate
  execute
}

main "$@"
