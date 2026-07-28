#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_ROOT=/opt/buzz-sprig
CODEX_ROOT=/opt/buzz-codex-acp
ENV_ROOT=/etc/buzz-agents
WORK_ROOT=/srv/buzz-agents
UNIT_ROOT=/etc/systemd/system

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: remote-install.sh \
  --agent-name NAME \
  --service-user USER \
  --allow-shared-service-user true|false \
  --agent-runtime buzz-agent|codex \
  --codex-acp-version EXACT_VERSION \
  --sprig-version rolling|VERSION \
  --sprig-sha256 64_HEX_CHARACTERS \
  --agent-env-file PATH \
  --enable-service true|false \
  --start-service true|false
USAGE
}

normalize_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) printf 'true\n' ;;
    false|0|no|off) printf 'false\n' ;;
    *) die "expected true or false, got: $1" ;;
  esac
}

AGENT_NAME=
SERVICE_USER=
ALLOW_SHARED_SERVICE_USER=
AGENT_RUNTIME=
CODEX_ACP_VERSION=
SPRIG_VERSION=
SPRIG_SHA256=
AGENT_ENV_FILE=
ENABLE_SERVICE=
START_SERVICE=

while (($#)); do
  case "$1" in
    --agent-name) AGENT_NAME="${2:?missing --agent-name value}"; shift 2 ;;
    --service-user) SERVICE_USER="${2:?missing --service-user value}"; shift 2 ;;
    --allow-shared-service-user) ALLOW_SHARED_SERVICE_USER="$(normalize_bool "${2:?missing --allow-shared-service-user value}")"; shift 2 ;;
    --agent-runtime) AGENT_RUNTIME="${2:?missing --agent-runtime value}"; shift 2 ;;
    --codex-acp-version) CODEX_ACP_VERSION="${2:?missing --codex-acp-version value}"; shift 2 ;;
    --sprig-version) SPRIG_VERSION="${2:?missing --sprig-version value}"; shift 2 ;;
    --sprig-sha256) SPRIG_SHA256="${2:?missing --sprig-sha256 value}"; shift 2 ;;
    --agent-env-file) AGENT_ENV_FILE="${2:?missing --agent-env-file value}"; shift 2 ;;
    --enable-service) ENABLE_SERVICE="$(normalize_bool "${2:?missing --enable-service value}")"; shift 2 ;;
    --start-service) START_SERVICE="$(normalize_bool "${2:?missing --start-service value}")"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "remote installer must run as root"
