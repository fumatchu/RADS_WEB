#!/usr/bin/env bash
# RADS-WEB Installer — First Domain Controller (new AD forest)
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
  /root/RADS_WEBInstaller/RADS_WEBInstallFirstServer.sh
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
  # Kerberos realm must be uppercase
  AD_REALM=$(echo "$AD_REALM" | tr '[:lower:]' '[:upper:]')
  # NetBIOS domain = first label of realm, uppercase (e.g. TEST.INT → TEST)
  AD_DOMAIN=$(echo "$AD_REALM" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')
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
    --yesno "Provision Active Directory with these settings?\n\nRealm:   ${AD_REALM}\nDomain:  ${AD_DOMAIN}\nDC FQDN: ${FQDN}\nNTP:     ${NTP_SERVER}" \
    12 65
  if [[ $? -ne 0 ]]; then
    gather_domain_config
    return
  fi
  # Wipe the dialog box off the screen so "Domain config: ..." starts a
  # clean page instead of overlapping whatever dialog left drawn behind it.
  clear
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

  step_info "Installing EPEL repository..."
  dnf -y install epel-release --setopt=install_weak_deps=False --color=never >>"$log" 2>&1
  step_ok "EPEL repository installed"

  step_info "Installing dnf-plugins-core..."
  dnf -y install dnf-plugins-core --setopt=install_weak_deps=False --color=never >>"$log" 2>&1 || true
  step_ok "dnf-plugins-core installed"

  # CRB — needed for many build deps
  step_info "Enabling CRB repository..."
  dnf config-manager --set-enabled crb --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable crb >>"$log" 2>&1 || true
  step_ok "CRB repository enabled"

  # Devel — required for python3-setproctitle, samba-dc, samba-common-tools
  # and python3-talloc-devel (Samba build deps not in CRB or base)
  step_info "Enabling Devel repository..."
  dnf config-manager --set-enabled devel --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable devel >>"$log" 2>&1 || true
  step_ok "Devel repository enabled"

  # Metadata refresh across the 3 newly-enabled repos is the genuinely slow,
  # silent part of this step — everything above it usually finishes in a
  # couple seconds each. Run it in the background and tick a dot on the same
  # line every second so it's obvious the installer is still working rather
  # than hung, instead of one long unexplained pause.
  printf "  ${YELLOW}→${TEXTRESET} Refreshing package metadata "
  dnf -y makecache --refresh --color=never >>"$log" 2>&1 &
  local mc_pid=$!
  while kill -0 "$mc_pid" 2>/dev/null; do
    printf "."
    sleep 1
  done
  wait "$mc_pid"
  echo ""
  step_ok "Package metadata refreshed"
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
    gcc make tar bzip2-devel openssl openssl-devel libffi-devel zlib-devel
    rpmbuild rpm-build mock createrepo_c
    krb5-workstation openldap-clients bind-utils
    chrony net-tools dmidecode ipcalc
    ntsysv wget curl rsync
    nano htop iotop iptraf-ng mc
    fail2ban
    httpd mod_ssl mod_proxy_html
    python3 python3-pip python3-psutil pam-devel python3-devel
    policycoreutils-python-utils
    acl zip util-linux expect sshpass
    dnf-automatic dnf-plugins-core dnf-utils
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
      dnf -y -q install --color=never --setopt=tsflags=nodocs --setopt=install_weak_deps=False "$PKG" >>"$log" 2>&1
    done
    echo "100"; echo "XXX"; echo "Base packages installed."; echo "XXX"
  } > "$PIPE"
  wait; rm -f "$PIPE"
  clear; section "Base Packages"
  step_ok "Base packages installed"
  # Cockpit is not used — remove it whether installed by the OS or as a weak dep
  dnf remove -y 'cockpit*' >>"$log" 2>&1 || true
  step_info "Cockpit removed (not needed)"
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

  # Port 8000 (uvicorn) is internal-only — not opened externally
  firewall-cmd --reload >/dev/null 2>&1
  systemctl restart firewalld >/dev/null 2>&1
  step_ok "Firewall rules applied (Samba AD + DNS + Kerberos + HTTP/HTTPS)"
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
  # (same samba-dc-bind-dlz exclusion as the fresh-build path below — a stale
  # cache dir from before this exclusion existed would otherwise still ship it)
  local CACHED_RPMS=()
  for rpm in "${MOCK_RESULT}"/*.rpm; do
    [[ "$rpm" == *src.rpm ]]    && continue
    [[ "$rpm" == *debuginfo* ]] && continue
    [[ "$rpm" == *debugsource* ]] && continue
    [[ "$rpm" == *samba-dc-bind-dlz* ]] && continue
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
  # ── Build prerequisites: NOT installed on host, intentionally ────────────
  # REAL INCIDENT (2026-07-23): this used to `dnf -y install` a BUILD_DEPS
  # array of -devel headers here (@development-tools, libtalloc-devel,
  # libtevent-devel, libldb-devel, krb5-devel, avahi-devel, openldap-devel,
  # gnutls-devel, etc.), then strip them back out after the build via an
  # "appliance hardening" removal step. That removal step turned out to be
  # unsafe on multiple fresh installs: dnf's dependency solver cascaded past
  # the intended -devel/gcc packages and also erased samba-dc, samba-tools,
  # python3-samba, python3-samba-dc, krb5-server, avahi, certmonger, and
  # cepces — this custom mock "DC flavor" build apparently gives those
  # runtime packages a Requires back onto one or more of the -devel packages
  # above. A --setopt=protected_packages guard was tried and did NOT stop the
  # cascade either. mock resolves 100% of Samba's BuildRequires itself,
  # inside its own isolated chroot, via config_opts['dnf_builddep_opts']
  # below — that's the whole reason samba_update.py's on-demand rebuild
  # pipeline never installs a single host-level -devel package and still
  # builds fine. These host copies were never load-bearing for the compile;
  # they were also the exact package class behind the original `dnf update`
  # deadlock incident (exact-NVR-pinned against glibc/glib2 from the devel
  # repo). Skipping the install here closes both bugs and leaves nothing to
  # clean up afterward.
  step_ok "Build dependencies resolved by mock inside its isolated chroot (nothing installed on host)"
  # ── Configure mock ────────────────────────────────────────────────────────
  step_info "Setting up mock build environment for Rocky 10..."
  usermod -a -G mock root >>"$log" 2>&1 || true
  # ── Download Samba SRPM ───────────────────────────────────────────────────
  # A single opaque `dnf download`, same deal as the metadata refresh in
  # enable_repos() — no discrete sub-steps to hook progress into, so tick a
  # dot per second in the background while it runs.
  local SRPM_DIR="/root/samba-srpm"
  mkdir -p "$SRPM_DIR"
  # Clear out any SRPM left from a prior run before downloading a fresh one.
  # Without this, a stale SRPM from an older Rocky point release can sit
  # alongside the new one, and the `ls | head -1` below picks alphabetically
  # — not newest — so an old cached 4.23.x could silently outrank a real
  # 4.24.x. Same cleanup api/samba_update.py's rebuild pipeline already does.
  rm -f "$SRPM_DIR"/samba-*.src.rpm
  dnf config-manager --set-enabled devel >>"$log" 2>&1 || true
  cd "$SRPM_DIR" || exit 1
  printf "  ${YELLOW}→${TEXTRESET} Fetching Samba SRPM from Rocky 10 repos "
  dnf download --source samba >>"$log" 2>&1 &
  local srpm_dl_pid=$!
  while kill -0 "$srpm_dl_pid" 2>/dev/null; do
    printf "."
    sleep 1
  done
  wait "$srpm_dl_pid"
  echo ""
  local SRPM_FILE
  SRPM_FILE=$(ls "$SRPM_DIR"/samba-*.src.rpm 2>/dev/null | head -1)
  if [[ -z "$SRPM_FILE" ]]; then
    step_fail "Could not download Samba SRPM"
    exit 1
  fi
  step_ok "SRPM: $(basename "$SRPM_FILE")"
  # ── Detect dist tag ───────────────────────────────────────────────────────
  local SRPM_DIST; SRPM_DIST=$(rpm -qp --qf '%{RELEASE}' "$SRPM_FILE" 2>/dev/null \
    | grep -oP '\.el\d+[^.]*$' || echo ".el10")
  local MOCK_DIST="${SRPM_DIST}.dc"
  step_info "Using dist tag: ${MOCK_DIST}"
  # ── Detect Samba version ──────────────────────────────────────────────────
  # Pulled straight off the SRPM we just downloaded rather than hardcoded —
  # Rocky bumps this on point releases (10.2 today, 10.4/10.5/etc. later),
  # and the stub packages below must claim the SAME version the real SRPM's
  # spec expects, or a future bump silently breaks BuildRequires resolution.
  local SRPM_VERSION; SRPM_VERSION=$(rpm -qp --qf '%{VERSION}' "$SRPM_FILE" 2>/dev/null)
  if [[ -z "$SRPM_VERSION" ]]; then
    step_fail "Could not determine Samba version from SRPM — aborting rather than guess"
    exit 1
  fi
  step_info "Detected Samba version: ${SRPM_VERSION}"
  # ── Build stub repo for circular bootstrap packages ──────────────────────
  # --with dc adds BuildRequires baked into the Rocky SRPM's binary metadata
  # for packages that are circular or excluded in the mock chroot:
  #   samba-dc           → obsoleted/merged into main samba in Rocky 10
  #   samba-common-tools → excluded by repo exclude filters in the chroot
  # python3-setproctitle comes from EPEL (configured in mock config below).
  # Stubs just satisfy dnf builddep — the real packages are compiled from source.
  # Version is pinned to SRPM_VERSION (detected above), not a literal, so
  # this keeps working after Rocky ships a newer Samba.
  step_info "Building DC bootstrap stub packages for mock..."
  local STUB_DIR="/root/samba-dc-stubs"
  mkdir -p "$STUB_DIR"
  for stub_name in samba-dc samba-common-tools; do
    cat > "/tmp/${stub_name}-stub.spec" << SPEC
Name:       ${stub_name}
Version:    ${SRPM_VERSION}
Release:    0.stub
Summary:    Bootstrap stub for Samba DC mock build
License:    GPL-3.0+
BuildArch:  noarch
%description
Minimal stub to satisfy circular BuildRequires during Samba DC build.
%files
SPEC
    rpmbuild -bb "/tmp/${stub_name}-stub.spec" \
      --define "_rpmdir ${STUB_DIR}" \
      --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
      >>"$log" 2>&1 || true
  done
  find "$STUB_DIR" -mindepth 2 -name "*.rpm" -exec mv {} "$STUB_DIR/" \; 2>/dev/null || true
  createrepo_c "$STUB_DIR" >>"$log" 2>&1
  step_ok "Stub repo ready: $(ls "${STUB_DIR}"/*.rpm 2>/dev/null | wc -l) stub packages"
  # ── Write mock config ─────────────────────────────────────────────────────
  local _os_major _arch
  _os_major=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null | awk -F. '{print $1}')
  [[ -z "$_os_major" ]] && _os_major="10"
  _arch=$(uname -m)
  local MOCK_CFG_FILE="/etc/mock/rocky-10-x86_64-samba-dc.cfg"
  cat > "$MOCK_CFG_FILE" << MOCKCFG
include('/etc/mock/rocky-10-x86_64.cfg')
config_opts['dnf.conf'] += """
[samba-dc-stubs]
name=Samba DC Bootstrap Stubs
baseurl=file://${STUB_DIR}
enabled=1
gpgcheck=0
priority=1
[epel]
name=Extra Packages for Enterprise Linux ${_os_major}
baseurl=https://dl.fedoraproject.org/pub/epel/${_os_major}/Everything/${_arch}/
enabled=1
gpgcheck=0
"""
config_opts['dnf_builddep_opts'] = ['--setopt=devel.exclude=', '--setopt=appstream.exclude=', '--setopt=baseos.exclude=']
MOCKCFG
  step_ok "Mock config: ${MOCK_CFG_FILE}"
  local MOCK_BUILD_CFG="rocky-10-x86_64-samba-dc"
  MOCK_RESULT="/var/lib/mock/${MOCK_BUILD_CFG}/result"
  # ── Build with mock ───────────────────────────────────────────────────────
  step_info "Building Samba RPMs with mock (this takes 15-30 minutes)..."
  echo ""
  echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────────┐${TEXTRESET}"
  echo -e "${CYAN}  │  mock build output — streaming live                         │${TEXTRESET}"
  echo -e "${CYAN}  │  Full log: ${log}${TEXTRESET}"
  echo -e "${CYAN}  └─────────────────────────────────────────────────────────────┘${TEXTRESET}"
  echo ""
  sleep 2
  # --isolation=simple: mock's systemd-nspawn default needs nested
  # mount-namespace support that many hypervisors don't fully pass through to
  # the guest, failing with "Failed to mount /proc/sys ... Child died too
  # early." Plain chroot isolation doesn't need that, so it works in VMs
  # where nspawn doesn't. Same fix applied in api/samba_update.py's rebuild
  # pipeline, which runs the same mock command.
  mock -r "$MOCK_BUILD_CFG" \
    --isolation=simple \
    --enablerepo=devel \
    --verbose \
    --with dc \
    --define "dist ${MOCK_DIST}" \
    --rebuild "$SRPM_FILE" \
    --resultdir="$MOCK_RESULT" \
    2>&1 \
  | tee -a "$log" \
  | while IFS= read -r _mock_line; do
      # DEBUG is the vast majority of mock --verbose output and flies by
      # unthrottled; the handful of Start/Finish/INFO/WARNING/ERROR lines
      # actually mark a stage boundary, so those get a beat of pause after
      # printing so a human can actually register them going by.
      case "$_mock_line" in
        Start*)
          printf '\x1b[36m%s\x1b[0m\n' "$_mock_line"
          sleep 1
          ;;
        Finish*)
          printf '\x1b[32m%s\x1b[0m\n' "$_mock_line"
          sleep 1
          ;;
        INFO:*)
          printf '\x1b[34m%s\x1b[0m\n' "$_mock_line"
          sleep 1
          ;;
        ERROR:*)
          printf '\x1b[31m%s\x1b[0m\n' "$_mock_line"
          sleep 1
          ;;
        WARNING:*)
          printf '\x1b[33m%s\x1b[0m\n' "$_mock_line"
          sleep 1
          ;;
        DEBUG:*)
          printf '\x1b[2m%s\x1b[0m\n' "$_mock_line"
          ;;
        *)
          printf '%s\n' "$_mock_line"
          ;;
      esac
    done
  local BUILD_EXIT=${PIPESTATUS[0]}
  echo ""
  if [[ "$BUILD_EXIT" -ne 0 ]]; then
    step_fail "Mock build failed (exit: ${BUILD_EXIT}) — see ${log}"
    dialog --title "Build Failed" \
      --msgbox "Samba SRPM build failed.\nSee: ${log}\n\nCommon issues:\n- Missing build deps\n- Mock configuration\n\nTrying dnf install as fallback..." 12 65
    # Fallback to dnf
    # --exclude keeps the BIND9-DLZ subpackage (and the bind/bind-dnssec-utils
    # it drags in) off the box — we run the hybrid DNS setup (Samba on :53,
    # BIND forwarder on :5353) instead of the BIND_DLZ backend, so it's dead
    # weight that only confuses the dashboard's service health checks.
    dnf -y install --exclude=samba-dc-bind-dlz samba samba-dc samba-client samba-common-tools \
      samba-winbind samba-winbind-clients >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "Samba installed via dnf fallback" \
      || { step_fail "All Samba install methods failed"; exit 1; }
    return
  fi
  # ── Collect and install built RPMs ──────────────────────────────────────
  # samba-dc-bind-dlz is excluded here too: it's Samba's BIND9-DLZ backend,
  # an alternative to the internal DNS server we actually use. Installing it
  # drags in bind + bind-dnssec-utils as unused, never-started dead weight
  # (see Tranquil IT's hybrid DNS docs — DLZ isn't required for that setup).
  local ALL_RPMS=()
  for rpm in "${MOCK_RESULT}"/*.rpm; do
    [[ "$rpm" == *src.rpm ]]    && continue
    [[ "$rpm" == *debuginfo* ]] && continue
    [[ "$rpm" == *debugsource* ]] && continue
    [[ "$rpm" == *samba-dc-bind-dlz* ]] && continue
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
  # ── Fix samba.smbd Python module path ────────────────────────────────────
  # Our DC build installs smbd.cpython-*.so under samba/samba3/ but provision
  # imports it as `samba.smbd` (looks in samba/ directly). Symlink it into place.
  local _smbd_src _smbd_dst _pyver
  _pyver=$(python3 -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null)
  _smbd_src="/usr/lib64/python3.${_pyver#3}/site-packages/samba/samba3/smbd.cpython-${_pyver}-x86_64-linux-gnu.so"
  _smbd_dst="/usr/lib64/python3.${_pyver#3}/site-packages/samba/smbd.cpython-${_pyver}-x86_64-linux-gnu.so"
  # Simpler glob-based detection
  _smbd_src=$(ls /usr/lib64/python3*/site-packages/samba/samba3/smbd.cpython-*.so 2>/dev/null | head -1)
  _smbd_dst=$(echo "$_smbd_src" | sed 's|/samba3/|/|')
  if [[ -f "$_smbd_src" && ! -f "$_smbd_dst" ]]; then
    ln -sf "$_smbd_src" "$_smbd_dst"
    step_ok "Linked samba.smbd Python extension into correct path"
  elif [[ -f "$_smbd_dst" ]]; then
    step_ok "samba.smbd already in place"
  else
    step_info "samba.smbd not found in samba3/ — provision may fail"
  fi
  # ── Appliance hardening, take 3 ───────────────────────────────────────────
  # Nothing to remove here anymore — see the comment above where BUILD_DEPS
  # used to be installed. We never install host-level -devel headers or
  # @development-tools in the first place (mock resolves everything itself),
  # so there's no package-removal cascade risk left to guard against. The one
  # thing still worth doing is making sure "devel" (enabled early in the
  # install for `dnf download --source samba` / mock's own --enablerepo=devel)
  # doesn't stay enabled indefinitely — a plain repo disable, no package
  # removal, so no Requires-cascade risk.
  dnf config-manager --set-disabled devel >/dev/null 2>&1 || true
  if ! command -v samba-tool >/dev/null 2>&1; then
    step_fail "samba-tool missing after Samba RPM install — investigate before provisioning"
  else
    step_ok "'devel' repo disabled — no build tooling was ever installed on host to clean up"
  fi
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
  # Stop any conflicting services (including samba in AD DC mode)
  systemctl stop samba smb nmb winbind 2>/dev/null || true
  pkill -9 -x smbd   2>/dev/null || true
  pkill -9 -x nmbd   2>/dev/null || true
  pkill -9 -x samba  2>/dev/null || true
  sleep 1
  # Remove any existing Samba config (clean provision)
  # ── Ensure filesystem ACL + xattr support (required for smbd.set_simple_acl) ─
  local _mnt _dev _fstype
  _mnt=$(df /var/lib/samba 2>/dev/null | awk 'NR==2{print $NF}')
  [[ -z "$_mnt" ]] && _mnt=$(df /var 2>/dev/null | awk 'NR==2{print $NF}')
  [[ -z "$_mnt" ]] && _mnt="/"
  _dev=$(findmnt -n -o SOURCE "$_mnt" 2>/dev/null)
  _fstype=$(findmnt -n -o FSTYPE "$_mnt" 2>/dev/null)
  # XFS has ACLs on by default; ext4/ext3 need explicit mount options
  if [[ "$_fstype" == "ext4" || "$_fstype" == "ext3" || "$_fstype" == "ext2" ]]; then
    step_info "Enabling ACL+xattr on ${_mnt} (${_fstype})..."
    mount -o remount,acl,user_xattr "$_mnt" >>"$log" 2>&1 && step_ok "Remounted ${_mnt} with acl,user_xattr" || true
    # Make persistent in fstab
    if ! grep -qP "^\S+\s+${_mnt}\s+\S+\s+[^#]*\bacl\b" /etc/fstab 2>/dev/null; then
      sed -i -E "s|^([^#]\S+\s+${_mnt}\s+\S+\s+)(\S+)|\1\2,acl,user_xattr|" /etc/fstab
      step_ok "Updated /etc/fstab with acl,user_xattr for ${_mnt}"
    fi
  fi
  # Back up existing smb.conf if present (matches old DCInstall.sh behavior)
  [[ -f /etc/samba/smb.conf ]] && mv -f /etc/samba/smb.conf /etc/samba/smb.bak.orig
  # After 30+ minutes of mock build + dialog + dnf, the installer's bash process
  # has a fragmented virtual address space.  When samba-tool forks from it,
  # TALLOC's mmap calls fail to find contiguous regions → MemoryError.
  # Running via systemd-run has PID 1 spawn provision with a clean address space.
  #
  # REAL INCIDENT (2026-07-23): even with systemd-run, samba-tool's own sysvol
  # ACL step (setsysvolacl → smbd.set_simple_acl) reliably crashed with an
  # uncaught MemoryError when provisioning ran immediately after the RPM
  # install transaction finished — reproduced on two consecutive fresh full
  # rebuilds, confirmed via samba-provision.log both times. A manual retry run
  # a minute or two later (after typing a few commands) never hit it, so a
  # short settle pause here is cheap insurance against the timing window.
  step_info "Letting the system settle after the RPM install before provisioning..."
  sync
  sleep 5
  local _prov_log="${log%/*}/samba-provision.log"
  echo "[provision] realm=${AD_REALM} domain=${AD_DOMAIN}" > "$_prov_log"
  echo "[provision] realm=${AD_REALM} domain=${AD_DOMAIN}" >> "$log"
  systemd-run --wait \
    --unit="samba-provision-$$" \
    --description="Samba AD domain provision" \
    --property="StandardOutput=append:${_prov_log}" \
    --property="StandardError=append:${_prov_log}" \
    -- samba-tool domain provision \
      --realm="${AD_REALM}" \
      --domain="${AD_DOMAIN}" \
      --adminpass="${AD_ADMIN_PASS}" \
      --use-rfc2307
  local PROVISION_RC=$?
  [[ "$_prov_log" != "$log" ]] && cat "$_prov_log" >> "$log"
  if [[ $PROVISION_RC -ne 0 ]]; then
    step_fail "Samba AD provisioning failed — see ${_prov_log}"
    dialog --title "Provision Failed" --msgbox "Samba AD provisioning failed.\nSee: ${_prov_log}" 8 60
    exit 1
  fi
  # samba-tool's own netcmd error handler can catch an internal exception deep
  # in provisioning (confirmed case: MemoryError in setsysvolacl), print
  # "ERROR(<class '...'>): uncaught exception", and STILL exit 0 — so
  # PROVISION_RC alone does not reliably catch this failure mode. Everything
  # before that point (schema, forest/domain updates, DNS, Kerberos config)
  # had already completed successfully in both observed cases, so rather than
  # re-running the entire multi-minute provision, just redo the sysvol ACL
  # pass with the command Samba itself documents for exactly this repair.
  if grep -q "^ERROR(" "$_prov_log" 2>/dev/null; then
    step_info "Provision reported success but logged an internal error — repairing sysvol ACLs..."
    if samba-tool ntacl sysvolreset >>"$log" 2>&1; then
      step_ok "Sysvol ACLs repaired via 'samba-tool ntacl sysvolreset'"
    else
      step_fail "Sysvol ACL repair failed — see ${log} (domain is provisioned but sysvol permissions may be wrong; rerun 'samba-tool ntacl sysvolreset' manually)"
    fi
  fi
  step_ok "Samba AD provisioned (Realm: ${AD_REALM})"
  # ── Kerberos — install krb5.conf before starting Samba ─────────────────
  # Provision may have been killed by MemoryError before writing private/krb5.conf.
  # Fall back to the Samba setup template if needed.
  if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    \cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
    step_ok "Kerberos config installed from provision output"
  elif [[ -f /usr/share/samba/setup/krb5.conf ]]; then
    local _realm_lc _fqdn
    _realm_lc=$(echo "${AD_REALM}" | tr '[:upper:]' '[:lower:]')
    _fqdn=$(hostname)
    sed -e "s|\${REALM}|${AD_REALM}|g" \
        -e "s|\${DNSDOMAIN}|${_realm_lc}|g" \
        -e "s|\${HOSTNAME}|${_fqdn}|g" \
        /usr/share/samba/setup/krb5.conf > /etc/krb5.conf
    step_ok "Kerberos config generated from template"
  else
    step_fail "Cannot locate krb5.conf template — Kerberos may not work"
  fi
  # Rocky 10's default krb5.conf has default_realm commented out.
  # Ensure it is always present regardless of which path above ran.
  if [[ -f /etc/krb5.conf ]]; then
    if grep -q "^\s*#\s*default_realm\|^\s*default_realm" /etc/krb5.conf; then
      # Replace commented or wrong value
      sed -i "s|^\s*#\?\s*default_realm\s*=.*|\\tdefault_realm = ${AD_REALM}|" /etc/krb5.conf
    else
      # Insert after [libdefaults]
      sed -i "/^\[libdefaults\]/a\\\\tdefault_realm = ${AD_REALM}" /etc/krb5.conf
    fi
    step_ok "Verified default_realm = ${AD_REALM} in /etc/krb5.conf"
  fi
  # Samba starts MIT KDC with KRB5_CONFIG=/var/lib/samba/private/krb5.conf.
  # If provision hit MemoryError that file won't exist — copy ours in.
  if [[ ! -f /var/lib/samba/private/krb5.conf ]]; then
    \cp -f /etc/krb5.conf /var/lib/samba/private/krb5.conf
    step_ok "Copied krb5.conf into samba private dir for MIT KDC"
  fi
  # Samba sets KRB5_KDC_PROFILE=/var/lib/samba/private/kdc.conf when starting
  # MIT KDC. Without this file KDC falls back to its system default which tries
  # the db2 backend at /var/kerberos/krb5kdc/principal (doesn't exist).
  # Generate the kdc.conf pointing MIT KDC at Samba's own database module.
  if [[ ! -f /var/lib/samba/private/kdc.conf ]]; then
    cat > /var/lib/samba/private/kdc.conf << KDCCONF
