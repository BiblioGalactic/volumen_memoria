# Collatz‑Hipotesiaren Memoria Sistema Tokiko LLM-entzat

Pakete honek erakusten du nola aplikatu heuristika matematiko bat tokiko hizkuntza-modelo baten testuinguru-memoria kudeatzeko ([llama.cpp](https://github.com/ggerganov/llama.cpp) bidez). Sistema honek testuinguru‑leihoaren gehiegizko erabilera saihesten du, aldi berean elkarrizketa garrantzitsua gordez.

## Barne dauden fitxategiak

| Fitxategi / Direktorio | Deskribapena                                                                                             |
|------------------------|---------------------------------------------------------------------------------------------------------|
| `launch_MemorySystem.sh` | Bash script bat, tokiko LLM-a memoria kontrolarekin eta automatikoki garbitzeko exekutatzen du.        |
| `memory/theorem.txt`     | Heuristika osorik azaltzen du, Levenshtein distantzia, Collatz eta Goldbach hipotesiak eta Riemannen hipotesi operazionala konbinatuz. |
| `memory/prompt.txt`      | Laguntzailearen izena eta rola definitzen duen prompt hasierakoa.                                       |
| `memory/memory.txt`      | Elkarrizketa-dinamikoko memoria gordetzen den fitxategia. Exekuzio bakoitzean automatikoki eguneratzen da. |
| `logs/`                  | Exekuzio-logak gordetzen diren direktorioa. Log nagusia `memory_system.log` da.                         |

## Eskakizunak

* Unix antzeko ingurune bat, **bash** eta `split`, `wc`, `tail` eta `head` utilitate estandarrekin.
* `llama-cli` binarioa `llama.cpp`-tik konpilatua eta modelo-fitxategi bateragarria. Lehenetsita script-ak espero du:
  - `llama-cli` `$HOME/modelo/llama.cpp/build/bin/llama-cli`-n
  - Modelo-fitxategi bat `$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf`-n

  Bideak ezberdinak badira, aldatu `LLAMA_CLI` eta `MODEL_FILE` aldagaien balioak `launch_MemorySystem.sh` fitxategiaren goialdean.

## Erabilera

1. Jarri pakete honetako fitxategi eta direktorio guztiak karpeta berean.
2. Egin script exekutagarria:

   ```bash
   chmod +x launch_MemorySystem.sh
   ```

3. Exekutatu script-a:

   ```bash
   ./launch_MemorySystem.sh
   ```

   Exekuzio bakoitzean script-ak egingo du:

   * Beharrezko fitxategiak daudela eta `llama-cli`, `split`, `wc`, `tail` eta `head` komandoak erabilgarri daudela egiaztatzea.
   * Memoria-fitxategitik fragmentu semantikoak aukeratzea Levenshtein distantzia sinplifikatu batekin (fragmentu luzeena eta bereziena).
   * Base prompt-a eta hautatutako fragmentuak konbinatuz prompt temporala sortzea.
   * `llama-cli` exekutatzea flag finkoez erantzuna sortzeko.
   * Azken erabiltzaile-sarrera eta laguntzailearen erantzuna `memory/memory.txt`-ra gehitzea.
   * `memory/theorem.txt`-ean deskribatutako heuristika matematikoa aplikatzea memoria handitzeko edo murrizteko (Collatz, Goldbach eta Riemann urratsak).
   * Aurrerapen-mezuak eta timestamp-ak `logs/memory_system.log`-ean idaztea.
   * Fitxategi temporalak garbitzea amaitutakoan.

4. Kontsultatu `logs/memory_system.log` exekuzio-erregistroa ikusteko eta `memory/memory.txt` elkarrizketako zein fragmentu gordetzen diren berrikusteko.

## Oharrez

* `levenshtein_fragment_selector` funtzioak hurbilketa sinplifikatu bat erabiltzen du eta ez du benetako Levenshtein distantzia kalkulatzen. Ekoizpen-erabilerarako, kontuan hartu distantzia-bazatutako konparadore bat inplementatzea.
* Script barruan gehienezko token-muga eta fragmentu tamaina egokitu daitezke `TOKENS_MAX` eta `fragment_size` aldagaien balioak aldatuz.
* Sistema hau **prototipo estruktural eta funtzionala** da; ez da tokiko LLMetan profesional memoria-kudeaketa teknikak ordezkatzeko helburua.

**Eto Demerzel** (Gustavo Silva Da Costa)
https://etodemerzel.gumroad.com  
https://github.com/BiblioGalactic