[[ "${AGENT_NAME}" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "invalid agent name"
[[ "${SERVICE_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid service user"
[[ "${#SERVICE_USER}" -le 32 ]] || die "service user must be at most 32 characters"
[[ "${SERVICE_USER}" != "root" ]] || die "service user must not be root"
case "${AGENT_RUNTIME}" in
  buzz-agent) ;;
  codex)
    [[ "${CODEX_ACP_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] ||
      die "invalid exact codex-acp version"
    ;;
  *) die "agent runtime must be buzz-agent or codex" ;;
esac
[[ "${SPRIG_VERSION}" == "rolling" || "${SPRIG_VERSION}" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] ||
  die "invalid Sprig version"
[[ "${SPRIG_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid pinned Sprig checksum"
[[ -f "${AGENT_ENV_FILE}" ]] || die "agent environment file not found"
[[ -n "${ALLOW_SHARED_SERVICE_USER}" && -n "${ENABLE_SERVICE}" && -n "${START_SERVICE}" ]] ||
  die "service flags are required"
command -v systemctl >/dev/null 2>&1 || die "target is not a systemd machine"

UNIT_PATH="${UNIT_ROOT}/buzz-agent@${AGENT_NAME}.service"

install_missing_packages() {
  local missing=0 command
  for command in awk bash cmp curl getent git groupadd install sha256sum tar useradd usermod; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      missing=1
    fi
  done
  (( missing )) || return 0

  printf 'Installing required system packages...\n'
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y bash ca-certificates coreutils curl diffutils gawk git passwd tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y bash ca-certificates coreutils curl diffutils gawk git shadow-utils tar
  elif command -v yum >/dev/null 2>&1; then
    yum install -y bash ca-certificates coreutils curl diffutils gawk git shadow-utils tar
  else
    die "missing required commands and no supported package manager was found"
  fi
}

install_missing_packages

if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
  command -v node >/dev/null 2>&1 ||
    die "Codex runtime requires Node.js 20 or newer; install Node.js, then rerun"
  command -v npm >/dev/null 2>&1 ||
    die "Codex runtime requires npm; install npm, then rerun"
  command -v runuser >/dev/null 2>&1 ||
    die "Codex runtime requires runuser (normally provided by util-linux)"
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "${NODE_MAJOR}" =~ ^[0-9]+$ && "${NODE_MAJOR}" -ge 20 ]] ||
    die "Codex runtime requires Node.js 20 or newer; found $(node --version)"
fi

case "$(uname -m)" in
  x86_64|amd64) TARGET=x86_64-unknown-linux-musl ;;
  aarch64|arm64) TARGET=aarch64-unknown-linux-musl ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

if [[ "${SPRIG_VERSION}" == "rolling" ]]; then
  RELEASE_TAG=sprig-latest
  ARCHIVE_NAME="sprig-${TARGET}.tar.gz"
else
  RELEASE_TAG="sprig-v${SPRIG_VERSION}"
  ARCHIVE_NAME="sprig-${SPRIG_VERSION}-${TARGET}.tar.gz"
fi

BASE_URL="https://github.com/block/buzz/releases/download/${RELEASE_TAG}"
DOWNLOAD_DIR="$(mktemp -d /tmp/buzz-sprig-install.XXXXXX)"
CODEX_RELEASE_TEMP=
cleanup() {
  if [[ "${DOWNLOAD_DIR}" =~ ^/tmp/buzz-sprig-install\.[A-Za-z0-9]+$ ]]; then
    rm -rf -- "${DOWNLOAD_DIR}"
  fi
  if [[ "${CODEX_RELEASE_TEMP}" =~ ^/opt/buzz-codex-acp/releases/\.install\.[A-Za-z0-9]+$ ]]; then
    rm -rf -- "${CODEX_RELEASE_TEMP}"
  fi
}
trap cleanup EXIT

ARCHIVE_PATH="${DOWNLOAD_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

printf 'Fetching Sprig %s for %s...\n' "${SPRIG_VERSION}" "${TARGET}"
curl --fail --location --silent --show-error --retry 3 \
  --output "${ARCHIVE_PATH}" "${BASE_URL}/${ARCHIVE_NAME}"
curl --fail --location --silent --show-error --retry 3 \
  --output "${CHECKSUM_PATH}" "${BASE_URL}/${ARCHIVE_NAME}.sha256"

EXPECTED_CHECKSUM="$(awk 'NR == 1 {print $1}' "${CHECKSUM_PATH}")"
[[ "${EXPECTED_CHECKSUM}" =~ ^[0-9a-fA-F]{64}$ ]] || die "release checksum file is malformed"
[[ "${EXPECTED_CHECKSUM,,}" == "${SPRIG_SHA256,,}" ]] ||
  die "published Sprig checksum does not match SPRIG_SHA256; review the release before updating the pin"
ACTUAL_CHECKSUM="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
[[ "${ACTUAL_CHECKSUM,,}" == "${SPRIG_SHA256,,}" ]] || die "Sprig archive checksum mismatch"

PAYLOAD_DIR="${DOWNLOAD_DIR}/payload"
mkdir -p -- "${PAYLOAD_DIR}"

ARCHIVE_LIST="${DOWNLOAD_DIR}/archive.list"
tar -tzf "${ARCHIVE_PATH}" >"${ARCHIVE_LIST}" ||
  die "could not list Sprig archive"
while IFS= read -r entry; do
  normalized="${entry#./}"
  [[ -n "${normalized}" && "${normalized}" != /* ]] ||
    die "Sprig archive contains an unsafe absolute or empty path"
  case "/${normalized}/" in
    */../*) die "Sprig archive contains a parent-directory path" ;;
  esac
done <"${ARCHIVE_LIST}"

tar -tvzf "${ARCHIVE_PATH}" |
  awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { exit 1 }' ||
  die "Sprig archive contains a link, device, or other unsupported entry"

tar -xzf "${ARCHIVE_PATH}" \
  --no-same-owner \
  --no-same-permissions \
  -C "${PAYLOAD_DIR}"

if find "${PAYLOAD_DIR}" -type l -print -quit | grep -q .; then
  die "Sprig archive extracted a symbolic link"
fi

for binary in sprig buzz-acp buzz-agent buzz-dev-mcp buzz; do
  [[ -x "${PAYLOAD_DIR}/${binary}" ]] || die "archive is missing executable ${binary}"
done

SPRIG_VERSION_OUTPUT="$("${PAYLOAD_DIR}/sprig" --version)"
VERSION_ID="${SPRIG_VERSION_OUTPUT#sprig }"
VERSION_ID="$(printf '%s' "${VERSION_ID}" | tr -c 'A-Za-z0-9._+-' '_')"
[[ -n "${VERSION_ID}" ]] || die "could not determine installed Sprig version"

install -d -m 0755 "${INSTALL_ROOT}" "${INSTALL_ROOT}/releases"
RELEASE_DIR="${INSTALL_ROOT}/releases/${VERSION_ID}-${EXPECTED_CHECKSUM:0:12}-${TARGET}"
CURRENT_CHECKSUM=
if [[ -f "${INSTALL_ROOT}/.archive-sha256" ]]; then
  CURRENT_CHECKSUM="$(<"${INSTALL_ROOT}/.archive-sha256")"
fi

BINARY_CHANGED=0
if [[ "${CURRENT_CHECKSUM,,}" != "${EXPECTED_CHECKSUM,,}" || ! -x "${INSTALL_ROOT}/current/sprig" ]]; then
  if [[ ! -d "${RELEASE_DIR}" ]]; then
    RELEASE_TEMP="$(mktemp -d "${INSTALL_ROOT}/releases/.install.XXXXXX")"
    cp -a "${PAYLOAD_DIR}/." "${RELEASE_TEMP}/"
    chmod -R a-w "${RELEASE_TEMP}"
    mv -- "${RELEASE_TEMP}" "${RELEASE_DIR}"
  fi
  LINK_TEMP="${INSTALL_ROOT}/.current.$$"
  ln -s "${RELEASE_DIR}" "${LINK_TEMP}"
  mv -Tf "${LINK_TEMP}" "${INSTALL_ROOT}/current"
  printf '%s\n' "${EXPECTED_CHECKSUM,,}" >"${INSTALL_ROOT}/.archive-sha256"
  BINARY_CHANGED=1
  printf 'Activated %s\n' "${RELEASE_DIR}"
else
  printf 'Sprig archive is unchanged; keeping current release.\n'
fi

CODEX_ACP_CHANGED=0
if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
  install -d -m 0755 "${CODEX_ROOT}" "${CODEX_ROOT}/releases"
  CODEX_RELEASE_DIR="${CODEX_ROOT}/releases/${CODEX_ACP_VERSION}"
  CODEX_ACP_PATH="${CODEX_RELEASE_DIR}/node_modules/.bin/codex-acp"
  CODEX_CLI_PATH="${CODEX_RELEASE_DIR}/node_modules/.bin/codex"

  if [[ -d "${CODEX_RELEASE_DIR}" ]]; then
    [[ -x "${CODEX_ACP_PATH}" && -x "${CODEX_CLI_PATH}" ]] ||
      die "existing Codex adapter release is incomplete: ${CODEX_RELEASE_DIR}"
  else
    printf 'Installing @agentclientprotocol/codex-acp %s...\n' "${CODEX_ACP_VERSION}"
    CODEX_RELEASE_TEMP="$(mktemp -d "${CODEX_ROOT}/releases/.install.XXXXXX")"
    npm install \
      --prefix "${CODEX_RELEASE_TEMP}" \
      --omit=dev \
      --no-audit \
      --no-fund \
      --ignore-scripts \
      --registry=https://registry.npmjs.org \
      "@agentclientprotocol/codex-acp@${CODEX_ACP_VERSION}"

    INSTALLED_CODEX_ACP_VERSION="$(
      node -p "require('${CODEX_RELEASE_TEMP}/node_modules/@agentclientprotocol/codex-acp/package.json').version"
    )"
    [[ "${INSTALLED_CODEX_ACP_VERSION}" == "${CODEX_ACP_VERSION}" ]] ||
      die "npm installed codex-acp ${INSTALLED_CODEX_ACP_VERSION}, expected ${CODEX_ACP_VERSION}"
    [[ -x "${CODEX_RELEASE_TEMP}/node_modules/.bin/codex-acp" ]] ||
      die "codex-acp package did not install an executable adapter"
    [[ -x "${CODEX_RELEASE_TEMP}/node_modules/.bin/codex" ]] ||
      die "codex-acp package did not install its compatible Codex CLI"

    chmod -R a-w "${CODEX_RELEASE_TEMP}"
    mv -- "${CODEX_RELEASE_TEMP}" "${CODEX_RELEASE_DIR}"
    CODEX_RELEASE_TEMP=
    CODEX_ACP_CHANGED=1
  fi

  CURRENT_CODEX_TARGET=
  if [[ -L "${CODEX_ROOT}/current" ]]; then
    CURRENT_CODEX_TARGET="$(readlink "${CODEX_ROOT}/current")"
  fi
  if [[ "${CURRENT_CODEX_TARGET}" != "${CODEX_RELEASE_DIR}" ]]; then
    CODEX_LINK_TEMP="${CODEX_ROOT}/.current.$$"
    ln -s "${CODEX_RELEASE_DIR}" "${CODEX_LINK_TEMP}"
    mv -Tf "${CODEX_LINK_TEMP}" "${CODEX_ROOT}/current"
    CODEX_ACP_CHANGED=1
    printf 'Activated codex-acp %s.\n' "${CODEX_ACP_VERSION}"
  else
    printf 'codex-acp %s is already active.\n' "${CODEX_ACP_VERSION}"
  fi
fi

if ! getent group "${SERVICE_USER}" >/dev/null 2>&1; then
  groupadd --system "${SERVICE_USER}"
fi
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system \
    --gid "${SERVICE_USER}" \
    --home-dir "/var/lib/${SERVICE_USER}" \
    --create-home \
    --shell /usr/sbin/nologin \
    "${SERVICE_USER}"
elif ! id -nG "${SERVICE_USER}" | tr ' ' '\n' | grep -Fxq "${SERVICE_USER}"; then
  usermod -a -G "${SERVICE_USER}" "${SERVICE_USER}"
fi
[[ "$(id -u "${SERVICE_USER}")" -ne 0 ]] || die "service user resolves to UID 0"

IFS=: read -r _ _ _ _ _ service_home service_shell < <(getent passwd "${SERVICE_USER}")
[[ "${service_home}" == "/var/lib/${SERVICE_USER}" ]] ||
  die "existing service user ${SERVICE_USER} has unexpected home ${service_home}"
case "${service_shell}" in
  */nologin|*/false) ;;
  *) die "existing service user ${SERVICE_USER} must have a non-login shell" ;;
esac

if [[ "${ALLOW_SHARED_SERVICE_USER}" == "false" ]]; then
  for existing_unit in "${UNIT_ROOT}"/buzz-agent@*.service; do
    [[ -e "${existing_unit}" &&
      "${existing_unit}" != "${UNIT_PATH}" &&
      "${existing_unit}" != "${UNIT_ROOT}/buzz-agent@.service" ]] || continue
    if grep -Fxq "User=${SERVICE_USER}" "${existing_unit}"; then
      die "service user ${SERVICE_USER} is already used by ${existing_unit}; choose a unique SERVICE_USER or explicitly set ALLOW_SHARED_SERVICE_USER=true"
    fi
  done
fi

install -d -m 0755 "${ENV_ROOT}"
install -d -m 0755 -o root -g root "${WORK_ROOT}"
install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
  "/var/lib/${SERVICE_USER}"
install -d -m 0750 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
  "${WORK_ROOT}/${AGENT_NAME}"
chown -R -h "${SERVICE_USER}:${SERVICE_USER}" "${WORK_ROOT}/${AGENT_NAME}"
if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
  install -d -m 0700 -o "${SERVICE_USER}" -g "${SERVICE_USER}" \
    "/var/lib/${SERVICE_USER}/.codex"
fi

grep -Eq '^[[:space:]]*BUZZ_RELAY_URL=' "${AGENT_ENV_FILE}" ||
  die "agent environment must set BUZZ_RELAY_URL"
grep -Eq '^[[:space:]]*BUZZ_PRIVATE_KEY=' "${AGENT_ENV_FILE}" ||
  die "agent environment must set BUZZ_PRIVATE_KEY"

NORMALIZED_ENV="${DOWNLOAD_DIR}/${AGENT_NAME}.env"
if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
  awk '
    /^[[:space:]]*(BUZZ_ACP_AGENT_COMMAND|BUZZ_ACP_MCP_COMMAND|AGENT_CWD|CODEX_HOME|CODEX_PATH|NO_BROWSER)=/ { next }
    /^[[:space:]]*(BUZZ_AGENT_|OPENAI_COMPAT_|ANTHROPIC_|DATABRICKS_)/ { next }
    { print }
  ' "${AGENT_ENV_FILE}" >"${NORMALIZED_ENV}"
else
  awk '
    /^[[:space:]]*(BUZZ_ACP_AGENT_COMMAND|BUZZ_ACP_MCP_COMMAND|AGENT_CWD|CODEX_HOME|CODEX_PATH|NO_BROWSER)=/ { next }
    { print }
  ' "${AGENT_ENV_FILE}" >"${NORMALIZED_ENV}"
fi
{
  printf '\n# Managed by buzz-sprig-deploy. These values intentionally win.\n'
  if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
    printf 'BUZZ_ACP_AGENT_COMMAND=/opt/buzz-codex-acp/current/node_modules/.bin/codex-acp\n'
    printf 'CODEX_PATH=/opt/buzz-codex-acp/current/node_modules/.bin/codex\n'
    printf 'NO_BROWSER=1\n'
  else
    printf 'BUZZ_ACP_AGENT_COMMAND=/opt/buzz-sprig/current/buzz-agent\n'
  fi
  printf 'BUZZ_ACP_MCP_COMMAND=/opt/buzz-sprig/current/buzz-dev-mcp\n'
  printf 'AGENT_CWD=/srv/buzz-agents/%s\n' "${AGENT_NAME}"
} >>"${NORMALIZED_ENV}"

ENV_CHANGED=0
REMOTE_ENV="${ENV_ROOT}/${AGENT_NAME}.env"
if [[ ! -f "${REMOTE_ENV}" ]] || ! cmp -s "${NORMALIZED_ENV}" "${REMOTE_ENV}"; then
  install -m 0600 -o root -g root "${NORMALIZED_ENV}" "${REMOTE_ENV}"
  ENV_CHANGED=1
  printf 'Updated %s\n' "${REMOTE_ENV}"
else
  printf 'Agent environment is unchanged.\n'
fi

UNIT_TEMP="${DOWNLOAD_DIR}/buzz-agent@${AGENT_NAME}.service"
CODEX_UNIT_ENV=
if [[ "${AGENT_RUNTIME}" == "codex" ]]; then
  CODEX_UNIT_ENV="Environment=CODEX_HOME=/var/lib/${SERVICE_USER}/.codex"
fi
cat >"${UNIT_TEMP}" <<UNIT
[Unit]
Description=Buzz Sprig agent ${AGENT_NAME} (${AGENT_RUNTIME})
Documentation=https://github.com/block/buzz
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${WORK_ROOT}/${AGENT_NAME}
EnvironmentFile=${ENV_ROOT}/${AGENT_NAME}.env
Environment=HOME=/var/lib/${SERVICE_USER}
${CODEX_UNIT_ENV}
ExecStart=${INSTALL_ROOT}/current/buzz-acp
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=control-group
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${WORK_ROOT}/${AGENT_NAME} /var/lib/${SERVICE_USER}

[Install]
WantedBy=multi-user.target
UNIT

UNIT_CHANGED=0
if [[ ! -f "${UNIT_PATH}" ]] || ! cmp -s "${UNIT_TEMP}" "${UNIT_PATH}"; then
  install -m 0644 -o root -g root "${UNIT_TEMP}" "${UNIT_PATH}"
  UNIT_CHANGED=1
  printf 'Updated %s\n' "${UNIT_PATH}"
else
  printf 'Systemd unit is unchanged.\n'
fi

systemctl daemon-reload
SERVICE_NAME="buzz-agent@${AGENT_NAME}.service"

codex_auth_ready() {
  [[ "${AGENT_RUNTIME}" == "codex" ]] || return 0
  runuser --user "${SERVICE_USER}" -- \
    env "HOME=/var/lib/${SERVICE_USER}" "CODEX_HOME=/var/lib/${SERVICE_USER}/.codex" \
    "${CODEX_ROOT}/current/node_modules/.bin/codex" login status >/dev/null 2>&1
}

if [[ "${ENABLE_SERVICE}" == "true" ]]; then
  systemctl enable "${SERVICE_NAME}" >/dev/null
fi

if [[ "${START_SERVICE}" == "true" ]]; then
  if [[ "${AGENT_RUNTIME}" == "codex" ]] && ! codex_auth_ready; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      systemctl stop "${SERVICE_NAME}"
    fi
    printf 'Codex is not authenticated for %s; service left stopped.\n' "${SERVICE_USER}"
    printf 'Run the controller codex-login command to authenticate and start it.\n'
  elif systemctl is-active --quiet "${SERVICE_NAME}"; then
    if (( BINARY_CHANGED || CODEX_ACP_CHANGED || ENV_CHANGED || UNIT_CHANGED )); then
      systemctl restart "${SERVICE_NAME}"
      printf 'Restarted %s because deployed state changed.\n' "${SERVICE_NAME}"
    else
      printf '%s is active and unchanged; no restart needed.\n' "${SERVICE_NAME}"
    fi
  else
    systemctl start "${SERVICE_NAME}"
    printf 'Started %s\n' "${SERVICE_NAME}"
  fi
fi

printf '\nInstallation complete.\n'
printf '  Sprig:  %s\n' "${SPRIG_VERSION_OUTPUT}"
printf '  Agent:  %s\n' "${AGENT_NAME}"
printf '  Service: %s\n' "${SERVICE_NAME}"
printf '  Workdir: %s/%s\n' "${WORK_ROOT}" "${AGENT_NAME}"
