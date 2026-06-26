#!/usr/bin/env bash
# RADS-WEB Main Installer
# Rocky Active Directory Server — Web Edition
# Requires: Rocky Linux 10.0+, run as root

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"

SRC_BASE="/root/RADS_WEBInstaller"
INSTALL_BASE="/opt/rads-web"
LOGDIR="/var/log/rads-installer"
mkdir -p "$LOGDIR"

# =============================================================
# OUTPUT HELPERS
# =============================================================
step_ok()   { echo -e "  [${GREEN}✓${TEXTRESET}] $*"; }
step_fail() { echo -e "  [${RED}✗${TEXTRESET}] $*"; }
step_info() { echo -e "  [${YELLOW}→${TEXTRESET}] $*"; }
section()   { echo ""; echo -e "${CYAN}── $* ──${TEXTRESET}"; }

# =============================================================
# VALIDATION HELPERS
# =============================================================
validate_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; }
validate_ip()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
validate_fqdn() { [[ "$1" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; }
check_hostname_in_domain() {
  local fqdn="$1" hostname="${1%%.*}" domain="${1#*.}"
  [[ ! "$domain" =~ (^|\.)"$hostname"(\.|$) ]]
}
ip_to_int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }
int_to_ip() { local i=$1; printf "%d.%d.%d.%d" $(( (i>>24)&255 )) $(( (i>>16)&255 )) $(( (i>>8)&255 )) $(( i&255 )); }

# =============================================================
# STEP 1 — ROOT + OS CHECK
# =============================================================
check_root_and_os() {
  section "System Checks"

  if [[ $EUID -eq 0 ]]; then
    step_ok "Running as root"
  else
    step_fail "Must be run as root"
    exit 1
  fi

  local OSVER_RAW OSVER_MAJOR OSVER_MINOR
  if [[ -f /etc/os-release ]]; then
    OSVER_RAW=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null)
  elif [[ -f /etc/redhat-release ]]; then
    OSVER_RAW=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
  fi

  OSVER_MAJOR=$(echo "$OSVER_RAW" | awk -F. '{print $1}')
  OSVER_MINOR=$(echo "$OSVER_RAW" | awk -F. '{print ($2==""?0:$2)}')

  if (( OSVER_MAJOR >= 10 )); then
    step_ok "OS check passed — Rocky Linux ${OSVER_MAJOR}.${OSVER_MINOR}"
  else
    step_fail "Rocky Linux 10.0+ required (detected: ${OSVER_MAJOR:-unknown}.${OSVER_MINOR:-x})"
    exit 1
  fi
  sleep 1
}

# =============================================================
# STEP 2 — SELINUX
# =============================================================
check_and_enable_selinux() {
  section "SELinux"
  local status; status=$(getenforce 2>/dev/null || echo "Unknown")

  if [[ "$status" == "Enforcing" ]]; then
    step_ok "SELinux is Enforcing"
  else
    step_info "SELinux is ${status} — enabling..."
    sed -i 's/SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config
    sed -i 's/SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
    setenforce 1 2>/dev/null || true
    [[ "$(getenforce)" == "Enforcing" ]] && step_ok "SELinux enabled (Enforcing)" \
      || step_fail "SELinux could not be set to Enforcing — check config manually"
  fi
  sleep 1
}

# =============================================================
# STEP 3 — CHECK FOR EXISTING SAMBA
# =============================================================
check_samba_not_running() {
  section "Existing Samba Check"
  if systemctl is-active --quiet smb 2>/dev/null || systemctl is-active --quiet samba 2>/dev/null; then
    dialog --backtitle "RADS-WEB Installer" --title "Samba Already Running" \
      --msgbox "Samba is already running on this system.\n\nIf you want to install a fresh AD, start with a clean OS install.\n\nIf Samba is already configured, you can install just the Web UI by running:\n  bash ${SRC_BASE}/install-webui-only.sh" \
      12 70
    exit 1
  fi
  step_ok "No existing Samba service detected"
  sleep 1
}

# =============================================================
# STEP 4 — NETWORK INTERFACE DETECTION
# =============================================================
detect_active_interface() {
  section "Network Interface"
  step_info "Detecting active network interface..."

  # Ensure NetworkManager is running
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
    step_info "NetworkManager not running — starting it..."
    systemctl enable --now NetworkManager >/dev/null 2>&1
    sleep 3
    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
      dialog --title "Interface Error" --msgbox "NetworkManager could not be started.\nCheck your network configuration." 7 55
      exit 1
    fi
    step_ok "NetworkManager started"
  fi

  INTERFACE=$(nmcli -t -f DEVICE,TYPE,STATE device | grep "ethernet:connected" | cut -d: -f1 | head -n1)
  [[ -z "$INTERFACE" ]] && INTERFACE=$(ip -o -4 addr show up | grep -v ' lo ' | awk '{print $2}' | head -n1)

  if [[ -n "$INTERFACE" ]]; then
    CONNECTION=$(nmcli -t -f NAME,DEVICE connection show | grep ":$INTERFACE" | cut -d: -f1)
  fi

  if [[ -z "$INTERFACE" || -z "$CONNECTION" ]]; then
    dialog --title "Interface Error" --msgbox "No active network interface found.\nCheck your network configuration." 7 55
    exit 1
  fi

  step_ok "Interface: ${INTERFACE} (${CONNECTION})"
  export INTERFACE CONNECTION
  sleep 1
}

