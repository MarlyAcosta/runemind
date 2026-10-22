#!/usr/bin/env bash
# SEL_* flags are read indirectly through sel() (eval).
# shellcheck disable=SC2034
set -euo pipefail

OPENCODE_VERSION="1.18.31"
DECK_VERSION="v0.12.0"
NODE_MAJOR="22"
NVM_VERSION="v0.40.8"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
STARTED=$SECONDS

COMPONENTS="node gh claude opencode codex vtex shopify deck library remote"
SEL_node=1 SEL_gh=1 SEL_claude=1 SEL_opencode=1 SEL_codex=0 SEL_vtex=1 SEL_shopify=1 SEL_deck=1 SEL_library=1 SEL_remote=0
DRY=0
ASSUME_YES=0
LOGINS=1
MODE="install"
TODO=()
GRABADAS=0
FALLIDAS=0

usage() {
  cat <<'EOF'
Uso: ./install.sh [opciones]   (o: rune install [opciones])

Prepara una máquina Linux (o WSL) o macOS con Runemind: deck, Claude Code,
OpenCode y tu biblioteca de skills. Primero te deja elegir qué grabar. Se puede
correr varias veces: lo que ya está instalado lo salta.

Opciones:
  --yes          No preguntar: graba lo marcado por defecto
  --with-codex   Marca también Codex
  --with-remote  Marca el acceso desde el celular (Tailscale)
  --no-vtex      Desmarca VTEX CLI
  --no-shopify   Desmarca Shopify CLI
  --no-login     No ofrecer los vínculos (inicios de sesión) al final
  --post-deck    Solo los ajustes que van después de configurar deck
  --dry-run      Mostrar qué haría, sin cambiar nada
  -h, --help     Esta ayuda

Variables: RUNEMIND_RUNES=0 usa símbolos simples si tu fuente no tiene runas.
EOF
}

for a in "$@"; do
  case "$a" in
    --yes) ASSUME_YES=1 ;;
    --with-codex) SEL_codex=1 ;;
    --with-remote) SEL_remote=1 ;;
    --no-vtex) SEL_vtex=0 ;;
    --no-shopify) SEL_shopify=0 ;;
    --no-login) LOGINS=0 ;;
    --post-deck) MODE="post-deck" ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opción desconocida: $a" >&2; usage; exit 1 ;;
  esac
done

RM_ASSUME_YES=$ASSUME_YES
RM_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/runemind/install-$STAMP.log"
# shellcheck source=lib/ui.sh
. "$LIB/lib/ui.sh"
ln -sfn "$RM_LOG" "$(dirname "$RM_LOG")/last.log" 2>/dev/null || true
trap 'rm_cursor_show; rm -rf "$TMP"' EXIT

has() { command -v "$1" >/dev/null 2>&1; }
sel() { eval "[ \"\${SEL_$1}\" = 1 ]"; }
die() { rm_line "  $(rm_c "$P_RED" "$G_FAIL") $*" >&2; exit 1; }
INTERACTIVE=0
[ "$ASSUME_YES" = 0 ] && [ "$DRY" = 0 ] && [ "$RM_IN" = 1 ] && INTERACTIVE=1

case "$(uname -s)" in
  Linux) PLATFORM="linux" ;;
  Darwin) PLATFORM="macos" ;;
  *) die "Sistema no soportado: $(uname -s) (deck solo corre en Linux y macOS)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) die "Arquitectura no soportada: $(uname -m)" ;;
esac
case "${SHELL:-}" in */zsh) RC="$HOME/.zshrc" ;; *) RC="$HOME/.bashrc" ;; esac

download() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 3 --retry-all-errors "$1" -o "$2"; }

step() {
  # step "label" command...  -> runs with the living rune; on failure keeps going and records the pending command
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then rm_branch "$(rm_dim "$G_SKIP simulación: $label")"; return 0; fi
  if rm_run "$label" "" -- "$@"; then GRABADAS=$((GRABADAS + 1)); return 0; fi
  FALLIDAS=$((FALLIDAS + 1))
  tail -n 3 "$RM_LOG" 2>/dev/null | while IFS= read -r l; do rm_cont "$(rm_dim "$l")"; done
  return 1
}