[kdcdefaults]
 kdc_ports = 88
 kdc_tcp_ports = 88
 restrict_anonymous_to_tun = false
[realms]
 ${AD_REALM} = {
  database_module = samba
  acl_file = /var/lib/samba/private/krb5kdc.acl
  admin_keytab = /var/lib/samba/private/dns.keytab
 }
[dbmodules]
 samba = {
  db_library = samba
 }
KDCCONF
    step_ok "Generated MIT KDC config (/var/lib/samba/private/kdc.conf)"
  fi
  # ── DNS — point NIC at itself so Samba internal DNS resolves correctly ───
  local _dc_ip _iface
  _dc_ip=$(hostname -I | awk '{print $1}')
  _iface=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | awk -F: '$2=="connected"{print $1}' | head -1)
  if [[ -n "$_dc_ip" && -n "$_iface" ]]; then
    nmcli con mod "$_iface" ipv4.dns "$_dc_ip" >>"$log" 2>&1
    systemctl restart NetworkManager >>"$log" 2>&1
    sleep 2
    step_ok "DNS resolver set to ${_dc_ip} on ${_iface}"
  else
    step_info "Could not auto-detect interface for DNS — set manually if needed"
  fi
  # ── Enable and start Samba ──────────────────────────────────────────────
  systemctl enable samba >>"$log" 2>&1 || systemctl enable smb >>"$log" 2>&1
  systemctl start  samba >>"$log" 2>&1 || systemctl start  smb >>"$log" 2>&1
  sleep 3
  if systemctl is-active --quiet samba || systemctl is-active --quiet smb; then
    step_ok "Samba service running"
    # Fix sysvol ACLs if provision skipped them (MemoryError workaround)
    samba-tool ntacl sysvolreset >>"$log" 2>&1 && step_ok "Sysvol ACLs set" || true
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
# (updated: added psutil for system monitor)
# =============================================================
install_python_packages() {
  section "Python / FastAPI"
  local log="$LOGDIR/python.log"; : > "$log"
  # pip calls os.getcwd() at startup; if the installer's cwd was deleted
  # (e.g. mock build chroot cleanup) pip crashes before doing anything.
  cd /root || cd /tmp
  step_info "Upgrading pip..."
  python3 -m pip install --upgrade pip setuptools wheel --break-system-packages >>"$log" 2>&1
  local PACKAGES=(
    "fastapi"
    "uvicorn[standard]"
    "python-multipart"
    "python-pam"       # PAM auth against Rocky system users
    "aiofiles"
    "python-dotenv"
  )
  # psutil is managed by dnf (python3-psutil) to avoid RPM/pip conflict
  local all_ok=1
  for pkg in "${PACKAGES[@]}"; do
    python3 -m pip install -U "$pkg" --break-system-packages >>"$log" 2>&1
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
      [[ -d "${SRC_BASE}/upgrade" ]] && cp -r "${SRC_BASE}/upgrade" "$INSTALL_BASE/" >>"$log" 2>&1
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
  mkdir -p "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state" "${INSTALL_BASE}/tools"
  # Permissions
  find "$INSTALL_BASE" -type d -exec chmod 755 {} \;
  find "${INSTALL_BASE}/api" -type f -name "*.py" -exec chmod 644 {} \;
  find "${INSTALL_BASE}/ui"  -type f -exec chmod 644 {} \;
  [[ -d "${INSTALL_BASE}/scripts" ]] && find "${INSTALL_BASE}/scripts" -type f -name "*.sh" -exec chmod 700 {} \;
  [[ -d "${INSTALL_BASE}/upgrade" ]] && find "${INSTALL_BASE}/upgrade" -type f -name "*.sh" -exec chmod 700 {} \;
  chmod 755 "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state" "${INSTALL_BASE}/tools"
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
# STEP 22 — GENERATE SELF-SIGNED TLS CERTIFICATE
# (new step — runs before configure_apache)
# =============================================================
generate_ssl_cert() {
  section "TLS Certificate (self-signed)"
  local log="$LOGDIR/ssl.log"; : > "$log"

  local CERT="/etc/pki/tls/certs/rads-web.crt"
  local KEY="/etc/pki/tls/private/rads-web.key"
  local FQDN; FQDN=$(hostname -f 2>/dev/null || hostname)
  local SHORT; SHORT=$(hostname -s 2>/dev/null || hostname)
  local SERVER_IP; SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
    || hostname -I | awk '{print $1}')

  # Disable the default mod_ssl VirtualHost FIRST — always, regardless of
  # cert generation outcome. Our rads-web.conf declares Listen 443 itself,
  # so ssl.conf being present causes a duplicate-listener error in Apache.
  #
  # IMPORTANT: we edit ssl.conf IN PLACE (comment out its Listen line)
  # instead of renaming it away. /etc/httpd/conf.d/ssl.conf ships from the
  # mod_ssl RPM as %config(noreplace) — DNF only protects a config file
  # from being overwritten on update when it still exists at its original
  # path with modified content. Renaming it to ssl.conf.disabled makes DNF
  # think the file is simply missing, so the next mod_ssl update reinstalls
  # a pristine ssl.conf (Listen line and all), silently reintroducing the
  # duplicate-listener bug. Editing in place keeps DNF's noreplace
  # protection active — a future update drops ssl.conf.rpmnew alongside
  # instead of clobbering this fix. Play by DNF's rules, not our own.
  local DEFAULT_SSL="/etc/httpd/conf.d/ssl.conf"
  local OLD_DISABLED="${DEFAULT_SSL}.disabled"

  # A previous install/version of this script may have renamed it away —
  # restore it to its real path first so DNF can actually track it.
  if [[ ! -f "$DEFAULT_SSL" && -f "$OLD_DISABLED" ]]; then
    mv "$OLD_DISABLED" "$DEFAULT_SSL"
    step_info "Restored ssl.conf from a previous .disabled rename"
  fi

  if [[ -f "$DEFAULT_SSL" ]]; then
    if grep -qE '^[[:space:]]*Listen[[:space:]]+443' "$DEFAULT_SSL"; then
      sed -i -E 's/^([[:space:]]*)(Listen[[:space:]]+443.*)/\1# \2  # disabled by RADS-WEB installer -- rads-web.conf declares its own Listen 443; kept in place (not renamed) so DNF noreplace protects this edit/' "$DEFAULT_SSL"
      step_ok "Default ssl.conf Listen 443 commented out in place (DNF-safe)"
    else
      step_ok "Default ssl.conf Listen 443 already disabled"
    fi

    # Commenting out Listen 443 above is NOT enough on its own: Apache
    # matches <VirtualHost _default_:443> against any Listen 443 that
    # exists anywhere on the server (rads-web.conf declares its own), so
    # this file's default VirtualHost block is still parsed even with its
    # local Listen line disabled. That block's SSLCertificateFile points at
    # /etc/pki/tls/certs/localhost.crt -- a file the mod_ssl RPM references
    # but never actually creates on RHEL/Rocky 8+ -- which fails apachectl
    # configtest with AH00526 ("does not exist or is empty") and blocks
    # httpd from starting. rads-web.conf's own VirtualHost *:443 (using the
    # real rads-web.crt/key generated above) fully replaces this block, so
    # comment the whole thing out in place too -- same DNF-safe approach,
    # not a rename, so mod_ssl updates keep dropping ssl.conf.rpmnew instead
    # of silently reintroducing this failure.
    if grep -qE '^[[:space:]]*<VirtualHost[[:space:]]+_default_:443>' "$DEFAULT_SSL"; then
      sed -i '/^[[:space:]]*<VirtualHost[[:space:]]\+_default_:443>/,/^[[:space:]]*<\/VirtualHost>/ s/^/# /' "$DEFAULT_SSL"
      step_ok "Default ssl.conf <VirtualHost _default_:443> block commented out in place (DNF-safe)"
    else
      step_ok "Default ssl.conf VirtualHost block already disabled"
    fi
  fi

  if [[ -f "$CERT" && -f "$KEY" ]]; then
    step_ok "Certificate already exists — skipping generation"
  else
    step_info "Generating 4096-bit RSA self-signed cert for ${FQDN} / ${SERVER_IP}..."
    openssl req -x509 \
      -newkey rsa:4096 \
      -keyout "$KEY" \
      -out    "$CERT" \
      -days   3650 \
      -nodes \
      -subj "/C=US/ST=Local/L=Local/O=RADS-WEB/OU=AD-DC/CN=${FQDN}" \
      -addext "subjectAltName=DNS:${FQDN},DNS:${SHORT},IP:${SERVER_IP}" \
      >>"$log" 2>&1
    if [[ $? -eq 0 ]]; then
      chmod 600 "$KEY"
      chmod 644 "$CERT"
      step_ok "Self-signed cert generated (10-year / RSA-4096)"
      step_ok "  CN : ${FQDN}"
      step_ok "  SAN: DNS:${FQDN}, DNS:${SHORT}, IP:${SERVER_IP}"
    else
      step_fail "openssl cert generation failed — see ${log}"
      return 1
    fi
  fi

  # SELinux context on cert files
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -v "$CERT" "$KEY" >>"$log" 2>&1 || true
    step_ok "SELinux context restored on cert/key"
  fi

  sleep 1
}
# =============================================================
# STEP 23 — APACHE VIRTUALHOST (HTTPS)
# (updated: HTTPS on 443, redirect from 80, WebSocket proxy)
# =============================================================
configure_apache() {
  section "Apache VirtualHost (HTTPS)"
  local log="$LOGDIR/apache.log"; : > "$log"
  local CONF="/etc/httpd/conf.d/rads-web.conf"

  # ── Proxy modules conf ───────────────────────────────────────
  # Only write if mod_proxy_wstunnel isn't already declared — avoids
  # "module already loaded" warnings from the default httpd module configs.
  if ! grep -qr "mod_proxy_wstunnel" /etc/httpd/conf.modules.d/ 2>/dev/null; then
    cat > /etc/httpd/conf.modules.d/00-rads-proxy.conf <<'EOF'
LoadModule proxy_module           modules/mod_proxy.so
LoadModule proxy_http_module      modules/mod_proxy_http.so
LoadModule proxy_html_module      modules/mod_proxy_html.so
LoadModule proxy_wstunnel_module  modules/mod_proxy_wstunnel.so
LoadModule rewrite_module         modules/mod_rewrite.so
LoadModule headers_module         modules/mod_headers.so
EOF
    step_ok "Proxy module conf written"
  else
    step_ok "Proxy modules already loaded — skipping"
  fi

  # ── VirtualHost config ───────────────────────────────────────
  cat > "$CONF" <<'APACHECONF'
# ── RADS-WEB Apache VirtualHost ─────────────────────────────────
# Listen 443 normally comes from ssl.conf — declare it here since
# we disable that file to avoid VirtualHost conflicts.
Listen 443 https

# HTTP → HTTPS redirect (port 80)
<VirtualHost *:80>
    RewriteEngine On
    RewriteRule ^/?(.*) https://%{HTTP_HOST}/$1 [R=301,L]
    ErrorLog  /var/log/httpd/rads-web-error.log
    CustomLog /var/log/httpd/rads-web-access.log combined
</VirtualHost>

# HTTPS VirtualHost (port 443)
<VirtualHost *:443>
    DocumentRoot "/opt/rads-web/ui"
    DirectoryIndex index.html login.html

    # SSL
    SSLEngine             On
    SSLCertificateFile    /etc/pki/tls/certs/rads-web.crt
    SSLCertificateKeyFile /etc/pki/tls/private/rads-web.key
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:HIGH:!aNULL:!MD5:!3DES
    SSLHonorCipherOrder   On
    SSLSessionTickets     Off

    # Security headers
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains"
    Header always set X-Frame-Options            "SAMEORIGIN"
    Header always set X-Content-Type-Options     "nosniff"
    Header always set Referrer-Policy            "strict-origin-when-cross-origin"

    <Directory "/opt/rads-web/ui">
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ProxyRequests    Off
    ProxyPreserveHost On

    # API routes like /api/sites/subnets/{cidr} carry a literal "/" (from
    # the CIDR) URL-encoded as %2F in the path — e.g. editing or deleting
    # 192.168.245.0/24 hits /api/sites/subnets/192.168.245.0%2F24. Apache's
    # default AllowEncodedSlashes (Off) 404s any request URI containing an
    # encoded slash before it ever reaches ProxyPass/mod_proxy, so PATCH/DELETE
    # on subnets silently failed (POST/GET without a CIDR in the path were
    # unaffected). Must be On for those routes to reach the backend at all.
    AllowEncodedSlashes On

    # WebSocket PTY terminal — must come before the /api/ catch-all
    ProxyPass        /ws/ ws://127.0.0.1:8000/ws/
    ProxyPassReverse /ws/ ws://127.0.0.1:8000/ws/

    # Logout (not under /api/, needs explicit rule)
    ProxyPass        /logout http://127.0.0.1:8000/logout
    ProxyPassReverse /logout http://127.0.0.1:8000/logout

    # All API routes
    ProxyPass        /api/ http://127.0.0.1:8000/api/
    ProxyPassReverse /api/ http://127.0.0.1:8000/api/

    ErrorLog  /var/log/httpd/rads-web-ssl-error.log
    CustomLog /var/log/httpd/rads-web-ssl-access.log combined
</VirtualHost>
APACHECONF

  # ── Syntax check ─────────────────────────────────────────────
  local syntax_out; syntax_out=$(apachectl configtest 2>&1)
  echo "$syntax_out" | grep -q "Syntax OK" \
    && step_ok "Apache config syntax OK" \
    || { step_fail "Apache config syntax error:"; echo "$syntax_out"; return 1; }

  systemctl enable --now httpd >>"$log" 2>&1
  systemctl restart httpd      >>"$log" 2>&1

  systemctl is-active --quiet httpd \
    && step_ok "Apache (httpd) running with SSL" \
    || step_fail "Apache failed to start — see /var/log/httpd/error_log"
  sleep 1
}
# =============================================================
# STEP 24 — RADS-WEB SYSTEMD SERVICE
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
# STEP 25 — FAIL2BAN
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
# STEP 26 — RADS-WEB PLATFORM UPDATE CHECK
# =============================================================
install_rads_update_check() {
  section "RADS-WEB Update Check"
  local log="$LOGDIR/rads-update-check.log"; : > "$log"
  local CHECK_SCRIPT="${INSTALL_BASE}/upgrade/update_check.sh"

  if [[ ! -x "$CHECK_SCRIPT" ]]; then
    step_fail "update_check.sh not found at ${CHECK_SCRIPT} — skipping timer setup"
    step_info "Platform Updates card will still work manually from the UI"
    return 0
  fi

  cat > /etc/systemd/system/rads-update-check.service <<EOF
[Unit]
Description=RADS-WEB Update Check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT}
User=root
StandardOutput=journal
StandardError=journal
EOF
  cat > /etc/systemd/system/rads-update-check.timer <<'EOF'
