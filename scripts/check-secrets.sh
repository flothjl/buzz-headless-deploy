#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

failed=0

report() {
  printf 'possible secret: %s\n' "$1" >&2
  failed=1
}

scan_file() {
  local file="$1" matches

  matches="$(grep -nE \
    'nsec1[023456789ac-hj-np-z]{40,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----' \
    "${file}" 2>/dev/null || true)"
  if [[ -n "${matches}" ]]; then
    report "${file}"
  fi

  matches="$(grep -nE \
    '^[[:space:]]*(BUZZ_PRIVATE_KEY|OPENAI_COMPAT_API_KEY|ANTHROPIC_API_KEY|DATABRICKS_TOKEN)=' \
    "${file}" 2>/dev/null |
    grep -Ev '=($|CHANGE_ME($|[^A-Za-z0-9]))|=nsec1CHANGE_ME$' || true)"
  if [[ -n "${matches}" ]]; then
    report "${file}"
  fi
}

if command -v git >/dev/null 2>&1 &&
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [[ -n "$(git ls-files)" ]]; then
  while IFS= read -r file; do
    case "${file}" in
      config/*.env) report "${file} is tracked by Git" ;;
    esac
    [[ -f "${file}" ]] && scan_file "${file}"
  done < <(git ls-files)
else
  while IFS= read -r file; do
    scan_file "${file#./}"
  done < <(
    find . -type f \
      -not -path './.git/*' \
      -not -path './config/agent.env' \
      -not -path './config/deploy.env' \
      -print
  )
fi

(( failed == 0 )) || exit 1
printf 'secret scan passed\n'
