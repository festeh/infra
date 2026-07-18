# Production service inventory

This file is the authoritative restoration scope for the rebuilt IONOS VPS.
An application is not part of production merely because an old playbook,
project repository, DNS record, or backup still exists.

Current state: Caddy, PostgreSQL, CLIProxyAPI, Miniflux, and the static
`dimalip.in` and Papujki sites are active; every other retained service is
absent. Caddy has deny-by-default catch-alls plus the reviewed `ai.dimalip.in`,
`rss.dimalip.in`, `dimalip.in`, `www.dimalip.in`, `papujki.space`, and
`www.papujki.space` routes. Listener and route values record the reviewed
production shape; every role must revalidate them before enabling the service.

## Retained services

| Service | Source | Private listener | Public route | Dependencies |
| --- | --- | --- | --- | --- |
| Caddy | Official stable package repository | admin on `127.0.0.1:2019` | TCP 80/443 | retained HTTP services |
| OAuth2 Proxy | Ansible-managed upstream release | `127.0.0.1:4180` | none directly | Caddy, OAuth provider credentials |
| PostgreSQL | Ubuntu package | `127.0.0.1:5432`, `[::1]:5432` | none | Miniflux, Coach |
| CLIProxyAPI / ai | Ansible-managed upstream release | `127.0.0.1:8317` | `ai.dimalip.in` | Caddy, model-provider credentials |
| Miniflux / rss | Ansible-managed upstream release | `127.0.0.1:8085` | `rss.dimalip.in` | PostgreSQL, Caddy |
| Coach | `festeh/coach` artifact | `127.0.0.1:8080` | `coach.dimalip.in` | PostgreSQL, OAuth2 Proxy, Caddy |
| My Agents | `festeh/my-agents` artifact; Coach agent only | `127.0.0.1:8001` | `agents.dimalip.in` | Coach, CLIProxyAPI, OAuth2 Proxy, Caddy |
| dimalip.in | `festeh/dimalip.in` static artifact | none | `dimalip.in`, `www.dimalip.in` | Caddy |
| Papujki | `festeh/papujki` static artifact | none | `papujki.space`, `www.papujki.space` | Caddy |
| Syncthing | Ansible-managed upstream package plus retained identity/data | GUI on `127.0.0.1:8384`; sync transport pending review | no HTTP route | reviewed IONOS firewall rule if direct sync is retained |

Restore in dependency order: shared foundations, CLIProxyAPI, application
services, then Syncthing. Coach must implement its dedicated PostgreSQL
persistence layer before deployment. Syncthing must remain last so an incorrect
identity, path, or folder mode cannot overwrite recovered data.

## Ownership boundaries

- Ansible owns users, directories, systemd units, protected runtime secret
  files, databases, Caddy routes, and listener declarations.
- Application repositories build immutable artifacts. Their routine deployment
  workflows may replace only their own application release and, where a
  process exists, restart only their own unit.
- Routine application deployments never receive the Ansible Vault password and
  never write application secrets.
- A new service or route requires an explicit inventory change before its role
  is added to `ansible/playbooks/site.yml`.
