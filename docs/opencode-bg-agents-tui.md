# Plugin TUI `bg-agents-tui` para opencode

Estado: construido y probado en vivo (instancia aislada), **sin aplicar** a la configuración real.
Código: `~/.config/opencode/bg-agents-tui-next/` (repo git propio, local).

## 1. Hallazgos (API de plugins TUI en opencode 2.0.21)

Fuentes: tipos `~/.config/opencode/node_modules/@opencode/plugin/dist/tui/context.d.ts`
(`Context`, `SlotMap`, `Keymap`, `Dialog`, `Storage`), `dist/host.js` (resolución de entradas),
strings del binario `~/.opencode/bin/opencode` (plugins internos `opencode.sidebar.context`/`opencode.sidebar.mcp`,
transformador babel-solid para `.tsx`, tabla de keybinds por defecto) y los plugins existentes
`herdr-opencode/tui.js` + `herdr-tui-session.js`. La página https://opencode.ai/docs/plugins **no** documenta
plugins TUI (solo plugins de servidor); la referencia real es el `.d.ts` y el binario.

| Pregunta | Respuesta | Evidencia |
|---|---|---|
| (a) Sección en el sidebar | **Sí**: `ui.slot({append:"sidebar.content", render})` | `SlotMap["sidebar.content"]`; MCP/Context internos se declaran igual |
| (b) Segmento en footer / barra | **Sí**: `prompt.footer.status`, `session.composer.top` (línea sobre el prompt), `home.footer.status` | `SlotMap` |
| (c) Keybinding / comando / slash / paleta | **Sí**: `keymap.layer(() => ({commands:[{id,bind,palette,slash,run}]}))`; modo `global` | `Keymap`, `KeymapCommand`; uso interno `session.aside` (`/btw`) |
| (c2) Modal / listas | **Sí**: `ui.dialog.select/confirm/prompt/show` | `Dialog` |
| (c3) Saltar a una sesión hija | **Sí**: `ui.router.navigate({type:"session", sessionID})`. Nativo: `session_child_first` = `down`, `session_parent` = `up` | `UI.router`; tabla de keybinds |
| (d) Refrescar / leer ficheros | **Sí**: el plugin es JS normal de Bun (fs, child_process, `setInterval`); estado reactivo con `storage.memory()` (store de solid, sin importar solid-js) | `Storage`; herdr usa `setInterval` |
| JSX | Los `.tsx`/`.jsx` se transforman al cargar (babel-solid, módulo `@opentui/solid` provisto por el runtime). Directorio con `tui.tsx` basta | strings del binario (`lK`, `yK`) |
| Declaración | `cli.json` -> `{"plugins":["./dir"]}`; el directorio expone `tui.(js|tsx)` con `export default {id, setup(api)}` | `host.js`, `cli.json` actual |

Conflicto de teclas: `<leader>b` es el sidebar, `<leader>a/m/l/n/g/...` están ocupados; se usa **`<leader>j`** (ctrl+x j).

## 2. Qué se construyó

Mapa respecto a lo pedido (modelo Claude Code):

1. **Segmento footer** `← N bg agents · ctrl+x j to manage` (slot `prompt.footer.status`) + barra sobre el prompt
   `● N agents · <desc> (tiempo) · <última actividad>   ctrl+x j to manage` (`session.composer.top`). Posible, hecho.
2. **Lista de gestión** (`/agents`, ctrl+x j, paleta): modal con secciones Running / Finished; fila
   `● <agente>  <descripción>` + última actividad + `tiempo · ↓ tokens` (los tokens salen de los mensajes que el TUI ya
   tiene de ese hijo; el registro no los expone, así que puede faltar). Hecho. No es una lista inferior inline como en
   Claude Code: la API ofrece modal, no un panel que robe el foco de las flechas.
3. **Enter -> transcripción en vivo**: Enter abre un segundo menú: *Open live transcript* (navega a la sesión hija con el
   renderer nativo de opencode; `up` vuelve al padre), *Show tail (refreshing)* (modal que refresca `bg-agents-ctl tail`
   cada 1,5 s; si `tail` no existe usa `lastActivity`/`excerpt`) y *Stop agent*. La navegación nativa
   es la vía principal; el tail es el respaldo.