add_rc_line() {
  local marker="$1" line="$2" needle="$3"
  [ -f "$RC" ] && grep -vE '^[[:space:]]*#' "$RC" | grep -qF -- "$needle" && return 0
  [ "$DRY" = 1 ] && return 0
  printf '\n# %s\n%s\n' "$marker" "$line" >> "$RC"
}

backup_file() { if [ -e "$1" ] && [ "$DRY" = 0 ]; then cp -p "$1" "$1.bak-$STAMP"; fi; }

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  set +u
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  set -u
}

opencode_version() {
  local oc
  oc="$(command -v opencode || echo "$HOME/.opencode/bin/opencode")"
  [ -x "$oc" ] || return 1
  "$oc" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
deck_version() { has deck || return 1; deck version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }

label() {
  case "$1" in
    node) echo "Node.js $NODE_MAJOR + cambio por .nvmrc" ;;
    gh) echo "GitHub CLI" ;;
    claude) echo "Claude Code" ;;
    opencode) echo "OpenCode $OPENCODE_VERSION" ;;
    codex) echo "Codex CLI" ;;
    vtex) echo "VTEX CLI" ;;
    shopify) echo "Shopify CLI" ;;
    deck) echo "Deck $DECK_VERSION" ;;
    library) echo "Biblioteca de skills" ;;
    remote) echo "Acceso desde el celular" ;;
  esac
}
short() { case "$1" in node) echo node ;; gh) echo gh ;; claude) echo claude ;; opencode) echo opencode ;; codex) echo codex ;; vtex) echo vtex ;; shopify) echo shopify ;; deck) echo deck ;; library) echo biblioteca ;; remote) echo celular ;; esac; }
rune_of() {
  case "$1" in
    node) echo "ᚦ" ;; gh) echo "ᚷ" ;; claude) echo "ᚲ" ;; opencode) echo "ᛟ" ;; codex) echo "ᚹ" ;;
    vtex) echo "ᚠ" ;; shopify) echo "ᛒ" ;; deck) echo "ᛞ" ;; library) echo "ᚱ" ;; remote) echo "ᛖ" ;;
  esac
}
needs_sudo() { case "$1" in vtex) return 0 ;; remote) [ "$PLATFORM" = linux ] ;; *) return 1 ;; esac; }

installed() {
  case "$1" in
    node) load_nvm; has nvm && [ "$(set +u; nvm version "$NODE_MAJOR")" != "N/A" ] ;;
    gh) has gh ;;
    claude) has claude ;;
    opencode) [ "$(opencode_version || true)" = "$OPENCODE_VERSION" ] ;;
    codex) has codex ;;
    vtex) has vtex ;;
    shopify) has shopify ;;
    deck) [ "v$(deck_version || true)" = "$DECK_VERSION" ] ;;
    library) [ "$(readlink "$BIN/rune" 2>/dev/null)" = "$LIB/bin/rune" ] && [ -f "$HOME/.claude/settings.json" ] && grep -q "$BIN/rune auto" "$HOME/.claude/settings.json" ;;
    remote) has tailscale ;;
  esac
}

compute_states() { local c; for c in $COMPONENTS; do if installed "$c"; then eval "STATE_$c=1"; else eval "STATE_$c=0"; fi; done; }
is_installed() { eval "[ \"\${STATE_$1:-0}\" = 1 ]"; }

# ---------- Welcome ----------

welcome() {
  rm_logo
  echo
  rm_head "El ritual empieza"
  rm_root "ᛞ"
  local found="" c pending=0
  for c in $COMPONENTS; do
    if is_installed "$c"; then found="$found$(short "$c") · "; elif sel "$c"; then pending=$((pending + 1)); fi
  done
  rm_branch "$(rm_dim "equipo")  $PLATFORM · $ARCH · bash ${BASH_VERSION%%(*}"
  [ -n "$found" ] && rm_branch "$(rm_done_txt "sellos encontrados" "${found% · }")"
  if [ "$pending" = 1 ]; then rm_last "$(rm_c "$P_BLUE" "$G_TODO") $(rm_gold "1 runa") por grabar"
  else rm_last "$(rm_c "$P_BLUE" "$G_TODO") $(rm_gold "$pending runas") por grabar"; fi
  echo
}

