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
    └── listener_audit/
```

Active service configuration belongs in roles included by `site.yml`.
Obsolete standalone playbooks and global templates were deleted; Git history
retains their previous implementation.

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

The current site playbook maintains SSH hardening, upgrades the base Ubuntu
system, enables unattended security updates, configures persistent bounded
logs and time synchronization, reboots when a package upgrade requires it,
and rejects unexpected network listeners.

The IONOS firewall remains the external firewall. The listener audit is a
separate host-level invariant: loopback sockets are accepted automatically;
every other TCP or UDP listener must match the reviewed production allowlist
by protocol, port, and process. Application roles will be added to `site.yml`
only after their bind address and public Caddy exposure are declared.