# =============================================================
# STEP 5 — STATIC IP
# =============================================================
prompt_static_ip_if_dhcp() {
  section "IP Configuration"
  IP_METHOD=$(nmcli -g ipv4.method connection show "$CONNECTION" | tr -d '' | xargs)

  if [[ "$IP_METHOD" == "manual" ]]; then
    step_ok "Static IP already configured on ${INTERFACE}"
    return
  fi

  if [[ "$IP_METHOD" == "auto" ]]; then
    step_info "DHCP detected on ${INTERFACE} — static IP required for AD server"
    while true; do
      while true; do
        IPADDR=$(dialog --backtitle "Network Setup" --title "Static IP Required" \
          --inputbox "DHCP detected on '${INTERFACE}'\n\nEnter static IP in CIDR format (e.g., 192.168.1.100/24):" \
          9 75 3>&1 1>&2 2>&3)
        validate_cidr "$IPADDR" && break || dialog --msgbox "Invalid CIDR format. Try again." 6 40
      done
      while true; do
        GW=$(dialog --backtitle "Network Setup" --title "Gateway" \
          --inputbox "Enter default gateway:" 8 60 3>&1 1>&2 2>&3)
        validate_ip "$GW" && break || dialog --msgbox "Invalid IP. Try again." 6 40
      done
      while true; do
        DNSSERVER=$(dialog --backtitle "Network Setup" --title "DNS Server" \
          --inputbox "Enter upstream DNS server IP (will be replaced by this DC after provisioning):" 9 70 3>&1 1>&2 2>&3)
        validate_ip "$DNSSERVER" && break || dialog --msgbox "Invalid IP. Try again." 6 40
      done
      while true; do
        HOSTNAME=$(dialog --backtitle "Network Setup" --title "FQDN" \
          --inputbox "Enter FQDN for this server (e.g., dc1.corp.local):" 8 70 3>&1 1>&2 2>&3)
        if validate_fqdn "$HOSTNAME" && check_hostname_in_domain "$HOSTNAME"; then break
        else dialog --msgbox "Invalid FQDN. Must be host.domain.tld format. Try again." 7 60; fi
      done
      while true; do
        DNSSEARCH=$(dialog --backtitle "Network Setup" --title "DNS Search Domain" \
          --inputbox "Enter DNS search domain (e.g., corp.local):" 8 60 3>&1 1>&2 2>&3)
        [[ -n "$DNSSEARCH" ]] && break || dialog --msgbox "Search domain cannot be blank." 6 40
      done

      dialog --backtitle "Network Setup" --title "Confirm Settings" \
        --yesno "Apply these settings?\n\nInterface: ${INTERFACE}\nIP: ${IPADDR}\nGateway: ${GW}\nFQDN: ${HOSTNAME}\nDNS: ${DNSSERVER}\nSearch: ${DNSSEARCH}" \
        13 65

      if [[ $? -eq 0 ]]; then
        nmcli con mod "$CONNECTION" ipv4.addresses "$IPADDR" ipv4.gateway "$GW" \
          ipv4.method manual ipv4.dns "$DNSSERVER" ipv4.dns-search "$DNSSEARCH"
        hostnamectl set-hostname "$HOSTNAME"

        PROFILE="/root/.bash_profile"
        if ! grep -q "RADS_WEBInstall" "$PROFILE" 2>/dev/null; then
          cat >> "$PROFILE" << 'BASHEOF'

## RADS-WEB Installer — auto-resume after reboot ##
if [[ $- == *i* ]]; then
  /root/RADS_WEBInstaller/RADS_WEBInstall.sh
fi
BASHEOF
        fi

        dialog --title "Reboot Required" \
          --msgbox "Network configured. System will reboot.\n\nReconnect at: ${IPADDR%%/*}" 7 60
        reboot
      fi
    done
  fi
}

# =============================================================
# STEP 6 — HOSTNAME
# =============================================================
validate_and_set_hostname() {
  section "Hostname"
  local current; current=$(hostname)

  if [[ "$current" == "localhost.localdomain" ]]; then
    while true; do
      NEW_HOSTNAME=$(dialog --backtitle "Hostname Setup" --title "Set FQDN" \
        --inputbox "Current hostname is '${current}'.\nEnter FQDN (e.g., dc1.corp.local):" \
        8 65 3>&1 1>&2 2>&3)
      if validate_fqdn "$NEW_HOSTNAME" && check_hostname_in_domain "$NEW_HOSTNAME"; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        step_ok "Hostname set to: ${NEW_HOSTNAME}"
        break
      else
        dialog --msgbox "Invalid FQDN — must be host.domain.tld format. Try again." 6 60
      fi
    done
  else
    step_ok "Hostname: ${current}"
  fi
  sleep 1
}

# =============================================================
# STEP 7 — INTERNET CHECK
# =============================================================
check_internet_connectivity() {
  section "Internet Connectivity"
  local dns_ok=0 ip_ok=0

  ping -c 1 -W 2 8.8.8.8 &>/dev/null && ip_ok=1
  ping -c 1 -W 2 google.com &>/dev/null && dns_ok=1

  [[ $ip_ok -eq 1 ]] && step_ok "Direct IP reachable (8.8.8.8)" || step_fail "Cannot reach 8.8.8.8"
  [[ $dns_ok -eq 1 ]] && step_ok "DNS resolution working" || step_fail "DNS resolution failed"

  if [[ $ip_ok -eq 0 || $dns_ok -eq 0 ]]; then
    dialog --title "Network Warning" \
      --yesno "Internet connectivity issues detected.\n\nContinue anyway?" 8 55
    [[ $? -ne 0 ]] && exit 1
  fi
  sleep 1
}

