# Ansible Infrastructure

This repository manages the public IONOS service host and a private Tailscale
server through Ansible. Run infrastructure operations from the repository root
through `just`; do not expose individual Ansible phases as separate Just
recipes.

## Command surface

- `just provision public SHA256:...` and
  `just provision private SHA256:...` are the one-time server provisioning
  operations. The ED25519 fingerprint must be obtained independently from the
  corresponding provider console. Provisioning compares it with the network
  key before sending the temporary root password, creates `dima`, installs the
  controller SSH key, verifies key-based administration, disables root/password
  SSH, and converges the shared operating-system baseline.
- `just sb-capture-authorize` is the one-time Google Drive consent for
  sb-capture. It runs rclone locally, opens a browser once, and writes the
  encrypted credential into `sb_capture.vault.yml` itself. The consent does not
  expire; nothing else about that service is manual.
- `just apply` repeatedly converges and verifies only the public service host.
- `just apply-private` repeatedly converges and verifies the private host,
  including Tailscale. Its first run requires a one-off or restricted auth key
  in the controller's `TAILSCALE_AUTH_KEY` environment variable; later runs use
  the node's persistent identity and need no key.
- Additional Ansible flags pass through the same command, for example
  `just apply --check --diff` or `just apply --tags base`.

After provisioning, root SSH, SSH password authentication, and the root
password are disabled. Recovery therefore uses the corresponding provider's
rescue/password-reset facilities, not an expected root-password login through
the KVM console.

## Current deployed state

The base state was deployed and reboot-tested on 2026-07-12. Caddy,
PostgreSQL, CLIProxyAPI, Miniflux, dimalip.in, Papujki, Coach, My Agents, and
Syncthing were restored by 2026-07-19:

- Public host: SSH alias `ionos`, inventory host `web_server`.
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
  the reviewed CLIProxyAPI, Miniflux, Coach, My Agents, dimalip.in, and Papujki
  hosts described below.
  Structured access logs redact query strings, rotate at 25 MiB or midnight,
  retain at most 40 rotated files and 30 days, and therefore use at most about
  1 GiB before compression plus the active file.
  It was installed as Caddy 2.11.4 from the official stable repository. Every
  Caddy-role apply installs or upgrades to the latest signed stable package.
- PostgreSQL 18 is active on `127.0.0.1:5432` and `[::1]:5432` only. Miniflux
  and Coach each have a dedicated database and SCRAM login with no superuser,
  database-creation, role-creation, or replication privileges.
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
- Coach is active as a static Go binary under the dedicated unprivileged
  `coach` account on `127.0.0.1:8080`. It stores focus, attention, agent-lock,
  decision, and temptation state in its dedicated PostgreSQL database; the old
  PocketBase dependency and TCP/8090 listener are absent. Caddy publishes
  `coach.dimalip.in` with Basic Authentication for browser access and a
  separate rotated bearer/query token for machine and WebSocket clients. Query
  strings, Authorization, Cookie, and management-key headers are removed from
  structured access logs. The systemd sandbox reports an exposure score of
  1.3 (`OK`). A passwordless, non-sudo `coach-deploy` account accepts one
  project-specific ED25519 key through a forced command that permits only
  checksum-verified upload, atomic activation with rollback, status, and the
  exact `coach.service` restart. The GitHub workflow receives no application,
  PostgreSQL, Caddy, or Ansible secrets.
- My Agents is active under the dedicated unprivileged `my-agents` account on
  `127.0.0.1:8001` and registers only the Coach agent. Its SQLite LangGraph
  checkpoints live in `/var/lib/my-agents`; model traffic goes only to the
  loopback CLIProxyAPI listener and Coach tool traffic goes only to the
  loopback Coach listener. Caddy publishes only the bearer-authenticated
  health probe and the Coach WebSocket path at `agents.dimalip.in`; the latter
  accepts the rotated Coach query token and removes it before proxying. The
  service runs the `uv.lock`-resolved environment on the VPS's Python 3.14.
  A separate `my-agents-deploy` forced-command identity may upload and
  atomically activate only bounded source archives, run pinned uv with
  `--locked`, roll back failed service starts, and restart only
  `my-agents.service`. Runtime credentials remain in Ansible Vault and are not
  available to GitHub Actions or the deployment identity.
