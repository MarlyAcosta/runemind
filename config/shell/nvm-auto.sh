# Switches Node with nvm when the current directory changes: the version in the
# nearest .nvmrc (installed on first use), or the nvm default when there is none.
# Sourced from ~/.bashrc or ~/.zshrc after nvm itself.

_agent_skills_nvm_auto() {
  [ "${_AGENT_SKILLS_NVM_PWD:-}" = "$PWD" ] && return 0
  _AGENT_SKILLS_NVM_PWD="$PWD"
  command -v nvm_find_nvmrc >/dev/null 2>&1 || return 0

  local nvmrc wanted resolved
  nvmrc="$(nvm_find_nvmrc)"
  if [ -n "$nvmrc" ]; then
    wanted="$(tr -d '[:space:]' < "$nvmrc")"
    [ -n "$wanted" ] || return 0
    resolved="$(nvm version "$wanted")"
    if [ "$resolved" = "N/A" ]; then
      printf 'nvm: installing Node %s for %s... ' "$wanted" "$(dirname "$nvmrc")"
      if nvm install "$wanted" >/dev/null 2>&1 && nvm use "$wanted" >/dev/null; then
        printf 'done\n'
      else
        printf 'failed (run: nvm install %s)\n' "$wanted"
      fi
    elif [ "$resolved" != "$(nvm current)" ]; then
      nvm use "$wanted" >/dev/null
    fi
  else
    resolved="$(nvm version default)"
    if [ "$resolved" != "N/A" ] && [ "$resolved" != "$(nvm current)" ]; then
      nvm use default >/dev/null
    fi
  fi
}

if [ -n "${ZSH_VERSION:-}" ]; then
  autoload -U add-zsh-hook
  add-zsh-hook chpwd _agent_skills_nvm_auto
elif [ -n "${BASH_VERSION:-}" ]; then
  case ";${PROMPT_COMMAND:-};" in
    *";_agent_skills_nvm_auto;"*) ;;
    *) PROMPT_COMMAND="_agent_skills_nvm_auto${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
fi

_agent_skills_nvm_auto