# ---------- Menu ----------

MENU_ITEMS="#ᚦ fundamentos|node|gh|claude|opencode|codex|#ᚠ plataformas|vtex|shopify|#ᛞ agentes|deck|library|#ᛖ acceso|remote"

menu_line() {
  local c="$1" cur="$2" conn="$3" mark text
  if is_installed "$c"; then
    text="$(rm_done_txt "$(label "$c")" "ya grabada")"
  elif sel "$c"; then
    text="$(rm_c "$P_BLUE" "$(rune_of "$c")") $(label "$c")  $(rm_gold "$G_PICK grabar")"
    needs_sudo "$c" && text="$text $(rm_c "$P_AMBER" "sudo")"
  else
    text="$(rm_dim "$G_SKIP $(label "$c")  omitir")"
    needs_sudo "$c" && text="$text $(rm_dim "sudo")"
  fi
  if [ "$cur" = 1 ]; then mark="$(rm_gold "$G_STAR")"; else mark=" "; fi
  printf '\r\033[K     %s %s%s\n' "$(rm_dim "$conn")" "$mark" "$text"
}

menu_draw() {
  local cur_idx="$1" i=0 k=0 entry next conn n items
  IFS='|' read -r -a items <<< "$MENU_ITEMS"
  n=${#items[@]}
  while [ "$k" -lt "$n" ]; do
    entry="${items[$k]}"
    if [ "${entry:0:1}" = "#" ]; then
      printf '\r\033[K  %s%s %s\n' "$(rm_gold "${entry:1:1}")" "$(rm_dim "━━┓")" "$(rm_dim "${entry:3}")"
    else
      next="${items[$((k + 1))]:-#}"
      if [ "${next:0:1}" = "#" ]; then conn="┗━"; else conn="┣━"; fi
      if [ "$i" = "$cur_idx" ]; then menu_line "$entry" 1 "$conn"; else menu_line "$entry" 0 "$conn"; fi
      i=$((i + 1))
    fi
    k=$((k + 1))
  done
  printf '\r\033[K  %s' "$(rm_dim "↑↓ moverse · espacio grabar u omitir · a todo · n nada · enter seguir")"
}

menu() {
  local items keys=() lines=0 e count cur=0 key rest c
  IFS='|' read -r -a items <<< "$MENU_ITEMS"
  for e in "${items[@]}"; do lines=$((lines + 1)); [ "${e:0:1}" = "#" ] || keys+=("$e"); done
  count=${#keys[@]}
  rm_head "Elige tus runas"
  rm_cursor_hide
  menu_draw "$cur"
  while :; do
    key=""
    IFS= read -rsn1 -u 3 key || break
    case "$key" in
      $'\e') rest=""; IFS= read -rsn2 -u 3 rest || true
        case "$rest" in '[A'|'OA') cur=$(( (cur - 1 + count) % count )) ;; '[B'|'OB') cur=$(( (cur + 1) % count )) ;; esac ;;
      k) cur=$(( (cur - 1 + count) % count )) ;;
      j) cur=$(( (cur + 1) % count )) ;;
      ' ') c="${keys[$cur]}"; is_installed "$c" || { if sel "$c"; then eval "SEL_$c=0"; else eval "SEL_$c=1"; fi; } ;;
      a|A) for c in "${keys[@]}"; do eval "SEL_$c=1"; done ;;
      n|N) for c in "${keys[@]}"; do eval "SEL_$c=0"; done ;;
      ''|$'\n'|$'\r') break ;;
    esac
    printf '\r\033[%dA' "$lines"
    menu_draw "$cur"
  done
  rm_cursor_show
  printf '\n\n'
}

