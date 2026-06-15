#!/bin/bash
# bento — system hardening
#
# Adapted from https://github.com/felipefontoura/ubinkaze/blob/stable/install.sh
# Original by Felipe Fontoura, based on https://gist.github.com/rameerez/238927b78f9108a71a77aed34208de11
#
# Differences from upstream ubinkaze:
#   - Distro check relaxed: any apt-get-capable system passes (Ubuntu, Debian,
#     Mint, Pop!_OS, etc.) instead of the strict upstream Ubuntu LTS check.
#   - Drops a reboot sentinel at /var/lib/bento/reboot-required so the
#     parent install.sh can detect and prompt cleanly.
#   - /etc/docker/daemon.json omits "userland-proxy": false. Upstream sets it
#     for a small RAM/security gain, but on single-public-IP hosts (Hetzner,
#     DO, etc.) it breaks hairpin NAT: a container that resolves its own
#     public hostname egresses to the public iface and never loops back, so
#     any agent calling its sibling stack via the public URL hangs. Docker's
#     default (true) keeps docker-proxy alive per published port and DNATs
#     correctly. See bento#31.

set -euo pipefail
IFS=$'\n\t'

# --- Constants ---
# Prefixed with BENTO_HARDENING_* so they can't collide with anything
# the user already exported. MIN_DISK_GB used to be 20 — that bounced
# users on Hetzner CX11 (25 GB) when the docker image cache was warm.
# 5 GB is enough to install all bento dependencies; the optional apps
# inflate it from there.
BENTO_HARDENING_MIN_RAM_MB="${BENTO_HARDENING_MIN_RAM_MB:-1024}"
BENTO_HARDENING_MIN_DISK_GB="${BENTO_HARDENING_MIN_DISK_GB:-5}"
BENTO_REBOOT_SENTINEL=/var/lib/bento/reboot-required

# --- Aesthetics ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
ICON='\xF0\x9F\x8D\xB1'   # 🍱 bento box (replacement for ubinkaze's 🌀)
NC='\033[0m'

# --- Functions ---
print_message() {
  local color=$1
  local message=$2
  echo -e "${color}${ICON} ${message}${NC}"
}

print_error() {
  print_message "${RED}" "ERROR: $1"
}

print_warning() {
  print_message "${YELLOW}" "WARNING: $1"
}

print_success() {
  print_message "${GREEN}" "SUCCESS: $1"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
  fi
}

check_distro() {
  if ! command -v apt-get >/dev/null 2>&1; then
    print_error "bento hardening requires an apt-based distro (Ubuntu, Debian, Mint, Pop!_OS, etc.)"
    exit 1
  fi

  local distro="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    distro=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
  fi
  print_message "${GREEN}" "Detected: $distro"
}

check_resources() {
  local total_ram_mb total_disk_gb
  total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  total_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

  if ((total_ram_mb < BENTO_HARDENING_MIN_RAM_MB)); then
    print_error "Insufficient RAM. Required: ${BENTO_HARDENING_MIN_RAM_MB}MB, Found: ${total_ram_mb}MB"
    exit 1
  fi

  if ((total_disk_gb < BENTO_HARDENING_MIN_DISK_GB)); then
    print_error "Insufficient disk space. Required: ${BENTO_HARDENING_MIN_DISK_GB}GB, Found: ${total_disk_gb}GB"
    exit 1
  fi
}