4. **Stop**: acción del menú, con confirmación, vía `bg-agents-ctl stop <id>`. (No hay tecla `x` por fila: `dialog.select`
   no admite teclas personalizadas por opción.)
5. **Sidebar** `Sub-agentes en segundo plano · N activos`: icono de estado (`●` corriendo, `✓`, `✗`, `■`, `?` huérfano),
   descripción truncada, tiempo y última actividad; refresco 2 s; oculto sin hijos. Muestra los hijos de la sesión actual
   (o de su familia raíz) y los terminados hasta 2 min.
6. **Sidebar `Tareas  N/M`** desde `~/.local/state/opencode-bg/todos/<sessionID>.json` (esquema del plugin de servidor):
   `✓` completada (tenue), `▶` en curso (resaltada), `○` pendiente; oculta si no hay fichero o está vacío. Además segmento
   de footer `▶ tarea actual · N/M`.
7. **Kill switch**: `BG_AGENTS_DISABLED=1` (al arrancar) o el fichero `~/.config/opencode/bg-agents.disabled`
   (se evalúa cada 2 s, sin reiniciar): se oculta todo y el comando se desactiva.
8. Nunca bloquea la UI: lecturas asíncronas, `execFile` asíncrono con timeout 8 s, un solo sondeo a la vez.

Se lee del registro `~/.local/state/opencode-bg/registry.json` (override `BG_AGENTS_STATE_DIR`); `lastActivity` y
`bg-agents-ctl tail` los añade el otro escritor. Binario ctl: `~/.config/opencode/bg-agents/bin/bg-agents-ctl`
(override `BG_AGENTS_CTL`; si el instalador final mueve `bg-agents-next` a `bg-agents`, la ruta sigue valiendo).

## 3. Pruebas

- **Unitarias**: `cd bg-agents-tui-next && node --test test/` -> 8 tests OK (registro, familia de sesiones, visibilidad,
  formato, kill switch, todos, stop/tail con ctl simulado).
- **En vivo y aisladas**: `opencode --standalone -s ses_bgtuitest0001` en un tmux propio (`tmux -L bgtui`), con
  `XDG_*` y `BG_AGENTS_STATE_DIR` en `/tmp/claude-1000/.../scratchpad/live`, registro y todos de prueba. Se capturó la
  pantalla: sidebar con ambas secciones, barra sobre el prompt, segmento de footer, `ctrl+x j` abre el modal, Enter abre
  el submenú, "Show tail" muestra el modal con el respaldo, y el flag file oculta todo. Se probó también el flujo
  `apply.sh`/`rollback.sh` (symlink relativo `./bg-agents-tui`) tanto sobre un directorio de config de prueba como
  arrancando el TUI con él. No se tocó el opencode real.
- **Sin verificar en vivo**: *Open live transcript* sobre un hijo real (en la prueba los hijos eran ficticios, sin sesión
  en el servidor); depende de que el TUI esté conectado al mismo servidor que creó el hijo. Los tokens con datos reales.
  Con `bg-agents-ctl tail` real (aún no existe en `bg-agents/`).

## 4. Aplicar / revertir / desactivar

```
~/.config/opencode/bg-agents-tui-next/apply.sh      # backup cli.json.bak-<fecha>, symlink atómico, añade ./bg-agents-tui
# reiniciar opencode
~/.config/opencode/bg-agents-tui-next/rollback.sh   # quita la entrada y el symlink (con backup)
touch ~/.config/opencode/bg-agents.disabled         # desactivar sin reiniciar (rm para reactivar)
```

`apply.sh` reescribe `cli.json` con formato JSON estándar (el actual es JSON plano).

## 5. Límites

- Lista de gestión modal, no panel inferior con foco propio; sin tecla `x` por fila (stop = acción del submenú).
- Tokens: solo si el TUI tiene los mensajes del hijo cargados; si no, se omiten.
- La barra `session.composer.top` aparece pegada encima del prompt; su aspecto exacto depende del tema.
- Si una versión futura renombra los slots, las reclamaciones degradan al ancestro más cercano o se suprimen (doc de `SlotClaim`).
- Plugin de TUI solo ve hijos del registro; los sub-agentes nativos (no bg) ya los muestra opencode con `↓ N subagent`.