select_components() {
  compute_states
  welcome
  if [ "$INTERACTIVE" = 1 ] && [ "$RM_COLOR" != none ]; then menu; fi
  if { sel shopify || sel codex; } && ! sel node && ! is_installed node; then rm_warn "Shopify CLI y Codex se instalan con npm: agrego Node.js"; SEL_node=1; fi
  if sel library && ! sel claude && ! has claude; then rm_warn "la biblioteca necesita Claude Code: la agrego"; SEL_claude=1; fi
  if [ "$INTERACTIVE" = 1 ]; then rm_ask "¿Empezamos el ritual?" y || die "Cancelado"; fi
}

# ---------- Sudo seal ----------

sudo_seal() {
  echo
  rm_seal "Sello de protección" "$1 necesita sudo" "$(rm_dim "la contraseña la pide sudo; rune nunca la ve")"
  [ "$DRY" = 1 ] && return 0
  if [ "$INTERACTIVE" = 1 ] && ! rm_ask "¿Continuar?" y; then return 1; fi
  if [ "$RM_IN" = 1 ]; then sudo -v <&3; else sudo -v; fi
}

# ---------- Install steps ----------

do_base() {
  local missing=() c
  for c in git curl python3 tar; do has "$c" || missing+=("$c"); done
  [ "$PLATFORM" = linux ] || has unzip || missing+=("unzip")
  [ "${#missing[@]}" -eq 0 ] && return 0
  [ "$PLATFORM" = macos ] && die "faltan ${missing[*]}: instala las Command Line Tools con 'xcode-select --install' y vuelve a correr esto"
  sudo_seal "instalar ${missing[*]}" || die "las herramientas base son necesarias"
  if has apt-get; then step "herramientas base" sudo apt-get install -y -qq "${missing[@]}"
  elif has dnf; then step "herramientas base" sudo dnf install -y -q "${missing[@]}"
  else die "instala ${missing[*]} con el gestor de paquetes de tu sistema"; fi
}