verify_security_settings() {
  local failed=0

  # Check kernel parameters
  local params=(
    "kernel.unprivileged_bpf_disabled=1"
    "net.ipv4.conf.all.log_martians=0"
    "net.ipv4.ip_forward=1"
    "fs.protected_hardlinks=1"
    "fs.protected_symlinks=1"
  )

  for param in "${params[@]}"; do
    local name=${param%=*}
    local expected=${param#*=}
    local actual
    actual=$(sysctl -n "$name" 2>/dev/null || echo "NOT_FOUND")

    if [[ "$actual" != "$expected" ]]; then
      print_error "Kernel parameter $name = $actual (expected $expected)"
      failed=1
    fi
  done

  # Check Docker cgroup driver.
  #
  # The previous check piped `docker info` to `grep -q "Cgroup Driver: systemd"`
  # — exact-string match against `docker info`'s human output. On Ubuntu 26.04
  # + Docker 29.x + cgroup v2 unified the formatting shifted enough that the
  # grep failed even when the daemon was configured correctly via
  # /etc/docker/daemon.json's "exec-opts": ["native.cgroupdriver=systemd"].
  # Use the format-string accessor instead — it returns the literal value the
  # daemon reports for CgroupDriver, no parsing.
  local cgroup_driver
  cgroup_driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null)
  if [[ "$cgroup_driver" != "systemd" ]]; then
    print_error "Docker cgroup driver is '$cgroup_driver' (expected 'systemd')"
    failed=1
  fi

  if [[ "$(stat -c %a /var/run/docker.sock)" != "660" ]]; then
    print_error "Docker socket has incorrect permissions"
    failed=1
  fi

  # Check services
  local services=(
    "docker"
    "fail2ban"
    "ufw"
    "auditd"
    "chrony"
  )

  for service in "${services[@]}"; do
    if ! systemctl is-active --quiet "$service"; then
      print_error "Service $service is not running"
      failed=1
    fi
  done

  # Check AIDE database
  if [ ! -f /var/lib/aide/aide.db ]; then
    print_error "AIDE database not initialized"
    failed=1
  fi

  # Check Chrony sync. Run once, distinguish "binary missing" from
  # "binary works but no reference selected yet". The previous &>/dev/null
  # form treated both as "not syncing" — but a missing chronyc is a
  # broken install (much more serious than a slow first sync).
  if ! command -v chronyc >/dev/null 2>&1; then
    print_error "chronyc binary missing — Chrony apt install did not land."
    failed=1
  else
    chrony_out=$(chronyc tracking 2>&1) || true
    if ! grep -q "Reference ID" <<< "$chrony_out"; then
      print_error "Chrony is not syncing time. chronyc said:"
      echo "$chrony_out" | sed 's/^/    /'
      failed=1
    fi
  fi

  # Additional security checks
  if ! ufw status | grep -q "Status: active"; then
    print_error "UFW firewall is not active"
    failed=1
  fi

  if ! apparmor_status | grep -q "apparmor module is loaded."; then
    print_error "AppArmor is not loaded"
    failed=1
  fi

  return $failed
}

handle_error() {
  local line_number=$1
  print_error "Script failed on line ${line_number}"
  print_error "Please check the logs above for more information"
  exit 1
}

# Set up error handling
trap 'handle_error ${LINENO}' ERR

# --- Pre-flight Checks ---
print_message "${YELLOW}" "Performing pre-flight checks..."
check_root
check_distro
check_resources

# --- System Updates ---
print_message "${YELLOW}" "Updating system packages..."
NEEDRESTART_MODE=a apt-get update
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# --- Essential Packages ---
print_message "${YELLOW}" "Installing essential packages..."
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ufw \
  fail2ban \
  curl \
  wget \
  gnupg \
  lsb-release \
  ca-certificates \
  apt-transport-https \
  software-properties-common \
  sysstat \
  auditd \
  audispd-plugins \
  unattended-upgrades \
  acl \
  apparmor \
  apparmor-utils \
  aide \
  rkhunter \
  logwatch \
  git \
  python3-pyinotify

# --- Time Synchronization ---
print_message "${YELLOW}" "Configuring time synchronization..."
systemctl stop systemd-timesyncd || true
systemctl disable systemd-timesyncd || true
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get remove -y systemd-timesyncd || true
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
if systemctl -q is-enabled systemd-timesyncd 2>/dev/null; then
  systemctl disable systemd-timesyncd
  systemctl stop systemd-timesyncd
fi
systemctl enable chrony.service || true # use .service to avoid alias issues
systemctl start chrony.service

# --- System Hardening ---
print_message "${YELLOW}" "Configuring system security..."

# Configure AppArmor
systemctl enable apparmor
systemctl start apparmor

# Initialize AIDE
aide --config=/etc/aide/aide.conf --init
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# Configure kernel parameters
cat <<EOF >/etc/sysctl.d/99-security.conf
# Network security
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Docker needs IPv4 forwarding
net.ipv4.ip_forward = 1

# System limits
fs.file-max = 1048576
kernel.pid_max = 65536
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_tw_reuse = 1
vm.max_map_count = 262144
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2