[Unit]
Description=RADS-WEB Daily Update Check
Requires=rads-update-check.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >>"$log" 2>&1
  systemctl enable --now rads-update-check.timer >>"$log" 2>&1

  if systemctl is-active --quiet rads-update-check.timer; then
    step_ok "rads-update-check.timer enabled (runs daily, checks fumatchu/RADS_WEB)"
  else
    step_fail "rads-update-check.timer failed to start — see ${log}"
  fi

  # Run one check now so the Platform Updates card has fresh state on first login
  bash "$CHECK_SCRIPT" >>"$log" 2>&1 || true
  sleep 1
}
# =============================================================
# STEP 27 — MONITORING SCRIPT
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
# STEP 28 — DNF AUTOMATIC SECURITY UPDATES
# =============================================================
configure_dnf_automatic() {
  section "DNF Automatic Security Updates"
  local log="$LOGDIR/dnf-automatic.log"
  : > "$log"

  # ── Write automatic.conf ──────────────────────────────────────
  cat > /etc/dnf/automatic.conf <<'EOF'
[commands]
# Security updates only — versionlocked packages (Samba) are skipped automatically
upgrade_type = security
random_sleep = 0
download_updates = yes
apply_updates = yes

[emitters]
system_name = None
emit_via = motd, stdio

[email]
email_from = root@localhost
email_to = root
email_host = localhost

[base]
debuglevel = 1
EOF

  step_ok "dnf-automatic configured (security updates only, auto-apply)"
  step_info "Versionlocked Samba packages will be skipped automatically"

  # ── Enable the install timer ──────────────────────────────────
  # dnf-automatic-install.timer: checks, downloads, and applies updates daily
  systemctl enable --now dnf-automatic-install.timer >>"$log" 2>&1

  if systemctl is-active --quiet dnf-automatic-install.timer; then
    step_ok "dnf-automatic-install.timer enabled (runs daily)"
  else
    step_fail "dnf-automatic-install.timer failed to start — see ${log}"
  fi

  sleep 1
}

