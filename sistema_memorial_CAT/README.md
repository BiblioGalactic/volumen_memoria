# Sistema de Memòria de la Conjectura de Collatz per a LLMs Locals

Aquest paquet demostra com aplicar una heurística matemàtica per gestionar la memòria de context d’un model de llenguatge local (mitjançant [llama.cpp](https://github.com/ggerganov/llama.cpp)). El sistema evita el desbordament de la finestra de context tot preservant la conversa rellevant.

## Fitxers inclosos

| Fitxer / Directori          | Descripció                                                                                               |
|-----------------------------|----------------------------------------------------------------------------------------------------------|
| `launch_MemorySystem.sh`    | Script Bash que llança el LLM local amb control de memòria i neteja automàtica.                         |
| `memory/theorem.txt`        | Explicació completa de la heurística que combina la distància de Levenshtein, les conjectures de Collatz i Goldbach, |
|                             | i la hipòtesi de Riemann operacional.                                                                   |
| `memory/prompt.txt`         | Prompt inicial que defineix el nom i el rol de l’assistent.                                             |
| `memory/memory.txt`         | Fitxer on es desa la memòria dinàmica de la conversa. S’actualitza automàticament a cada execució.      |
| `logs/`                     | Directori on s’escriuen els registres d’execució. El registre principal és `memory_system.log`.         |

## Requisits

* Un entorn tipus Unix amb **bash** i utilitats estàndard `split`, `wc`, `tail` i `head`.
* L’executable `llama-cli` compilat a partir de `llama.cpp` i un fitxer de model compatible. Per defecte, l’script espera:
  - `llama-cli` a `$HOME/modelo/llama.cpp/build/bin/llama-cli`
  - Un fitxer de model a `$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf`

  Si les teves rutes són diferents, ajusta les variables `LLAMA_CLI` i `MODEL_FILE` a la part superior de `launch_MemorySystem.sh`.

## Ús

1. Col·loca tots els fitxers i directoris d’aquest paquet a la mateixa carpeta.
2. Fes executable l’script:

   ```bash
   chmod +x launch_MemorySystem.sh
   ```

3. Executa l’script:

   ```bash
   ./launch_MemorySystem.sh
   ```

   Durant cada execució, l’script:

   * Validarà que existeixen els fitxers requerits i que les ordres externes `llama-cli`, `split`, `wc`, `tail` i `head` estan disponibles.
   * Seleccionarà fragments semàntics del fitxer de memòria utilitzant una distància de Levenshtein simplificada (els fragments més llargs i únics).
   * Construirà un prompt temporal combinant el prompt base i els fragments seleccionats.
   * Invocarà `llama-cli` amb paràmetres fixos per generar una resposta.
   * Afegirà l’última entrada de l’usuari i la resposta de l’assistent a `memory/memory.txt`.
   * Aplicarà l’heurística matemàtica descrita a `memory/theorem.txt` per expandir o contraure la memòria (passos de Collatz, Goldbach i Riemann).
   * Escriurà missatges de progrés i marques de temps a `logs/memory_system.log`.
   * Eliminarà fitxers temporals en finalitzar.

4. Consulta `logs/memory_system.log` per veure el registre d’execució i `memory/memory.txt` per revisar quins fragments de la conversa es preserven entre execucions.

## Notes

* La funció `levenshtein_fragment_selector` utilitza un enfocament simplificat i **no** calcula una distància de Levenshtein real. Per a ús en producció, considera implementar un comparador real basat en distància.
* Pots ajustar el límit màxim de tokens i la mida del fragment dins de l’script modificant les variables `TOKENS_MAX` i `fragment_size`.
* Aquest sistema està pensat com a **prototip estructural i funcional**; no pretén substituir tècniques professionals de gestió de memòria en LLMs de producció.

**Eto Demerzel** (Gustavo Silva Da Costa)
https://etodemerzel.gumroad.com  
https://github.com/BiblioGalactic
