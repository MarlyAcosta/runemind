# shellcheck shell=bash
# Runemind grimorios: owner-signed updates, discovery of private grimorio repos, access admin, revocation
# tidying and the migration from the old single-repo layout. Sourced by bin/rune, which provides LIB,
# CATALOG_PY, CATALOG, US, MARKET, QUIET, the rm_* helpers and the pack_* / off_pack functions.

CORE_URL="${RUNEMIND_CORE_URL:-https://github.com/MarlyAcosta/runemind.git}"
# where the old private library went when the public core took its name (migration only)
LEGACY_GRIMORIO_URL="${RUNEMIND_LEGACY_GRIMORIO_URL:-https://github.com/MarlyAcosta/runemind-grimorios.git}"
GRIMORIOS="$LIB/grimorios"
TOPIC="runemind-grimorio"
SIGNERS="$LIB/security/allowed_signers"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/runemind"
PROJECTS="$STATE/projects"
GHJSON="$LIB/lib/ghjson.py"

# Git authenticates with the token of the gh account recorded in the clone (runemind.account);
# the active gh account is never switched.
# shellcheck disable=SC2016
GIT_HELPER='!f() { test "$1" = get || exit 0; a=$(git config runemind.account) || exit 0; echo username=x-access-token; echo "password=$(gh auth token -u "$a")"; }; f'

note() { [ "$QUIET" = 1 ] || rm_branch "$*"; }
warn() { [ "$QUIET" = 1 ] || rm_warn "$*"; }

# the old layout: this checkout is the private library itself (core + skills, grimorio.json at the root)
is_legacy() { [ -f "$LIB/grimorio.json" ]; }

# ---------- owner signatures ----------

# owner_signed dir commit: the commit carries an SSH signature by a key in security/allowed_signers
owner_signed() {
  [ -f "$SIGNERS" ] || return 1
  case "$(git -C "$1" cat-file commit "$2" 2>/dev/null)" in
    *"gpgsig -----BEGIN SSH SIGNATURE-----"*) ;;
    *) return 1 ;;
  esac
  git -C "$1" -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-commit "$2" >/dev/null 2>&1
}

# signed_target dir tip [base] -> "<commit> <n>": the newest commit on tip's first-parent line that the owner
# signed (and that contains base), and how many commits above it were skipped; "- <n>" if there is none.
# An owner-signed merge vouches for its whole tree, unsigned second parents included.
signed_target() {
  local dir="$1" tip="$2" base="${3:-}" c n=0
  for c in $(git -C "$dir" rev-list --first-parent "$tip" ${base:+"^$base"}); do
    if owner_signed "$dir" "$c" && { [ -z "$base" ] || git -C "$dir" merge-base --is-ancestor "$base" "$c"; }; then
      echo "$c $n"
      return 0
    fi
    n=$((n + 1))
  done
  echo "- $n"
  return 1
}

# signed_pull dir label: fetch origin main and fast-forward to its newest owner-signed commit; the commits
# above it (unsigned or signed by someone else) are reported and left out. The installed HEAD is the baseline.
signed_pull() {
  local dir="$1" label="$2" tip head res target n
  if ! GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet origin main 2>/dev/null; then
    warn "$label: no pude conectarme con su repositorio; sigo con la versión local"
    return 1
  fi
  tip="$(git -C "$dir" rev-parse FETCH_HEAD)"
  head="$(git -C "$dir" rev-parse HEAD)"
  [ "$tip" = "$head" ] && { note "$(rm_done_txt "$label" "al día")"; return 0; }
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$tip"; then
    if git -C "$dir" merge-base --is-ancestor "$tip" HEAD; then note "$(rm_done_txt "$label" "tu copia va por delante")"
    else warn "$label: origin/main ya no contiene tu versión (¿historia reescrita?); no actualicé"; fi
    return 0
  fi
  res="$(signed_target "$dir" "$tip" HEAD || true)"
  target="${res% *}"; n="${res#* }"
  if [ "$target" != - ]; then
    if ! git -C "$dir" merge --ff-only --quiet "$target" >/dev/null 2>&1; then
      warn "$label: no pude avanzar (¿cambios locales en $dir?)"
      return 1
    fi
    note "$(rm_done_txt "$label" "actualizado a $(git -C "$dir" rev-parse --short HEAD)")"
  fi
  if [ "$n" != 0 ]; then
    warn "$label: ignoré $n commit(s) de origin/main que no firmó el dueño (se instalan cuando el dueño firme encima)"
  fi
  return 0
}

