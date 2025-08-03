# Collatz‑Conjecture Memory System for Local LLMs

This package demonstrates how to apply a mathematical heuristic to manage context memory for a local
language model (via [llama.cpp](https://github.com/ggerganov/llama.cpp)).  The system prevents
context‑window overflow while preserving relevant conversation.

## Included files

| File / Directory            | Description                                                                                               |
|-----------------------------|-----------------------------------------------------------------------------------------------------------|
| `launch_MemorySystem.sh`    | Bash script that launches the local LLM with memory control and automatic cleanup.                        |
| `memory/theorem.txt`        | Full explanation of the heuristic combining Levenshtein distance, the Collatz and Goldbach conjectures,
                              | and the operational Riemann hypothesis.                                                                  |
| `memory/prompt.txt`         | Initial prompt defining the assistant’s name and role.                                                    |
| `memory/memory.txt`         | File where the dynamic conversation memory is stored.  Updated automatically on each run.                |
| `logs/`                     | Directory where execution logs are written. The main log is `memory_system.log`.                         |

## Requirements

* A Unix‑like environment with **bash** and standard utilities `split`, `wc`, `tail` and `head`.
* The `llama-cli` binary compiled from `llama.cpp` and a compatible model file.  By default the script
  expects:
  - `llama-cli` at `$HOME/modelo/llama.cpp/build/bin/llama-cli`
  - A model file at `$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf`

  If your paths differ, adjust the `LLAMA_CLI` and `MODEL_FILE` variables at the top of
  `launch_MemorySystem.sh`.

## Usage

1. Place all files and directories from this package in the same folder.
2. Make the script executable:

   ```bash
   chmod +x launch_MemorySystem.sh
   ```

3. Run the script:

   ```bash
   ./launch_MemorySystem.sh
   ```

   During each invocation the script will:

   * Validate that the required files exist and that the external commands `llama-cli`, `split`,
     `wc`, `tail` and `head` are available.
   * Select semantic fragments from the memory file using a simplified Levenshtein distance
     (the longest and most unique fragments).
   * Build a temporary prompt combining the base prompt and the selected fragments.
   * Invoke `llama-cli` with fixed flags to generate a response.
   * Append the last user input and assistant response to `memory/memory.txt`.
   * Apply the mathematical heuristic described in `memory/theorem.txt` to expand or contract the
     memory (Collatz, Goldbach and Riemann steps).
   * Write progress messages and timestamps to `logs/memory_system.log`.
   * Clean up temporary files when finished.

4. Consult `logs/memory_system.log` to see the execution record and `memory/memory.txt` to review
   which fragments of the conversation are preserved across runs.

## Notes

* The `levenshtein_fragment_selector` function uses a simplified approach and does **not** compute
  a true Levenshtein distance.  For production use, consider implementing a real distance‑based
  comparator.
* You can adjust the maximum token limit and fragment size inside the script by modifying the
  `TOKENS_MAX` and `fragment_size` variables.
* This system is meant as a **structural and functional prototype**; it is not intended to replace
  professional memory management techniques in production LLMs.
