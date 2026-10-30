# opencode: sub-agentes en segundo plano (`bg-agents`)

Plugin de opencode v2.0.21 que da a opencode el flujo de sub-agentes de Claude Code: lanzar, seguir trabajando, enterarse cuando terminan, y poder listar, esperar o detener. Código en `~/.config/opencode/bg-agents/` (repo git propio, solo local).

## Lo primero que hay que saber (hallazgos sobre opencode 2.0.21)

1. **opencode 2.0.21 ya trae sub-agentes en segundo plano.** La herramienta nativa `subagent` (el antiguo `task`) acepta `background: true`: devuelve el id al instante y, al terminar, opencode mete un mensaje `<subagent sessionID=… state="completed">` en la sesión padre. Si el padre está parado, se despierta solo; si está ocupado, el mensaje queda en cola y se entrega cuando acaba la herramienta en curso, sin interrumpirla. Se midió: ver "Evidencia". Lo que fallaba en la práctica es que el modelo no pasa `background: true` por defecto; desde la 0.2 lo fuerza el plugin (ver "Segundo plano por defecto").
2. Lo que **no** trae: listar, consultar, esperar y recuperar resultados por id, un límite de concurrencia, timeout, cascada al abortar el padre, ni un registro que pueda leer una herramienta externa (el dock). Eso es lo que añade `bg-agents`.
3. **`cli.json` no carga plugins de servidor.** Su clave `plugins` es la lista de plugins de la TUI (`herdr-opencode` es solo `tui.js`; no aparece en `GET /api/plugin` del servicio). Los plugins de servidor se cargan desde `~/.config/opencode/plugins/` (archivos o directorios/enlaces simbólicos) o desde `opencode.jsonc`. Por eso `bg-agents` se activa con un enlace en `plugins/` (ver "Activar"), no con `cli.json`. Probado en el sandbox: ni `./ruta` ni ruta absoluta en `cli.json` cargaron el plugin.
4. **No existe `todowrite` en opencode 2.0.21** (la lista de herramientas es `patch edit glob grep … subagent webfetch websearch write`; no hay eventos `todo.*` ni en el esquema ni en la base de datos real). Sin esa herramienta el panel TODO que pide el puente no puede salir de opencode. `bg-agents` añade una `todowrite`/`todoread` propias (mismo esquema que opencode 1.x) y las refleja en el puente (ver "TODO → puente").
5. API de plugin v2 (verificada leyendo `@opencode/plugin` 2.0.4, los plugins ya instalados `engram.ts`, `telemetry-runtime.ts` y la propia ejecución): un plugin exporta `{ id, setup(ctx) }`; `ctx.tool.transform(ed => ed.add({name, description, input /* JSON Schema */, options:{codemode:false}, execute(input, context)}))`, `ctx.event.subscribe()`, `ctx.session.{get,create,prompt,synthetic,interrupt,wait,context}`, `ctx.tool.list()`. Los eventos son `{type, data:{sessionID…}}` (`session.execution.started|succeeded|failed|interrupted` hace de `session.idle`). La API HTTP v2 es `/api/…` (p. ej. `POST /api/session/{id}/interrupt`, no `/session/{id}/abort`), con `?location[directory]=`. `ctx.session.create` **no** acepta `parentID`; por eso `bg_spawn` delega en la herramienta nativa `subagent` (hijo real, listado en la TUI).

## Herramientas

Se registran con `options.codemode=false` (herramientas directas, como `subagent`).

| Herramienta | Qué hace |
|---|---|
| `bg_spawn({agent, description, prompt, model?})` | Llama a `subagent` con `background:true`. Devuelve `{id, agent, started_at}` al instante. Respeta los permisos del agente hijo y del padre (no los amplía). |
| `bg_list()` | Hijos de esta sesión: id, agente, descripción, estado, tiempo, última actividad. |
| `bg_status(id)` | Estado (`running\|done\|error\|aborted`), tiempo, nº de llamadas a herramientas, extracto del último mensaje. |
| `bg_result(id)` | Texto final del hijo + ficheros que cambió (de `edit/write/patch`). Error claro si sigue en marcha. |
| `bg_wait({ids?, timeout_s?})` | Espera bloqueante opcional (por defecto todos los activos, 600 s). |
| `bg_stop(id)`, `bg_stop_all()` | `session.interrupt` del hijo (y de sus hijos); queda `aborted` en segundos. |
| `todowrite`, `todoread` | Lista de tareas; solo se añaden si opencode no trae una (ver más abajo). |