# clone_signed url dir [account]: clone and check out the newest owner-signed commit of main
clone_signed() {
  local url="$1" dir="$2" acct="${3:-}" res
  [ ! -e "$dir" ] || return 1
  git -c init.defaultBranch=main init -q "$dir"
  git -C "$dir" remote add origin "$url"
  [ -z "$acct" ] || set_clone_auth "$dir" "$acct"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet origin main 2>/dev/null; then
    rm -rf -- "$dir"
    return 1
  fi
  if ! res="$(signed_target "$dir" FETCH_HEAD)"; then
    rm -rf -- "$dir"
    warn "$url no tiene ningún commit firmado por el dueño; no lo instalé"
    return 1
  fi
  git -C "$dir" checkout --quiet -b main "${res% *}"
  git -C "$dir" branch --quiet --set-upstream-to=origin/main main 2>/dev/null || true
  [ "${res#* }" = 0 ] || warn "$(basename "$dir"): ignoré ${res#* } commit(s) recientes sin la firma del dueño"
}

set_clone_auth() {
  git -C "$1" config runemind.account "$2"
  git -C "$1" config --replace-all credential.https://github.com.helper ''
  git -C "$1" config --add credential.https://github.com.helper "$GIT_HELPER"
}

# ---------- GitHub through gh, one account at a time ----------

gh_accounts() { has gh && gh auth status 2>/dev/null | sed -nE 's/.*Logged in to github.com account ([^ ]+).*/\1/p'; return 0; }

# gh_as account args…: gh with that account's token (never the active account by accident)
gh_as() {
  local token
  token="$(gh auth token -u "$1" 2>/dev/null)" && [ -n "$token" ] || return 1
  shift
  GH_TOKEN="$token" gh "$@"
}

trusted_owners() { python3 -I "$CATALOG_PY" owners; }

# discover -> "full_name<TAB>clone_url<TAB>account" for every repo with the grimorio topic, owned by a trusted
# owner, that some gh account owns or collaborates on (first account wins)
discover() {
  local a owners
  owners="$(trusted_owners | tr '\n' ' ')"
  for a in $(gh_accounts); do
    # shellcheck disable=SC2086
    gh_as "$a" api --paginate "user/repos?affiliation=owner,collaborator&per_page=100" 2>/dev/null \
      | python3 -I "$GHJSON" repos "$a" "$TOPIC" $owners || true
  done | awk -F '\t' '!seen[$1]++'
}

# accept_invitations: teammates get a repository invitation from `rune admin grant`; rune accepts it for them
accept_invitations() {
  local a owners id full
  owners="$(trusted_owners | tr '\n' ' ')"
  for a in $(gh_accounts); do
    # shellcheck disable=SC2086
    while IFS=$'\t' read -r id full; do
      [ -n "$id" ] || continue
      if gh_as "$a" api -X PATCH "user/repository_invitations/$id" --silent >/dev/null 2>&1; then
        note "$(rm_done_txt "invitación a $full" "aceptada con $a")"
      fi
    done <<< "$(gh_as "$a" api "user/repository_invitations" 2>/dev/null | python3 -I "$GHJSON" invitations "$TOPIC" $owners || true)"
  done
}

gh_online() {
  local a
  for a in $(gh_accounts); do gh_as "$a" api user --silent >/dev/null 2>&1 && return 0; done
  return 1
}

