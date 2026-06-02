#!/usr/bin/env bash
###############################################################################
# VPS Hardening + Docker Host + Caddy Reverse Proxy Setup
# Target: Ubuntu 24.04+ — run as root
# Installs Docker, caddy_net, and (when run from the repo) stacks under
# /opt/stacks: caddy, uptime-kuma, dozzle, dockge.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
STACKS_SRC="${REPO_ROOT}/stacks"

# shellcheck source=lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=lib/setup-env.sh
source "${REPO_ROOT}/lib/setup-env.sh"

[[ $EUID -ne 0 ]] && error "Run this script as root (fresh VPS: ssh root@your-server)."

###############################################################################
# 0. Bootstrap — git, editor, envsubst (before setup.env / clone on minimal images)
###############################################################################
info "Installing bootstrap packages (git, nano, gettext-base, curl)..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git nano vim gettext-base

load_setup_env
validate_setup_env_v2

###############################################################################
# 1. System Update & Base Packages
###############################################################################
info "Updating system packages..."
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get install -y \
  apt-transport-https gnupg lsb-release \
  software-properties-common unattended-upgrades apt-listchanges \
  fail2ban ufw logwatch apparmor apparmor-utils \
  htop tmux wget jq net-tools \
  libpam-pwquality needrestart lynis

###############################################################################
# 2. Timezone & Locale
###############################################################################
info "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "${TIMEZONE}"
timedatectl set-ntp true

###############################################################################
# 3. Create Non-Root Sudo User
###############################################################################
info "Creating user '${NEW_USER}'..."
if id "${NEW_USER}" &>/dev/null; then
  warn "User '${NEW_USER}' already exists — skipping creation."
else
  adduser --disabled-password --gecos "" "${NEW_USER}"
  usermod -aG sudo "${NEW_USER}"
fi

# Set up SSH keys for the new user
USER_HOME="/home/${NEW_USER}"
mkdir -p "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
echo "${SSH_PUBLIC_KEYS}" | sed '/^\s*$/d' > "${USER_HOME}/.ssh/authorized_keys"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.ssh"

# Allow sudo without password (optional — remove if you prefer password)
echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${NEW_USER}"
chmod 440 "/etc/sudoers.d/${NEW_USER}"

###############################################################################
# 4. SSH Hardening
###############################################################################
info "Hardening SSH..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%s)"

# Write a hardened sshd_config drop-in
cat > /etc/ssh/sshd_config.d/99-hardened.conf <<EOF
# ── Port & Protocol ──
Port ${SSH_PORT}

# ── Authentication ──
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 20

# ── Forwarding & Tunnels ──
AllowTcpForwarding no
X11Forwarding no
AllowAgentForwarding no

# ── Misc hardening ──
ClientAliveInterval 300
ClientAliveCountMax 2
PermitEmptyPasswords no
PermitUserEnvironment no
DebianBanner no
Banner none

# ── Restrict to our user ──
AllowUsers ${NEW_USER}
EOF

# Validate config before restarting
if ! sshd -t; then
  warn "SSH config validation failed — restoring backup."
  cp "${SSHD_CONFIG}.bak."* "${SSHD_CONFIG}" 2>/dev/null
  rm -f /etc/ssh/sshd_config.d/99-hardened.conf
  error "SSH config validation failed — backup restored. Fix manually before re-running."
fi

# Ubuntu 22.10+ (incl. 24.04): ssh.socket owns the listen port; Port in sshd_config
# alone often leaves sshd on 22 until ssh.socket is updated (see: systemctl status ssh).
if systemctl cat ssh.socket &>/dev/null; then
  info "Configuring ssh.socket for port ${SSH_PORT}..."
  mkdir -p /etc/systemd/system/ssh.socket.d
  cat > /etc/systemd/system/ssh.socket.d/99-hardened-port.conf <<EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
  systemctl daemon-reload
  systemctl restart ssh.socket
fi

# Debian/Ubuntu: ssh.service — RHEL/Fedora: sshd.service
if systemctl cat ssh.service &>/dev/null; then
  systemctl restart ssh.service
elif systemctl cat sshd.service &>/dev/null; then
  systemctl restart sshd.service
else
  error "Neither ssh.service nor sshd.service found — restart OpenSSH manually."
fi

if ! ss -tlnp 2>/dev/null | grep -qE ":${SSH_PORT}[[:space:]]"; then
  error "SSH is not listening on port ${SSH_PORT} after restart — check ssh.socket and sshd_config."
fi
info "SSH now listens on port ${SSH_PORT}. Root login disabled."

