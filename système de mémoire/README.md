# Système de Mémoire de la Conjecture de Collatz pour LLMs Locaux

Ce package démontre comment appliquer une heuristique mathématique pour gérer la mémoire de contexte d'un modèle de langage local (via [llama.cpp](https://github.com/ggerganov/llama.cpp)). Le système évite le débordement de la fenêtre de contexte en préservant la conversation pertinente.

## Fichiers inclus

| Fichier / Répertoire            | Description                                                                                               |
|--------------------------------|-----------------------------------------------------------------------------------------------------------|
| `lanzar_SistemaMemoria.sh`      | Script Bash qui démarre le LLM local avec contrôle de mémoire et nettoyage automatique.                        |
| `memoria/teorema.txt`           | Explication complète de l'heuristique combinant la distance de Levenshtein, les conjectures de Collatz et Goldbach, et la version opérationnelle de l'hypothèse de Riemann. |
| `memoria/indicacion.txt`        | Prompt initial qui définit le nom et le rôle de l'assistant.                                                    |
| `memoria/memoria.txt`           | Fichier où est stockée la mémoire dynamique de la conversation. Se met à jour automatiquement à chaque exécution.                |
| `registros/`                    | Répertoire où sont écrits les journaux d'exécution. Le journal principal est `sistema_memoria.log`.                         |

## Prérequis

* Un environnement type Unix avec **bash** et les utilitaires standards `split`, `wc`, `tail` et `head`.
* Le binaire `llama-cli` compilé de `llama.cpp` et un fichier de modèle compatible. Par défaut, le script attend :
  - `llama-cli` dans `$HOME/modelo/llama.cpp/build/bin/llama-cli`
  - Un fichier de modèle dans `$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf`
  
  Si vos chemins diffèrent, ajustez les variables `LLAMA_CLI` et `MODEL_FILE` au début de `lanzar_SistemaMemoria.sh`.

## Utilisation

1. Placez tous les fichiers et répertoires de ce package dans le même dossier.
2. Rendez le script exécutable :

   chmod +x lanzar_SistemaMemoria.sh

3. Exécutez le script :

   ./lanzar_SistemaMemoria.sh

   À chaque invocation, le script :
   * Validera que les fichiers requis existent et que les commandes externes `llama-cli`, `split`, `wc`, `tail` et `head` sont disponibles.
   * Sélectionnera des fragments sémantiques du fichier de mémoire en utilisant une distance de Levenshtein simplifiée (les fragments les plus longs et les plus uniques).
   * Construira un prompt temporaire combinant le prompt de base et les fragments sélectionnés.
   * Invoquera `llama-cli` avec des flags fixes pour générer une réponse.
   * Ajoutera la dernière entrée de l'utilisateur et la réponse de l'assistant à `memoria/memoria.txt`.
   * Appliquera l'heuristique mathématique décrite dans `memoria/teorema.txt` pour élargir ou réduire la mémoire (étapes de Collatz, Goldbach et Riemann).
   * Écrira des messages de progression et des horodatages dans `registros/sistema_memoria.log`.
   * Nettoiera les fichiers temporaires à la fin.

4. Consultez `registros/sistema_memoria.log` pour voir le journal d'exécution et `memoria/memoria.txt` pour vérifier quels fragments de la conversation sont conservés entre les exécutions.

## Notes

* La fonction `levenshtein_fragment_selector` utilise une approche simplifiée et **ne** calcule **pas** une distance de Levenshtein réelle. Pour un usage en production, envisagez d'implémenter un comparateur basé sur une distance réelle.
* Vous pouvez ajuster la limite maximale de tokens et la taille des fragments dans le script en modifiant les variables `TOKENS_MAX` et `FRAGMENT_SIZE`.
* Ce système est conçu comme un **prototype structurel et fonctionnel** ; il ne prétend pas remplacer les techniques professionnelles de gestion de mémoire dans les LLMs de production.

**Eto Demerzel** (Gustavo Silva Da Costa)  
https://etodemerzel.gumroad.com  
https://github.com/BiblioGalactic