set shell := ["bash", "-euo", "pipefail", "-c"]

ansible_dir := justfile_directory() + "/ansible"
# The sb checkout the private server's CLI and skills are installed from.
sb_checkout := env('SB_CHECKOUT', env('HOME') + "/projects/sb")
public_inventory := ansible_dir + "/inventories/public/hosts.yml"
private_inventory := ansible_dir + "/inventories/private/hosts.yml"

default:
    @just --list

# Print the untrusted ED25519 fingerprint currently offered by a server.
_host-fingerprint scope:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ scope }}" in
      public) host_alias=ionos ;;
      private) host_alias=private ;;
      *) echo "Scope must be public or private" >&2; exit 2 ;;
    esac

    resolved_host="$(ssh -G "$host_alias" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    port="$(ssh -G "$host_alias" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT
    ssh-keyscan -T 10 -p "$port" -t ed25519 "$resolved_host" > "$key_file" 2>/dev/null
    ssh-keygen -lf "$key_file" -E sha256

# Trust a host key only when it matches a fingerprint obtained independently
# from the corresponding provider console.
_trust-host scope expected_fingerprint:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ scope }}" in
      public) host_alias=ionos ;;
      private) host_alias=private ;;
      *) echo "Scope must be public or private" >&2; exit 2 ;;
    esac

    resolved_host="$(ssh -G "$host_alias" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    port="$(ssh -G "$host_alias" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT

    ssh-keyscan -T 10 -p "$port" -t ed25519 "$resolved_host" > "$key_file" 2>/dev/null
    actual_fingerprint="$(ssh-keygen -lf "$key_file" -E sha256 | awk '{ print $2 }')"

    if [[ "$actual_fingerprint" != "{{ expected_fingerprint }}" ]]; then
      echo "Host-key mismatch: expected {{ expected_fingerprint }}, received $actual_fingerprint" >&2
      exit 1
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/known_hosts"
    chmod 600 "$HOME/.ssh/known_hosts"

    ssh-keygen -R "$host_alias" >/dev/null 2>&1 || true
    ssh-keygen -R "$resolved_host" >/dev/null 2>&1 || true
    ssh-keygen -R "[$resolved_host]:$port" >/dev/null 2>&1 || true
    key_line="$(awk '$2 == "ssh-ed25519" { print; exit }' "$key_file")"
    if [[ -z "$key_line" ]]; then
      echo "ssh-keyscan returned no ED25519 host key" >&2
      exit 1
    fi
    printf '%s\n' "$key_line" >> "$HOME/.ssh/known_hosts"

    echo "Trusted $resolved_host:$port with $actual_fingerprint"

# Trust the host, provision access, harden SSH, and converge the shared base.
provision scope expected_fingerprint:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ scope }}" in
      public) inventory="{{ public_inventory }}" ;;
      private) inventory="{{ private_inventory }}" ;;
      *) echo "Scope must be public or private" >&2; exit 2 ;;
    esac

    command -v ansible-playbook >/dev/null || { echo "ansible-playbook is required" >&2; exit 1; }
    password_args=(--ask-pass)
    if [[ -n "${ANSIBLE_CONNECTION_PASSWORD_FILE:-}" ]]; then
      password_args=(--connection-password-file "$ANSIBLE_CONNECTION_PASSWORD_FILE")
    else
      command -v sshpass >/dev/null || { echo "sshpass is required for Ansible --ask-pass" >&2; exit 1; }
    fi

    just _trust-host "{{ scope }}" "{{ expected_fingerprint }}"
    cd "{{ ansible_dir }}"
    ansible-playbook -i "$inventory" playbooks/shared/bootstrap-access.yml "${password_args[@]}" -e ansible_user=root
    ansible-playbook -i "$inventory" playbooks/shared/harden-ssh.yml
    ansible-playbook -i "$inventory" playbooks/shared/base.yml

# Authorize Google Drive for sb-capture: one browser approval, once, ever.
sb-capture-authorize scope="drive.file":
    cd "{{ ansible_dir }}" && ./scripts/sb-capture-authorize-drive "{{ scope }}"

# Converge the complete public service stack and run all safety checks.
apply *ansible_args:
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ public_inventory }}" playbooks/public/site.yml {{ ansible_args }}

# Converge the private server, including Tailscale, and run all safety checks.
apply-private *ansible_args:
    #!/usr/bin/env bash
    set -euo pipefail

    dotfiles_env="$HOME/dotfiles/.env"
    if [[ ! -r "$dotfiles_env" ]]; then
      echo "Private apply requires a readable $dotfiles_env" >&2
      exit 1
    fi

    load_private_harness_secret() {
      local variable_name="$1"
      (
        set +u
        source "$dotfiles_env"
        value="${!variable_name:-}"
        [[ -n "$value" ]] || exit 1
        printf %s "$value"
      )
    }

    if ! KIMI_API_KEY="$(load_private_harness_secret KIMI_API_KEY)"; then
      echo "KIMI_API_KEY is missing from $dotfiles_env" >&2
      exit 1
    fi
    if ! OLLAMA_API_KEY="$(load_private_harness_secret OLLAMA_API_KEY)"; then
      echo "OLLAMA_API_KEY is missing from $dotfiles_env" >&2
      exit 1
    fi
    export KIMI_API_KEY OLLAMA_API_KEY

    # The vault's sync server and bearer token, as the sb builds read them.
    sync_env="$HOME/.config/sb/sync.env"
    if [[ ! -r "$sync_env" ]]; then
      echo "Private apply requires a readable $sync_env" >&2
      exit 1
    fi
    set -o allexport
    source "$sync_env"
    set +o allexport
    : "${SB_SYNC_URL:?SB_SYNC_URL is missing from $sync_env}"
    : "${SB_SYNC_TOKEN:?SB_SYNC_TOKEN is missing from $sync_env}"

    cd "{{ ansible_dir }}"
    ansible-playbook -i "{{ private_inventory }}" playbooks/private/site.yml {{ ansible_args }}

# Install the private server's sb CLI and skills from the local sb checkout.
# Build the binary first: `cd ~/projects/sb && just cli`.
apply-sb-vault: (apply-private "--tags" "sb_vault" "-e" ("sb_vault_release_artifact_path=" + sb_checkout + "/target/x86_64-unknown-linux-musl/release/sb") "-e" ("sb_vault_skills_path=" + sb_checkout + "/skills"))
