set shell := ["bash", "-euo", "pipefail", "-c"]

ansible_dir := justfile_directory() + "/ansible"
inventory := ansible_dir + "/inventories/production/hosts.yml"
host_alias := "ionos"

default:
    @just --list

# Print the untrusted ED25519 fingerprint currently offered by the VPS.
_host-fingerprint:
    #!/usr/bin/env bash
    resolved_host="$(ssh -G "{{ host_alias }}" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    port="$(ssh -G "{{ host_alias }}" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT
    ssh-keyscan -T 10 -p "$port" -t ed25519 "$resolved_host" > "$key_file" 2>/dev/null
    ssh-keygen -lf "$key_file" -E sha256

# Replace the stale pre-reinstall host key only when it matches the fingerprint
# obtained independently from the IONOS console.
_trust-host expected_fingerprint:
    #!/usr/bin/env bash
    resolved_host="$(ssh -G "{{ host_alias }}" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
    port="$(ssh -G "{{ host_alias }}" 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
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

    ssh-keygen -R "{{ host_alias }}" >/dev/null 2>&1 || true
    ssh-keygen -R "$resolved_host" >/dev/null 2>&1 || true
    ssh-keygen -R "[$resolved_host]:$port" >/dev/null 2>&1 || true
    key_line="$(awk '$2 == "ssh-ed25519" { print; exit }' "$key_file")"
    if [[ -z "$key_line" ]]; then
      echo "ssh-keyscan returned no ED25519 host key" >&2
      exit 1
    fi
    printf '%s\n' "$key_line" >> "$HOME/.ssh/known_hosts"

    echo "Trusted $resolved_host:$port with $actual_fingerprint"

# Trust an independently verified host key, provision dima, and harden SSH.
bootstrap expected_fingerprint:
    @command -v ansible-playbook >/dev/null || { echo "ansible-playbook is required" >&2; exit 1; }
    @command -v sshpass >/dev/null || { echo "sshpass is required for Ansible --ask-pass" >&2; exit 1; }
    @just _trust-host "{{ expected_fingerprint }}"
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" playbooks/bootstrap-access.yml --ask-pass -e ansible_user=root
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" playbooks/harden-ssh.yml

# Converge the complete declared server state and run all safety checks.
apply *ansible_args:
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" playbooks/site.yml {{ ansible_args }}
