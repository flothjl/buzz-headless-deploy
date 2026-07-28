# Security policy

## Scope

Buzz Sprig Deploy is an independent community helper for installing the
official Buzz Sprig bundle. It is not an official Block deployment or support
channel.

Security fixes are maintained on the repository's default branch. There is no
separate long-term-support branch. The supported target is a systemd-based
x86-64 or ARM64 Linux host using APT, DNF, or YUM.

## Trust model

This project deliberately crosses several strong trust boundaries:

- The local deployment account can connect to the target over SSH.
- The remote installer runs as root to install packages, users, files, and
  systemd units.
- The Sprig binaries come from the official `block/buzz` GitHub releases and
  must match a SHA-256 value pinned in local configuration.
- `buzz-acp` holds an agent Nostr private key and model-provider credentials.
- `buzz-dev-mcp` lets the model run shell and file operations as the dedicated
  service account.
- The agent has outbound network access.

The systemd sandbox limits writes to the instance workspace and service home,
hides normal home directories, gives the service a private temporary directory,
and prevents privilege escalation. It does not make arbitrary model-directed
code safe.

Treat channel messages, web content, repositories, dependencies, tool output,
and model output as untrusted. Prompt injection or a compromised dependency can
read and exfiltrate anything available to the service account. Keep each agent
in a dedicated Unix account unless the instances intentionally share one trust
boundary. Use narrowly scoped provider credentials, spending limits, response
allowlists, and workspaces containing only intended data.

## Secrets

Never commit real configuration files such as:

- `config/agent.env`
- `config/deploy.env`

All `config/*.env` files are ignored by Git, but `git add --force` can override
that protection.
The deployer requires `config/agent.env` mode `0600`, and the remote copy is
root-owned with mode `0600`. Run `./scripts/check-secrets.sh` before publishing
changes and enable GitHub secret scanning plus push protection on public
repositories.

If a secret is exposed, revoke or rotate it before removing it from Git history.
Deleting a file in a later commit does not remove it from existing clones.

## Release verification

`SPRIG_SHA256` is the local trust pin. The installer requires both the published
checksum and the downloaded archive to match it. A checksum downloaded from the
same release location is not by itself proof against a compromised publisher;
review release provenance before accepting and storing a new pin.

Archive paths and entry types are checked before extraction. Only regular files
and directories are accepted; links, devices, absolute paths, and parent-path
traversal are rejected.

## Reporting a vulnerability

Use the repository's private vulnerability-reporting feature when enabled.
Otherwise contact the maintainer privately before opening a public issue. Do
not include private keys, provider credentials, host details, or working
exploits in a public report.

For vulnerabilities in Buzz or Sprig themselves, follow the upstream
[`block/buzz` security policy](https://github.com/block/buzz/security).
