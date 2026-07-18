# Infrastructure

Ansible manages the VPS. `just` provides the small, repeatable command surface.

## Repository layout

```text
ansible/
├── inventories/production/
│   ├── hosts.yml
│   └── group_vars/all/main.yml
├── playbooks/
│   ├── bootstrap-access.yml
│   ├── harden-ssh.yml
│   └── site.yml
└── roles/
    ├── access/
    ├── base/
    ├── caddy/
    ├── cliproxyapi/
    ├── dimalip/
    ├── listener_audit/
    ├── miniflux/
    ├── postgresql/
    └── runtime_secrets/
docs/
└── service-inventory.md
```

Active service configuration belongs in roles included by `site.yml`.
Obsolete standalone playbooks and global templates were deleted; Git history
retains their previous implementation.

[`docs/service-inventory.md`](docs/service-inventory.md) is the authoritative
production restoration scope. Repositories, DNS records, backups, and old Git
history do not make a service active unless it appears in that retained list.

## Bootstrap a reinstalled VPS

The bootstrap is deliberately split into two safety stages. The first connects
once as root and provisions `dima`; the second must establish a separate
key-based `dima` connection before it disables root and password authentication.

Prerequisites on the controller:

- `ansible-playbook`
- `just`
- `sshpass` (used only for Ansible's interactive `--ask-pass` prompt)
- `~/.ssh/id_ed25519.pub`, or `BOOTSTRAP_SSH_PUBLIC_KEY` pointing to another key

1. The password shown by IONOS after reinstall is temporary. If it has been
   exposed, change it from the IONOS console before using it.
2. In the IONOS console, print the new server's ED25519 host-key fingerprint:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
   ```

3. Pass that independently verified fingerprint to the one-time bootstrap. It
   compares the fingerprint with the key offered over the network before it
   permits Ansible to send the temporary root password:

   ```bash
   just bootstrap SHA256:YOUR_VERIFIED_FINGERPRINT
   ```

   Enter the temporary root password only at Ansible's prompt. It is never
   stored in the repository or command line.

On success, SSH accepts the controller key for `dima`; root SSH, SSH password
authentication, and the root password are disabled.

## Apply the declared server state

After the one-time bootstrap, one command converges and verifies the server:

```bash
just apply
```

Additional Ansible arguments can be passed through the same command, for
example `just apply --check --diff`.

## Production secrets

Production secret variables are committed only in the encrypted
`ansible/inventories/production/group_vars/all/vault.yml` file. Ansible obtains
the Vault password from `ANSIBLE_VAULT_PASSWORD` in `~/dotfiles/.env` through a
checked-in password client; the env file must be owned by the current user and
must not grant access to group or others.

The password's recovery copy belongs in Bitwarden. Runtime application secrets
are installed as root-owned files below `/etc/<service>/`, readable only by
root and the corresponding service group. Routine application deployments
replace code without receiving the Vault password or rewriting these files.

The current site playbook maintains SSH hardening, upgrades the base Ubuntu
system, enables unattended security updates, configures persistent bounded
logs and time synchronization, manages the deny-by-default Caddy edge and
loopback-only PostgreSQL, CLIProxyAPI, and Miniflux services, the static
`dimalip.in` site, reboots when a package upgrade requires it, and rejects
unexpected network listeners.

The IONOS firewall remains the external firewall. The listener audit is a
separate host-level invariant: loopback sockets are accepted automatically;
every other TCP or UDP listener must match the reviewed production allowlist
by protocol, port, and process. Application roles will be added to `site.yml`
only after their bind address and public Caddy exposure are declared.

Caddy writes structured request activity to `/var/log/caddy/access.log` with
query strings redacted. It rotates at midnight or 25 MiB, retains no more than
40 rotated files or 30 days, and keeps runtime/service messages in journald.

## CLIProxyAPI management panel

Open `https://ai.dimalip.in/management.html` and paste the CLIProxyAPI
management key into the panel login. Copy it to the Wayland clipboard without
displaying it:

```bash
source ~/dotfiles/.env
printf %s "$CLIPROXYAPI_MGMT_KEY" | wl-copy
```

The service itself remains bound to `127.0.0.1`. Caddy exposes only the static
login page and the exact `/v0/management/*` API paths. The management API
requires CLIProxyAPI's management key; loading the login page reveals no
configuration or credentials. The OpenAI-compatible `/v1/*` routes continue
to require their separate API key; every other path returns 404.

The panel asset is checksum-pinned and installed by Ansible; its automatic
updater is disabled. Ansible remains the source of truth for the protected
configuration, so provider keys and model configuration belong in the Vault
and role rather than dashboard edits.

## Miniflux

Open `https://rss.dimalip.in` and sign in as `admin`. Copy the generated
password without displaying it:

```bash
source ~/dotfiles/.env
printf %s "$MINIFLUX_ADMIN_PASSWORD" | wl-copy
```

The `miniflux` role installs the checksum-pinned upstream release, creates a
non-superuser SCRAM PostgreSQL login and dedicated database, binds Miniflux to
`127.0.0.1:8085`, and exposes it only through Caddy. The three subscriptions
recovered from Git history are managed declaratively: The Rundown AI, Ben's
Bites, and The Sequence. The recovered administrator preference is also
enforced declaratively as the dark sans-serif theme.

Ben's Bites uses a Kill-the-Newsletter Atom endpoint. During restoration its
first response from the VPS took 25.25 seconds, exceeding Miniflux's 20-second
default and producing a fetch timeout even though the feed was healthy. The
managed configuration uses a 40-minute (2400-second) fetch timeout. Every apply
verifies that Ben's Bites remains enabled with imported entries and fails on a
persistent error streak. It deliberately does not force a refresh because the
upstream endpoint rate-limits repeated requests with HTTP 429.

## dimalip.in

`dimalip.in` is a static Vue site. Its build generates the visualization
catalogue and packages only `dist/` plus a revision marker; production has no
application process, database, runtime secret, or private listener for it.
Caddy serves the active release from `/opt/dimalip.in/current/dist` and returns
404 for the removed `/api/*` paths and unknown files.

Ansible owns the `dimalip-deploy` account, release directories, forced command,
public deployment key, and Caddy route. The account has no password or sudo
access. Its SSH key is restricted from shells, PTYs, forwarding, agents, and
user startup files; the forced command accepts only checksum-verified `upload`,
`activate`, and `status` operations for this release tree. Activation is an
atomic symlink replacement and retains the five newest releases.

The `festeh/dimalip.in` GitHub repository stores the pinned VPS host key and
address as `DEPLOY_KNOWN_HOSTS` and `DEPLOY_HOST` variables. Its only deployment
secret is `DEPLOY_SSH_PRIVATE_KEY`; it receives neither sudo access nor the
Ansible Vault password. A push to `main` builds, audits, uploads, activates, and
verifies the checksum-addressed release.