Ejemplo de la conversación (el modelo decide cuándo; las descripciones le dicen que use `bg_spawn` para trabajo independiente y `subagent` bloqueante solo si necesita el resultado ya):

```
bg_spawn {agent:"gentle-ai-explore", description:"mapear módulo sync", prompt:"…"}
→ {"id":"ses_…","agent":"gentle-ai-explore","started_at":"2026-10-19T…Z"}
(el padre sigue trabajando; al terminar el hijo llega la notificación y se despierta)
bg_result {id:"ses_…"}
```

## Cómo funciona la notificación

La notificación de fin es la **nativa** de opencode (mensaje `<subagent … state="completed|failed|cancelled">` con la salida), porque duplicarla solo metería ruido. Entrega `steer`: con el padre parado lo despierta; con el padre ocupado queda en cola y entra al acabar la herramienta en curso (medido: padre en `sleep 14`, aviso en cola a los 17,7 s, entregado a los 22,7 s al terminar el `sleep`; nunca interrumpe una herramienta). El plugin añade su propio aviso solo cuando el nativo no explica la causa: **timeout** (`[bg:<id>] <agente> fue abortado (15s) (timeout 15s). Detalle: bg_result <id>`), agrupando varios fines simultáneos en un único mensaje (`Batcher`, ventana de 750 ms).

## Segundo plano por defecto (herramienta nativa `subagent`)

Desde la versión 0.2 **todo `subagent` se lanza en segundo plano**, como en Claude Code, sin que el modelo tenga que pedirlo.

**Cómo funciona (API v2 verificada en 2.0.21).** En `ctx.tool.transform` el plugin llama a `ed.update("subagent", t => …)` (la interfaz `ToolEditor` ofrece `list/get/add/update/remove`) y sustituye `t.execute` por un envoltorio (`src/wrap.js`); el original se guarda para `bg_spawn`, así no se cuenta dos veces. El envoltorio decide por llamada (`src/force.js`, función pura `decide`):

| Situación | Resultado |
|---|---|
| sin `background` | se ejecuta con `background:true` (forzado) |
| `background:false` explícito | bloquea (vía de escape cuando el resultado hace falta ya) |
| `background:true` explícito | segundo plano (se registra igual) |
| agente en `BG_AGENTS_FOREGROUND_AGENTS` | bloquea (lista opt-in, **vacía por defecto**) |
| forzado desactivado (ver abajo) | comportamiento nativo |
| límite de concurrencia alcanzado (`BG_AGENTS_MAX`) | **se ejecuta en primer plano**, no falla, y añade al resultado `[bg-agents] Background limit reached (4/4 running…): this sub-agent ran in the foreground instead.` |
| la sesión que llama ya es hija (profundidad 1) | sin tocar |
| kill switch (`BG_AGENTS_DISABLED`, `bg-agents.disabled`) | comportamiento nativo exacto |

El hijo forzado entra en el mismo registro que `bg_spawn` (mismos límites, timeout, cascada al abortar el padre; lo ven `bg_list/status/result/wait/stop` y el dock). El resultado que recibe el modelo es una línea: `Running in background (id ses_…). You will be notified when it finishes; continue with other work or use bg_wait/bg_result.` La notificación de fin sigue siendo la nativa (una sola; el plugin solo añade la suya en los timeouts), así que no hay doble aviso. La descripción de la herramienta se amplía con una frase que explica el valor por defecto.

**Interruptores del forzado** (el resto del plugin sigue activo; los kill switches de siempre lo apagan todo):

- `BG_AGENTS_FORCE_BACKGROUND=0` (también `false|off|no`) en el entorno del servidor.
- Fichero `~/.config/opencode/bg-agents.noforce` (se evalúa en cada llamada, sin reiniciar).
- `bg-agents-ctl force on|off|status` crea/borra ese fichero y muestra el estado efectivo.
- `BG_AGENTS_FOREGROUND_AGENTS="review-*,jd-*"` (lista con `*`, sin distinguir mayúsculas; vacía por defecto) y, opcionalmente, un fichero `~/.config/opencode/bg-agents.foreground` con un patrón por línea.