# =============================================================
# STEP 29 — LOGIN BANNER
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
# STEP 30 — FINAL REPORT
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
  echo ""; echo -e "  ${CYAN}Active Directory:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Realm:     ${AD_REALM}"
  echo -e "  ${YELLOW}→${TEXTRESET}  DC FQDN:   ${FQDN}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Admin:     Administrator@${AD_REALM}"
  echo ""; echo -e "  ${CYAN}Access Points:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  RADS-WEB:  https://${MY_IP}/"
  echo -e "  ${YELLOW}→${TEXTRESET}  API logs:  journalctl -u rads-web -f"
  echo -e "  ${YELLOW}→${TEXTRESET}  Installer: ${LOGDIR}/"
  echo ""; echo -e "  ${CYAN}Next Steps:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Log in at https://${MY_IP}/ with your root credentials"
  echo ""
  echo -e "  ${GREEN}RADS-WEB installation complete.${TEXTRESET}"
  echo ""
  # Clean up auto-resume from .bash_profile
  sed -i '/## RADS-WEB Installer — auto-resume after reboot ##/,/^fi$/d' /root/.bash_profile 2>/dev/null || true
}
# =============================================================
# STEP 31 — CLEANUP
# =============================================================
cleanup_install_artifacts() {
  section "Cleanup"
  # Everything removed here is scratch space from building Samba or running
  # this installer — none of it is needed once samba/samba-dc are actually
  # built and installed. Only reached after every prior step in main()
  # succeeded (anything earlier that fails calls exit 1 directly), so this
  # never runs on a failed/partial install where these dirs are exactly what
  # you'd want left behind to debug.
  #
  # Deliberately NOT touched:
  #   /var/lib/mock/*        — mock's own cache. build_samba_from_srpm()'s
  #                            cached-RPM check and the Samba Updates
  #                            rebuild/rollback pipeline in the web UI both
  #                            read from here; wiping it would force a full
  #                            15-30 min rebuild next time for no reason.
  #   /var/log/rads-installer — this run's logs; kept for post-install review.
  #   /root/anaconda-ks.cfg   — pre-existing OS install file, not ours.
  cd /root 2>/dev/null || cd / 2>/dev/null || true
  rm -rf /root/RADS_WEBInstaller
  rm -rf /root/rpmbuild
  rm -rf /root/samba-dc-stubs
  rm -rf /root/samba-srpm
  step_ok "Removed installer clone and Samba build scratch directories"
  sleep 1
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
  generate_ssl_cert
  configure_apache
  install_rads_service
  configure_fail2ban
  install_rads_update_check
  install_samba_monitor
  configure_dnf_automatic
  update_issue_file
  final_status_report
  cleanup_install_artifacts
}
main
