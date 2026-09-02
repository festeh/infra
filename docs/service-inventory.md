# Public service inventory

This file is the authoritative restoration scope for the public IONOS VPS.
An application is not part of the public stack merely because an old playbook,
project repository, DNS record, or backup still exists.

Current state: Caddy, PostgreSQL, CLIProxyAPI, Miniflux, Coach, My Agents,
sb server, and the static `dimalip.in` and Papujki sites are active; OAuth2 Proxy remains deferred. Caddy has
deny-by-default catch-alls plus the reviewed `ai.dimalip.in`, `rss.dimalip.in`,
`coach.dimalip.in`, `agents.dimalip.in`, `sb.dimalip.in`, `dimalip.in`,
`www.dimalip.in`, `papujki.space`, and `www.papujki.space` routes. Listener
and route values record the reviewed public shape; every role must
revalidate them before enabling the service.

sb server replaced sb capture (`capture.dimalip.in`, `127.0.0.1:8092`) on
2026-09-02: the same binary now also holds the vault as a SQLite store and
serves the sync routes the sb apps follow. Syncthing was retired the same day
by `playbooks/public/retire-syncthing.yml` once every device had joined the
new server; its TCP/22000 IONOS firewall rule is no longer needed.

## Retained services

| Service | Source | Private listener | Public route | Dependencies |
| --- | --- | --- | --- | --- |
| Caddy | Official stable package repository | admin on `127.0.0.1:2019` | TCP 80/443 | retained HTTP services |
| OAuth2 Proxy | Ansible-managed upstream release | `127.0.0.1:4180` | none directly | Caddy, OAuth provider credentials |
| PostgreSQL | Ubuntu package | `127.0.0.1:5432`, `[::1]:5432` | none | Miniflux, Coach |
| CLIProxyAPI / ai | Ansible-managed upstream release | `127.0.0.1:8317` | `ai.dimalip.in` | Caddy, model-provider credentials |
| Miniflux / rss | Ansible-managed upstream release | `127.0.0.1:8085` | `rss.dimalip.in` | PostgreSQL, Caddy |
| Coach | `festeh/coach` artifact | `127.0.0.1:8080` | `coach.dimalip.in` | PostgreSQL, Caddy |
| My Agents | `festeh/my-agents` locked uv source artifact; Coach agent only | `127.0.0.1:8001` | `agents.dimalip.in` | Coach, CLIProxyAPI, Caddy |
| dimalip.in | `festeh/dimalip.in` static artifact | none | `dimalip.in`, `www.dimalip.in` | Caddy |
| Papujki | `festeh/papujki` static artifact | none | `papujki.space`, `www.papujki.space` | Caddy |
| sb server | `festeh/sb` statically linked `sb-server` (vault store, sync routes, voice capture) | `127.0.0.1:8093` | `sb.dimalip.in`, bearer only except `/health` | Caddy, ffmpeg, rclone Google Drive remote, ElevenLabs |

Restore in dependency order: shared foundations, CLIProxyAPI, then application
services. Coach owns a dedicated PostgreSQL persistence layer; its browser
surface currently uses Caddy Basic Authentication while OAuth2 Proxy remains
deferred. sb server's vault store can be reseeded from any sb device; only its
version history lives on the VPS alone.

## Ownership boundaries

- Ansible owns users, directories, systemd units, protected runtime secret
  files, databases, Caddy routes, and listener declarations.
- Application repositories build immutable artifacts. Their routine deployment
  workflows may replace only their own application release and, where a
  process exists, restart only their own unit.
- Routine application deployments never receive the Ansible Vault password and
  never write application secrets.
- A new service or route requires an explicit public-inventory change before
  its role is added to `ansible/playbooks/public/site.yml`.
