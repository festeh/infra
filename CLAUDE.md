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

The base state was deployed and reboot-tested on 2026-07-12. Caddy,
PostgreSQL, CLIProxyAPI, Miniflux, dimalip.in, and Papujki were restored by
2026-07-18:

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
- Caddy is active on TCP/80 and TCP/443. Unknown hosts receive an empty 404
  response, the admin API binds only to `127.0.0.1:2019`, and HTTP/3 is disabled
  to avoid an unreviewed UDP listener. Its application routes are limited to
  the reviewed CLIProxyAPI, Miniflux, dimalip.in, and Papujki hosts described
  below.
  Structured access logs redact query strings, rotate at 25 MiB or midnight,
  retain at most 40 rotated files and 30 days, and therefore use at most about
  1 GiB before compression plus the active file.
  It was installed as Caddy 2.11.4 from the official stable repository. Every
  Caddy-role apply installs or upgrades to the latest signed stable package.
- PostgreSQL 18 is active on `127.0.0.1:5432` and `[::1]:5432` only. Miniflux
  has a dedicated database and SCRAM login with no superuser, database-creation,
  role-creation, or replication privileges.
- CLIProxyAPI 7.2.88 is active as the dedicated unprivileged `cliproxyapi`
  account, using the checksum-pinned plugin-free upstream release. It binds
  only to `127.0.0.1:8317`, writes operational logs to the bounded system
  journal, and reads its root-owned `0640` configuration from Ansible Vault.
  Caddy exposes authenticated `/v1` routes, the exact static
  `/management.html` login page, and management-key-protected `/v0/management`
  routes at `ai.dimalip.in`; all other public paths return 404. CLIProxyAPI
  itself remains loopback-only. The pinned panel is managed by Ansible, and
  panel auto-update is disabled. The
  configured providers are OpenRouter, Groq, Gemini, and Kimi. One real chat-completion
  request through the public endpoint passed for each provider after deployment.
- Miniflux 2.3.2 is checksum-pinned and active as an unprivileged `miniflux`
  account on `127.0.0.1:8085`. Caddy publishes `rss.dimalip.in`; Miniflux's own
  session and API authentication remain mandatory. The role declares the three
  recovered feed subscriptions and the administrator's dark sans-serif theme,
  and verifies both preferences and retained Ben's Bites entries on every
  apply without forcing rate-limited upstream requests. Its
  Kill-the-Newsletter endpoint exceeded the upstream client's 20-second
  default during investigation, so the reviewed fetch timeout is 40 minutes
  (2400 seconds).
  Runtime and fetch logs remain in the bounded system journal.
- `dimalip.in` and `www.dimalip.in` are active as a fully static Vue site.
  Caddy reads `/opt/dimalip.in/current/dist` directly; there is no backend,
  database, runtime secret, systemd unit, or TCP/6190 listener. Unknown files
  and the removed `/api/*` paths return 404. A passwordless, non-sudo
  `dimalip-deploy` account accepts one project-specific ED25519 key through an
  OpenSSH forced command. That command permits only size-limited,
  checksum-verified upload, atomic activation, and status operations within
  the dimalip.in release tree. Shell commands are rejected and OpenSSH's
  `restrict` option disables PTYs, forwarding, agents, and user startup files.
- `papujki.space` and `www.papujki.space` are active as a fully static Next.js
  export. Caddy reads `/opt/papujki/current/dist` directly; there is no Node.js
  process, systemd application unit, runtime secret, database, or TCP/3333
  listener. A passwordless, non-sudo `papujki-deploy` account accepts one
  project-specific ED25519 key through the same size-limited,
  checksum-verified, forced-command release protocol used by dimalip.in.

The base state has been verified across a real reboot and with a negative
listener-audit test. The restored sites passed their dry runs, Caddy
configuration, log-redaction and retention assertions, public CLIProxyAPI and
Miniflux route/authentication checks, one model smoke test per provider,
static-site and
negative-shell deployment tests, the listener audit, and complete idempotence
applies.

## Restoration scope

`docs/service-inventory.md` is authoritative. The retained production scope is
Caddy, OAuth2 Proxy, PostgreSQL, CLIProxyAPI/ai, Miniflux/rss, Coach, My Agents
with only the Coach agent, dimalip.in, Papujki, and Syncthing. Coach owns a
dedicated PostgreSQL database.

## Ansible structure

- `ansible/playbooks/site.yml` is the only repeatable site entry point.
- `ansible/playbooks/harden-ssh.yml` is the bootstrap/site wrapper for the
  `access` role, which continuously verifies the SSH access invariants.
- `ansible/roles/access` owns SSH hardening and root-password locking.
- `ansible/roles/base` owns packages, upgrades, time, journald, and reboot
  handling.
- `ansible/roles/caddy` owns the official package repository, edge service,
  shared access logger, deny-by-default routes, and systemd sandbox.
- `ansible/roles/postgresql` owns the single loopback-only PostgreSQL cluster
  and its local authentication policy.
- `ansible/roles/cliproxyapi` owns the pinned release, unprivileged service,
  protected provider configuration, loopback listener, restricted Caddy route,
  and service-specific verification.
- `ansible/roles/miniflux` owns its pinned release, restricted PostgreSQL role
  and database, protected configuration, declared feeds, loopback listener,
  Caddy route, and feed-specific verification.
- `ansible/roles/dimalip` owns the static release tree, restricted deployment
  identity and command, public deployment key, Caddy route, and public/negative
  verification. It intentionally owns no application service or secret.
- `ansible/roles/papujki` owns the Papujki deployment declaration, static Caddy
  route, and public/negative verification. It intentionally owns no
  application service or secret.
- `ansible/roles/static_release` implements the shared restricted deployment
  identity, checksum-addressed release receiver, atomic activation, retention,
  and active-file validation used by static application roles.
- `ansible/roles/runtime_secrets` owns protected per-service secret files.
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
- TCP/80 and TCP/443 owned by `caddy` (one IPv4/IPv6 wildcard socket each).
- UDP/68 owned by `systemd-network`, the image's DHCP client.

Caddy's admin API on `127.0.0.1:2019` is ignored as loopback. HTTP/3 is
deliberately disabled, so Caddy must not own UDP/443.

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

## Secrets

Never print or commit secret values. Treat every credential present on the
compromised VPS as exposed and rotate it before restoring the corresponding
service.

The production Vault password is stored as `ANSIBLE_VAULT_PASSWORD` in the
ignored `~/dotfiles/.env`, which must remain owned by the current user with mode
`0600`. Its recovery copy belongs in the Bitwarden item
`infra: production Ansible Vault`. The checked-in
`ansible/scripts/vault-password-client` is the only supported password bridge;
do not add a plaintext vault-password file.

Encrypted production values live in
`ansible/inventories/production/group_vars/all/vault.yml` under
`vault_service_secrets`. Service roles map those values into
`runtime_secret_files`; the `runtime_secrets` role writes root-owned `0640`
files below `/etc/<service>/` with `no_log: true` and diffs disabled. Do not run
secret-bearing tasks with `ANSIBLE_DEBUG=1`, and never give routine application
deployment workflows the Vault password.

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
