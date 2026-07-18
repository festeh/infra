# Ansible Infrastructure

This repository manages the IONOS VPS through Ansible. Run infrastructure
operations from the repository root through `just`; do not expose individual
Ansible phases as separate Just recipes.

## Command surface

- `just bootstrap SHA256:...` is the one-time operation for a reinstalled VPS.
  The ED25519 fingerprint must be obtained independently from the IONOS console.
  Bootstrap compares it with the network key before sending the temporary root
  password, creates `dima`, installs the controller SSH key, and verifies that
  key-based administration works before disabling root/password SSH.
- `just apply` repeatedly converges and verifies the complete declared state.
- Additional Ansible flags pass through the same command, for example
  `just apply --check --diff` or `just apply --tags base`.

After bootstrap, root SSH, SSH password authentication, and the root password
are disabled. Recovery therefore uses IONOS rescue/password-reset facilities,
not an expected root-password login through the KVM console.

## Current deployed state

The base state was deployed and reboot-tested on 2026-07-12:

- Production host: SSH alias `ionos`, inventory host `web_server`.
- Operating system: Ubuntu 26.04 LTS.
- Administration: key-based `dima` with non-interactive sudo.
- Timezone: `Europe/Berlin`; Chrony is active and synchronized.
- Daily unattended security upgrades are active; automatic unattended reboots
  are disabled. An explicit `just apply` reboots when Ubuntu reports that an
  upgrade requires it.
- Journald uses persistent compressed storage, capped at 256 MiB with a 14-day
  retention target.
- The IONOS control-plane firewall is authoritative. Ansible does not configure
  UFW/nftables or Fail2ban.
- Caddy and all applications are currently absent. OpenCode is disabled.

The deployed state has been verified with a dry run, two consecutive
idempotent applies (`changed=0`), a real reboot followed by another idempotent
apply, and a negative listener-audit test.

## Ansible structure

- `ansible/playbooks/site.yml` is the only repeatable site entry point.
- `ansible/playbooks/harden-ssh.yml` is the bootstrap/site wrapper for the
  `access` role, which continuously verifies the SSH access invariants.
- `ansible/roles/access` owns SSH hardening and root-password locking.
- `ansible/roles/base` owns packages, upgrades, time, journald, and reboot
  handling.
- `ansible/roles/listener_audit` installs and runs the listener guard.
- Production variables live below
  `ansible/inventories/production/group_vars/`.

Roles own service configuration and must be idempotent. A second `just apply`
after any completed change should report `changed=0`.

## Network exposure invariant

The listener audit runs at the end of every `just apply`, including check mode.
It ignores `127.0.0.0/8` and `::1` listeners. Every socket on a wildcard,
interface, or other non-loopback address must match the production allowlist by
protocol, port, and process. Linux process names reported by `ss` may be
truncated to 15 characters.

The current allowlist contains only:

- TCP/22 owned by `sshd` (one IPv4 and one IPv6 socket).
- UDP/68 owned by `systemd-network`, the image's DHCP client.

Do not add an allowlist entry merely to make a failed deployment pass. First
determine why the listener exists and whether it genuinely needs direct network
exposure. The guard can be run manually on the server with:

```bash
sudo /usr/local/libexec/infra-listener-audit
```

The IONOS firewall and this audit solve different problems: IONOS filters
external traffic, while the audit prevents accidental wildcard binds and
records the intended host-level exposure.

## Adding a service

For each service restored after the rebuild:

1. Implement it directly as an Ansible role. Obsolete standalone service
   playbooks were deleted and remain available through Git history.
2. Use a dedicated unprivileged system user.
3. Configure its listen address explicitly. Internal services bind to
   `127.0.0.1` or `::1`; container port publishing must also use a loopback host
   address.
4. Start the service and let the mandatory listener audit verify it.
5. Add a Caddy route only when intentional public access and authentication
   have been reviewed. A loopback bind does not prevent Caddy from exposing a
   service.
6. Add a public-listener rule only for genuine edge services such as SSH or
   Caddy.
7. Run `just apply --check --diff`, then `just apply`, then `just apply` again
   to prove idempotence.

## OpenCode safety boundary

The previous VPS compromise occurred because OpenCode was publicly proxied
without authentication, listened on all interfaces, and ran as root. Its API
can intentionally execute shell commands, so Fail2ban or rate limiting would
not have prevented the breach.

Never restore the old OpenCode unit or `code.dimalip.in` Caddy block. OpenCode
may be reintroduced only when all of these are true:

- No public Caddy route; use an SSH tunnel or private VPN.
- Bind only to loopback.
- Enable `OPENCODE_SERVER_PASSWORD` even on the private path.
- Run as the unprivileged `opencode` user with a minimal workspace and secrets.
- Use a pinned, patched version and an isolated container/VM or strong systemd
  sandbox with resource limits. Never mount the Docker socket or host SSH keys.

## Secrets

Never print or commit secret values. Treat every credential present on the
compromised VPS as exposed and rotate it before restoring the corresponding
service.

The ignored plaintext `ansible/secrets.yml` contains untrusted historical
values and is not an approved source for the rebuilt server. Migrate only
rotated values into encrypted production variables when service restoration
begins. Do not copy old values into a new vault merely to preserve the previous
deployment.

Obsolete standalone playbooks, global templates, the duplicate inventory, and
the mise configuration were deleted; use Git history when their previous logic
needs to be inspected. New service configuration belongs only in roles included
by `site.yml`. `just` is the infrastructure task interface; do not reintroduce
mise as the task runner.
