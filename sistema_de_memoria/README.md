# Sistema de Memoria de la Conjetura de Collatz para LLMs Locales

Este paquete demuestra cómo aplicar una heurística matemática para gestionar la memoria de contexto de un modelo de lenguaje local (a través de [llama.cpp](https://github.com/ggerganov/llama.cpp)). El sistema evita el desbordamiento de la ventana de contexto preservando la conversación relevante.

## Archivos incluidos

| Archivo / Directorio            | Descripción                                                                                               |
|--------------------------------|-----------------------------------------------------------------------------------------------------------|
| `lanzar_SistemaMemoria.sh`      | Script de Bash que inicia el LLM local con control de memoria y limpieza automática.                        |
| `memoria/teorema.txt`           | Explicación completa de la heurística que combina la distancia de Levenshtein, las conjeturas de Collatz y Goldbach, y la versión operacional de la hipótesis de Riemann. |
| `memoria/indicacion.txt`        | Prompt inicial que define el nombre y el rol del asistente.                                                    |
| `memoria/memoria.txt`           | Archivo donde se almacena la memoria dinámica de la conversación. Se actualiza automáticamente en cada ejecución.                |
| `registros/`                    | Directorio donde se escriben los registros de ejecución. El registro principal es `sistema_memoria.log`.                         |

## Requisitos

* Un entorno tipo Unix con **bash** y utilidades estándar `split`, `wc`, `tail` y `head`.
* El binario `llama-cli` compilado de `llama.cpp` y un archivo de modelo compatible. Por defecto, el script espera:
  - `llama-cli` en `$HOME/modelo/llama.cpp/build/bin/llama-cli`
  - Un archivo de modelo en `$HOME/modelo/modelos_grandes/M6/mistral-7b-instruct-v0.1.Q6_K.gguf`

  Si tus rutas difieren, ajusta las variables `LLAMA_CLI` y `MODEL_FILE` al inicio de `lanzar_SistemaMemoria.sh`.

## Uso

1. Coloca todos los archivos y directorios de este paquete en la misma carpeta.
2. Haz el script ejecutable:

   ```bash
   chmod +x lanzar_SistemaMemoria.sh
   ```

3. Ejecuta el script:

   ```bash
   ./lanzar_SistemaMemoria.sh
   ```

   En cada invocación el script:

   * Validará que los archivos requeridos existen y que los comandos externos `llama-cli`, `split`, `wc`, `tail` y `head` están disponibles.
   * Seleccionará fragmentos semánticos del archivo de memoria usando una distancia de Levenshtein simplificada (los fragmentos más largos y más únicos).
   * Construirá un prompt temporal combinando el prompt base y los fragmentos seleccionados.
   * Invocará `llama-cli` con flags fijos para generar una respuesta.
   * Añadirá la última entrada del usuario y la respuesta del asistente a `memoria/memoria.txt`.
   * Aplicará la heurística matemática descrita en `memoria/teorema.txt` para expandir o contraer la memoria (pasos de Collatz, Goldbach y Riemann).
   * Escribirá mensajes de progreso y marcas de tiempo en `registros/sistema_memoria.log`.
   * Limpiará los archivos temporales al finalizar.

4. Consulta `registros/sistema_memoria.log` para ver el registro de ejecución y `memoria/memoria.txt` para revisar qué fragmentos de la conversación se conservan entre ejecuciones.

## Notas

* La función `levenshtein_fragment_selector` usa un enfoque simplificado y **no** calcula una distancia de Levenshtein real. Para uso en producción, considera implementar un comparador basado en una distancia real.
* Puedes ajustar el límite máximo de tokens y el tamaño de los fragmentos dentro del script modificando las variables `TOKENS_MAX` y `FRAGMENT_SIZE`.
* Este sistema está pensado como un **prototipo estructural y funcional**; no pretende reemplazar técnicas profesionales de gestión de memoria en LLMs de producción.