- Syncthing 2.1.2 is active as the dedicated unprivileged `syncthing` account.
  Its rotated device identity is
  `PZTBJU7-PPJFEKC-LZPAYF2-RUGIGLV-Q62MSSJ-2AH2NN5-4JTCTJX-EIEKKAJ` and its
  only non-loopback socket is the reviewed IPv4 TCP/22000 sync listener. The
  authenticated GUI and API bind to `127.0.0.1:8384` with newly rotated Vault
  credentials and have no Caddy route. QUIC, IPv6 sync, global/local discovery,
  relays, NAT traversal, usage reporting, crash reporting, and self-upgrades
  are disabled. The `vault` folder is receive-encrypted with one-year staggered
  versioning; its encryption password exists only on trusted devices and is
  absent from the VPS configuration. The laptop seeded 48 files and 13
  directories, the VPS reports zero needed items, no plaintext Markdown names
  exist on disk, and the systemd sandbox reports an exposure score of 1.5
  (`OK`). The retired pre-compromise VPS identity was removed from the laptop
  only after the rotated peer reached 100% completion. The phone still requires
  the same one-time identity replacement.

- sb capture is active as the dedicated unprivileged `sb-capture` account on
  `127.0.0.1:8092`, serving the watch voice-capture pipeline for the `sb`
  vault: it trims silence with ffmpeg, transcribes through ElevenLabs Scribe,
  and archives the original recording to Google Drive with rclone. Caddy
  publishes `capture.dimalip.in` as a machine-only bearer route with no browser
  fallback; every other path returns 404. It never touches the vault — the VPS
  holds that as an encrypted Syncthing peer and the phone writes the
  transcript. Audio is trimmed and transcribed in a tmpfs `RuntimeDirectory`
  and deleted immediately; the idempotency cache is memory-only with a one-hour
  TTL so transcripts never reach this disk. A failed Drive upload spools to
  `/var/lib/sb-capture/spool` and a 15-minute timer drains it; `/health`
  reports the spool depth. Unlike the loopback-only services here its sandbox
  permits egress, since it must reach ElevenLabs and Google. Its Drive consent
  is a one-time browser approval performed by `just sb-capture-authorize`.

The base state has been verified across a real reboot and with a negative
listener-audit test. The restored sites passed their dry runs, Caddy
configuration, log-redaction and retention assertions, public CLIProxyAPI and
Miniflux route/authentication checks, one model smoke test per provider,
static-site, Coach authentication/database/sandbox, negative-shell deployment,
Syncthing authentication/encryption/listener/seed checks, the listener audit,
and complete idempotence applies.

## Restoration scope

`docs/service-inventory.md` is authoritative. The retained public scope is
Caddy, OAuth2 Proxy, PostgreSQL, CLIProxyAPI/ai, Miniflux/rss, Coach, My Agents
with only the Coach agent, dimalip.in, Papujki, and Syncthing. Coach owns a
dedicated PostgreSQL database.

## Ansible structure

- `ansible/playbooks/public/site.yml` is the only application-stack entry point
  and must never run with the private inventory.
- `ansible/playbooks/shared/harden-ssh.yml` is the provisioning/public-site
  wrapper for the
  `access` role, which continuously verifies the SSH access invariants.
- `ansible/playbooks/shared/bootstrap-access.yml` and `base.yml` own the other
  shared provisioning phases.
- `ansible/playbooks/private/site.yml` is the repeatable private entry point;
  it applies the shared baseline and Tailscale only.
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
- `ansible/roles/coach` owns its unprivileged service, restricted PostgreSQL
  role and database, protected environment, systemd sandbox, authenticated
  Caddy route, immutable release declaration, and service-specific checks.
- `ansible/roles/my_agents` owns its unprivileged service, protected runtime
  environment, persistent SQLite state, systemd sandbox, narrow authenticated
  Caddy route, initial release construction, and service-specific checks.
- `ansible/roles/syncthing` owns the signed stable-v2 package source, rotated
  device identity and GUI/API credentials, receive-encrypted vault declaration,
  trusted-peer IDs, versioning, systemd sandbox, exact listener shape, seeded
  data minimums, and service-specific checks. It never receives the trusted
  peers' folder-encryption password.
- `ansible/roles/tailscale` owns the signed stable package source, fixed
  UDP/41641 peer port, private MagicDNS name, conservative client preferences,
  first-time enrollment, and online-state verification. Enrollment consumes a
  controller environment auth key through a temporary root-only file and never
  persists that key.