# File system hardening
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0

# Additional network hardening
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.log_martians = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
EOF

sysctl -p /etc/sysctl.d/99-security.conf
sysctl --system

# Configure system limits
cat <<EOF >/etc/security/limits.d/docker.conf
*       soft    nproc     10000
*       hard    nproc     10000
*       soft    nofile    1048576
*       hard    nofile    1048576
*       soft    core      0
*       hard    core      0
*       soft    stack     8192
*       hard    stack     8192
EOF

# --- Docker Installation ---
print_message "${YELLOW}" "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# --- Docker Configuration ---
print_message "${YELLOW}" "Configuring Docker..."
mkdir -p /etc/docker
cat <<EOF >/etc/docker/daemon.json
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "icc": true,
    "live-restore": false,
    "no-new-privileges": true,
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 64000,
            "Soft": 64000
        }
    },
    "features": {
        "buildkit": true
    },
    "experimental": false,
    "default-runtime": "runc",
    "storage-driver": "overlay2",
    "metrics-addr": "127.0.0.1:9323",
    "builder": {
        "gc": {
            "enabled": true,
            "defaultKeepStorage": "20GB"
        }
    }
}
EOF

# After Docker daemon.json configuration. Capture the full docker info
# output once so we can both detect daemon failure AND grep for the
# config keys without running the command twice (and without piping
# blind — if docker dies between the two calls the second one prints
# nothing and the operator never knows).
print_message "${YELLOW}" "Testing Docker configuration..."
docker_info_out=$(docker info 2>&1) || {
  print_error "Docker failed to start. docker info said:"
  echo "$docker_info_out" | sed 's/^/    /'
  print_error "Daemon logs:"
  journalctl -u docker.service --no-pager | tail -n 50
  exit 1
}

systemctl enable docker
systemctl restart docker || {
  print_error "Docker failed to start. Logs:"
  journalctl -u docker.service --no-pager | tail -n 50
  exit 1
}

# Verify Docker configuration. Re-capture after the restart so we read
# the post-restart config rather than the pre-restart one.
print_message "${YELLOW}" "Verifying Docker configuration..."
docker_info_out=$(docker info 2>&1) || {
  print_error "docker info failed after restart:"
  echo "$docker_info_out" | sed 's/^/    /'
  exit 1
}
echo "$docker_info_out" | grep -E "Cgroup Driver|Storage Driver|Logging Driver" || \
  print_message "${YELLOW}" "(no Cgroup/Storage/Logging Driver lines in docker info — daemon may be partially configured)"

# --- Firewall Configuration ---
print_message "${YELLOW}" "Configuring firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# Rate-limit SSH at the OS level (fail2ban handles repeated offenders
# at a longer window; ufw limit drops brute-force attempts at 6 conns/30s).
ufw limit ssh
ufw allow http
ufw allow https
# ICMP (echo-request, destination-unreachable, time-exceeded,
# parameter-problem) is already accepted by /etc/ufw/before.rules on
# stock Ubuntu/Debian, so we do NOT add a user rule here. UFW 0.36.2+
# rejects the legacy `ufw allow proto icmp` syntax altogether
# ("Need 'to' or 'from' clause" / "Unsupported protocol 'icmp'"), and
# the kernel sysctl net.ipv4.icmp_echo_ignore_broadcasts=1 (set above)
# still drops broadcast pings.
ufw --force enable

# --- fail2ban Configuration ---
print_message "${YELLOW}" "Configuring fail2ban..."

cat <<EOF >/etc/fail2ban/filter.d/docker.conf
[Definition]
failregex = failed login attempt from <HOST>
ignoreregex =
EOF

cat <<EOF >/etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 10
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 10
bantime = 3600

[docker]
enabled = true
filter = docker
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
EOF

# --- Enable and Start Services ---
print_message "${YELLOW}" "Enabling services..."
systemctl enable docker fail2ban auditd chrony
systemctl restart docker fail2ban auditd chrony

# --- Verify Setup ---
print_message "${YELLOW}" "Verifying security settings..."
if verify_security_settings; then
  print_success "Security verification passed"
else
  print_warning "Some security checks failed. Please review the warnings above."
fi