## Contrato de datos para lectores externos (dock, widget de la TUI)

Todo lo siguiente es **estable**: solo se añaden campos opcionales.

**`registry.json`** (ver arriba). Campos opcionales nuevos en cada hijo: `lastActivity` (última herramienta con su objetivo, p. ej. `shell sleep 10`, o la última línea de texto, máx. 100 caracteres), `lastActivityAt` (ms), `toolCalls`, y `todos` (`{done,total,current}`, solo si esa sesión escribió una lista TODO). `lastActivity` se actualiza con los eventos de herramienta/mensaje del hijo con **como máximo una escritura cada 2 s**. `source` vale `bg_spawn`, `subagent` (forzado o `background:true` explícito) o `native`.

**`~/.local/state/opencode-bg/todos/<sessionID>.json`** (escritura atómica en cada `todowrite`, borrado al borrar la sesión; al arrancar se podan las de más de 24 h y las de más de 1 h cuya sesión ya no existe):

```json
{"version":1,"session":"ses_…","parent":"ses_…|null","updated":1792384425310,
 "items":[{"content":"unit one","status":"completed|in_progress|pending|cancelled","priority":"high|medium|low"}],
 "progress":{"done":1,"total":3,"current":"unit two"}}
```

`progress` ignora las canceladas. `parent` es la sesión padre (null en la raíz).

**Herramientas de línea de comandos** (`bin/bg-agents-ctl`):

```bash
bg-agents-ctl tail <id> [n]        # últimos n (10) mensajes/herramientas del hijo, leídos por la API del servidor
bg-agents-ctl todos [sessionID]    # lista TODO de la sesión (o la más reciente): ✓ hecho  ▶ en curso  ○ pendiente  ✗ cancelado
bg-agents-ctl force on|off|status
```

## Límites y seguridad

| Qué | Valor | Cómo cambiarlo |
|---|---|---|
| Hijos simultáneos por padre | 4 | `BG_AGENTS_MAX` |
| Timeout por hijo | 30 min (aborta y avisa al padre) | `BG_AGENTS_TIMEOUT_MIN` |
| Con el límite alcanzado | un `subagent` sin `background` se ejecuta en primer plano y lo dice; `bg_spawn` sigue devolviendo error | — |
| Profundidad | 1: un hijo no puede llamar a `bg_spawn` (y `subagent` ya limita a 1) | — |
| Cascada | interrumpir o borrar el padre aborta sus hijos en marcha. Que el padre **termine su turno** NO los aborta (es el uso normal) | — |
| Permisos | el hijo conserva los suyos de `opencode.jsonc` | — |

Reservas de hueco síncronas: tres `bg_spawn` en paralelo con límite 2 aceptan 2 y rechazan 1.

## Apagarlo

- `BG_AGENTS_DISABLED=1` en el entorno del servidor: no registra ninguna herramienta al cargar.
- Fichero `~/.config/opencode/bg-agents.disabled` (`install.sh disable` / `enable`): se evalúa en cada llamada, sin reiniciar; las herramientas devuelven "bg-agents is disabled" y el espejo de TODO se silencia.
- Solo el forzado: `bg-agents-ctl force off` (ver arriba).
- Quitar el enlace: `~/.config/opencode/bg-agents/install.sh uninstall`.

## Activar

No se ha tocado `opencode.jsonc`, `AGENTS.md` ni `cli.json` (ver hallazgo 3). Para activarlo en sesiones nuevas:

```bash
~/.config/opencode/bg-agents/install.sh        # crea ~/.config/opencode/plugins/bg-agents -> bg-agents
opencode service restart                        # o cerrar y reabrir opencode
```

Ojo: el servicio de fondo vigila `plugins/` y puede cargar el plugin en caliente; hacerlo con ninguna tarea importante en curso. Estas dos órdenes **no se han ejecutado** sobre la instalación real.

## Registro y control externo (dock / puente)

`~/.local/state/opencode-bg/registry.json` (escritura atómica, varias instancias comparten el fichero por `pid`, se podan los terminados a las 24 h):