- `ansible/roles/binary_release` implements the shared restricted deployment
  identity, checksum-addressed binary receiver, atomic activation/rollback,
  retention, exact-unit restart permission, and active-binary validation used
  by process-backed application roles.
- `ansible/roles/static_release` implements the shared restricted deployment
  identity, checksum-addressed release receiver, atomic activation, retention,
  and active-file validation used by static application roles.
- `ansible/roles/uv_release` installs the checksum-pinned uv runtime and
  implements bounded source upload, locked dependency synchronization,
  checksum-addressed atomic activation/rollback, retention, exact-unit restart
  permission, and virtual-environment validation for Python services.
- `ansible/roles/runtime_secrets` owns protected per-service secret files.
- `ansible/roles/listener_audit` installs and runs the listener guard.
- Public application variables live below
  `ansible/inventories/public/group_vars/`. The private inventory contains only
  its Tailscale declaration and no Vault files.

Roles own service configuration and must be idempotent. A second run of the
applicable `just apply` or `just apply-private` command after any completed
change should report `changed=0`.

## Network exposure invariant

The listener audit runs at the end of every `just apply` and
`just apply-private`, including check mode. It ignores `127.0.0.0/8` and `::1`
listeners. Every socket on a wildcard, interface, or other non-loopback address
must match the scope-specific allowlist by protocol, port, and process. Linux
process names reported by `ss` may be truncated to 15 characters.

The public allowlist contains only:

- TCP/22 owned by `sshd` (one IPv4 and one IPv6 socket).
- TCP/80 and TCP/443 owned by `caddy` (one IPv4/IPv6 wildcard socket each).
- TCP/22000 owned by `syncthing` (one IPv4-only sync socket).
- UDP/68 owned by `systemd-network`, the image's DHCP client.

The private allowlist contains TCP/22 from `sshd`, UDP/68 from the image's DHCP
client, and Tailscale's explicitly fixed UDP/41641 peer socket from
`tailscaled`. It also permits `tailscaled`'s dynamic TCP PeerAPI listeners only
when they bind within Tailscale's private `100.64.0.0/10` or
`fd7a:115c:a1e0::/48` ranges; the same ports remain forbidden on wildcard and
public addresses. Tailscale SSH remains disabled; clients use the existing
hardened OpenSSH service over the tailnet. The provider firewall should allow
inbound UDP/41641 to maximize direct peer connections, while Tailscale can use
a relay when a direct path is unavailable.

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
6. Add a public-listener rule only for genuine edge services such as SSH/Caddy
   or an explicitly reviewed peer transport such as Syncthing TCP/22000.
7. Run `just apply --check --diff`, then `just apply`, then `just apply` again
   to prove idempotence.

## Secrets

Never print or commit secret values. Treat every credential present on the
compromised VPS as exposed and rotate it before restoring the corresponding
service.

The public Vault password is stored as `ANSIBLE_VAULT_PASSWORD` in the
ignored `~/dotfiles/.env`, which must remain owned by the current user with mode
`0600`. Its recovery copy belongs in the Bitwarden item
`infra: public Ansible Vault`. The checked-in
`ansible/scripts/vault-password-client` is the only supported password bridge;
do not add a plaintext vault-password file.

Encrypted public-service values live below
`ansible/inventories/public/group_vars/all/`; shared service values use
`vault.yml` and separately reviewable service files may use inline `!vault`
values such as `coach.vault.yml` and `syncthing.vault.yml`. Service roles map
runtime-file values into `runtime_secret_files`; the `runtime_secrets` role
writes root-owned `0640` files below `/etc/<service>/` with `no_log: true` and
diffs disabled. Do not run secret-bearing tasks with `ANSIBLE_DEBUG=1`, and
never give routine application deployment workflows the Vault password.

The ignored plaintext `ansible/secrets.yml` is not an approved source for the
rebuilt server. Its application values are untrusted historical material. Its
mode-`0600` Syncthing folder-encryption password is retained only as a
controller-side recovery copy for trusted peers, matches the active laptop
configuration, and must never be referenced by the Syncthing role or sent to
the VPS. Migrate only rotated server-side values into encrypted public
variables; do not copy old application values into a new vault merely to
preserve the previous deployment.

Obsolete standalone playbooks, global templates, the duplicate inventory, and
the mise configuration were deleted; use Git history when their previous logic
needs to be inspected. New service configuration belongs only in roles included
by `playbooks/public/site.yml`. `just` is the infrastructure task interface; do
not reintroduce mise as the task runner.