# Add logging configuration
print_message "${YELLOW}" "Configuring system logging..."
cat <<EOF >/etc/logrotate.d/docker-logs
/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=100M
    missingok
    delaycompress
    copytruncate
}
EOF

# Automated cleanup to prevent residual files
print_message "${YELLOW}" "Setting up maintenance tasks..."
cat <<EOF >/etc/cron.daily/docker-cleanup
#!/bin/bash
docker system prune -af --volumes
docker builder prune -af --keep-storage=20GB
EOF
chmod +x /etc/cron.daily/docker-cleanup

# Configure auditd
#
# CIS Docker Benchmark says to audit the daemon's configuration surface, NOT
# the on-disk storage tree. Watching `/var/lib/docker` with `-w` recursively
# enrolls every file in every container layer (millions on a populous host) —
# each `docker pull`, `service update`, `container start` then fires syscall
# events the kernel must serialize through auditd before the syscall can
# return. Observed in production 2026-06-11 on a CX22: auditd pinned at 80%
# CPU sustained, `docker pull` stuck "Preparing" for 15 minutes, and the
# audit backlog spilling enough events to log "lost 162" entries. The line
# was removed and image pulls + service starts immediately recovered.
#
# Keep the watches on dockerd / docker binary / service / daemon.json /
# etc/default — those rarely change and capture the real configuration
# tampering you'd want to know about.
cat <<EOF >/etc/audit/rules.d/audit.rules
# Docker daemon configuration
-w /usr/bin/dockerd -k docker
-w /etc/docker -k docker
-w /usr/lib/systemd/system/docker.service -k docker
-w /etc/default/docker -k docker
-w /etc/docker/daemon.json -k docker
-w /usr/bin/docker -k docker-bin
EOF

# Reload audit rules
auditctl -R /etc/audit/rules.d/audit.rules

# Configure unattended-upgrades for automated security updates.
#
# Automatic-Reboot is "true" with a 04:00 window because a kernel CVE
# patched but not applied is the single biggest residual exposure on a
# small unattended VPS — auto-reboot turns "downloaded" into "running"
# without depending on the operator remembering. Off-peak 04:00 caps the
# worst case at "users get bumped from an SSH session in the middle of
# the night".
print_message "${YELLOW}" "Configuring automatic updates..."
cat <<EOF >/etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# --- Final Cleanup ---
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
apt-get clean

# Only signal "reboot needed" to install.sh when Ubuntu's own apt
# machinery decided one is required — i.e. a kernel, glibc, or openssl
# upgrade landed in this run that cannot be applied without rebooting.
# Service restarts that DO apply at runtime (UFW, fail2ban, AppArmor,
# Docker daemon.json, sysctl) handled themselves via systemctl in the
# blocks above. If `/var/run/reboot-required` is absent, the running
# kernel and libraries already match what's on disk and a reboot would
# just be ceremony.
mkdir -p "$(dirname "$BENTO_REBOOT_SENTINEL")"
if [ -f /var/run/reboot-required ]; then
    date -Iseconds > "$BENTO_REBOOT_SENTINEL"
    print_message "${YELLOW}" "Kernel or core lib was upgraded — reboot will be needed."
else
    # Make sure no stale sentinel from a previous failed run survives.
    rm -f "$BENTO_REBOOT_SENTINEL"
    print_message "${GREEN}" "No kernel/lib upgrade pending — reboot can be skipped."
fi

print_success "Setup complete! System hardening successful."
print_message "${YELLOW}" "Important next steps:"
if [ -f "$BENTO_REBOOT_SENTINEL" ]; then
    print_message "${YELLOW}" "1. REBOOT THE SYSTEM to apply the new kernel/libs"
    print_message "${YELLOW}" "2. After reboot, re-run bento to continue with infra setup"
else
    print_message "${YELLOW}" "1. Continue with Step 2 — no reboot needed this time"
fi

# Additional verification info
print_message "${GREEN}" "System Information:"
echo "Docker Version: $(docker --version)"
echo "Kernel Version: $(uname -r)"
echo "AppArmor Status: $(aa-status --enabled && echo 'Enabled' || echo 'Disabled')"
echo "UFW Status: $(ufw status | grep Status)"
echo "fail2ban Status: $(fail2ban-client status | grep "Number of jail:")"
