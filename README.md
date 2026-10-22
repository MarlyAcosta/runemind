# Runemind

```
  ✧ ᚱ ᚢ ᚾ ᛖ ᛗ ᛁ ᚾ ᛞ ──────────── ✧
  █▀█ █ █ █▄ █ █▀▀ █▀▄▀█ █ █▄ █ █▀▄
  █▀▄ █▄█ █ ▀█ ██▄ █ ▀ █ █ █ ▀█ █▄▀
  ✧ ──────────── ᛞ ᚾ ᛁ ᛗ ᛖ ᚾ ᚢ ᚱ ✧
```

El conocimiento de tus agentes, grabado en runas. Runemind prepara cualquier PC con [deck](https://github.com/kevin15011/deck), Claude Code y OpenCode, y graba en cada proyecto solo los skills que le corresponden: VTEX, Shopify o desarrollos a la medida.

## Instalar

En Linux, WSL o macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/MarlyAcosta/runemind/main/bootstrap.sh | bash
```

Con opciones: `… | bash -s -- --with-remote`.

Runemind tiene dos partes:

- **El núcleo** (este repo, público, MIT): `rune`, el instalador, el catálogo de grimorios públicos y la interfaz. Se clona sin cuenta de GitHub en `~/runemind`.
- **Los grimorios privados**: repos privados con skills propios (topic `runemind-grimorio`). Si tu cuenta de GitHub tiene acceso, `rune` los encuentra y los clona en `~/runemind/grimorios/` con el token de esa cuenta (`gh auth token -u`), sin cambiar tu cuenta activa de `gh`.

`bootstrap.sh` instala `git`, `python3`, `ssh-keygen` y `gh` si faltan, te ofrece iniciar sesión en GitHub (puedes saltarlo y tener solo el núcleo), clona el núcleo y corre el instalador. Se puede correr las veces que quieras: si ya hay una instalación la actualiza, y si es una instalación antigua la migra (ver "Migración").

A mano:

```bash
git clone https://github.com/MarlyAcosta/runemind.git ~/runemind
~/runemind/install.sh
```

## El ritual de instalación

`rune install` (o `install.sh`) hace todo en un solo recorrido:

1. **El ritual empieza.** Detecta el equipo y lo que ya tienes ("sellos encontrados").
2. **Elige tus runas.** Menú en árbol por grupos (fundamentos, plataformas, agentes, acceso). ↑↓ para moverte, espacio para grabar u omitir, `a` todo, `n` nada, Enter para seguir.
3. **Sello de protección.** Antes de usar `sudo` explica para qué. La contraseña la pide `sudo`; rune no la ve. Solo lo usan la VTEX CLI, Tailscale y, en Linux, las herramientas base si faltan. Si `sudo` no puede pedirla, ese paso queda pendiente y el resto sigue.
4. **Grabando runas.** Cada paso muestra una runa que cambia mientras trabaja; las descargas que controla rune llevan una barra de energía con el avance real. Las descargas se reintentan; si algo falla ("la runa se quebró"), queda en la lista final y el ritual continúa.
5. **Vínculos.** Te ofrece iniciar sesión en lo que falte: `gh`, `claude`, `opencode`, `codex`, `vtex` y Tailscale. Cada herramienta pide sus credenciales en su propia pantalla.
6. **Runas grabadas.** Resumen, tiempo total y lo que falta.

| Componente | Versión |
|---|---|
| Node.js | 22 por defecto con nvm; cada proyecto con `.nvmrc` cambia solo a su versión (`config/shell/nvm-auto.sh`) |
| OpenCode | **1.18.31** fijo: deck 0.12 no funciona con OpenCode 2.x ([kevin15011/deck#15](https://github.com/kevin15011/deck/issues/15)) |
| Deck | **v0.12.0** fijo |
| Claude Code, gh, VTEX CLI, Shopify CLI, Codex | la última |

Las versiones fijas están al inicio de `install.sh`.

Opciones: `--yes` (sin preguntas), `--with-codex`, `--with-remote`, `--no-vtex`, `--no-shopify`, `--no-login`, `--dry-run`, `--post-deck`.

Después de configurar OpenCode en deck corre `rune install --post-deck`: desactiva la actualización automática de OpenCode, agrega `codebase-memory-mcp` (que deck 0.12 no escribe) y, si deck tiene Supermemory activado, te pide su clave de runtime sin mostrarla y la guarda con permisos 600 tras limpiar caracteres invisibles.

Los modelos y niveles de razonamiento de cada rol los eliges tú en deck → **Configure models**.

## El comando `rune`

```bash
rune                      # estado del proyecto: grimorios, deck, node, celular
rune use <grimorio>       # graba un grimorio en este repo
rune off <grimorio>       # lo quita
rune auto                 # detecta el tipo de proyecto y graba lo que corresponde
rune list                 # grimorios disponibles (públicos y los privados a los que tienes acceso)
rune update               # núcleo, grimorios y skills de VTEX: solo commits firmados por el dueño
rune setup                # descubre tus grimorios y registra el marketplace de Claude
rune admin grant <user>   # (dueño) da acceso a tu grimorio; revoke lo quita; list muestra quién tiene
rune remote on            # deck en tu celular (ver docs/remote-access.md)
rune install              # el ritual de instalación
rune log                  # detalle de la última instalación
```

## Grimorios

Cada grimorio es a la vez un plugin de Claude Code y una carpeta de skills que `rune` enlaza en `.agents/skills` de cada repo, donde los buscan OpenCode y Codex.

| Grimorio | Contenido | Se graba |
|---|---|---|
| `faststore` | `faststore-storefront` oficial de VTEX | En repos FastStore |
| `shopify` | [Shopify AI Toolkit](https://github.com/Shopify/Shopify-AI-Toolkit) oficial (con la telemetría desactivada) | Solo en repos Shopify |
| `custom` | Tus convenciones para desarrollos a la medida | Cuando nada más aplica, y solo si ya tiene skills |
| privados | Los de cada grimorio privado al que tengas acceso (`rune list` los muestra) | Según sus propias reglas |

El núcleo trae su catálogo en [`catalog/packs.json`](catalog/packs.json): fuentes de skills oficiales, dueños de confianza de grimorios y grimorios públicos. Cada grimorio privado trae un `grimorio.json` con el mismo formato. `lib/catalog.py` los une (avisa si dos usan el mismo nombre) y genera el marketplace `runemind` de Claude en `~/runemind/.claude-plugin/marketplace.json`, con todos los plugins dentro de `~/runemind` (Claude no sigue enlaces que salen del marketplace).

### Detección

| Si el repo tiene… | Graba |
|---|---|
| `@faststore/core` o `@faststore/cli` en `package.json`, o `faststore.config.js` / `discovery.config.js` en la raíz | `faststore` |
| `shopify.app.toml`, `layout/theme.liquid`, `sections/` + `snippets/`, o dependencias `@shopify/hydrogen…`, `@shopify/shopify-app…`, `@shopify/cli…` | `shopify` |
| Lo que digan las reglas de tus grimorios privados (por ejemplo, un `manifest.json` de VTEX IO y sus `builders`) | Esos grimorios |
| Nada de lo anterior | `custom`, pero mientras no tenga skills no se graba nada |

En Claude Code corre sola con el hook `SessionStart` de `~/.claude/settings.json` (`rune auto --hook`). La primera vez en un repo graba el grimorio y pide reiniciar la sesión, porque los plugins se cargan al iniciar. Los grimorios que ya estaban grabados se quedan y se actualizan hasta que corras `rune off <grimorio>`.

Nada se sube a los repos de los clientes: el plugin se activa con `--scope local` (`.claude/settings.local.json`), los skills son enlaces en `.agents/skills/`, y las dos rutas van a `.git/info/exclude`. `rune` anota en `~/.local/state/runemind/projects` los repos donde grabó algo, para actualizarlos o limpiarlos después.

### Skills de VTEX

Los skills oficiales de VTEX no se copian a ningún repo: `rune` los trae de [vtexdocs/ai-skills](https://github.com/vtexdocs/ai-skills) en una versión fija (`sources` en `catalog/packs.json`, hoy `v1.11.0`) y graba en cada proyecto solo los que su grimorio lista.

- La primera vez que se graba un grimorio que los usa, `rune` clona esa versión en `.vendor/vtex-docs@v1.11.0` y copia sus skills en `plugins/<grimorio>/upstream/` de su repo (fuera de git). Sin red se usa la copia que ya exista; si no hay ninguna, el grimorio queda con sus skills propios y `rune` avisa.
- `rune update` vuelve a revisar la versión fijada y avisa si VTEX publicó una más nueva, pero no la cambia: VTEX ha quitado y renombrado skills entre versiones.
- Para subir la versión: cambia `ref` en `catalog/packs.json`, corre `python3 -I scripts/lint-skills` (comprueba que cada skill listado exista en la nueva versión y que los `related:` resuelvan) y después `rune update`.

## Acceso y actualizaciones firmadas

- **Dar o quitar acceso** (dueño de un grimorio): `rune admin grant <usuario>`, `rune admin revoke <usuario>` y `rune admin list`. Usa el token de la cuenta de `gh` dueña del repo; inicia sesión con ella (`gh auth login`) aunque no sea la activa.
- **Del otro lado**: el próximo `rune update` (o `rune setup`) de esa persona acepta la invitación y clona el grimorio. Cuando le quitas el acceso, su próximo `rune update` borra el clon, desactiva sus plugins en Claude y quita los enlaces de sus proyectos. Es orden, no protección: lo que ya copió sigue en su equipo.
- **Firmas**: en un repo personal todo colaborador puede escribir, así que `rune update` solo avanza hasta el commit más nuevo de `main` firmado por el dueño, verificado con [`security/allowed_signers`](security/allowed_signers) (`git verify-commit` con firma SSH). Los commits de otras personas que estén encima quedan fuera, con un aviso, hasta que el dueño firme un commit o un merge encima. La historia anterior a las firmas se toma como punto de partida de confianza. El primer clon de cada repo también se detiene en el commit firmado más nuevo, y `bootstrap.sh` trae la clave del dueño para verificar el núcleo desde el principio.

## Migración

Antes, `~/runemind` era un clon del repo privado con todo junto. Cuando el núcleo público existe:

- `rune update` lo detecta (el remoto ya no comparte historia con tu copia), clona el núcleo firmado, lo pone en `~/runemind` y convierte tu copia anterior en `~/runemind/grimorios/runemind-grimorios`, apuntando al repo privado renombrado. Luego regenera el marketplace (mismo nombre `runemind`, así que `vtex@runemind` sigue activo) y vuelve a enlazar tus proyectos.
- Si `rune update` falla o tu instalación es muy vieja, corre otra vez el `curl` de "Instalar": hace la misma migración y se puede repetir sin riesgo.

## La interfaz

`lib/ui.sh` es la librería del estilo Ritual que usan `rune` y el instalador: marcos de runas, árboles, runa cambiante, barra de energía con chispa y el error en magenta. Usa colores de 24 bits si la terminal los soporta (`COLORTERM=truecolor`, Windows Terminal, iTerm2, WezTerm, VS Code), 256 colores si no (la Terminal de macOS), y nada de color si la salida no es una terminal o existe `NO_COLOR`. Si tu fuente no tiene runas, `RUNEMIND_RUNES=0` (o `runes=0` en `~/.config/runemind/config`) usa ✓ ● ○ en su lugar. Las animaciones solo corren en una terminal interactiva.

## Deck desde el celular

La opción **Acceso desde el celular** del instalador instala Tailscale, y `rune remote on` publica la interfaz web de deck solo dentro de tu red privada de Tailscale, con código de emparejamiento por dispositivo. Pasos, capas de seguridad y la política de acceso recomendada: [docs/remote-access.md](docs/remote-access.md).

## Desarrollo

- `python3 -I lib/catalog.py validate` y `check-marketplace`: el catálogo del núcleo, cada grimorio y sus `plugin.json`.
- `python3 -I scripts/lint-skills`: frontmatter de los skills propios y skills oficiales presentes en la versión fijada.
- `scripts/test-detect`: detección con un grimorio de prueba.
- `scripts/test-split`: simulación completa con repos locales, un `gh` falso y claves de prueba (dueño, colaborador, invitación, sin acceso, acceso quitado, commits sin firma, migración).

CI corre todo eso más shellcheck. Los skills se cambian en el repo de cada grimorio, que tiene su propio CI contra este núcleo.
