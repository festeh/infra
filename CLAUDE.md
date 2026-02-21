# Ansible Infrastructure

This directory contains Ansible playbooks for managing the VPS server.

## Inventory

The inventory file is not tracked in git. Create `inventory.yml` with:

```yaml
all:
  hosts:
    web_server:
      ansible_host: your-server.example.com
```

## Playbooks

- **init.yml** - Initial server setup (timezone, packages, upgrades)
- **setup-mise.yml** - Install mise and Node.js
- **latest-caddy.yml** - Install/update Caddy web server
- **latest-miniflux.yml** - Install/update Miniflux RSS reader
- **latest-pocketbase.yml** - Install/update PocketBase
- **config-caddy.yml** - Configure Caddy
- **config-coach.yml** - Configure Coach service

## Usage

```bash
cd ~/projects/infra/ansible

# Initialize server (run first on fresh install)
ansible-playbook playbooks/init.yml

# Install Miniflux (requires env vars)
export MINIFLUX_DB_PASSWORD=your_password
export MINIFLUX_ADMIN_PASSWORD=your_password
ansible-playbook playbooks/latest-miniflux.yml
```