###############################################################################
# 5. Firewall (UFW)
###############################################################################
info "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Rate-limit SSH
ufw limit "${SSH_PORT}/tcp"

ufw --force enable
ufw status verbose

###############################################################################
# 6. Fail2Ban
###############################################################################
info "Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban
systemctl restart fail2ban

###############################################################################
# 7. Automatic Security Updates
###############################################################################
info "Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

###############################################################################
# 8. Kernel / Sysctl Hardening
###############################################################################
info "Applying sysctl hardening..."
cat > /etc/sysctl.d/99-hardened.conf <<'EOF'
# ── Network hardening ──
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1

# ── Kernel hardening ──
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF

sysctl --system

###############################################################################
# 9. Shared Memory Hardening
###############################################################################
info "Securing shared memory..."
if ! grep -q '/run/shm' /etc/fstab; then
  echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
fi

###############################################################################
# 10. Disable Unnecessary Services
###############################################################################
info "Disabling unnecessary services..."
for svc in avahi-daemon cups bluetooth; do
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    systemctl stop "${svc}"
    systemctl disable "${svc}"
    info "  Disabled ${svc}"
  fi
done

###############################################################################
# 11. Install Docker Engine (Official Repo)
###############################################################################
info "Installing Docker Engine..."
# Remove old/unofficial packages
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  apt-get remove -y "${pkg}" 2>/dev/null || true
done

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Add deploy user to docker group
usermod -aG docker "${NEW_USER}"

# Docker daemon tuning (compatible with Caddy stacks: Dozzle/Dockge need docker.sock)
# userns-remap is intentionally omitted — it breaks socket-mounted management tools.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "icc": false,
  "default-address-pools": [
    { "base": "172.20.0.0/16", "size": 24 }
  ]
}
EOF

systemctl enable docker
systemctl restart docker

###############################################################################
# 12. Docker Network for Caddy
###############################################################################
info "Creating shared Docker network 'caddy_net'..."
if ! docker network inspect caddy_net &>/dev/null; then
  docker network create --driver bridge caddy_net
else
  warn "Network 'caddy_net' already exists."
fi

###############################################################################
# 13. Directory Structure
###############################################################################
info "Creating /opt/stacks directory structure..."
mkdir -p /opt/stacks/{caddy,uptime-kuma,dozzle,dockge,_template}

###############################################################################
# 14. Install stack files (Caddy, Uptime Kuma, Dozzle, Dockge)
###############################################################################
if [[ -d "${STACKS_SRC}" ]]; then
  info "Installing stack files from ${REPO_ROOT}..."
  STACKS_DEST=/opt/stacks bash "${REPO_ROOT}/scripts/install-stacks.sh"
  install -m 0755 -d /opt/stacks/_template 2>/dev/null || true
else
  warn "No ${STACKS_SRC} — clone the repo and run: sudo bash scripts/install-stacks.sh"
fi

chown -R "${NEW_USER}:${NEW_USER}" /opt/stacks

###############################################################################
# 15. Validate stack compose files
###############################################################################
STACK_COMPOSE_OK=true
for stack in caddy uptime-kuma dozzle dockge; do
  compose_file="/opt/stacks/${stack}/compose.yml"
  if [[ -f "${compose_file}" ]]; then
    info "Validating compose: ${stack}..."
    if ! docker compose -f "${compose_file}" config -q; then
      warn "Invalid compose.yml in ${stack}"
      STACK_COMPOSE_OK=false
    fi
  else
    warn "Missing ${compose_file} — install stack files before 'docker compose up'."
    STACK_COMPOSE_OK=false
  fi
done

if [[ -f /opt/stacks/caddy/Caddyfile ]]; then
  info "Caddyfile present at /opt/stacks/caddy/Caddyfile"
else
  warn "Missing Caddyfile — reverse proxy config not installed."
  STACK_COMPOSE_OK=false
fi

###############################################################################
# 16. App Deployment Template
###############################################################################
info "Creating app deployment template..."
cat > /opt/stacks/_template/compose.yml <<'EOF'
# ──────────────────────────────────────────────────────────
# App Template — copy this folder for each new application
# ──────────────────────────────────────────────────────────
services:
  app:
    image: your-image:latest
    container_name: myapp
    restart: unless-stopped
    # expose port only to Docker network, NOT to host
    expose:
      - "8080"
    environment:
      - NODE_ENV=production
    networks:
      - caddy_net
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    mem_limit: 512m
    cpus: 1.0
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8080/health"]
      interval: 30s
      timeout: 5s
      retries: 3

networks:
  caddy_net:
    external: true
EOF

chown -R "${NEW_USER}:${NEW_USER}" /opt/stacks