# ---------- grimorio clones ----------

grimorio_dirs() {
  local d
  for d in "$GRIMORIOS"/*/; do [ -d "$d.git" ] && printf '%s\n' "${d%/}"; done
  return 0
}

# sync_grimorios: accept invitations, clone new grimorios, update the rest (owner-signed) and tidy away the
# ones no account can read any more
sync_grimorios() {
  local list full url acct name dir
  if [ -z "$(gh_accounts)" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] && { signed_pull "$dir" "grimorio $(basename "$dir")" || true; }
    done <<< "$(grimorio_dirs)"
    note "$(rm_todo_txt "grimorios privados" "inicia sesión en gh para descubrir los que puedes leer")"
    return 0
  fi
  accept_invitations
  list="$(discover)"
  mkdir -p "$GRIMORIOS"
  while IFS=$'\t' read -r full url acct; do
    [ -n "$full" ] || continue
    name="${full#*/}"; dir="$GRIMORIOS/$name"
    if [ -d "$dir/.git" ]; then
      if [ "$(git -C "$dir" config runemind.repo 2>/dev/null)" != "$full" ]; then
        warn "grimorios/$name no es un clon de $full; lo dejo como está"
        continue
      fi
      set_clone_auth "$dir" "$acct"
      signed_pull "$dir" "grimorio $name" || true
    elif clone_signed "$url" "$dir" "$acct"; then
      git -C "$dir" config runemind.repo "$full"
      note "$(rm_done_txt "grimorio $name" "clonado de $full con $acct")"
    else
      warn "no pude clonar el grimorio $full"
    fi
  done <<< "$list"
  [ -n "$list" ] || note "$(rm_todo_txt "sin grimorios privados accesibles" "pide acceso al dueño; llega como invitación")"
  tidy_revoked "$list"
}

# tidy_revoked list: a grimorio clone whose repo no gh account can read is removed, with its plugins and links
# (tidying, not protection: copies already made stay where they are). Never runs offline.
tidy_revoked() {
  local list="$1" dir repo a ok
  gh_online || return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    repo="$(git -C "$dir" config runemind.repo 2>/dev/null)" || continue
    printf '%s\n' "$list" | cut -f1 | grep -qxF -- "$repo" && continue
    ok=0
    for a in $(gh_accounts); do gh_as "$a" api "repos/$repo" --silent >/dev/null 2>&1 && { ok=1; break; }; done
    [ "$ok" = 1 ] || revoke_grimorio "$dir" "$repo"
  done <<< "$(grimorio_dirs)"
}

revoke_grimorio() {
  local dir="$1" repo="$2" name packs pack proj saved="$QUIET"
  name="$(basename "$dir")"
  packs="$(printf '%s\n' "$CATALOG" | awk -F "$US" -v g="$name" '$10 == g { print $1 }')"
  QUIET=1
  while IFS= read -r proj; do
    [ -d "$proj" ] || continue
    for pack in $packs; do off_pack "$proj" "$pack"; done
  done <<< "$(registered_projects)"
  for pack in $packs; do
    [ "$(pack_mode "$pack")" = global ] || continue
    if has claude; then claude plugin uninstall "$(claude_name "$pack")@$MARKET" --scope user >/dev/null 2>&1 || true; fi
    unlink_pack "$HOME" "$pack"
  done
  QUIET="$saved"
  rm -rf -- "$dir"
  warn "ya no tienes acceso a $repo: quité sus grimorios de Claude, de OpenCode y de tus proyectos"
}

# ---------- projects rune has linked into ----------

register_project() {
  mkdir -p "$STATE"
  touch "$PROJECTS"
  grep -qxF -- "$1" "$PROJECTS" || printf '%s\n' "$1" >> "$PROJECTS"
}

registered_projects() { [ -f "$PROJECTS" ] && cat "$PROJECTS"; return 0; }

