#!/bin/bash
#
# FASTPANEL VPS bootstrap for Laravel queue workers (Supervisord).
#
# Install or update (as root, public repo):
#   wget -qO- https://raw.githubusercontent.com/EgyptDevRu/clients-vps-init/main/init.sh | sudo bash
#
# From a checkout:  sudo bash init.sh
#
# Installs/enables Supervisord, keeps conf.d and the control socket root-only,
# installs activate-worker.sh, and adds the root cron that renders each site
# user's ~/supervisor/*.conf into conf.d. Cron uses activate-worker.sh --all
# (setpriv, no PAM) so systemd --user is not spawned on each tick.
#

set -euo pipefail

REPO_URL="https://github.com/EgyptDevRu/clients-vps-init.git"
INSTALL_DIR="/opt/EgyptDevRu/clients-vps-init"

# Piped run (wget | bash): no sibling files, so clone/pull the repo and re-exec
# the checkout's init.sh.
bootstrap() {
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v git >/dev/null 2>&1 || [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
        echo "Installing git..."
        apt-get update -qq
        apt-get install -y git ca-certificates
    fi

    # The checkout is executed as root: refuse paths anyone else could modify.
    local dir
    for dir in "$(dirname "${INSTALL_DIR}")" "${INSTALL_DIR}"; do
        if [[ -e "${dir}" ]] && { [[ -L "${dir}" ]] || [[ "$(stat -c %u "${dir}")" -ne 0 ]] \
            || [[ -n "$(find "${dir}" -maxdepth 0 -perm /022)" ]]; }; then
            echo "${dir} must be a root-owned directory not writable by others; fix it and re-run."
            exit 1
        fi
    done

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        echo "Updating ${INSTALL_DIR}..."
        git -C "${INSTALL_DIR}" pull --ff-only
    elif [[ -e "${INSTALL_DIR}" ]]; then
        echo "${INSTALL_DIR} exists but is not a git checkout; move it away and re-run."
        exit 1
    else
        echo "Cloning into ${INSTALL_DIR}..."
        mkdir -p "$(dirname "${INSTALL_DIR}")"
        git clone "${REPO_URL}" "${INSTALL_DIR}"
    fi

    exec bash "${INSTALL_DIR}/init.sh" "$@" </dev/null
}

main() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run this script as root: sudo bash init.sh"
        exit 1
    fi

    local source_path="${BASH_SOURCE[0]:-}"
    local script_dir=""
    if [[ -n "${source_path}" && -f "${source_path}" ]]; then
        script_dir="$(cd "$(dirname "${source_path}")" && pwd)"
    fi

    if [[ -z "${script_dir}" || ! -f "${script_dir}/activate-worker.sh" ]]; then
        bootstrap "$@"
    fi

    local worker_src="${script_dir}/activate-worker.sh"
    local worker_dst="/usr/local/bin/activate-worker.sh"
    local supervisor_conf="/etc/supervisor/supervisord.conf"
    local conf_d="/etc/supervisor/conf.d"
    local state_dir="/var/lib/activate-worker"
    local user_log_root="/var/log/supervisor/users"
    local cron_marker="activate-worker.sh"
    local cron_line='*/5 * * * * /usr/local/bin/activate-worker.sh --all > /dev/null 2>&1'

    echo "=== clients-vps-init: host setup ==="

    echo "Installing Supervisord and cron..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # Minimal Debian images ship without cron.
    apt-get install -y supervisor cron
    systemctl enable --now cron
    systemctl enable supervisor
    systemctl start supervisor

    # Site users must never write here: Supervisord runs as root and would run
    # any [program] they define (user=root, log files written as root, ...).
    echo "Locking ${conf_d} to root..."
    mkdir -p "${conf_d}"
    chown root:root "${conf_d}"
    chmod 755 "${conf_d}"

    if [[ ! -f "${supervisor_conf}" ]]; then
        echo "Missing ${supervisor_conf}"
        exit 1
    fi

    # Socket access = control over every client's workers, so root only.
    echo "Restricting the Supervisord control socket to root..."
    if grep -q '^\[unix_http_server\]' "${supervisor_conf}"; then
        sed -i '/^\[unix_http_server\]/,/^\[/{/^chown=/d}' "${supervisor_conf}"
        if grep -A30 '^\[unix_http_server\]' "${supervisor_conf}" | grep -qE '^chmod='; then
            sed -i '/^\[unix_http_server\]/,/^\[/{s/^chmod=.*/chmod=0700/}' "${supervisor_conf}"
        else
            sed -i '/^\[unix_http_server\]/a chmod=0700' "${supervisor_conf}"
        fi
    else
        echo "Warning: [unix_http_server] section not found in ${supervisor_conf}"
    fi

    echo "Installing ${worker_dst}..."
    install -m 755 -o root -g root "${worker_src}" "${worker_dst}"

    echo "Preparing ${state_dir} and ${user_log_root}..."
    install -d -m 700 -o root -g root "${state_dir}"
    install -d -m 755 -o root -g root "${user_log_root}"
    # Force a full scan and a supervisor apply on the run below.
    rm -f "${state_dir}/last-scan" "${state_dir}/confd.sha256"

    echo "Ensuring root cron runs activate-worker every 5 minutes..."
    local existing filtered
    existing="$(crontab -l 2>/dev/null || true)"
    filtered="$(printf '%s\n' "${existing}" | grep -vF "${cron_marker}" || true)"
    {
        printf '%s\n' "${filtered}"
        printf '%s\n' "${cron_line}"
    } | grep -v '^$' | crontab -

    # Migrates user-written conf.d files to ~/supervisor before Supervisord
    # restarts and loads conf.d again.
    echo "Running activate-worker once for all site users (setpriv, no PAM)..."
    "${worker_dst}" --all || true

    systemctl restart supervisor

    echo "=== Host setup complete ==="
    echo "Check: supervisorctl status"
    echo "Update later with the same wget command, or: sudo bash ${INSTALL_DIR}/init.sh"
}

main "$@"
