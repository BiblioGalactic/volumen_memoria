#!/bin/bash
# === 🚀 IAren Abiarazlea Memoria Kontrol Dinamikoarekin ===
# Script honek heuristika matematikoa aplikatzen du LLM lokal baten testuinguru-memoria kudeatzeko.
# Levenshtein distantzia, Collatz eta Goldbach aieruan eta Riemann
# hipotesiaren bertsio operazional batean oinarritzen da. Helburua elkarrizketaren
# memoria adimentsuki zabaldu edo uzkurtzea da, hizkuntza-modelo lokal batek testuinguru
# garrantzitsua mantendu ahal izateko bere prompt-leihoa gainezka egin gabe.

# -----------------------------------------------------------------------------
# Segurtasuna eta errore kudeaketa
# Errorean, definitu gabeko aldagaietan eta pipeline-aren hutsegiteetan irteten gara. Garbitze
# funtzio bat beti exekutatzen da irtetean fitxategi temporalak ezabatzeko.
set -euo pipefail
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 🛠 Konfigurazioa
# Doitu bide hauek zure instalazioa desberdina bada. Modeloak GGUF
# formatuan egon behar du eta llama-cli-rekin bateragarria izan.
LLAMA_CLI="$HOME/modelo/llama.cpp/build/bin/llama-cli"
MODEL_FILE="$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf"

# Lan-fitxategiak
PROMPT_FILE="memory/prompt.txt"
MEMORY_FILE="memory/memory.txt"
LOG_FILE="logs/memory_system.log"
BACKUP_FILE="${MEMORY_FILE}.backup"

# Parametro heuristikoak
TOKENS_MAX=4096            # testuinguru-luzera maximoa llama-cli-rentzat
FRAGMENT_SIZE=800         # byte-tamaina zatitzeko fragmentuak hautatzean

# Fitxategi temporal markatzaileak (execute()-n hasieratuta)
TEMP_PROMPT=""
UNIQUE_FILE=""
COMMON_FILE=""

# -----------------------------------------------------------------------------
# 📋 Erregistro laguntzailea
# Mezu informatibo bat idazten du erregistroan denbora-zigilua duela. Mezuak
# aldi berean stdout-era bidaltzen dira erabiltzailearen ikusgaitasunerako eta erregistro-fitxategira gehitzen dira.
log_info() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[INFO][$ts] $1" | tee -a "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# ✅ Ingurunearen balidazioa
# Beharrezko fitxategi, baimen eta kanpoko komando guztiak bertan daudela ziurtatzen du.
validate() {
  log_info "Ingurune eta mendekotasunak balioztatzen…"

  # Egiaztatu prompt eta memoria-fitxategiak badaudela; bestela, sortu
  # iruzkin egokiekin script-a ez apurtzeko.
  for f in "$PROMPT_FILE" "$MEMORY_FILE"; do
    if [[ ! -f "$f" ]]; then
      log_info "Falta den fitxategia sortzen: $f"
      mkdir -p "$(dirname "$f")"
      : > "$f"
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
      echo "[ERROR] Irakurketa/idazketa baimen nahikorik ez $f-n" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  # Ziurtatu erregistro-direktorioa badagoela
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  # Egiaztatu llama-cli binarioa
  if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "[ERROR] llama-cli binarioa ez da aurkitu edo ez da exekutagarria $LLAMA_CLI-n" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Egiaztatu modelo-fitxategiaren irakurgarritasuna
  if [[ ! -r "$MODEL_FILE" ]]; then
    echo "[ERROR] Modelo-fitxategia ez da irakurgarria: $MODEL_FILE" | tee -a "$LOG_FILE" >&2
    exit 1
  fi

  # Egiaztatu beharrezko kanpoko komandoak erabilgarri daudela
  for cmd in split wc tail head; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[ERROR] Beharrezko komandoa ez da aurkitu: $cmd" | tee -a "$LOG_FILE" >&2
      exit 1
    fi
  done

  log_info "Ingurunearen balidazioa arrakastaz osatuta."
}