```json
{"version":1,"updated":…,"server":{"url":"http://127.0.0.1:49374","pid":…,"directory":"…"},
 "children":[{"id":"ses_…","parent":"ses_…","agent":"general","description":"…","state":"running",
              "started":…,"finished":null,"serverUrl":"http://127.0.0.1:49374","directory":"…","pid":…}]}
```

`serverUrl` sale de `--port/--hostname` del servidor o, si es el servicio de fondo, de `~/.local/state/opencode/service.json` (mismo pid). Para detener: `POST <serverUrl>/api/session/<id>/interrupt?location[directory]=<directory>` con Basic auth `opencode:<contraseña>` (contraseña en `service.json` o `OPENCODE_SERVER_PASSWORD`).

Helper sin dependencias:

```bash
~/.config/opencode/bg-agents/bin/bg-agents-ctl ls [--all]     # marca "stale" si el servidor murió
~/.config/opencode/bg-agents/bin/bg-agents-ctl stop <id>
~/.config/opencode/bg-agents/bin/bg-agents-ctl stop-all
~/.config/opencode/bg-agents/bin/bg-agents-ctl tail <id> [n]
~/.config/opencode/bg-agents/bin/bg-agents-ctl todos [sessionID]
~/.config/opencode/bg-agents/bin/bg-agents-ctl force on|off|status
```

## TODO → puente

opencode 2.0.21 no tiene `todowrite`, así que el plugin lo aporta (solo si no existe otro; si una versión futura trae uno nativo, se refleja el nativo por el hook `execute.after`). En cada actualización de la lista: si hay un trabajo del puente con `agent == "opencode"` y `state ∈ {sent, working}` en `.bridge/state/*.json` (y su `repo` contiene o está dentro del directorio del proyecto), ejecuta `bridge.sh progress <id> <hechas> <total> "<ítem in_progress>"` en segundo plano. Reglas: máximo 1 llamada cada 2 s (se envía el último estado al vencer el intervalo), nada si no cambió, nunca sin trabajo activo, errores solo al log (`~/.local/state/opencode-bg/bg-agents.log`), mismo interruptor que arriba. `BG_AGENTS_BRIDGE_DIR` cambia la carpeta del puente (las pruebas usan un `bridge.sh` falso, nunca el real).

**Importante:** el TODO que ve el usuario en el panel `/dock` aparece cuando el agente usa `todowrite` (el mensaje del puente ya se lo pide). La lista **no** se dibuja en la barra lateral de la TUI de opencode 2.0.21: esa barra no existe para este plugin; el lugar visible es el panel del dock.

## Evidencia de verificación

Entorno: servidor `opencode serve` aislado y desechable (`XDG_*` propios, puerto libre, credenciales copiadas a una BD temporal, modelo `opencode-go/glm-5.3-flash`, céntimos). El servicio real (pid 357449) y la sesión F12-T03 no se tocaron. Ejecución: `test/e2e.sh` (todos los grupos) — salida literal abreviada:

```
PASS  1. two bg_spawn calls return immediately            [spawn call -> result 155 ms]
PASS  1b. parent keeps working while children run         [bg_list 3433 ms after spawn]
PASS  2. idle parent is woken by the completion notification [woken +0 ms after notice]
PASS  3a/3b/3c. bg_list (2 hijos), bg_status, bg_result   [texto final A-done / B-done]
PASS  3d. registry.json lists both as done with serverUrl
PASS  4a. bg_stop aborts a child running `sleep 120`      [interrupted in 26 ms]
PASS  4b. registry marks it aborted
PASS  4c/4d. bg-agents-ctl ls / stop <id> (HTTP)          [{"interrupted":true} -> 189 ms]
PASS  4e. bg_stop_all aborts every running child
PASS  5a. interrupting the busy parent aborts its child   [+93 ms; reason=parent aborted]
PASS  5b. deleting the parent aborts its child            [+45 ms]
PASS  5c. per-child timeout auto-aborts (15 s)            [aborted 15.2s after spawn]
PASS  5d. parent is told about the timeout                [[bg:ses_…] general fue abortado (15s) (timeout 15s)…]
PASS  6a. concurrency limit (BG_AGENTS_MAX=2)             [2 accepted, 1 "limit reached"]
PASS  6b. depth 1: a child cannot call bg_spawn           [error "depth limit: …"]
PASS  7a/7b. flag file disables at call time / re-enables
PASS  7c. BG_AGENTS_DISABLED=1 registers no tools
PASS  8a-8e. todowrite -> bridge.sh progress (fake bridge): 0/3 "unit one" | 1/3 "unit two" | 3/3;
              calls 3.0 s and 3.0 s apart; none without an active job; none with the flag
```