# seed_projects: projects where Claude has a runemind plugin enabled (from before the registry existed)
seed_projects() {
  local f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" proj
  [ -f "$f" ] || return 0
  while IFS= read -r proj; do
    [ -n "$proj" ] && [ -d "$proj" ] && register_project "$proj"
  done <<< "$(python3 - "$f" "$MARKET" <<'EOF' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1])).get("plugins", {})
seen = set()
for key, entries in data.items():
    if key.endswith("@" + sys.argv[2]):
        for e in entries if isinstance(entries, list) else []:
            p = e.get("projectPath")
            if p and p not in seen:
                seen.add(p)
                print(p)
EOF
)"
}

# relink_projects: every registered project gets its grimorios refreshed (new skills, moved paths, revoked ones)
relink_projects() {
  local proj n=0 keep
  [ -f "$PROJECTS" ] || return 0
  keep="$(mktemp)"
  while IFS= read -r proj; do
    [ -d "$proj/.git" ] || [ -f "$proj/.git" ] || continue
    printf '%s\n' "$proj" >> "$keep"
    (cd "$proj" && "$LIB/bin/rune" auto --quiet >/dev/null 2>&1) || true
    n=$((n + 1))
  done < "$PROJECTS"
  mv "$keep" "$PROJECTS"
  [ "$n" = 0 ] || note "$(rm_done_txt "proyectos" "$n con sus grimorios al día")"
}

# ---------- migration from the single-repo layout ----------

# legacy_split_detected: origin now answers with the public core (unrelated history) or with a grimorio that
# no longer carries the CLI; either way this checkout must become a grimorio clone
legacy_split_detected() {
  is_legacy || return 1
  GIT_TERMINAL_PROMPT=0 git -C "$LIB" fetch --quiet origin main 2>/dev/null || return 1
  ! git -C "$LIB" merge-base HEAD FETCH_HEAD >/dev/null 2>&1 || ! git -C "$LIB" cat-file -e FETCH_HEAD:bin/rune 2>/dev/null
}

# legacy_migrate: clone the owner-signed public core next to this checkout, swap them, and let the new core
# adopt the old checkout as its grimorio (rune update --adopt). Returns only on failure.
legacy_migrate() {
  local parent new hold
  parent="$(dirname "$LIB")"; new="$parent/.runemind-core-$$"; hold="$parent/.runemind-legacy-$$"
  note "$(rm_gold "ᛗ") la biblioteca se dividió en un núcleo público y un grimorio privado: migrando"
  if ! clone_signed "$CORE_URL" "$new"; then
    warn "no pude traer el núcleo firmado de $CORE_URL; no migré (vuelve a intentarlo o corre el instalador)"
    return 1
  fi
  if [ -f "$new/grimorio.json" ]; then
    rm -rf -- "$new"
    warn "$CORE_URL todavía sirve la biblioteca privada; no migré"
    return 1
  fi
  mv "$LIB" "$hold" || { rm -rf -- "$new"; return 1; }
  if ! mv "$new" "$LIB"; then mv "$hold" "$LIB"; return 1; fi
  exec "$LIB/bin/rune" update --adopt "$hold" ${QUIET_FLAG[@]+"${QUIET_FLAG[@]}"}
}

url_repo() { local u="${1%.git}"; u="${u%/}"; printf '%s/%s\n' "$(basename "$(dirname "$u")")" "$(basename "$u")"; }

# adopt_legacy hold: the old checkout becomes grimorios/<name>, tracking the renamed private repo
adopt_legacy() {
  local hold="$1" name dest
  [ -d "$hold/.git" ] || return 0
  name="$(basename "${LEGACY_GRIMORIO_URL%.git}")"; dest="$GRIMORIOS/$name"
  if [ -e "$dest" ]; then
    warn "ya existe grimorios/$name; dejé la biblioteca anterior en $hold"
    return 0
  fi
  mkdir -p "$GRIMORIOS"
  if [ -d "$hold/.vendor" ] && [ ! -e "$LIB/.vendor" ]; then mv "$hold/.vendor" "$LIB/.vendor"; fi
  mv "$hold" "$dest"
  git -C "$dest" remote set-url origin "$LEGACY_GRIMORIO_URL"
  git -C "$dest" config runemind.repo "$(url_repo "$LEGACY_GRIMORIO_URL")"
  seed_projects
  note "$(rm_done_txt "biblioteca anterior" "ahora es el grimorio $name")"
}