# -----------------------------------------------------------------------------
# 🧠 Fragmentuen hautaketa (Levenshtein sinplifikatua)
# Sarrerako testu-fitxategi bat emanda, fragmentu ezberdin eta arruntenen
# bi fitxategi sortzen ditu. Sinpletasunagatik inplementazio honek ez du Levenshtein distantzia
# erreala kalkulatzen – zatitu ondoren lehen eta azken fragmentuak hautatzen ditu.
# Parametroak: $1 – sarrerako fitxategia aztertzeko
#              $2 – irteerako fitxategia fragmentu bereiziarentzat
#              $3 – irteerako fitxategia fragmentu arruntarentzat
levenshtein_fragment_selector() {
  local input_file="$1"
  local output_unique="$2"
  local output_common="$3"

  # Sarrerako fitxategia falta bada edo hutsik badago, irteera hutsak sortu eta itzuli
  if [[ ! -s "$input_file" ]]; then
    : > "$output_unique"
    : > "$output_common"
    return
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)

  # Zatitu sarrera FRAGMENT_SIZE byte-ko fragmentu binarrietan
  split -b "$FRAGMENT_SIZE" "$input_file" "$tmp_dir/frag_" || true

  # Zehaztu lexikografikoki lehenengo eta azken fragmentu-izenak
  local first_fragment last_fragment
  first_fragment=$(ls "$tmp_dir" | sort | head -n1 || true)
  last_fragment=$(ls "$tmp_dir" | sort | tail -n1 || true)

  # Kopiatu lehen fragmentua irteera bereizira
  if [[ -n "$first_fragment" ]]; then
    cat "$tmp_dir/$first_fragment" > "$output_unique"
  else
    : > "$output_unique"
  fi

  # Kopiatu azken fragmentua irteera arruntera (desberdina bada)
  if [[ -n "$last_fragment" && "$last_fragment" != "$first_fragment" ]]; then
    cat "$tmp_dir/$last_fragment" > "$output_common"
  else
    : > "$output_common"
  fi

  rm -rf "$tmp_dir"
}