###############################################################################
# 17. Logrotate for Docker
###############################################################################
info "Configuring logrotate for Docker..."
cat > /etc/logrotate.d/docker <<'EOF'
/var/lib/docker/containers/*/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    maxsize 50M
}
EOF

###############################################################################
# 18. Swap (if < 2 GB RAM)
###############################################################################
TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ ${TOTAL_MEM} -lt 2048 ]] && [[ ! -f /swapfile ]]; then
  info "Creating 2 GB swap file (low RAM detected)..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.d/99-hardened.conf
fi

###############################################################################
# 19. Helper Scripts
###############################################################################
info "Installing helper scripts..."

# Quick deploy helper
cat > /usr/local/bin/deploy-app <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
APP_NAME="${1:?Usage: deploy-app <app-name>}"
APP_DIR="/opt/stacks/${APP_NAME}"

if [[ -d "${APP_DIR}" ]]; then
  echo "Updating ${APP_NAME}..."
  cd "${APP_DIR}"
  docker compose pull
  docker compose up -d --remove-orphans
else
  echo "Creating ${APP_NAME} from template..."
  cp -r /opt/stacks/_template "${APP_DIR}"
  echo "Edit ${APP_DIR}/compose.yml, then run: deploy-app ${APP_NAME}"
fi
SCRIPT
chmod +x /usr/local/bin/deploy-app

# Docker cleanup cron
cat > /etc/cron.weekly/docker-cleanup <<'SCRIPT'
#!/usr/bin/env bash
# Do not prune volumes — Caddy/Uptime Kuma/Dockge use named volumes
docker system prune -af --filter "until=168h"
SCRIPT
chmod +x /etc/cron.weekly/docker-cleanup

cat > /usr/local/bin/update-stacks <<EOF
#!/usr/bin/env bash
set -euo pipefail
export REPO_ROOT="${REPO_ROOT}"
exec bash "${REPO_ROOT}/scripts/install-stacks.sh"
EOF
chmod +x /usr/local/bin/update-stacks

if [[ -d "${REPO_ROOT}" ]]; then
  chown -R "${NEW_USER}:${NEW_USER}" "${REPO_ROOT}"
  info "Repository owned by ${NEW_USER}: ${REPO_ROOT}"
fi

###############################################################################
# 20. Final Summary
###############################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "SETUP COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  ${GREEN}SSH User:${NC}       ${NEW_USER}"
echo -e "  ${GREEN}SSH Port:${NC}       ${SSH_PORT}"
echo -e "  ${GREEN}Stacks dir:${NC}     /opt/stacks/"
echo -e "  ${GREEN}Docker network:${NC} caddy_net (external in each compose.yml)"
echo -e "  ${GREEN}App template:${NC}    /opt/stacks/_template/compose.yml"
echo -e "  ${GREEN}Deploy helper:${NC}   deploy-app <app-name>"
echo -e "  ${GREEN}Update stacks:${NC}   update-stacks  (after git pull)"
echo -e "  ${GREEN}Apps domain:${NC}     *.${APPS_DOMAIN}"
if [[ "${STACK_COMPOSE_OK}" == true ]]; then
  echo -e "  ${GREEN}Stack files:${NC}     installed and compose configs validated"
else
  echo -e "  ${YELLOW}Stack files:${NC}     incomplete — copy stacks/* before starting services"
fi
echo ""
echo -e "  ${YELLOW}⚠  BEFORE CLOSING ROOT SSH — test deploy login in a NEW terminal:${NC}"
echo -e "     ${GREEN}ssh -p ${SSH_PORT} ${NEW_USER}@<your-ip>${NC}"
echo ""
echo -e "  ${GREEN}Then as ${NEW_USER} (not root) — start containers:${NC}"
echo -e "     ${GREEN}cd /opt/stacks/caddy && docker compose up -d${NC}"
echo -e "     ${GREEN}cd /opt/stacks/uptime-kuma && docker compose up -d${NC}"
echo -e "     ${GREEN}cd /opt/stacks/dozzle && docker compose up -d${NC}"
echo -e "     ${GREEN}cd /opt/stacks/dockge && docker compose up -d${NC}"
echo ""
echo -e "  ${GREEN}Later (as ${NEW_USER}):${NC} git pull in ${REPO_ROOT}, then ${GREEN}sudo update-stacks${NC}"
echo -e "  ${YELLOW}Root SSH is disabled after this script — use ${NEW_USER} from now on.${NC}"
if [[ ! -d "${STACKS_SRC}" ]]; then
  echo -e "  ${RED}Stacks missing:${NC} clone repo, create setup.env, run: sudo bash scripts/install-stacks.sh"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"