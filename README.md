# Infrastructure

Ansible manages a public application server and a private Tailscale server.
`just` provides the small, repeatable command surface.

## Repository layout

```text
ansible/
├── inventories/
│   ├── public/
│   │   ├── hosts.yml
│   │   └── group_vars/all/
│   └── private/
│       ├── hosts.yml
│       └── group_vars/all/main.yml
├── playbooks/
│   ├── shared/
│   │   ├── base.yml
│   │   ├── bootstrap-access.yml
│   │   └── harden-ssh.yml
│   ├── private/site.yml
│   └── public/site.yml
└── roles/
    ├── access/
    ├── base/
    ├── binary_release/
    ├── caddy/
    ├── cliproxyapi/
    ├── coach/
    ├── dimalip/
    ├── listener_audit/
    ├── miniflux/
    ├── my_agents/
    ├── papujki/
    ├── postgresql/
    ├── private_harnesses/
    ├── runtime_secrets/
    ├── static_release/
    ├── syncthing/
    ├── tailscale/
    └── uv_release/
docs/
└── service-inventory.md
```

Public service configuration belongs in roles included by
`playbooks/public/site.yml`. The private site playbook adds Tailscale and the
private coding harnesses to the shared access, hardening, and operating-system
baseline.
Obsolete standalone playbooks and global templates were deleted; Git history
retains their previous implementation.

[`docs/service-inventory.md`](docs/service-inventory.md) is the authoritative
public restoration scope. Repositories, DNS records, backups, and old Git
history do not make a service active unless it appears in that retained list.

## Provision a server

The bootstrap is deliberately split into two safety stages. The first connects
once as root and provisions `dima`; the second must establish a separate
key-based `dima` connection before it disables root and password authentication.

Prerequisites on the controller:

- `ansible-playbook`
- `just`
- `sshpass` (used only for Ansible's interactive `--ask-pass` prompt)
- `~/.ssh/id_ed25519.pub`, or `BOOTSTRAP_SSH_PUBLIC_KEY` pointing to another key

1. The password shown by the hosting provider is temporary. If it has been
   exposed, reset it in the provider console before using it.
2. In the provider console, print the new server's ED25519 host-key fingerprint:

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
   ```

3. Pass that independently verified fingerprint to the one-time bootstrap. It
   compares the fingerprint with the key offered over the network before it
   permits Ansible to send the temporary root password:

   ```bash
   just provision public SHA256:YOUR_VERIFIED_FINGERPRINT
   # or: just provision private SHA256:YOUR_VERIFIED_FINGERPRINT
   ```

   Enter the temporary root password only at Ansible's prompt. It is never
   stored in the repository or command line.

On success, SSH accepts the controller key for `dima`; root SSH, SSH password
authentication, and the root password are disabled.

Provisioning installs key-based administration, hardens SSH, upgrades the
operating system, enables unattended security updates, and enforces the
scope-specific listener allowlist. It never loads the public application stack
for a private server.

## Apply the public server state

After the one-time bootstrap, one command converges and verifies the server:

```bash
just apply
```

Additional Ansible arguments can be passed through the same command, for
example `just apply --check --diff`.

## Apply the private server state

The first private apply needs a one-off or otherwise restricted Tailscale auth
key. Pass it only through the controller environment; Ansible uses a temporary
root-only file during enrollment and removes it immediately:

```bash
printf 'Tailscale auth key: ' >&2
IFS= read -r -s TAILSCALE_AUTH_KEY
printf '\n' >&2
export TAILSCALE_AUTH_KEY
just apply-private
unset TAILSCALE_AUTH_KEY
```

Later applies need no key because the node identity persists in Tailscale's
state directory:

```bash
just apply-private
```

Additional administrator SSH keys can be preserved by Ansible without storing
them in Git. Copy the private inventory's `local.yml.example` to `local.yml`,
replace the placeholder with the public key, and restrict the local file:

```bash
cp ansible/inventories/private/group_vars/all/local.yml.example \
  ansible/inventories/private/group_vars/all/local.yml
chmod 600 ansible/inventories/private/group_vars/all/local.yml
just apply-private
```

The inventory loads `local.yml` automatically, Git ignores it, and the access
role ensures every listed key remains in the administrator's
`authorized_keys`. Omitting a key does not revoke it; remove retired keys from
the server explicitly.

The role installs the latest package from Tailscale's signed stable repository,
uses the MagicDNS name `private`, accepts tailnet DNS, declines subnet routes,
and keeps Tailscale SSH disabled in favor of the existing hardened OpenSSH
service over the tailnet. The daemon uses its reviewed default UDP/41641 peer
transport; allow that port in the provider firewall for the best chance of
direct connections. Tailscale can still relay traffic when a direct path is not
available. Its HTTP PeerAPI uses dynamic TCP ports bound only to this node's
private Tailscale IPv4 and IPv6 addresses; the listener audit permits those
sockets without permitting the same ports on public or wildcard addresses.

### Private coding harnesses

The private stack keeps mise bootstrap and harness convergence in separate
playbooks. `playbooks/private/mise.yml` installs checksum-pinned mise 2026.9.1
and its private user directories; `playbooks/private/harnesses.yml` installs
the committed, locked tool declaration. The main private site imports both in
that order, so `just apply-private` remains the normal complete and idempotent
entry point.

Mise manages Node.js 24.20.0, OMP 18.1.7, Kimi Code 0.40.1, and Paseo 0.7.2.
The server therefore needs only `ca-certificates` as a mise bootstrap package;
the harness role removes the superseded apt `nodejs` and `npm` packages and the
old `/opt` installs after the replacement passes its checks. The committed
`mise.lock` pins the downloadable OMP and Node artifacts by URL and checksum,
while the two npm tools use exact package versions.

Paseo runs as `dima`, starts at boot, exposes its web and mobile control plane
only on the server's Tailscale IPv4 address, and requires its own password. The
relay, public/wildcard binds, and unused local speech model downloads are
disabled. OMP and Kimi Code are enabled as Paseo providers; OMP discovers
Ollama Cloud models and Kimi uses the Kimi Coding endpoint with K3 (model ID
`k3`) as its default, a 1M-token context window, and `max` reasoning effort.
`kimi-for-coding` remains available in the model selector. The Kimi Coding API
key must belong to an account with access to K3 and the 1M context window.

`just apply-private` reads only `KIMI_API_KEY` and `OLLAMA_API_KEY` from
`~/dotfiles/.env` and exports them to Ansible. Ansible task output and diffs are
suppressed for every secret-bearing operation. The keys are installed only in
mode-`0600` files owned by `dima`: the Ollama key in the private harness runtime
environment and the Kimi key in Kimi Code's protected provider configuration.

Paseo's separate 32-character password is generated once. Its controller copy
lives in the ignored mode-`0600` file
`ansible/inventories/private/group_vars/all/.paseo-password`; the server copy
lives in `/home/dima/.config/private-harnesses/paseo.env`. To display it only
in your current Termius session:

```bash
source ~/.config/private-harnesses/paseo.env
printf '%s\n' "$PASEO_PASSWORD"
```

On Android, connect Tailscale first, then add a direct connection in Paseo with
host `private:6767`, TLS/SSL off, and that password. Tailscale encrypts the
otherwise-HTTP connection. The same endpoint's browser UI is available at
`http://private:6767`. Standalone `omp`, `kimi`, and `paseo` commands are
system-path wrappers around the locked mise environment and are available over
the existing OpenSSH/Termius login.

## Production secrets

Public service secret variables are committed only as Ansible Vault ciphertext
below `ansible/inventories/public/group_vars/all/`. Shared values live in
`vault.yml`; separately reviewable service files may use inline `!vault`
values, as `coach.vault.yml` and `syncthing.vault.yml` do. Ansible obtains the
Vault password from `ANSIBLE_VAULT_PASSWORD` in `~/dotfiles/.env` through a
checked-in password client; the env file must be owned by the current user and
must not grant access to group or others.

The password's recovery copy belongs in Bitwarden. Runtime application secret
files are normally installed as root-owned files below `/etc/<service>/`,
readable only by root and the corresponding service group. Syncthing's API key
and password hash instead live in its mode-`0600` generated state. Routine
application deployments replace code without receiving the Vault password or
rewriting these files.

Private harness API keys are intentionally not added to Ansible Vault or Git.
They remain in `~/dotfiles/.env` on the controller and are injected during
`just apply-private`; the generated Paseo password is kept in the ignored local
inventory file described above.

The current site playbook maintains SSH hardening, upgrades the base Ubuntu
system, enables unattended security updates, configures persistent bounded
logs and time synchronization, manages the deny-by-default Caddy edge and
loopback-only PostgreSQL, CLIProxyAPI, Miniflux, Coach, and My Agents services,
the encrypted Syncthing vault peer, and the static `dimalip.in` and Papujki
sites, reboots when a package upgrade requires it, and rejects unexpected
network listeners.

The IONOS firewall remains the external firewall. The listener audit is a
separate host-level invariant: loopback sockets are accepted automatically;
every other TCP or UDP listener must match the reviewed public allowlist
by protocol, port, and process. Application roles will be added to
`playbooks/public/site.yml` only after their bind address and public Caddy
exposure are declared.

Syncthing is the only non-edge application with a direct listener: reviewed
IPv4 TCP/22000 for its mutually authenticated sync protocol. Its authenticated
GUI remains on `127.0.0.1:8384`; there is no Caddy route, IPv6 sync listener,
QUIC listener, discovery broadcast, NAT traversal, or public GUI socket.

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
catalogue and packages only `dist/` plus a revision marker; the public host has no
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

## Syncthing encrypted vault peer

The `syncthing` role installs Syncthing 2 from the checksum-pinned official
stable-v2 repository and runs it as the dedicated `syncthing` account. The
rotated VPS device identity is
`PZTBJU7-PPJFEKC-LZPAYF2-RUGIGLV-Q62MSSJ-2AH2NN5-4JTCTJX-EIEKKAJ`; trusted
devices reach it at `tcp://85.215.131.140:22000`. The IONOS firewall remains
authoritative for that port.

The `vault` folder is `receiveencrypted` on the VPS with one-year staggered
versioning. The folder-encryption password exists only on trusted peers and is
never stored in the public inventory or sent to the VPS. Ansible enforces an
empty server-side encryption-password field, the expected seeded file and
directory minimums, zero needed items, the exact listener shape, rotated GUI
and API credentials, and the systemd sandbox.

The GUI has no public route. To inspect it, first create an SSH tunnel and then
open `http://127.0.0.1:8384`:

```bash
ssh -N -L 8384:127.0.0.1:8384 ionos
```

The laptop has been re-paired and the encrypted VPS copy is complete. The phone
must replace the retired VPS ID
`Q4ZZEIX-7RLE7VC-5R6SSK3-72U45OV-EUA7AQZ-JKUYZ3P-I2SXE6G-TWLNHAN` with the
rotated ID above and reuse the existing `vault` folder-encryption password.
