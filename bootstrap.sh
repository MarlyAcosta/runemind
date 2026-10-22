#!/usr/bin/env bash
# Runemind bootstrap: puts the public core in ~/runemind (only owner-signed commits), migrates an install of
# the old single private repo, and runs the installer. Safe to run again at any time.
#   curl -fsSL https://raw.githubusercontent.com/MarlyAcosta/runemind/main/bootstrap.sh | bash
set -euo pipefail

CORE_URL="${RUNEMIND_CORE_URL:-https://github.com/MarlyAcosta/runemind.git}"
DEST="${RUNEMIND_DIR:-$HOME/runemind}"
BIN="$HOME/.local/bin"
# 1: prepare ~/runemind and stop, without prompts or the installer (tests)
ONLY="${RUNEMIND_BOOTSTRAP_ONLY:-0}"
# the owner key that signs the core (same line as security/allowed_signers)
SIGNERS_LINE='runemind-owner namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDP++CeOkr4LNINI/f6IOlvw47L2eEAgXDWUXXzGD2YH'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SIGNERS="${RUNEMIND_ALLOWED_SIGNERS_FILE:-$TMP/allowed_signers}"
[ -n "${RUNEMIND_ALLOWED_SIGNERS_FILE:-}" ] || printf '%s\n' "$SIGNERS_LINE" > "$SIGNERS"

say()  { printf '%s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

if [ "$ONLY" = 1 ]; then exec 3</dev/null
else exec 3</dev/tty 2>/dev/null || die "se necesita una terminal interactiva (no lo corras desde un script sin terminal)"; fi

case "$(uname -s)" in
  Linux) PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) die "sistema no soportado: $(uname -s) (deck solo corre en Linux y macOS)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "arquitectura no soportada: $(uname -m)" ;;
esac

say "Runemind: preparando este equipo ($PLATFORM/$ARCH)"

# ssh-keygen checks the owner's signature on every update
if ! has git || ! has python3 || ! has ssh-keygen; then
  if [ "$PLATFORM" = macos ]; then
    die "faltan git, python3 o ssh-keygen: instala las Command Line Tools con 'xcode-select --install' y vuelve a correr esto"
  fi
  has apt-get && [ "$ONLY" != 1 ] || die "faltan git, python3 o ssh-keygen; instálalos con el gestor de paquetes de tu sistema"
  say "faltan git, python3 o ssh-keygen; se instalan con sudo (te pedirá tu contraseña)"
  sudo apt-get update -qq <&3
  sudo apt-get install -y git python3 openssh-client <&3
fi

export PATH="$BIN:$PATH"

if ! has gh && [ "$ONLY" != 1 ]; then
  say "instalando GitHub CLI en $BIN"
  tag="$(curl -fsSL --retry 3 --retry-all-errors https://api.github.com/repos/cli/cli/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
  ver="${tag#v}"
  mkdir -p "$BIN"
  if [ "$PLATFORM" = linux ]; then
    asset="gh_${ver}_linux_${ARCH}.tar.gz"
    curl -fsSL --retry 3 --retry-all-errors "https://github.com/cli/cli/releases/download/$tag/$asset" -o "$TMP/$asset"
    tar -xzf "$TMP/$asset" -C "$TMP"
    cp "$TMP/gh_${ver}_linux_${ARCH}/bin/gh" "$BIN/gh"
  else
    asset="gh_${ver}_macOS_${ARCH}.zip"
    curl -fsSL --retry 3 --retry-all-errors "https://github.com/cli/cli/releases/download/$tag/$asset" -o "$TMP/$asset"
    unzip -q "$TMP/$asset" -d "$TMP"
    cp "$TMP/gh_${ver}_macOS_${ARCH}/bin/gh" "$BIN/gh"
  fi
fi

# The core is public; GitHub is only needed for private grimorios (rune finds them with your gh accounts).
accounts() { has gh && gh auth status 2>/dev/null | sed -nE 's/.*Logged in to github.com account ([^ ]+).*/\1/p'; return 0; }
if [ "$ONLY" != 1 ] && [ -z "$(accounts)" ]; then
  say ""
  printf '¿Tienes acceso a un grimorio privado de Runemind? Inicia sesión en GitHub con esa cuenta [S/n] '
  read -r answer <&3 || answer=n
  case "$answer" in
    n|N|no) say "sigo sin GitHub: tendrás el núcleo público; después puedes correr 'gh auth login' y 'rune update'" ;;
    *) gh auth login --hostname github.com --git-protocol https --web <&3 || say "no se pudo iniciar sesión; sigo con el núcleo público" ;;
  esac
fi

# owner_signed dir commit / clone_core dir: same rules as rune (lib/grimorios.sh)
owner_signed() {
  case "$(git -C "$1" cat-file commit "$2" 2>/dev/null)" in
    *"gpgsig -----BEGIN SSH SIGNATURE-----"*) ;;
    *) return 1 ;;
  esac
  git -C "$1" -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-commit "$2" >/dev/null 2>&1
}

clone_core() {
  local dir="$1" c
  git -c init.defaultBranch=main init -q "$dir"
  git -C "$dir" remote add origin "$CORE_URL"
  GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet origin main || { rm -rf "$dir"; return 1; }
  for c in $(git -C "$dir" rev-list --first-parent FETCH_HEAD); do
    if owner_signed "$dir" "$c"; then
      git -C "$dir" checkout --quiet -b main "$c"
      git -C "$dir" branch --quiet --set-upstream-to=origin/main main 2>/dev/null || true
      return 0
    fi
  done
  rm -rf "$dir"
  say "ningún commit de $CORE_URL tiene la firma del dueño"
  return 1
}

# the old layout: one private repo with the CLI and the skills (grimorio.json, or plugins/vtex without signers)
is_legacy() { [ -f "$1/grimorio.json" ] || { [ -d "$1/plugins/vtex" ] && [ ! -f "$1/security/allowed_signers" ]; }; }

if [ -d "$DEST/.git" ] && is_legacy "$DEST"; then
  say "migrando $DEST: el núcleo ahora es público y tus skills pasan a un grimorio privado"
  parent="$(dirname "$DEST")"; new="$parent/.runemind-core-$$"; hold="$parent/.runemind-legacy-$$"
  if clone_core "$new" && ! is_legacy "$new"; then
    mv "$DEST" "$hold"
    mv "$new" "$DEST" || { mv "$hold" "$DEST"; die "no pude mover el núcleo a $DEST"; }
    "$DEST/bin/rune" update --adopt "$hold" --quiet || say "la migración de los grimorios quedó a medias; corre: rune update"
  else
    # the public core is not published yet (or unreachable): keep the current install and update it
    rm -rf "$new"
    say "el núcleo público todavía no está disponible; actualizo la instalación actual"
    "$DEST/bin/rune" update --quiet || say "no se pudo actualizar; sigo con la versión local"
  fi
elif [ -d "$DEST/.git" ]; then
  say "actualizando $DEST"
  "$DEST/bin/rune" update --quiet || say "no se pudo actualizar; sigo con la versión local"
elif [ -e "$DEST" ]; then
  die "$DEST existe pero no es una instalación de Runemind; muévelo o usa RUNEMIND_DIR=otra/ruta"
else
  say "clonando el núcleo de Runemind en $DEST"
  clone_core "$DEST" || die "no pude clonar $CORE_URL"
fi

[ "$ONLY" = 1 ] && exit 0
say ""
exec bash "$DEST/install.sh" "$@" <&3