# =============================================================
# STEP 8 — DOMAIN PROVISIONING QUESTIONS (upfront)
# =============================================================
gather_domain_config() {
  section "Active Directory Configuration"
  step_info "Collecting domain provisioning information..."
  echo ""
  sleep 1

  local FQDN; FQDN=$(hostname)
  local DETECTED_DOMAIN; DETECTED_DOMAIN=$(echo "$FQDN" | cut -d. -f2- | tr '[:lower:]' '[:upper:]')
  local DETECTED_REALM; DETECTED_REALM=$(echo "$FQDN" | cut -d. -f2-)

  while true; do
    AD_REALM=$(dialog --backtitle "AD Configuration" --title "AD Realm" \
      --inputbox "Enter the AD Realm/Domain (e.g., CORP.LOCAL):" 8 65 "${DETECTED_REALM}" \
      3>&1 1>&2 2>&3)
    [[ -n "$AD_REALM" ]] && break
    dialog --msgbox "Realm cannot be blank." 6 40
  done

  AD_DOMAIN=$(echo "$AD_REALM" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')

  while true; do
    AD_ADMIN_PASS=$(dialog --backtitle "AD Configuration" --title "Administrator Password" \
      --passwordbox "Enter the Samba Administrator password (min 8 chars, complexity required):" 9 65 \
      3>&1 1>&2 2>&3)
    local PASS2
    PASS2=$(dialog --backtitle "AD Configuration" --title "Confirm Password" \
      --passwordbox "Confirm the Administrator password:" 9 65 3>&1 1>&2 2>&3)
    if [[ "$AD_ADMIN_PASS" != "$PASS2" ]]; then
      dialog --msgbox "Passwords do not match. Try again." 6 40
      continue
    fi
    [[ ${#AD_ADMIN_PASS} -ge 8 ]] && break
    dialog --msgbox "Password must be at least 8 characters." 6 50
  done

  while true; do
    NTP_SERVER=$(dialog --backtitle "AD Configuration" --title "NTP Server" \
      --inputbox "Enter an NTP server IP or FQDN (or press Enter for pool.ntp.org):" 8 70 "pool.ntp.org" \
      3>&1 1>&2 2>&3)
    [[ -n "$NTP_SERVER" ]] && break
    NTP_SERVER="pool.ntp.org"
    break
  done

  # Confirmation
  dialog --backtitle "AD Configuration" --title "Confirm Domain Settings" \
    --yesno "Provision Active Directory with these settings?\n\nRealm:     ${AD_REALM}\nDomain:    ${AD_DOMAIN}\nDC FQDN:   ${FQDN}\nNTP:       ${NTP_SERVER}" \
    12 65
  [[ $? -ne 0 ]] && gather_domain_config

  export AD_REALM AD_DOMAIN AD_ADMIN_PASS NTP_SERVER
  step_ok "Domain config: ${AD_REALM} (${AD_DOMAIN})"
  sleep 1
}

# =============================================================
# STEP 9 — REPOS
# =============================================================
enable_repos() {
  section "Repository Setup"
  local log="$LOGDIR/repo-setup.log"; : > "$log"

  step_info "Enabling EPEL, CRB, and Devel repositories..."
  dnf -y install epel-release --setopt=install_weak_deps=False --color=never >>"$log" 2>&1
  dnf -y install dnf-plugins-core --setopt=install_weak_deps=False --color=never >>"$log" 2>&1 || true

  # CRB — needed for many build deps
  dnf config-manager --set-enabled crb --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable crb >>"$log" 2>&1 || true

  # Devel — required for python3-setproctitle, samba-dc, samba-common-tools
  # and python3-talloc-devel (Samba build deps not in CRB or base)
  dnf config-manager --set-enabled devel --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable devel >>"$log" 2>&1 || true

  dnf -y makecache --refresh --color=never >>"$log" 2>&1

  step_ok "EPEL + CRB + Devel enabled"
  sleep 1
}

# =============================================================
# STEP 10 — SYSTEM UPGRADE
# =============================================================
run_system_upgrade() {
  section "System Upgrade"
  local log="$LOGDIR/system-upgrade.log"; : > "$log"

  step_info "Running dnf upgrade (this may take a while)..."

  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"
  mapfile -t PACKAGE_LIST < <(dnf -q repoquery --upgrades --qf '%{name}' 2>/dev/null | sort -u)
  local TOTAL=${#PACKAGE_LIST[@]}

  if [[ $TOTAL -eq 0 ]]; then
    step_ok "System already up to date"
    rm -f "$PIPE"; return
  fi

  clear
  dialog --backtitle "RADS-WEB Installer" --title "System Upgrade" \
    --gauge "Starting system upgrade..." 10 70 0 < "$PIPE" &

  local COUNT=0
  {
    for PKG in "${PACKAGE_LIST[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Upgrading: $PKG (${COUNT}/${TOTAL})"; echo "XXX"
      dnf -y -q upgrade --color=never --best --allowerasing "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Upgrade complete."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"

  clear; section "System Upgrade"
  step_ok "System packages upgraded (${TOTAL} packages)"
  sleep 1
}

# =============================================================
# STEP 11 — BASE PACKAGES
# =============================================================
install_base_packages() {
  section "Base Packages"
  local log="$LOGDIR/packages.log"; : > "$log"

  local PKGS=(
    gcc make tar bzip2-devel openssl-devel libffi-devel zlib-devel
    rpmbuild rpm-build mock createrepo_c
    krb5-workstation openldap-clients bind-utils
    chrony net-tools dmidecode ipcalc
    ntsysv wget curl rsync
    nano htop iotop iptraf-ng mc
    fail2ban cockpit cockpit-storaged cockpit-files
    httpd mod_ssl mod_proxy_html
    python3 python3-pip pam-devel python3-devel
    policycoreutils-python-utils
    acl zip util-linux expect sshpass
    dnf-automatic dnf-plugins-core
    at bc tuned
  )

  local TOTAL=${#PKGS[@]} COUNT=0
  local PIPE; PIPE=$(mktemp -u); mkfifo "$PIPE"

  clear
  dialog --backtitle "RADS-WEB Installer" --title "Installing Base Packages" \
    --gauge "Preparing..." 10 70 0 < "$PIPE" &

  {
    for PKG in "${PKGS[@]}"; do
      ((COUNT++))
      local PCT=$(( COUNT * 100 / TOTAL ))
      echo "$PCT"; echo "XXX"; echo "Installing: $PKG"; echo "XXX"
      dnf -y -q install --color=never --setopt=tsflags=nodocs "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Base packages installed."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"

  clear; section "Base Packages"
  step_ok "Base packages installed"
  sleep 1
}

# =============================================================
# STEP 12 — VM GUEST TOOLS
# =============================================================
vm_detection() {
  section "VM Guest Tools"
  local kvm_hw vmware_hw
  kvm_hw=$(dmidecode 2>/dev/null | grep -i -e manufacturer -e product -e vendor | grep KVM | cut -c16- || true)
  vmware_hw=$(dmidecode 2>/dev/null | grep -i "VMware, Inc." | head -1 || true)

  if [[ "$kvm_hw" == "KVM" ]]; then
    step_info "KVM detected — installing qemu-guest-agent..."
    dnf -y install qemu-guest-agent >/dev/null 2>&1
    systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true
    step_ok "qemu-guest-agent installed"
  elif [[ -n "$vmware_hw" ]]; then
    step_info "VMware detected — installing open-vm-tools..."
    dnf -y install open-vm-tools >/dev/null 2>&1
    systemctl enable --now vmtoolsd >/dev/null 2>&1 || true
    step_ok "open-vm-tools installed"
  else
    step_ok "Physical or unsupported hypervisor — no guest tools needed"
  fi
  sleep 1
}

# =============================================================
# STEP 13 — NTP / CHRONY
# =============================================================
configure_ntp() {
  section "NTP / Chrony"
  local log="$LOGDIR/ntp.log"; : > "$log"

  cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
  sed -i '/^\(server\|pool\)[[:space:]]/d' /etc/chrony.conf
  echo "server ${NTP_SERVER} iburst" >> /etc/chrony.conf
  # AD DC should be authoritative for local clients
  local MY_IP; MY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  local MY_NET; MY_NET=$(ip -o -4 addr show "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1)
  [[ -n "$MY_NET" ]] && echo "allow ${MY_NET%/*}/24" >> /etc/chrony.conf
  echo "local stratum 10" >> /etc/chrony.conf

  systemctl enable --now chronyd >>"$log" 2>&1
  systemctl restart chronyd >>"$log" 2>&1
  sleep 5

  step_ok "NTP configured (upstream: ${NTP_SERVER})"
  sleep 1
}

# =============================================================
# STEP 14 — FIREWALL
# =============================================================
configure_firewall() {
  section "Firewall"
  # Samba AD ports
  firewall-cmd --permanent --add-service=samba       >/dev/null 2>&1
  firewall-cmd --permanent --add-service=samba-dc    >/dev/null 2>&1
  firewall-cmd --permanent --add-service=dns         >/dev/null 2>&1
  firewall-cmd --permanent --add-service=kerberos    >/dev/null 2>&1
  firewall-cmd --permanent --add-service=ntp         >/dev/null 2>&1
  firewall-cmd --permanent --add-service=http        >/dev/null 2>&1
  firewall-cmd --permanent --add-service=https       >/dev/null 2>&1
  firewall-cmd --permanent --add-service=cockpit     >/dev/null 2>&1
  # LDAP/LDAPS
  firewall-cmd --permanent --add-port=389/tcp        >/dev/null 2>&1
  firewall-cmd --permanent --add-port=389/udp        >/dev/null 2>&1
  firewall-cmd --permanent --add-port=636/tcp        >/dev/null 2>&1
  firewall-cmd --permanent --add-port=3268/tcp       >/dev/null 2>&1
  firewall-cmd --permanent --add-port=3269/tcp       >/dev/null 2>&1
  # RPC
  firewall-cmd --permanent --add-port=49152-65535/tcp >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1
  systemctl restart firewalld >/dev/null 2>&1

  step_ok "Firewall rules applied (Samba AD + DNS + Kerberos + HTTP + Cockpit)"
  sleep 1
}

# =============================================================
# STEP 15 — SELINUX FOR SAMBA
# =============================================================
configure_selinux_samba() {
  section "SELinux — Samba AD"
  local log="$LOGDIR/selinux-samba.log"; : > "$log"

  setsebool -P samba_enable_home_dirs on  >>"$log" 2>&1 || true
  setsebool -P samba_export_all_rw on     >>"$log" 2>&1 || true
  setsebool -P httpd_can_network_connect on >>"$log" 2>&1

  step_ok "SELinux booleans set for Samba + Apache proxy"
  sleep 1
}

# =============================================================
# STEP 16 — BUILD SAMBA FROM SRPM (Rocky 10)
# =============================================================
build_samba_from_srpm() {
  section "Building Samba from SRPM (Rocky 10)"
  local log="$LOGDIR/samba-build.log"; : > "$log"

  local MOCK_CFG="rocky-10-x86_64"
  local MOCK_RESULT="/var/lib/mock/${MOCK_CFG}/result"

  # ── Check for cached RPMs from a prior build ─────────────────────────────
  local CACHED_RPMS=()
  for rpm in "${MOCK_RESULT}"/*.rpm; do
    [[ "$rpm" == *src.rpm ]]    && continue
    [[ "$rpm" == *debuginfo* ]] && continue
    [[ "$rpm" == *debugsource* ]] && continue
    [[ -f "$rpm" ]] && CACHED_RPMS+=("$rpm")
  done

  if [[ ${#CACHED_RPMS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────────┐${TEXTRESET}"
    echo -e "${CYAN}  │  Found ${#CACHED_RPMS[@]} pre-built RPMs in mock result dir               │${TEXTRESET}"
    echo -e "${CYAN}  └─────────────────────────────────────────────────────────────┘${TEXTRESET}"
    step_info "Mock result dir already contains ${#CACHED_RPMS[@]} RPMs — skipping 30-min rebuild"
    dialog --backtitle "RADS-WEB Installer" --title "Cached Build Found" \
      --yesno "Pre-built Samba RPMs were found from a prior build:\n  ${MOCK_RESULT}\n  (${#CACHED_RPMS[@]} packages)\n\nSkip the mock rebuild and install these cached RPMs?\n\n  [Yes] Use cached RPMs (fast)\n  [No]  Rebuild from scratch (15-30 min)" \
      13 70
    if [[ $? -eq 0 ]]; then
      step_ok "Using cached RPMs — skipping mock rebuild"
      # Jump straight to install
      _install_samba_rpms "${CACHED_RPMS[@]}"
      return
    else
      step_info "Rebuilding from scratch as requested..."
    fi
  fi

  step_info "This is the RADS approach — building Samba from the Rocky SRPM into RPMs"
  step_info "This ensures a trusted, dnf-managed Samba install with full AD/DC support"
  sleep 2

  # ── Install build prerequisites ──────────────────────────────────────────
  step_info "Installing Samba build dependencies..."
  local BUILD_DEPS=(
    "@development-tools"
    python3-devel gnutls-devel libacl-devel openldap-devel
    pam-devel cups-libs libtalloc-devel libtevent-devel
    libldb-devel libtdb-devel libwbclient-devel
    samba-common-libs krb5-devel avahi-devel dbus-devel
    perl-Parse-Yapp perl-JSON docbook-style-xsl libxslt
    quota-devel libaio-devel iniparser-devel
    gpgme-devel jansson-devel libnsl2-devel
    python3-dns python3-markdown
  )

  for dep in "${BUILD_DEPS[@]}"; do
    dnf -y install "$dep" --setopt=tsflags=nodocs --color=never >>"$log" 2>&1 || true
  done
  step_ok "Build dependencies installed"

  # ── Configure mock ────────────────────────────────────────────────────────
  step_info "Setting up mock build environment for Rocky 10..."
  usermod -a -G mock root >>"$log" 2>&1 || true

  # ── Download Samba SRPM ───────────────────────────────────────────────────
  step_info "Fetching Samba SRPM from Rocky 10 repos..."
  local SRPM_DIR="/root/samba-srpm"
  mkdir -p "$SRPM_DIR"

  # Enable source repos and download SRPM
  dnf config-manager --set-enabled devel >>"$log" 2>&1 || true
  cd "$SRPM_DIR" || exit 1
  dnf download --source samba >>"$log" 2>&1
  local SRPM_FILE
  SRPM_FILE=$(ls "$SRPM_DIR"/samba-*.src.rpm 2>/dev/null | head -1)

  if [[ -z "$SRPM_FILE" ]]; then
    step_fail "Could not download Samba SRPM — trying direct dnf install method"
    # Fallback: try dnf install with --enablerepo
    dnf -y install samba samba-dc samba-client samba-common-tools \
      samba-winbind samba-winbind-clients --setopt=tsflags=nodocs \
      --color=never >>"$log" 2>&1
    if [[ $? -eq 0 ]]; then
      step_ok "Samba installed via dnf (package build not available)"
    else
      step_fail "Samba install failed — see ${log}"
      dialog --title "Build Failed" --msgbox "Samba build/install failed.\nSee: ${log}\n\nYou may need to manually build the SRPM for Rocky 10." 10 65
      exit 1
    fi
    return
  fi

  step_ok "SRPM found: $(basename "$SRPM_FILE")"

  # ── Build with mock ───────────────────────────────────────────────────────
  step_info "Building Samba RPMs with mock (this takes 15-30 minutes)..."
  echo ""
  echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────────┐${TEXTRESET}"
  echo -e "${CYAN}  │  mock build output — streaming live                         │${TEXTRESET}"
  echo -e "${CYAN}  │  Full log: ${log}${TEXTRESET}"
  echo -e "${CYAN}  └─────────────────────────────────────────────────────────────┘${TEXTRESET}"
  echo ""

  # Stream mock output: tee to log (plain), colorize on terminal
  # $'s/.../\x1b[..m&\x1b[0m/' — bash expands \x1b to literal ESC before sed sees it
  # Detect the dist tag from the SRPM so built RPMs match the repo version
  # e.g. samba-4.23.5-109.el10_2.src.rpm → dist tag is .el10_2
  # Detect dist tag from SRPM release field (e.g. el10_2) so built RPMs
  # match the repo version and dnf won't treat them as downgrades
  local SRPM_DIST; SRPM_DIST=$(rpm -qp --qf '%{RELEASE}' "$SRPM_FILE" 2>/dev/null \
    | grep -oP '\.el\d+[^.]*$' || echo ".el10")
  # Append .dc suffix to signal this is the DC-enabled build
  local MOCK_DIST="${SRPM_DIST}.dc"
  step_info "Using dist tag: ${MOCK_DIST}"

  # --with dc            → enables AD/DC stack in the Samba spec so
  #                        samba-tool domain provision is built
  # --define dist        → overrides RPM dist macro to match repo NVRs
  # --enablerepo=epel    → needed for python3-setproctitle (not in devel/crb)
  # --rpmbuild-opts --nocheck → skips %check test suite which has a circular
  #                        BuildRequires on samba-dc/samba-common-tools
  #                        (those packages don't exist yet — we're building them)
  mock -r "$MOCK_CFG" \
    --enablerepo=crb \
    --enablerepo=devel \
    --enablerepo=epel \
    --verbose \
    --with dc \
    --define "dist ${MOCK_DIST}" \
    --rpmbuild-opts "--nocheck" \
    --rebuild "$SRPM_FILE" \
    --resultdir="$MOCK_RESULT" \
    2>&1 \
  | tee -a "$log" \
  | sed -u \
      -e $'s/^Start.*/\x1b[36m&\x1b[0m/' \
      -e $'s/^Finish.*/\x1b[32m&\x1b[0m/' \
      -e $'s/^INFO:.*/\x1b[34m&\x1b[0m/' \
      -e $'s/^ERROR:.*/\x1b[31m&\x1b[0m/' \
      -e $'s/^WARNING:.*/\x1b[33m&\x1b[0m/' \
      -e $'s/^DEBUG:.*/\x1b[2m&\x1b[0m/'

  local BUILD_EXIT=${PIPESTATUS[0]}

  echo ""

  if [[ "$BUILD_EXIT" -ne 0 ]]; then
    step_fail "Mock build failed (exit: ${BUILD_EXIT}) — see ${log}"
    dialog --title "Build Failed" \
      --msgbox "Samba SRPM build failed.\nSee: ${log}\n\nCommon issues:\n- Missing build deps\n- Mock configuration\n\nTrying dnf install as fallback..." 12 65

    # Fallback to dnf
    dnf -y install samba samba-dc samba-client samba-common-tools \
      samba-winbind samba-winbind-clients >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "Samba installed via dnf fallback" \
      || { step_fail "All Samba install methods failed"; exit 1; }
    return
  fi

  # ── Collect and install built RPMs ──────────────────────────────────────
  local ALL_RPMS=()
  for rpm in "${MOCK_RESULT}"/*.rpm; do
    [[ "$rpm" == *src.rpm ]]    && continue
    [[ "$rpm" == *debuginfo* ]] && continue
    [[ "$rpm" == *debugsource* ]] && continue
    [[ -f "$rpm" ]] && ALL_RPMS+=("$rpm")
  done

  _install_samba_rpms "${ALL_RPMS[@]}"

  # Cleanup
  rm -rf "$SRPM_DIR"
  step_ok "Build artifacts cleaned up"
  sleep 1
}

# ── Shared install/lock/record helper (used by both fresh build and cache path)
_install_samba_rpms() {
  local ALL_RPMS=("$@")
  local log="$LOGDIR/samba-build.log"
  local RPM_COUNT=0
  local INSTALLED_RPMS=()

  if [[ ${#ALL_RPMS[@]} -eq 0 ]]; then
    step_fail "No RPMs passed to install — check mock result dir"
    return 1
  fi

  step_info "Installing ${#ALL_RPMS[@]} RPMs in single transaction..."
  dnf -y install "${ALL_RPMS[@]}" --nogpgcheck --color=never >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then
    RPM_COUNT=${#ALL_RPMS[@]}
    INSTALLED_RPMS=("${ALL_RPMS[@]}")
  else
    # dnf may refuse if repo already has a newer dist-tag (e.g. el10_2 vs el10)
    # Fall back to rpm --force which bypasses version comparison
    step_info "dnf install failed (possible dist-tag mismatch) — using rpm --force..."
    rpm -Uvh --force --nodeps "${ALL_RPMS[@]}" >>"$log" 2>&1
    if [[ $? -eq 0 ]]; then
      RPM_COUNT=${#ALL_RPMS[@]}
      INSTALLED_RPMS=("${ALL_RPMS[@]}")
      step_ok "RPMs installed via rpm --force"
    else
      step_fail "rpm --force also failed — see ${log}"
      return 1
    fi
  fi

  [[ $RPM_COUNT -gt 0 ]] && step_ok "Samba RPMs installed (${RPM_COUNT} packages)" \
    || step_fail "No Samba RPMs installed — check ${log}"

  # ── Versionlock — prevent dnf from touching Samba ────────────────────────
  step_info "Locking Samba packages to prevent unintended dnf upgrades..."
  dnf -y install python3-dnf-plugin-versionlock --color=never >>"$log" 2>&1 || true

  for rpm in "${INSTALLED_RPMS[@]}"; do
    local PKG_NAME; PKG_NAME=$(rpm -qp --qf '%{NAME}' "$rpm" 2>/dev/null)
    [[ -n "$PKG_NAME" ]] && dnf versionlock add "$PKG_NAME" >>"$log" 2>&1 || true
  done

  for lib in libldb libtalloc libtevent libtdb libwbclient; do
    rpm -q "$lib" &>/dev/null && dnf versionlock add "$lib" >>"$log" 2>&1 || true
  done

  step_ok "Samba packages locked via versionlock"

  # ── Record installed version ──────────────────────────────────────────────
  mkdir -p /etc/samba-rads
  local SAMBA_NVR; SAMBA_NVR=$(rpm -q samba --qf '%{NAME}-%{VERSION}-%{RELEASE}' 2>/dev/null | head -1)
  echo "$SAMBA_NVR" > /etc/samba-rads/installed-version
  dnf versionlock list 2>/dev/null \
    | grep -E '^(samba|lib(ldb|talloc|tevent|tdb|wbclient))' \
    > /etc/samba-rads/locked-packages || true
  step_ok "Version recorded: ${SAMBA_NVR}"
}

# =============================================================
# STEP 17 — PROVISION SAMBA AD
# =============================================================
provision_samba_ad() {
  section "Samba AD Provisioning"
  local log="$LOGDIR/samba-provision.log"; : > "$log"
  local FQDN; FQDN=$(hostname)

  step_info "Provisioning Samba Active Directory..."
  step_info "Realm: ${AD_REALM} | Domain: ${AD_DOMAIN} | DC: ${FQDN}"

  # Stop any conflicting services
  systemctl stop smb nmb winbind 2>/dev/null || true

  # Remove any existing Samba config (clean provision)
  rm -f /etc/samba/smb.conf

  samba-tool domain provision \
    --realm="${AD_REALM}" \
    --domain="${AD_DOMAIN}" \
    --adminpass="${AD_ADMIN_PASS}" \
    --use-rfc2307 \
    >>"$log" 2>&1

  if [[ $? -ne 0 ]]; then
    step_fail "Samba AD provisioning failed — see ${log}"
    dialog --title "Provision Failed" --msgbox "Samba AD provisioning failed.\nSee: ${log}" 8 60
    exit 1
  fi

  step_ok "Samba AD provisioned (Realm: ${AD_REALM})"

  # ── Configure Kerberos ──────────────────────────────────────────────────
  if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    step_ok "Kerberos config updated"
  fi

  # ── Enable and start Samba ──────────────────────────────────────────────
  systemctl enable samba >>"$log" 2>&1 || systemctl enable smb >>"$log" 2>&1
  systemctl start  samba >>"$log" 2>&1 || systemctl start  smb >>"$log" 2>&1
  sleep 3

  if systemctl is-active --quiet samba || systemctl is-active --quiet smb; then
    step_ok "Samba service running"
  else
    step_fail "Samba failed to start — check ${log} and /var/log/samba/"
  fi
  sleep 1
}

# =============================================================
# STEP 18 — AD VERIFICATION TESTS
# =============================================================
verify_ad() {
  section "Active Directory Verification"
  local log="$LOGDIR/ad-verify.log"; : > "$log"
  local FQDN; FQDN=$(hostname)
  local MY_IP; MY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  sleep 5

  local all_pass=1

  # Kerberos TGT
  echo "${AD_ADMIN_PASS}" | kinit "Administrator@${AD_REALM}" >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "Kerberos TGT obtained"
  else step_fail "Kerberos TGT failed"; all_pass=0; fi

  # DNS SRV
  host -t SRV "_kerberos._udp.${AD_REALM}" "$MY_IP" >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "Kerberos SRV record (_kerberos._udp)"
  else step_fail "Kerberos SRV record not found"; all_pass=0; fi

  host -t SRV "_ldap._tcp.${AD_REALM}" "$MY_IP" >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "LDAP SRV record (_ldap._tcp)"
  else step_fail "LDAP SRV record not found"; all_pass=0; fi

  # Anonymous LDAP
  ldapsearch -H "ldap://${FQDN}" -x -b "" -s base >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "Anonymous LDAP query successful"
  else step_fail "Anonymous LDAP query failed"; all_pass=0; fi

  # List users
  samba-tool user list >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "samba-tool user list successful"
  else step_fail "samba-tool user list failed"; all_pass=0; fi

  if [[ $all_pass -eq 1 ]]; then
    step_ok "All AD verification tests passed"
  else
    step_info "Some tests failed — the AD may still be functional, check ${log}"
  fi
  sleep 2
}

# =============================================================
# STEP 19 — INSTALL PYTHON + FASTAPI
# =============================================================
install_python_packages() {
  section "Python / FastAPI"
  local log="$LOGDIR/python.log"; : > "$log"

  step_info "Upgrading pip..."
  python3 -m pip install --upgrade pip setuptools wheel >>"$log" 2>&1

  local PACKAGES=("fastapi" "uvicorn[standard]" "python-multipart" "python-pam" "aiofiles" "python-dotenv")
  local all_ok=1

  for pkg in "${PACKAGES[@]}"; do
    python3 -m pip install -U "$pkg" >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "pip install ${pkg}" \
      || { step_fail "pip install ${pkg} failed — see ${log}"; all_ok=0; }
  done

  [[ $all_ok -eq 1 ]] && step_ok "All Python packages installed" \
    || step_fail "Some Python packages failed — see ${log}"
  sleep 1
}

# =============================================================
# STEP 20 — DEPLOY RADS-WEB APP
# =============================================================
deploy_rads_web() {
  section "Deploy RADS-WEB Application"
  local log="$LOGDIR/deploy.log"; : > "$log"

  local TARBALL_URL="https://github.com/fumatchu/RADS_WEB/releases/latest/download/rads-web.tar.gz"
  local TARBALL="/tmp/rads-web.tar.gz"

  step_info "Downloading application package from GitHub Releases..."
  wget -q -O "$TARBALL" "$TARBALL_URL" 2>>"$log"

  if [[ $? -ne 0 || ! -s "$TARBALL" ]]; then
    # Fall back to installing from cloned source
    step_info "Release tarball not found — installing from cloned source..."
    if [[ -d "$SRC_BASE" ]]; then
      mkdir -p "$INSTALL_BASE"
      cp -r "${SRC_BASE}/api"     "$INSTALL_BASE/" >>"$log" 2>&1
      cp -r "${SRC_BASE}/ui"      "$INSTALL_BASE/" >>"$log" 2>&1
      [[ -d "${SRC_BASE}/scripts" ]] && cp -r "${SRC_BASE}/scripts" "$INSTALL_BASE/" >>"$log" 2>&1
      step_ok "Installed from source: ${SRC_BASE}"
    else
      step_fail "No source or release package available"
      return 1
    fi
  else
    local SIZE; SIZE=$(du -sh "$TARBALL" | cut -f1)
    step_ok "Downloaded rads-web.tar.gz (${SIZE})"

    [[ -d "$INSTALL_BASE" ]] && mv "$INSTALL_BASE" "${INSTALL_BASE}.bak.$(date +%Y%m%d%H%M%S)"

    tar -xzf "$TARBALL" -C /opt/ >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "Extracted to ${INSTALL_BASE}" \
      || { step_fail "Extraction failed"; return 1; }
    rm -f "$TARBALL"
  fi

  # Ensure runtime dirs
  mkdir -p "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state"

  # Permissions
  find "$INSTALL_BASE" -type d -exec chmod 755 {} \;
  find "${INSTALL_BASE}/api" -type f -name "*.py" -exec chmod 644 {} \;
  find "${INSTALL_BASE}/ui"  -type f -exec chmod 644 {} \;
  [[ -d "${INSTALL_BASE}/scripts" ]] && find "${INSTALL_BASE}/scripts" -type f -name "*.sh" -exec chmod 700 {} \;
  chmod 755 "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state"

  step_ok "Permissions set"
  sleep 1
}

# =============================================================
# STEP 21 — SELINUX FOR RADS-WEB
# =============================================================
configure_selinux_radsweb() {
  section "SELinux — RADS-WEB"
  local log="$LOGDIR/selinux-web.log"; : > "$log"

  command -v semanage >/dev/null 2>&1 || { step_fail "semanage not found"; return 1; }

  for dir in ui; do
    semanage fcontext -a -t httpd_sys_content_t \
      "${INSTALL_BASE}/${dir}(/.*)?" >>"$log" 2>&1 \
      || semanage fcontext -m -t httpd_sys_content_t \
        "${INSTALL_BASE}/${dir}(/.*)?" >>"$log" 2>&1 || true
    restorecon -Rv "${INSTALL_BASE}/${dir}" >>"$log" 2>&1 || true
    step_ok "SELinux: httpd_sys_content_t on ${dir}/"
  done

  setsebool -P httpd_can_network_connect 1 >>"$log" 2>&1
  step_ok "SELinux: httpd_can_network_connect enabled"
  sleep 1
}

# =============================================================
# STEP 22 — APACHE VIRTUALHOST
# =============================================================
configure_apache() {
  section "Apache VirtualHost"
  local log="$LOGDIR/apache.log"; : > "$log"
  local CONF="/etc/httpd/conf.d/rads-web.conf"

  cat > /etc/httpd/conf.modules.d/00-proxy.conf <<'EOF'
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule proxy_html_module modules/mod_proxy_html.so
EOF

  cat > "$CONF" <<'APACHECONF'
<VirtualHost *:80>
    DocumentRoot "/opt/rads-web/ui"

    <Directory "/opt/rads-web/ui">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    DirectoryIndex index.html login.html

    # API reverse proxy
    ProxyRequests Off
    ProxyPreserveHost On

    ProxyPass        /api/login        http://127.0.0.1:8000/api/login
    ProxyPassReverse /api/login        http://127.0.0.1:8000/api/login

    ProxyPass        /api/auth/check   http://127.0.0.1:8000/api/auth/check
    ProxyPassReverse /api/auth/check   http://127.0.0.1:8000/api/auth/check

    ProxyPass        /api/             http://127.0.0.1:8000/api/
    ProxyPassReverse /api/             http://127.0.0.1:8000/api/

    ErrorLog  /var/log/httpd/rads-web-error.log
    CustomLog /var/log/httpd/rads-web-access.log combined
</VirtualHost>
APACHECONF

  local syntax_out; syntax_out=$(apachectl configtest 2>&1)
  echo "$syntax_out" | grep -q "Syntax OK" \
    && step_ok "Apache config syntax OK" \
    || step_fail "Apache config syntax error: ${syntax_out}"

  systemctl enable --now httpd >>"$log" 2>&1
  systemctl restart httpd >>"$log" 2>&1
  systemctl is-active --quiet httpd && step_ok "Apache (httpd) running" \
    || step_fail "Apache failed to start — see /var/log/httpd/error_log"
  sleep 1
}

# =============================================================
# STEP 23 — RADS-WEB SYSTEMD SERVICE
# =============================================================
install_rads_service() {
  section "RADS-WEB Service"
  local SVC_FILE="/etc/systemd/system/rads-web.service"
  local log="$LOGDIR/service.log"; : > "$log"

  cat > "$SVC_FILE" <<'EOF'
[Unit]
Description=RADS-WEB FastAPI Backend
After=network.target samba.service
Wants=samba.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/rads-web/api
ExecStart=/usr/local/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now rads-web >>"$log" 2>&1
  sleep 3

  systemctl is-active --quiet rads-web \
    && step_ok "rads-web service running" \
    || { step_fail "rads-web service failed to start"; step_info "Check: journalctl -u rads-web -n 50 --no-pager"; }
  sleep 1
}

# =============================================================
# STEP 24 — FAIL2BAN
# =============================================================
configure_fail2ban() {
  section "Fail2ban"
  local log="$LOGDIR/fail2ban.log"; : > "$log"

  [[ -f /etc/fail2ban/jail.conf ]] && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local >>"$log" 2>&1 || true

  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
maxretry = 5
findtime = 300
bantime = 3600
bantime.increment = true
bantime.factor = 2
EOF

  systemctl enable --now fail2ban >>"$log" 2>&1
  sleep 2
  systemctl is-active --quiet fail2ban \
    && step_ok "Fail2ban running (SSH jail active)" \
    || step_fail "Fail2ban failed to start — see ${log}"
  sleep 1
}

# =============================================================
# STEP 25 — COCKPIT
# =============================================================
enable_cockpit() {
  section "Cockpit"
  local log="$LOGDIR/cockpit.log"; : > "$log"
  systemctl enable --now cockpit.socket >>"$log" 2>&1
  systemctl is-active --quiet cockpit.socket \
    && step_ok "Cockpit active (https://<server-ip>:9090)" \
    || step_fail "Cockpit failed to start"
  sleep 1
}

# =============================================================
# STEP 26 — MONITORING SCRIPT
# =============================================================
install_samba_monitor() {
  section "Samba Update Monitor"
  local log="$LOGDIR/monitor.log"; : > "$log"
  local MON_SCRIPT="/usr/local/sbin/samba-update-check.sh"

  cat > "$MON_SCRIPT" <<'MONEOF'
#!/usr/bin/env bash
# Checks whether a new Samba SRPM NVR is available in Rocky 10 repos.
# Compares against /etc/samba-rads/installed-version (set at install time).
# Writes /var/run/samba-update.flag if an update exists — never actually upgrades.

VERSION_FILE="/etc/samba-rads/installed-version"
FLAG_FILE="/var/run/samba-update.flag"

INSTALLED_NVR=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$INSTALLED_NVR" ]]; then
  logger -t samba-monitor "WARNING: $VERSION_FILE missing — cannot determine installed version"
  exit 0
fi

# Pull version/release from the repo (not the installed package) using dnf info
AVAIL_VER=$(dnf info --available samba 2>/dev/null \
  | awk '/^Version[[:space:]]*:/{ver=$3} /^Release[[:space:]]*:/{rel=$3} END{if(ver && rel) print "samba-"ver"-"rel}')

if [[ -z "$AVAIL_VER" ]]; then
  # No SRPM available in repos yet — nothing to report
  rm -f "$FLAG_FILE"
  exit 0
fi

if [[ "$INSTALLED_NVR" != "$AVAIL_VER"* ]]; then
  logger -t samba-monitor "Samba update available: installed=${INSTALLED_NVR} available=${AVAIL_VER}"
  printf '%s' "$AVAIL_VER" > "$FLAG_FILE"
else
  rm -f "$FLAG_FILE"
fi
MONEOF
  chmod 700 "$MON_SCRIPT"

  cat > /etc/systemd/system/samba-update-check.timer <<'EOF'
[Unit]
Description=Daily Samba update check
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/samba-update-check.service <<'EOF'
[Unit]
Description=Samba update check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-update-check.sh
EOF

  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now samba-update-check.timer >>"$log" 2>&1
  step_ok "Samba update monitor installed (runs daily)"
  sleep 1
}

# =============================================================
# STEP 27 — LOGIN BANNER
# =============================================================
update_issue_file() {
  section "Login Banner"
  cat > /etc/issue <<'EOF'
\S
Kernel \r on an \m
Hostname: \n
IP Address: \4
EOF
  step_ok "/etc/issue updated"
  sleep 1
}

# =============================================================
# STEP 28 — FINAL REPORT
# =============================================================
final_status_report() {
  section "Installation Summary"
  echo ""

  local FQDN; FQDN=$(hostname)
  local MY_IP; MY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || hostname -I | awk '{print $1}')

  local SERVICES=("samba" "rads-web" "httpd" "fail2ban" "chronyd" "firewalld")
  echo -e "  ${CYAN}Core Services:${TEXTRESET}"
  for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$svc" 2>/dev/null \
      && step_ok "${svc}" \
      || { systemctl is-active --quiet "smb" 2>/dev/null && [[ "$svc" == "samba" ]] \
        && step_ok "smb (samba)" || step_fail "${svc} (not running)"; }
  done

  local OPT_SERVICES=("cockpit.socket")
  echo ""; echo -e "  ${CYAN}Optional Services:${TEXTRESET}"
  for svc in "${OPT_SERVICES[@]}"; do
    systemctl is-active --quiet "$svc" 2>/dev/null \
      && step_ok "${svc}" || step_info "${svc} (check manually)"
  done

  echo ""; echo -e "  ${CYAN}Active Directory:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Realm:     ${AD_REALM}"
  echo -e "  ${YELLOW}→${TEXTRESET}  DC FQDN:   ${FQDN}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Admin:     Administrator@${AD_REALM}"

  echo ""; echo -e "  ${CYAN}Access Points:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  RADS-WEB:  http://${MY_IP}/"
  echo -e "  ${YELLOW}→${TEXTRESET}  Cockpit:   https://${MY_IP}:9090/"
  echo -e "  ${YELLOW}→${TEXTRESET}  API logs:  journalctl -u rads-web -f"
  echo -e "  ${YELLOW}→${TEXTRESET}  Installer: ${LOGDIR}/"

  echo ""; echo -e "  ${CYAN}Next Steps:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Log in at http://${MY_IP}/ with your PAM credentials"
  echo -e "  ${YELLOW}→${TEXTRESET}  Add a reverse DNS zone:"
  local NET_OCTETS; NET_OCTETS=$(echo "$MY_IP" | awk -F. '{print $3"."$2"."$1}')
  echo -e "       samba-tool dns zonecreate ${FQDN} ${NET_OCTETS}.in-addr.arpa -U Administrator"
  echo -e "  ${YELLOW}→${TEXTRESET}  Create your first AD user:"
  echo -e "       samba-tool user create <username> --given-name=<firstname> --surname=<lastname>"
  echo ""
  echo -e "  ${GREEN}RADS-WEB installation complete.${TEXTRESET}"
  echo ""

  # Clean up auto-resume from .bash_profile
  sed -i '/## RADS-WEB Installer — auto-resume after reboot ##/,/^fi$/d' /root/.bash_profile 2>/dev/null || true
}

# =============================================================
# MAIN
# =============================================================
main() {
  check_root_and_os
  check_and_enable_selinux
  check_samba_not_running
  detect_active_interface
  prompt_static_ip_if_dhcp
  validate_and_set_hostname
  check_internet_connectivity
  gather_domain_config
  enable_repos
  run_system_upgrade
  install_base_packages
  vm_detection
  configure_ntp
  configure_firewall
  configure_selinux_samba
  build_samba_from_srpm
  provision_samba_ad
  verify_ad
  install_python_packages
  deploy_rads_web
  configure_selinux_radsweb
  configure_apache
  install_rads_service
  configure_fail2ban
  enable_cockpit
  install_samba_monitor
  update_issue_file
  final_status_report
}

main