do_node() {
  load_nvm
  if [ ! -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    download "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" "$TMP/nvm.sh"
    step "nvm $NVM_VERSION" env PROFILE="$RC" bash "$TMP/nvm.sh" || { TODO+=("nvm: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"); return 0; }
    load_nvm
  fi
  if ! has nvm && [ "$DRY" = 0 ]; then TODO+=("abre una terminal nueva y corre de nuevo: rune install"); return 0; fi
  set +u
  if [ "$DRY" = 1 ] || [ "$(nvm version "$NODE_MAJOR")" = "N/A" ]; then step "Node.js $NODE_MAJOR" nvm install "$NODE_MAJOR" || TODO+=("nvm install $NODE_MAJOR"); fi
  if [ "$DRY" = 0 ]; then
    [ "$(nvm version default)" != "N/A" ] || nvm alias default "$NODE_MAJOR" >/dev/null
    nvm use "$NODE_MAJOR" >/dev/null 2>&1 || true
  fi
  set -u
  add_rc_line "Cambio automático de Node por .nvmrc (Runemind)" ". \"$LIB/config/shell/nvm-auto.sh\"" "nvm-auto.sh"
}

do_gh() {
  local tag ver asset
  tag="$(curl -fsSL --retry 3 --retry-all-errors https://api.github.com/repos/cli/cli/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)"
  if [ -z "$tag" ]; then rm_branch "$(rm_fail_txt "GitHub CLI" "no pude consultar la versión")"; FALLIDAS=$((FALLIDAS + 1)); TODO+=("gh: https://cli.github.com"); return 0; fi
  ver="${tag#v}"
  mkdir -p "$BIN"
  if [ "$PLATFORM" = linux ]; then asset="gh_${ver}_linux_${ARCH}.tar.gz"; else asset="gh_${ver}_macOS_${ARCH}.zip"; fi
  if [ "$DRY" = 1 ]; then rm_branch "$(rm_dim "$G_SKIP simulación: GitHub CLI $ver")"; return 0; fi
  if rm_download "https://github.com/cli/cli/releases/download/$tag/$asset" "$TMP/$asset" "GitHub CLI $ver"; then
    if [ "$PLATFORM" = linux ]; then tar -xzf "$TMP/$asset" -C "$TMP"; cp "$TMP/gh_${ver}_linux_${ARCH}/bin/gh" "$BIN/gh"
    else unzip -q "$TMP/$asset" -d "$TMP"; cp "$TMP/gh_${ver}_macOS_${ARCH}/bin/gh" "$BIN/gh"; fi
    GRABADAS=$((GRABADAS + 1))
  else
    FALLIDAS=$((FALLIDAS + 1)); TODO+=("gh: https://cli.github.com")
  fi
}

do_claude() {
  if ! download "https://claude.ai/install.sh" "$TMP/claude.sh"; then rm_branch "$(rm_fail_txt "Claude Code" "no pude descargar el instalador")"; FALLIDAS=$((FALLIDAS + 1)); TODO+=("Claude Code: curl -fsSL https://claude.ai/install.sh | bash"); return 0; fi
  step "Claude Code" bash "$TMP/claude.sh" || TODO+=("Claude Code: curl -fsSL https://claude.ai/install.sh | bash")
}

do_opencode() {
  local current
  current="$(opencode_version || true)"
  if [ -n "$current" ]; then
    rm_warn "tienes opencode $current; deck $DECK_VERSION necesita $OPENCODE_VERSION"
    if [ "$INTERACTIVE" = 1 ] && ! rm_ask "¿Reemplazarlo?" y; then rm_info "se queda opencode $current"; return 0; fi
    if [ "${current%%.*}" -ge 2 ] && [ -f "$HOME/.local/share/opencode/opencode.db" ] && [ "$DRY" = 0 ]; then
      mv "$HOME/.local/share/opencode/opencode.db" "$HOME/.local/share/opencode/opencode.db.v2-$STAMP"
      rm_info "la base de OpenCode 2.x quedó aparte; vas a tener que vincular OpenCode de nuevo"
    fi
  fi
  if ! download "https://opencode.ai/install" "$TMP/opencode.sh"; then rm_branch "$(rm_fail_txt "OpenCode" "no pude descargar el instalador")"; FALLIDAS=$((FALLIDAS + 1)); TODO+=("OpenCode: curl -fsSL https://opencode.ai/install | bash -s -- --version $OPENCODE_VERSION"); return 0; fi
  step "OpenCode $OPENCODE_VERSION" bash "$TMP/opencode.sh" --version "$OPENCODE_VERSION" --no-modify-path || TODO+=("OpenCode: curl -fsSL https://opencode.ai/install | bash -s -- --version $OPENCODE_VERSION")
  add_rc_line "opencode" "export PATH=\$HOME/.opencode/bin:\$PATH" ".opencode/bin"
}

do_codex() { load_nvm; step "Codex CLI" npm install -g @openai/codex || TODO+=("npm install -g @openai/codex"); }
do_shopify() { load_nvm; step "Shopify CLI" npm install -g @shopify/cli || TODO+=("npm install -g @shopify/cli"); }

do_vtex() {
  if ! sudo_seal "VTEX CLI (se graba en /usr/local)"; then TODO+=("VTEX CLI: curl -L https://vtex.io/vtexcli/install | sh"); return 0; fi
  if ! download "https://vtex.io/vtexcli/install" "$TMP/vtex.sh"; then FALLIDAS=$((FALLIDAS + 1)); TODO+=("VTEX CLI: curl -L https://vtex.io/vtexcli/install | sh"); return 0; fi
  step "VTEX CLI" sh "$TMP/vtex.sh" || TODO+=("VTEX CLI: curl -L https://vtex.io/vtexcli/install | sh")
}

do_deck() {
  if ! download "https://raw.githubusercontent.com/kevin15011/deck/main/scripts/install.sh" "$TMP/deck.sh"; then rm_branch "$(rm_fail_txt "Deck" "no pude descargar el instalador")"; FALLIDAS=$((FALLIDAS + 1)); TODO+=("rune install   (deck quedó pendiente)"); return 0; fi
  step "Deck $DECK_VERSION" bash "$TMP/deck.sh" --version "$DECK_VERSION" --dir "$BIN" \
    || step "Deck $DECK_VERSION (reintento)" bash "$TMP/deck.sh" --version "$DECK_VERSION" --dir "$BIN" \
    || TODO+=("rune install   (deck quedó pendiente)")
}

configure_claude() {
  local dir="$HOME/.claude" settings="$HOME/.claude/settings.json"
  mkdir -p "$dir"
  if [ -f "$settings" ] && grep -q "$BIN/rune auto --hook" "$settings"; then return 0; fi
  backup_file "$settings"
  python3 - "$settings" "$BIN/rune" <<'EOF'
import json, os, sys
path, rune = sys.argv[1], sys.argv[2]
data = json.load(open(path)) if os.path.exists(path) else {}
hooks = data.setdefault("hooks", {}).setdefault("SessionStart", [])
cmd = f"{rune} auto --hook"
found = False
for entry in hooks:
    for h in entry.get("hooks", []):
        c = h.get("command", "")
        if "skillpack auto" in c or "rune auto" in c:
            h["command"] = cmd
            found = True
if not found:
    hooks.append({"matcher": "startup", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]})
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
EOF
}

