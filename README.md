# Buzz Sprig Deploy

Idempotent SSH deployment for a headless Buzz agent on a Linux machine.

The project installs the published Sprig bundle, configures one agent instance,
and manages it with systemd. The remote machine needs no inbound application
port: `buzz-acp` connects outbound to the configured Buzz relay over WSS.

This is an independent community deployment helper, not an official Block
deployment or support channel. It downloads unmodified Sprig releases from the
official [`block/buzz`](https://github.com/block/buzz) project.

## What it installs

- `/opt/buzz-sprig/releases/<version>-<checksum>-<target>/` — immutable Sprig releases
- `/opt/buzz-sprig/current` — atomically updated symlink to the active release
- `/etc/buzz-agents/<agent>.env` — root-only agent configuration and secrets
- `/srv/buzz-agents/<agent>/` — agent working directory
- `/etc/systemd/system/buzz-agent@<agent>.service` — per-instance systemd unit
- A dedicated, non-login service account (default: `buzz-<agent>`)

The remote installer supports systemd-based x86-64 and ARM64 Linux hosts using
APT, DNF, or YUM. It installs missing baseline packages (`bash`, CA
certificates, `curl`, `git`, `tar`, and checksum utilities).

## Prerequisites

- A local Bash shell with `ssh` and `scp`
- SSH access to the target
- Either:
  - a remote root login with `DEPLOY_USE_SUDO=false`, or
  - passwordless sudo for the remote deployment user
- An agent Nostr private key (`nsec1...` or 64-character hex)
- The SHA-256 pin for the exact Sprig archive expected on the target architecture
- The agent must be admitted to the Buzz relay and added to the channels it
  should observe

The deploy command intentionally uses non-interactive sudo so installs do not
hang halfway through waiting for a password. The installer runs as root and can
install system packages, users, files under `/opt`, `/etc`, and `/srv`, and
systemd units. Use a trusted administrative account; avoid granting deployment
access to untrusted users.

## Configure

Create local configuration files:

```bash
./buzz-sprig-deploy init
$EDITOR config/deploy.env
$EDITOR config/agent.env
```

`config/deploy.env` describes the SSH target and installation behavior.
`config/agent.env` is copied to the target and contains the agent identity,
response policy, and LLM credentials.

Both real files are ignored by Git. The deployer refuses to use
`config/agent.env` unless its mode is exactly `0600`:

```bash
chmod 600 config/agent.env
```

The default agent environment runs the bundled `buzz-agent` and
`buzz-dev-mcp`. The remote installer owns these values and appends them after
normalizing the supplied file:

```dotenv
BUZZ_ACP_AGENT_COMMAND=/opt/buzz-sprig/current/buzz-agent
BUZZ_ACP_MCP_COMMAND=/opt/buzz-sprig/current/buzz-dev-mcp
AGENT_CWD=/srv/buzz-agents/<agent>
```

## Install or update

```bash
./install.sh
```

or equivalently:

```bash
./buzz-sprig-deploy install
```

The install is safe to repeat:

- the service user and directories are created only when missing;
- the published checksum and downloaded archive must both match the SHA-256
  pinned in local deployment configuration;
- a release is stored under a checksum-specific immutable directory;
- the `current` symlink is switched atomically;
- each instance gets its own service account and exact systemd unit by default;
- unchanged environment and unit files are not rewritten;
- an active service is restarted only when its binary, environment, or unit
  changed;
- systemd enablement is idempotent.

### Pinning and updating Sprig

The official project currently distributes Sprig through the mutable
`sprig-latest` rolling prerelease. `SPRIG_SHA256` makes the selected artifact
immutable from this deployer's perspective: a later replacement at the same
release URL is rejected until you review it and update the local pin.

Fetch the published checksum matching the target:

```bash
# x86-64
curl -fsSL \
  https://github.com/block/buzz/releases/download/sprig-latest/sprig-x86_64-unknown-linux-musl.tar.gz.sha256

# ARM64
curl -fsSL \
  https://github.com/block/buzz/releases/download/sprig-latest/sprig-aarch64-unknown-linux-musl.tar.gz.sha256
```

Copy only the first 64-character field into `SPRIG_SHA256`. Review the release
before trusting a new value. To update rolling Sprig, update that pin and run
`install` again. If versioned `sprig-v<VERSION>` releases are available, set
`SPRIG_VERSION` to that version and pin its architecture-specific archive in
the same way.

## Operations

```bash
./buzz-sprig-deploy check
./buzz-sprig-deploy validate
./buzz-sprig-deploy status
./buzz-sprig-deploy logs
./buzz-sprig-deploy restart
./buzz-sprig-deploy stop
./buzz-sprig-deploy start
```

Set up boot-time startup, or re-enable a previously disabled service:

```bash
./buzz-sprig-deploy setup-systemd
```

Disable boot-time startup and stop the service:

```bash
./buzz-sprig-deploy disable
```

`enable` is an alias for `setup-systemd`. `logs` follows the journal; press
Ctrl-C to exit.

`validate` checks the local configuration and required agent settings without
opening an SSH connection.

## Multiple agents

Use one checkout or one pair of config files per agent. You can override the
configuration paths without copying the project:

```bash
BUZZ_SPRIG_DEPLOY_CONFIG=/secure/agents/research.deploy.env \
BUZZ_SPRIG_AGENT_ENV=/secure/agents/research.agent.env \
  ./buzz-sprig-deploy install
```

Leave `SERVICE_USER` empty to derive a distinct `buzz-<AGENT_NAME>` account for
each instance. Each `AGENT_NAME` gets its own root-protected environment,
working directory, and exact systemd unit.

Do not reuse a service account across agents from different trust boundaries.
Processes with the same Unix UID can potentially inspect each other's
workspaces, processes, and environment secrets. The installer rejects reuse by
default. `ALLOW_SHARED_SERVICE_USER=true` is an explicit escape hatch only for
instances that intentionally share all of those privileges.

`BUZZ_ACP_AGENTS=2` creates two concurrent ACP workers behind one visible Nostr
identity; it does not create a second agent identity.

## Security notes

- `buzz-dev-mcp` gives the model shell and file-edit capabilities as the
  service user. Treat messages and retrieved content as potentially hostile
  prompt input. Put only intended data under the agent working directory.
- Never commit `config/agent.env`.
- Use separate LLM credentials with spending limits where possible.
- Keep the household response allowlist narrow. Relay and channel membership do
  not replace `BUZZ_ACP_RESPOND_TO`.
- The systemd unit blocks privilege escalation, hides home directories, gives
  the service a private `/tmp`, makes the host filesystem read-only, and permits
  writes only to the instance workspace and service home. Do not weaken these
  controls merely to make an agent-requested command work.
- Model requests and agent tools have outbound network access. Credentials and
  workspace content accessible to the service could be exfiltrated by malicious
  prompts or dependencies.
- Stop any local harness using the same agent key before enabling the remote
  service, otherwise both harnesses can answer the same mention.
- The deployer never prints the agent environment or private key.

See [SECURITY.md](SECURITY.md) for the full trust model and vulnerability
reporting guidance.

## Local validation

```bash
./scripts/test.sh
```

If ShellCheck is installed, the test script runs it in addition to Bash syntax
and command-surface checks. It always runs the repository secret scan.

GitHub Actions runs these checks on every push and pull request. Before making
the repository public, also enable GitHub secret scanning and push protection
in the repository security settings.

## Publishing checklist

Before the first public push:

```bash
./scripts/test.sh
git status --short --ignored
git diff --cached
```

Confirm that no real `config/*.env` file is staged. Remember that commit author
names and email addresses are public metadata; configure a GitHub noreply email
before committing if you do not want to publish a personal address. After
creating the repository, enable private vulnerability reporting, secret
scanning, and push protection in its security settings.

## License

Apache-2.0. See [LICENSE](LICENSE).