Escenarios de la versión 0.2 (segundo plano por defecto, todos en verde, servidores aislados):

```
PASS  9a. plain subagent call returns immediately         [call -> result 160 ms]
PASS  9b. result says "Running in background (id ses_…). You will be notified…"
PASS  9c/9d. child in registry as running, with lastActivity ["shell sleep 10; echo F-done"]
PASS  9e. bg-agents-ctl tail <id> 5                        [tool shell sleep 10; echo F-done [running]]
PASS  9f. parent woken by exactly one native notice        [notices=1, woken 1 ms after]
PASS  9h. background:false blocks                          [call -> result 15833 ms]
PASS  9i/9j. noforce flag blocks (15 s) / removing it restores background (148 ms), sin reiniciar
PASS  10a/10b. BG_AGENTS_FOREGROUND_AGENTS=explore blocks explore (4037 ms); general sigue en 2.º plano (123 ms)
PASS  11a/11b. BG_AGENTS_FORCE_BACKGROUND=0 restaura el bloqueo (15951 ms); los bg_* siguen activos
PASS  12a. BG_AGENTS_MAX=2, tres subagent en paralelo: 2 en 2.º plano, 1 en primer plano con nota, 0 errores
PASS  8f/8g. todowrite escribe todos/<sesión>.json (v1) y `bg-agents-ctl todos` pinta el checklist
```

Notas honestas: el grupo `limits` falló una vez (6b) por una carrera de la propia prueba (leía la llamada antes de que terminase de transmitirse) y se corrigió y repitió en verde; un primer 6a falló de verdad (tres `bg_spawn` en paralelo se colaban) y se arregló con la reserva síncrona de hueco. Pruebas unitarias (`node --test test/`, 69 verdes, sin red): formato, registro (atómico, poda, varias instancias), batcher, reductor de eventos, TODO/puente con `bridge.sh` falso, límites, interruptor, ctl con `fetch` falso. Lo que **solo** se verificó por pruebas y no en vivo: `bg_wait`, el espejo con el `bridge.sh` real y la carga en el servicio de fondo real.

## Despliegue de la versión 0.2 (`apply.sh` / `rollback.sh`)

La versión nueva vive en `~/.config/opencode/bg-agents-next/` (repo git propio) y **no** está aplicada. Con la tarea del puente terminada y ningún opencode que dependa del plugin:

```bash
~/.config/opencode/bg-agents-next/apply.sh [--force]   # intercambia bg-agents <-> bg-agents-next; el anterior queda en bg-agents.prev
opencode service restart                                # o cerrar y reabrir opencode
~/.config/opencode/bg-agents/rollback.sh                # deshacer: restaura bg-agents.prev (la nueva queda en bg-agents-next)
```

`apply.sh` se niega si `bridge.sh ls` muestra un trabajo `opencode` en `working` (salvo `--force`), pasa los tests unitarios antes de tocar nada y no deja nunca un directorio a medio escribir. `plugins/bg-agents` es un enlace simbólico al directorio, así que basta con el intercambio.

## Problemas frecuentes

| Síntoma | Causa / arreglo |
|---|---|
| El modelo no usa `bg_spawn` | Ejecutar `opencode` nuevo tras activar; si sigue ignorándolo, pedirlo explícitamente o añadir una línea al prompt del agente |
| `bg_spawn` dice "Subagent denied" | El agente padre no tiene permiso `task` para ese hijo en `opencode.jsonc` (el plugin no lo amplía) |
| `bg-agents is disabled` | Existe `bg-agents.disabled` o `BG_AGENTS_DISABLED` |
| `bg-agents-ctl stop` da 401 | Falta la contraseña: `OPENCODE_SERVER_PASSWORD` o `service.json` del mismo `url` |
| Entrada `stale` en `ls` | El servidor que la creó ya no existe |
| Ver qué pasa | `~/.local/state/opencode-bg/bg-agents.log` y `GET /api/plugin` (estado `active`/`failed`) |