do_library_inner() {
  local cmd
  mkdir -p "$BIN"
  ln -sfn "$LIB/bin/rune" "$BIN/rune"
  # skillpack and deck-remote were renamed to rune long ago; drop their dangling links
  for cmd in skillpack deck-remote; do
    if [ -L "$BIN/$cmd" ] && [ ! -e "$BIN/$cmd" ]; then rm -f "$BIN/$cmd"; fi
  done
  add_rc_line "Binarios locales (claude, gh, deck, rune)" "export PATH=\"\$PATH:$BIN\"" ".local/bin"
  "$LIB/bin/rune" setup --quiet
  configure_claude
}

do_library() {
  if [ "$DRY" = 1 ]; then rm_branch "$(rm_dim "$G_SKIP simulación: biblioteca, marketplace runemind y hook")"; return 0; fi
  step "Biblioteca · rune · marketplace runemind" do_library_inner || TODO+=("rune setup")
}

do_remote() {
  if ! has tailscale; then
    if [ "$PLATFORM" = macos ]; then
      if has brew; then step "Tailscale" brew install --cask tailscale || true
      else rm_info "instala la app de Tailscale desde la Mac App Store"; TODO+=("Tailscale: instala la app y después corre rune remote on"); return 0; fi
    else
      sudo_seal "Tailscale" || { TODO+=("Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"); return 0; }
      if ! download "https://tailscale.com/install.sh" "$TMP/tailscale.sh"; then TODO+=("Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"); return 0; fi
      step "Tailscale" sh "$TMP/tailscale.sh" || { TODO+=("Tailscale: curl -fsSL https://tailscale.com/install.sh | sh"); return 0; }
    fi
  fi
  if [ "$PLATFORM" = linux ] && [ "$DRY" = 0 ] && has tailscale; then
    # the log belongs to the user; only tailscale needs root
    # shellcheck disable=SC2024
    sudo tailscale set --operator="$USER" >> "$RM_LOG" 2>&1 || TODO+=("sudo tailscale set --operator=\$USER   (permiso para rune remote)")
  fi
}

# ---------- After deck ----------

supermemory_wanted() {
  local cfg="$HOME/.config/deck/config.json"
  [ -f "$cfg" ] || return 1
  python3 -c 'import json,sys;m=json.load(open(sys.argv[1])).get("adaptiveMemory",{});sys.exit(0 if m.get("enabled") and m.get("activeProvider")=="supermemory" else 1)' "$cfg" 2>/dev/null
}

