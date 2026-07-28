#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(
  "${PROJECT_DIR}/buzz-sprig-deploy"
  "${PROJECT_DIR}/install.sh"
  "${PROJECT_DIR}/scripts/check-secrets.sh"
  "${PROJECT_DIR}/scripts/remote-install.sh"
  "${PROJECT_DIR}/scripts/test.sh"
)

for script in "${SCRIPTS[@]}"; do
  bash -n "${script}"
done

"${PROJECT_DIR}/buzz-sprig-deploy" help >/dev/null
"${PROJECT_DIR}/scripts/remote-install.sh" --help >/dev/null

for command in validate install check status start stop restart setup-systemd enable disable logs; do
  grep -q "${command}" "${PROJECT_DIR}/buzz-sprig-deploy" ||
    {
      printf 'missing command surface: %s\n' "${command}" >&2
      exit 1
    }
done

for directive in \
  'NoNewPrivileges=true' \
  'PrivateTmp=true' \
  'ProtectSystem=strict' \
  'ProtectHome=true' \
  'CapabilityBoundingSet=' \
  'ReadWritePaths='; do
  grep -Fq "${directive}" "${PROJECT_DIR}/scripts/remote-install.sh" ||
    {
      printf 'missing systemd hardening directive: %s\n' "${directive}" >&2
      exit 1
    }
done

grep -Fq 'buzz-agent@${AGENT_NAME}.service' \
  "${PROJECT_DIR}/scripts/remote-install.sh" ||
  {
    printf 'remote installer must create a per-instance systemd unit\n' >&2
    exit 1
  }

TEST_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

TEST_DEPLOY_ENV="${TEST_DIR}/deploy.env"
TEST_AGENT_ENV="${TEST_DIR}/agent.env"

sed \
  -e "s/SPRIG_SHA256=CHANGE_ME_64_HEX/SPRIG_SHA256=$(printf 'a%.0s' {1..64})/" \
  "${PROJECT_DIR}/config/deploy.env.example" >"${TEST_DEPLOY_ENV}"

sed \
  -e 's#wss://buzz\.example\.com#wss://buzz.home.test#' \
  -e "s/nsec1CHANGE_ME/$(printf '1%.0s' {1..64})/" \
  -e "s/CHANGE_ME_OWNER_64_HEX/$(printf '2%.0s' {1..64})/" \
  -e "s/CHANGE_ME_WIFE_64_HEX/$(printf '3%.0s' {1..64})/" \
  -e 's/OPENAI_COMPAT_API_KEY=CHANGE_ME/OPENAI_COMPAT_API_KEY=test-key/' \
  -e 's/OPENAI_COMPAT_MODEL=CHANGE_ME/OPENAI_COMPAT_MODEL=test-model/' \
  "${PROJECT_DIR}/config/agent.env.example" >"${TEST_AGENT_ENV}"
chmod 600 "${TEST_AGENT_ENV}"

BUZZ_SPRIG_DEPLOY_CONFIG="${TEST_DEPLOY_ENV}" \
BUZZ_SPRIG_AGENT_ENV="${TEST_AGENT_ENV}" \
  "${PROJECT_DIR}/buzz-sprig-deploy" validate >/dev/null

chmod 644 "${TEST_AGENT_ENV}"
if BUZZ_SPRIG_DEPLOY_CONFIG="${TEST_DEPLOY_ENV}" \
  BUZZ_SPRIG_AGENT_ENV="${TEST_AGENT_ENV}" \
  "${PROJECT_DIR}/buzz-sprig-deploy" validate >/dev/null 2>&1; then
  printf 'validate accepted an agent env file that was not mode 0600\n' >&2
  exit 1
fi
chmod 600 "${TEST_AGENT_ENV}"

sed 's/^SERVICE_USER=$/SERVICE_USER=root/' \
  "${TEST_DEPLOY_ENV}" >"${TEST_DIR}/root.deploy.env"
if BUZZ_SPRIG_DEPLOY_CONFIG="${TEST_DIR}/root.deploy.env" \
  BUZZ_SPRIG_AGENT_ENV="${TEST_AGENT_ENV}" \
  "${PROJECT_DIR}/buzz-sprig-deploy" validate >/dev/null 2>&1; then
  printf 'validate accepted SERVICE_USER=root\n' >&2
  exit 1
fi

sed 's/^SPRIG_SHA256=.*/SPRIG_SHA256=bad/' \
  "${TEST_DEPLOY_ENV}" >"${TEST_DIR}/bad-sha.deploy.env"
if BUZZ_SPRIG_DEPLOY_CONFIG="${TEST_DIR}/bad-sha.deploy.env" \
  BUZZ_SPRIG_AGENT_ENV="${TEST_AGENT_ENV}" \
  "${PROJECT_DIR}/buzz-sprig-deploy" validate >/dev/null 2>&1; then
  printf 'validate accepted an invalid Sprig checksum pin\n' >&2
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${SCRIPTS[@]}"
elif [[ "${REQUIRE_SHELLCHECK:-0}" == "1" ]]; then
  printf 'shellcheck is required but not installed\n' >&2
  exit 1
else
  printf 'shellcheck not installed; skipped\n'
fi

"${PROJECT_DIR}/scripts/check-secrets.sh"

printf 'all local checks passed\n'