# -----------------------------------------------------------------------------
# 📈 Collatz memoria-kontrola
# Memoria-fitxategia zabaltzen edo uzkurtzen du total bikoiti/bakoiti baten arabera. Totala
# bikoitia bada, azken 4 lerroak mantentzen dira. Bakoitia bada, lerroen erdi
# berrienak bakarrik gordetzen dira.
collatz_memory_control() {
  local total="$1"
  local memory_file="$2"
  if (( total % 2 == 0 )); then
    log_info "Collatz urratsa: total bikoitia → memoria zabaltzen (azken 4 elkarrekintzak mantentzen)"
    if [[ -f "$memory_file" ]]; then
      tail -n 4 "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  else
    local lines_to_keep=$(( total / 2 ))
    [[ $lines_to_keep -lt 1 ]] && lines_to_keep=1
    log_info "Collatz urratsa: total bakoitia → memoria uzkurtzen (azken $lines_to_keep lerro mantentzen)"
    if [[ -f "$memory_file" ]]; then
      tail -n "$lines_to_keep" "$memory_file" > "$memory_file.tmp" || true
      mv "$memory_file.tmp" "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🔢 Lehen zenbakiaren egiaztapena
# 0 itzultzen du emandako zenbakia lehena bada, bestela 1. Goldbach-ek erabiltzen du.
is_prime() {
  local n=$1
  (( n < 2 )) && return 1
  for (( i=2; i*i<=n; i++ )); do
    (( n % i == 0 )) && return 1
  done
  return 0
}

# -----------------------------------------------------------------------------
# 🧩 Goldbach zatiketa
# Memoria-fitxategia bi luzera lehendun zati bihurtzen ditu, haien luzerak
# lerro guztien kopurua batzen dutelarik. Lehen handiagoarekin bat datorren zatia mantentzen da.
goldbach_split() {
  local memory_file="$1"
  local total_lines
  total_lines=$(wc -l < "$memory_file" || echo 0)

  # 2 lerro baino gutxiago badaude, ez dago ezer egitekorik
  if (( total_lines < 2 )); then
    return
  fi

  for (( i=2; i<total_lines; i++ )); do
    local j=$(( total_lines - i ))
    if is_prime "$i" && is_prime "$j"; then
      if (( j > i )); then
        log_info "Goldbach urratsa: azken $j lerroak mantentzen (lehen handiagoa)"
        tail -n "$j" "$memory_file" > "$memory_file.tmp" || true
      else
        log_info "Goldbach urratsa: lehen $i lerroak mantentzen (lehen handiagoa)"
        head -n "$i" "$memory_file" > "$memory_file.tmp" || true
      fi
      mv "$memory_file.tmp" "$memory_file"
      return
    fi
  done
}

# -----------------------------------------------------------------------------
# 🌀 Riemann hedapena
# Memoria-fitxategia lerro bakar batera erortzen denean, aurreko mezuaren
# erdia berreskuratzen du babeskopia batetik testuinguru gehigarria emateko. Kontzeptualki
# memoria oraindik unitate bat bezala hartzen da.
riemann_expansion_if_one() {
  local memory_file="$1"
  local backup_file="$2"
  local lines
  lines=$(wc -l < "$memory_file" || echo 0)
  if (( lines == 1 )); then
    log_info "Riemann urratsa: memoria 1 lerrora murriztuta, testuingurua babeskopiatik berreskuratzen"
    if [[ -f "$backup_file" ]]; then
      # Gehitu babeskopiatik aurreko lerroa (azken aurreko lerroa)
      tail -n 2 "$backup_file" | head -n 1 >> "$memory_file"
    fi
  fi
}

# -----------------------------------------------------------------------------
# 🚀 Modeloaren exekuzioa
# Prompt temporal bat eraikitzen du oinarrizko prompt-etik eta hautatutako fragmentuetatik, exekutatzen du
# llama-cli eta memoria-fitxategia eguneratzen du. Gero Collatz,
# Goldbach eta Riemann heuristikak aplikatzen ditu memoriari.
execute() {
  log_info "Memoriaren fragmentu semantikoak hautatzen…"
  # Sortu fitxategi temporalak fragmentu berezi eta arruntarentzat
  UNIQUE_FILE=$(mktemp)
  COMMON_FILE=$(mktemp)
  TEMP_PROMPT=$(mktemp)

  # Sortu fragmentu semantikoak existitzen den memoriatik
  levenshtein_fragment_selector "$MEMORY_FILE" "$UNIQUE_FILE" "$COMMON_FILE"

  log_info "Prompt temporala prestatzen…"
  # Konbinatu prompt-a hautatutako fragmentuekin
  cat "$PROMPT_FILE" "$COMMON_FILE" "$UNIQUE_FILE" > "$TEMP_PROMPT"

  log_info "llama-cli abiarazten…"
  local session_output
  session_output=$(mktemp)
  # Exekutatu modeloa; gehitu irteera erregistrora eta hartu memoria eguneratzeko
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

  log_info "Modeloaren exekuzioa osatuta. Memoria eguneratzen…"
  # Erregistratu erabiltzailearen azken sarrera eta laguntzailearen erantzuna trazabilidaderako
  local user_line ia_line
  user_line=$(tail -n 1 "$PROMPT_FILE" || echo "")
  ia_line=$(tail -n 1 "$session_output" || echo "")
  echo "Erabiltzailea: $user_line" >> "$MEMORY_FILE"
  echo "Laguntzailea: $ia_line" >> "$MEMORY_FILE"

  # Memoriaren babeskopia aldaketen aurretik
  cp "$MEMORY_FILE" "$BACKUP_FILE" || true

  # Zehaztu luzera logikoa: oinarrizko sarrera + erantzuna + adierazleak
  # fitxategi berezi/arruntak hutsik ez badaude
  local logical_length=2
  [[ -s "$UNIQUE_FILE" ]] && (( logical_length+=1 ))
  [[ -s "$COMMON_FILE" ]] && (( logical_length+=1 ))
  log_info "Luzera logikoa Collatz-entzat = $logical_length"

  # Aplikatu Collatz, Goldbach eta Riemann heuristikak
  collatz_memory_control "$logical_length" "$MEMORY_FILE"
  goldbach_split "$MEMORY_FILE"
  riemann_expansion_if_one "$MEMORY_FILE" "$BACKUP_FILE"

  log_info "Saioa arrakastaz amaitu da."
  # Garbitu execute()-n sortutako fitxategi temporalak
  rm -f "$session_output"
}

# -----------------------------------------------------------------------------
# 🧹 Garbitura
# Script-aren exekuzioan sortutako fitxategi temporal guztiak ezabatzen ditu. Funtzio hau
# automatikoki aktibatuko da irtetean hasieran definitutako trap-aren bidez.
cleanup() {
  # Ezabatu prompt eta fragmentu fitxategi temporalak existitzen badira
  [[ -n "${TEMP_PROMPT:-}" && -f "${TEMP_PROMPT:-}" ]] && rm -f "${TEMP_PROMPT:-}"
  [[ -n "${UNIQUE_FILE:-}" && -f "${UNIQUE_FILE:-}" ]] && rm -f "${UNIQUE_FILE:-}"
  [[ -n "${COMMON_FILE:-}" && -f "${COMMON_FILE:-}" ]] && rm -f "${COMMON_FILE:-}"
  # Ezabatu galdutako fitxategi temporal guztiak (ahalegin onena)
  rm -f *.tmp 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 🧪 Sarrera-puntua
main() {
  validate
  execute
}

main "$@"