# a migration interrupted between the swap and the adoption leaves .runemind-legacy-* next to the core
adopt_leftovers() {
  local d
  for d in "$(dirname "$LIB")"/.runemind-legacy-*; do
    [ -d "$d/.git" ] && adopt_legacy "$d"
  done
  return 0
}

# ---------- rune admin (owner) ----------

admin_repo() {
  local repos n
  if [ -n "$1" ]; then echo "$1"; return 0; fi
  repos="$(while IFS= read -r d; do [ -n "$d" ] && git -C "$d" config runemind.repo 2>/dev/null; done <<< "$(grimorio_dirs)" || true)"
  n="$(printf '%s' "$repos" | grep -c . || true)"
  [ "$n" = 1 ] || die "¿qué grimorio? usa --repo dueño/nombre${repos:+ (tienes: $(echo "$repos" | tr '\n' ' '))}"
  echo "$repos"
}

cmd_admin() {
  local sub="${1:-list}" repo="" user="" owner id login
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      *) user="$1"; shift ;;
    esac
  done
  repo="$(admin_repo "$repo")"
  owner="${repo%%/*}"
  gh_accounts | grep -qxF -- "$owner" || die "inicia sesión en gh con la cuenta $owner (gh auth login); rune no cambia tu cuenta activa"
  case "$sub" in
    grant)
      [ -n "$user" ] || die "rune admin grant <usuario-de-github>"
      gh_as "$owner" api -X PUT "repos/$repo/collaborators/$user" --silent >/dev/null || die "GitHub no aceptó invitar a $user"
      rm_line "  $(rm_gold "$G_STAR") $(rm_grad "$user invitado a $repo") $(rm_dim "· su próximo rune update acepta la invitación y graba los grimorios")"
      rm_info "en un repo personal todo colaborador puede escribir; rune solo instala commits firmados por ti"
      ;;
    revoke)
      [ -n "$user" ] || die "rune admin revoke <usuario-de-github>"
      gh_as "$owner" api -X DELETE "repos/$repo/collaborators/$user" --silent >/dev/null 2>&1 || true
      while IFS=$'\t' read -r id login; do
        [ "$login" = "$user" ] && gh_as "$owner" api -X DELETE "repos/$repo/invitations/$id" --silent >/dev/null 2>&1 || true
      done <<< "$(gh_as "$owner" api "repos/$repo/invitations" 2>/dev/null | python3 -I "$GHJSON" invitees || true)"
      rm_line "  $(rm_dim "$G_SKIP") $user ya no tiene acceso a $repo $(rm_dim "· su próximo rune update quita los grimorios")"
      ;;
    list)
      rm_head "Acceso a $repo"
      rm_root "$G_SEAL"
      while IFS= read -r login; do
        [ -n "$login" ] && rm_branch "$login"
      done <<< "$(gh_as "$owner" api --paginate "repos/$repo/collaborators?affiliation=direct&per_page=100" 2>/dev/null | python3 -I "$GHJSON" logins || true)"
      while IFS=$'\t' read -r id login; do
        [ -n "$login" ] && rm_branch "$login  $(rm_dim "invitación pendiente")"
      done <<< "$(gh_as "$owner" api "repos/$repo/invitations" 2>/dev/null | python3 -I "$GHJSON" invitees || true)"
      rm_last "$(rm_dim "rune admin grant <usuario> · rune admin revoke <usuario>")"
      ;;
    *) die "rune admin grant|revoke|list [usuario] [--repo dueño/nombre]" ;;
  esac
}