save_supermemory_key() {
  local file="$HOME/.config/deck/secrets/supermemory-api-key.secret" key=""
  [ -s "$file" ] && return 0
  supermemory_wanted || return 0
  if [ "$INTERACTIVE" != 1 ]; then TODO+=("clave de runtime de Supermemory: rune install --post-deck"); return 0; fi
  rm_ask "Deck tiene Supermemory activado y falta su clave de runtime. ¿La sellamos ahora?" y || return 0
  rm_read "Clave de Supermemory (no se muestra):" key secret
  key="$(printf '%s' "$key" | LC_ALL=C sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' | LC_ALL=C tr -d '[:space:][:cntrl:]')"
  if [ -z "$key" ]; then rm_warn "clave vacía, no se guardó"; return 0; fi
  case "$key" in sm_*) ;; *) rm_warn "la clave no empieza con sm_; revísala en el panel de Supermemory" ;; esac
  mkdir -p "$(dirname "$file")"; chmod 700 "$(dirname "$file")"
  (umask 077; printf '%s' "$key" > "$file")
  key=""
  rm_branch "$(rm_done_txt "clave de Supermemory sellada" "${file/#$HOME/~}")"
}

post_deck() {
  local cfg="$HOME/.config/opencode/opencode.json" cbm=""
  [ -f "$cfg" ] || return 0
  if [ "$DRY" = 1 ]; then rm_branch "$(rm_dim "$G_SKIP simulación: ajustes de OpenCode")"; return 0; fi
  cbm="$(command -v codebase-memory-mcp || true)"
  [ -z "$cbm" ] && [ -x "$BIN/codebase-memory-mcp" ] && cbm="$BIN/codebase-memory-mcp"
  backup_file "$cfg"
  python3 - "$cfg" "$cbm" <<'EOF'
import json, sys
path, cbm = sys.argv[1], sys.argv[2]
data = json.load(open(path))
if data.get("autoupdate") is not False:
    data["autoupdate"] = False
mcp = data.setdefault("mcp", {})
if cbm and "codebase-memory-mcp" not in mcp:
    mcp["codebase-memory-mcp"] = {"type": "local", "command": [cbm], "enabled": True}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
EOF
  rm_branch "$(rm_done_txt "ajustes de OpenCode" "sin actualización automática · codebase-memory")"
  save_supermemory_key
}

# ---------- Links (logins) ----------

claude_logged_in() { claude auth status --json 2>/dev/null | python3 -c 'import json,sys;sys.exit(0 if json.load(sys.stdin).get("loggedIn") else 1)' 2>/dev/null; }
opencode_credentials() { opencode auth list 2>/dev/null | grep -oE '[0-9]+ credentials' | grep -oE '[0-9]+' || echo 0; }
tailscale_connected() { has tailscale && tailscale status >/dev/null 2>&1; }

need_gh() { has gh && ! gh auth status >/dev/null 2>&1; }
need_claude() { has claude && ! claude_logged_in; }
need_opencode() { has opencode && [ "$(opencode_credentials)" = 0 ]; }
need_codex() { has codex && [ ! -s "$HOME/.codex/auth.json" ]; }
need_vtex() { has vtex && [ ! -d "$HOME/.vtex/session" ]; }
need_tailscale() { sel remote && has tailscale && ! tailscale_connected; }

links() {
  [ "$LOGINS" = 1 ] && [ "$INTERACTIVE" = 1 ] || return 0
  need_gh || need_claude || need_opencode || need_codex || need_vtex || need_tailscale || return 0
  echo
  rm_head "Vínculos"
  rm_line "  $(rm_dim "cada herramienta pide sus propias credenciales; rune no las ve ni las guarda")"
  rm_root "$G_SEAL"
  if need_gh && rm_ask "¿Vincular GitHub (gh auth login)?" y; then gh auth login <&3 || rm_warn "gh auth login no terminó"; fi
  if need_claude && rm_ask "¿Vincular Claude (claude auth login)?" y; then claude auth login <&3 || rm_warn "claude auth login no terminó"; fi
  if need_opencode && rm_ask "¿Vincular OpenCode (OpenCode Go, Console…)?" y; then
    while :; do opencode auth login <&3 || rm_warn "opencode auth login no terminó"; rm_ask "¿Vincular otro proveedor?" n || break; done
  fi
  if need_codex && rm_ask "¿Vincular Codex (codex login)?" y; then codex login <&3 || rm_warn "codex login no terminó"; fi
  if need_vtex && rm_ask "¿Vincular VTEX?" n; then
    local account=""
    rm_read "Cuenta de VTEX (ej. mitienda):" account
    if [ -n "$account" ]; then vtex login "$account" <&3 || rm_warn "vtex login no terminó"; fi
  fi
  if need_tailscale && rm_ask "¿Conectar este equipo a Tailscale (sudo tailscale up)?" y; then sudo tailscale up <&3 || rm_warn "tailscale up no terminó"; fi
}

pending_steps() {
  need_gh && TODO+=("gh auth login   (con la cuenta que tiene acceso a Runemind; puedes tener también la de trabajo)")
  need_claude && TODO+=("claude auth login")
  need_opencode && TODO+=("opencode auth login   (OpenCode Go; y Console si lo usas)")
  need_codex && TODO+=("codex login")
  need_vtex && TODO+=("vtex login <cuenta>")
  if has tailscale && ! tailscale_connected; then TODO+=("sudo tailscale up   (y después: rune remote on)")
  elif sel remote && has tailscale; then TODO+=("rune remote on   (deck en tu celular)"); fi
  if has deck && [ ! -f "$HOME/.local/share/deck/claude/model-assignments.json" ]; then
    TODO+=("deck → Start installation (Claude + OpenCode; rtk, context-mode, codebase-memory, context7, serena, Tavily)")
    TODO+=("deck → Configure models (elige el modelo de cada rol a tu gusto)")
  fi
  local cfg="$HOME/.config/opencode/opencode.json"
  if has deck && has opencode && { [ ! -f "$cfg" ] || ! python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get("autoupdate") is False and "codebase-memory-mcp" in d.get("mcp",{}) else 1)' "$cfg" 2>/dev/null; }; then
    TODO+=("rune install --post-deck   (después de configurar OpenCode en deck)")
  fi
  return 0
}

summary() {
  local i=0 t n
  echo
  rm_frame top
  rm_line "  $(rm_grad "R U N A S   G R A B A D A S")"
  rm_line "  $(rm_dim "$(rm_elapsed $((SECONDS - STARTED))) · $GRABADAS grabadas · $FALLIDAS quebradas")"
  rm_frame bottom
  pending_steps
  n=${#TODO[@]}
  if [ "$n" -gt 0 ]; then
    echo
    rm_head "Por grabar"
    rm_root "$G_FAIL"
    for t in "${TODO[@]}"; do
      i=$((i + 1))
      if [ "$i" = "$n" ]; then rm_last "$(rm_c "$P_BLUE" "$G_TODO") $t"; else rm_branch "$(rm_c "$P_BLUE" "$G_TODO") $t"; fi
    done
  fi
  echo
  rm_line "  $(rm_dim "abre una terminal nueva para que se apliquen los cambios · detalle: rune log")"
}

# ---------- main ----------

export PATH="$BIN:$HOME/.opencode/bin:$PATH"

if [ "$MODE" = post-deck ]; then
  rm_head "Ajustes después de deck"
  rm_root "ᛞ"
  post_deck
  rm_last "$(rm_dim "listo")"
  summary
  exit 0
fi

select_components
TOTAL=0
for c in $COMPONENTS; do if sel "$c" && ! is_installed "$c"; then TOTAL=$((TOTAL + 1)); fi; done
rm_head "Grabando runas" "$TOTAL por grabar"
rm_root "$G_ROOT"
do_base
for c in $COMPONENTS; do
  sel "$c" || continue
  if is_installed "$c"; then
    case "$c" in
      library) do_library ;;
      node) add_rc_line "Cambio automático de Node por .nvmrc (Runemind)" ". \"$LIB/config/shell/nvm-auto.sh\"" "nvm-auto.sh"; rm_branch "$(rm_done_txt "$(label "$c")" "ya estaba")" ;;
      *) rm_branch "$(rm_done_txt "$(label "$c")" "ya estaba")" ;;
    esac
    continue
  fi
  "do_$c"
done
post_deck
rm_last "$(rm_dim "el ritual terminó")"
links
summary
