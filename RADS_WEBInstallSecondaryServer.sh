#!/usr/bin/env bash
# RADS-WEB Installer — Secondary/Tertiary Domain Controller (join existing forest)
# Rocky Active Directory Server — Web Edition
# Requires: Rocky Linux 10.0+, run as root
#
# This is the "join" counterpart to RADS_WEBInstallFirstServer.sh. It shares
# that script's structure, output helpers, and — critically — its corrected
# mock/Samba build logic (--isolation=simple, dynamic SRPM version detection,
# stale-SRPM cleanup) verbatim. The parts that differ are exactly the parts
# that have to differ for a second/third DC: instead of provisioning a new
# forest, this validates and joins an existing one (ported from the legacy
# DC1-Install.sh join flow in fumatchu/RADS, restyled to match FirstServer's
# CLI look and feel and logging conventions).
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
      --msgbox "Samba is already running on this system.\n\nJoining an additional DC requires a clean OS install — start fresh.\n\nIf Samba is already configured, you can install just the Web UI by running:\n  bash ${SRC_BASE}/install-webui-only.sh" \
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
          --inputbox "DHCP detected on '${INTERFACE}'\n\nEnter static IP in CIDR format (e.g., 192.168.1.101/24):" \
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
          --inputbox "Enter DNS server IP (the existing AD DC is usually correct here):" 9 70 3>&1 1>&2 2>&3)
        validate_ip "$DNSSERVER" && break || dialog --msgbox "Invalid IP. Try again." 6 40
      done
      while true; do
        HOSTNAME=$(dialog --backtitle "Network Setup" --title "FQDN" \
          --inputbox "Enter FQDN for this server (e.g., dc2.corp.local) — must be in the target AD domain:" 8 75 3>&1 1>&2 2>&3)
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
  /root/RADS_WEBInstaller/RADS_WEBInstallSecondaryServer.sh
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
        --inputbox "Current hostname is '${current}'.\nEnter FQDN (e.g., dc2.corp.local) — must be in the target AD domain:" \
        8 70 3>&1 1>&2 2>&3)
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
# STEP 7.5 — VALIDATION PREREQUISITES
# validate_ad_server() and validate_ad_admin_password() below need `dig`/
# `host` (bind-utils) and `ldapwhoami` (openldap-clients) — but the full
# base-package install doesn't run until STEP 13, well after this. On a
# fresh minimal Rocky install the only things present at this point are the
# bootstrap deps from RADS_WEB-Installer.sh (wget/git/ipcalc/dialog), so
# every validation check would silently fail with "command not found"
# rather than actually testing the target DC. DC1-Install.sh had the same
# ordering requirement via its own install_requirements() step — this is
# that step, ported forward so DC/credential validation can fail fast
# before the ~10+ minutes of system upgrade and base package install.
# =============================================================
install_validation_deps() {
  section "Validation Prerequisites"
  local log="$LOGDIR/validation-deps.log"; : > "$log"
  step_info "Installing tools needed to validate the existing DC (bind-utils, openldap-clients)..."
  dnf -y install bind-utils openldap-clients --setopt=install_weak_deps=False --color=never >>"$log" 2>&1
  if [[ $? -eq 0 ]] && command -v dig >/dev/null 2>&1 && command -v host >/dev/null 2>&1 && command -v ldapwhoami >/dev/null 2>&1; then
    step_ok "bind-utils + openldap-clients installed"
  else
    step_fail "Failed to install validation prerequisites — see ${log}"
    exit 1
  fi
  sleep 1
}
# =============================================================
# STEP 8 — VALIDATE EXISTING DOMAIN CONTROLLER
# (ported from DC1-Install.sh's validate_ad_server — DNS/ping/LDAP SRV/
# Kerberos SRV checks against the pre-existing DC this server will join)
# =============================================================
validate_ad_server() {
  while true; do
    ADDC=$(dialog --backtitle "RADS-WEB Installer" --title "Existing Domain Controller" \
      --inputbox "Enter the FQDN of an existing, reachable AD Domain Controller to join\n(e.g., dc1.corp.local):" \
      9 74 3>&1 1>&2 2>&3)
    local RC=$?
    clear
    if [[ $RC -ne 0 ]]; then
      step_fail "Cancelled by user"
      exit 1
    fi
    if [[ -z "$ADDC" ]]; then
      dialog --msgbox "The FQDN cannot be blank." 6 50
      continue
    fi

    step_info "Validating ${ADDC}..."
    local dns_ok=0 ping_ok=0 ldap_ok=0 krb_ok=0 ip domain
    ip=$(dig +short "$ADDC" 2>/dev/null | head -n1)
    if [[ -n "$ip" ]]; then step_ok "DNS resolved: ${ADDC} → ${ip}"; dns_ok=1
    else step_fail "DNS resolution failed for ${ADDC}"; fi

    if [[ $dns_ok -eq 1 ]] && ping -c 1 -W 2 "$ip" &>/dev/null; then
      step_ok "Ping successful to ${ip}"; ping_ok=1
    else
      step_fail "Ping to ${ip:-$ADDC} failed"
    fi

    domain="${ADDC#*.}"
    if host -t SRV "_ldap._tcp.${domain}" 2>/dev/null | grep -qi "$ADDC"; then
      step_ok "LDAP SRV record found for ${ADDC}"; ldap_ok=1
    else
      step_fail "LDAP SRV record not found for ${ADDC}"
    fi
    if host -t SRV "_kerberos._udp.${domain}" 2>/dev/null | grep -qi "$ADDC"; then
      step_ok "Kerberos SRV record found for ${ADDC}"; krb_ok=1
    else
      step_fail "Kerberos SRV record not found for ${ADDC}"
    fi

    if [[ $dns_ok -eq 1 && $ping_ok -eq 1 && $ldap_ok -eq 1 && $krb_ok -eq 1 ]]; then
      DC_IP_ADDRESS="$ip"
      DOMAIN="$domain"
      export ADDC DC_IP_ADDRESS DOMAIN
      step_ok "Existing DC validated: ${ADDC} (${DOMAIN})"
      sleep 1
      break
    else
      dialog --backtitle "RADS-WEB Installer" --title "Validation Failed" \
        --yesno "One or more checks failed for ${ADDC}.\n\nTry a different FQDN?" 8 60
      [[ $? -ne 0 ]] && { step_fail "Cannot continue without a valid existing Domain Controller"; exit 1; }
    fi
  done
}
# =============================================================
# STEP 9 — VALIDATE ADMINISTRATOR CREDENTIALS
# (ported from DC1-Install.sh's validate_ad_admin_password — LDAPS bind
# test against the existing DC before any packages are touched)
# =============================================================
validate_ad_admin_password() {
  while true; do
    AD_ADMIN_PASS=$(dialog --backtitle "RADS-WEB Installer" --title "Administrator Password" \
      --insecure --passwordbox "Enter the password for Administrator@${DOMAIN}:" 9 65 3>&1 1>&2 2>&3)
    local RC=$?
    clear
    if [[ $RC -ne 0 ]]; then
      step_fail "Cancelled by user"
      exit 1
    fi
    if [[ -z "$AD_ADMIN_PASS" ]]; then
      dialog --msgbox "Password cannot be blank." 6 50
      continue
    fi
    step_info "Validating Administrator credentials against ${DC_IP_ADDRESS}..."
    if LDAPTLS_REQCERT=never ldapwhoami -x -H "ldaps://${DC_IP_ADDRESS}" \
         -D "Administrator@${DOMAIN}" -w "$AD_ADMIN_PASS" >/tmp/rads-ldap-test.out 2>&1; then
      step_ok "Administrator credentials validated"
      export AD_ADMIN_PASS
      sleep 1
      break
    else
      local err; err=$(tail -n1 /tmp/rads-ldap-test.out)
      step_fail "Authentication failed: ${err}"
      dialog --backtitle "RADS-WEB Installer" --title "Authentication Failed" \
        --yesno "Could not authenticate as Administrator@${DOMAIN}.\n\n${err}\n\nTry again?" 10 65
      [[ $? -ne 0 ]] && exit 1
    fi
  done
  rm -f /tmp/rads-ldap-test.out
}
# =============================================================
# STEP 10 — DOMAIN JOIN CONFIGURATION (upfront)
# =============================================================
gather_secondary_ad_config() {
  section "Active Directory — Join Existing Domain"
  # Only 2 items — no "hostname already set in the domain" prerequisite:
  # this server joins itself. samba-tool domain join registers the
  # computer object and DNS records as part of the join, it isn't
  # something that has to exist beforehand.
  #
  # Every line here is kept well under the 76-col box width on purpose.
  # dialog reflows text near the edge of that width unpredictably — a line
  # that's only a couple chars under 76 was getting silently re-wrapped by
  # dialog itself (independent of, and colliding with, the manual \n
  # breaks below), which is what produced the mid-word "tha t domain" and
  # orphaned "an" line seen before. Keeping real slack between line length
  # and box width means dialog never needs to auto-wrap anything — the \n
  # placements below are the only line breaks that end up happening.
  dialog --backtitle "RADS-WEB Installer" --title "Before You Begin" --msgbox "\
This installs RADS-WEB and joins this server to an\nexisting AD forest as an additional Domain Controller.\n\nYou will need:\n\n  1. The FQDN of an existing, reachable Domain Controller\n  2. The Administrator password for that domain\n" 13 76
  clear
  section "Active Directory — Join Existing Domain"
  validate_ad_server
  validate_ad_admin_password
  AD_REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')
  AD_DOMAIN=$(echo "$AD_REALM" | cut -d. -f1)
  NTP_SERVER="$ADDC"
  export AD_REALM AD_DOMAIN NTP_SERVER
  step_ok "Will join: ${AD_REALM} (${AD_DOMAIN}) via ${ADDC}"
  sleep 1
}
# =============================================================
# STEP 11 — REPOS
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

  step_info "Enabling CRB repository..."
  dnf config-manager --set-enabled crb --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable crb >>"$log" 2>&1 || true
  step_ok "CRB repository enabled"

  step_info "Enabling Devel repository..."
  dnf config-manager --set-enabled devel --color=never >>"$log" 2>&1 \
    || dnf config-manager --enable devel >>"$log" 2>&1 || true
  step_ok "Devel repository enabled"

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
# STEP 12 — SYSTEM UPGRADE
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
# STEP 13 — BASE PACKAGES
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
  dnf remove -y 'cockpit*' >>"$log" 2>&1 || true
  step_info "Cockpit removed (not needed)"
  sleep 1
}
# =============================================================
# STEP 14 — VM GUEST TOOLS
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
# STEP 15 — NTP / CHRONY
# (syncs from the existing DC being joined, rather than pool.ntp.org — set
# as NTP_SERVER=$ADDC in gather_secondary_ad_config(). Otherwise identical
# to FirstServer's configure_ntp().)
# =============================================================
configure_ntp() {
  section "NTP / Chrony"
  local log="$LOGDIR/ntp.log"; : > "$log"
  cp /etc/chrony.conf /etc/chrony.conf.bak 2>/dev/null || true
  sed -i '/^\(server\|pool\)[[:space:]]/d' /etc/chrony.conf
  echo "server ${NTP_SERVER} iburst" >> /etc/chrony.conf
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
# STEP 16 — FIREWALL
# =============================================================
configure_firewall() {
  section "Firewall"
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
# STEP 17 — SELINUX FOR SAMBA
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
# STEP 18 — BUILD SAMBA FROM SRPM (Rocky 10)
# Identical to RADS_WEBInstallFirstServer.sh's build_samba_from_srpm() —
# same mock --isolation=simple fix, dynamic SRPM version detection, and
# stale-SRPM cleanup before download. Building Samba doesn't differ between
# a first DC and a joining DC, only what happens after (provision vs join).
# =============================================================
build_samba_from_srpm() {
  section "Building Samba from SRPM (Rocky 10)"
  local log="$LOGDIR/samba-build.log"; : > "$log"
  local MOCK_CFG="rocky-10-x86_64"
  local MOCK_RESULT="/var/lib/mock/${MOCK_CFG}/result"
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
      _install_samba_rpms "${CACHED_RPMS[@]}"
      return
    else
      step_info "Rebuilding from scratch as requested..."
    fi
  fi
  # ── Build prerequisites: NOT installed on host, intentionally ────────────
  # See RADS_WEBInstallFirstServer.sh for the full incident writeup. Short
  # version: a host-level BUILD_DEPS install (@development-tools + a pile of
  # -devel headers) followed by an "appliance hardening" removal step caused
  # dnf's solver to cascade-erase samba-dc/samba-tools/python3-samba/
  # krb5-server/avahi/certmonger/cepces on two separate fresh installs — a
  # --setopt=protected_packages guard did NOT stop it either. mock resolves
  # 100% of Samba's BuildRequires itself inside its own isolated chroot
  # (config_opts['dnf_builddep_opts'] below), so none of this was ever
  # load-bearing for the compile — it was also the exact package class behind
  # the original `dnf update` deadlock incident (exact-NVR-pinned against
  # glibc/glib2 from the devel repo). Skipping the install here closes both
  # bugs and leaves nothing to clean up afterward.
  step_ok "Build dependencies resolved by mock inside its isolated chroot (nothing installed on host)"
  step_info "Setting up mock build environment for Rocky 10..."
  usermod -a -G mock root >>"$log" 2>&1 || true
  local SRPM_DIR="/root/samba-srpm"
  mkdir -p "$SRPM_DIR"
  # Clear out any SRPM left from a prior run before downloading a fresh one —
  # see RADS_WEBInstallFirstServer.sh for the full rationale (alphabetical
  # `ls | head -1` picking a stale point-release SRPM otherwise).
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
  local SRPM_DIST; SRPM_DIST=$(rpm -qp --qf '%{RELEASE}' "$SRPM_FILE" 2>/dev/null \
    | grep -oP '\.el\d+[^.]*$' || echo ".el10")
  local MOCK_DIST="${SRPM_DIST}.dc"
  step_info "Using dist tag: ${MOCK_DIST}"
  # Detected off the SRPM, not hardcoded — see FirstServer for rationale.
  local SRPM_VERSION; SRPM_VERSION=$(rpm -qp --qf '%{VERSION}' "$SRPM_FILE" 2>/dev/null)
  if [[ -z "$SRPM_VERSION" ]]; then
    step_fail "Could not determine Samba version from SRPM — aborting rather than guess"
    exit 1
  fi
  step_info "Detected Samba version: ${SRPM_VERSION}"
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
  step_info "Building Samba RPMs with mock (this takes 15-30 minutes)..."
  echo ""
  echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────────┐${TEXTRESET}"
  echo -e "${CYAN}  │  mock build output — streaming live                         │${TEXTRESET}"
  echo -e "${CYAN}  │  Full log: ${log}${TEXTRESET}"
  echo -e "${CYAN}  └─────────────────────────────────────────────────────────────┘${TEXTRESET}"
  echo ""
  sleep 2
  # --isolation=simple: mock's systemd-nspawn default needs nested
  # mount-namespace support many hypervisors don't fully pass through to the
  # guest, failing with "Failed to mount /proc/sys ... Child died too
  # early." Plain chroot isolation works in VMs where nspawn doesn't. Same
  # fix as FirstServer and api/samba_update.py's rebuild pipeline.
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
    dnf -y install --exclude=samba-dc-bind-dlz samba samba-dc samba-client samba-common-tools \
      samba-winbind samba-winbind-clients >>"$log" 2>&1
    [[ $? -eq 0 ]] && step_ok "Samba installed via dnf fallback" \
      || { step_fail "All Samba install methods failed"; exit 1; }
    return
  fi
  local ALL_RPMS=()
  for rpm in "${MOCK_RESULT}"/*.rpm; do
    [[ "$rpm" == *src.rpm ]]    && continue
    [[ "$rpm" == *debuginfo* ]] && continue
    [[ "$rpm" == *debugsource* ]] && continue
    [[ "$rpm" == *samba-dc-bind-dlz* ]] && continue
    [[ -f "$rpm" ]] && ALL_RPMS+=("$rpm")
  done
  _install_samba_rpms "${ALL_RPMS[@]}"
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
  mkdir -p /etc/samba-rads
  local SAMBA_NVR; SAMBA_NVR=$(rpm -q samba --qf '%{NAME}-%{VERSION}-%{RELEASE}' 2>/dev/null | head -1)
  echo "$SAMBA_NVR" > /etc/samba-rads/installed-version
  dnf versionlock list 2>/dev/null \
    | grep -E '^(samba|lib(ldb|talloc|tevent|tdb|wbclient))' \
    > /etc/samba-rads/locked-packages || true
  step_ok "Version recorded: ${SAMBA_NVR}"
  local _smbd_src _smbd_dst _pyver
  _pyver=$(python3 -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')" 2>/dev/null)
  _smbd_src=$(ls /usr/lib64/python3*/site-packages/samba/samba3/smbd.cpython-*.so 2>/dev/null | head -1)
  _smbd_dst=$(echo "$_smbd_src" | sed 's|/samba3/|/|')
  if [[ -f "$_smbd_src" && ! -f "$_smbd_dst" ]]; then
    ln -sf "$_smbd_src" "$_smbd_dst"
    step_ok "Linked samba.smbd Python extension into correct path"
  elif [[ -f "$_smbd_dst" ]]; then
    step_ok "samba.smbd already in place"
  else
    step_info "samba.smbd not found in samba3/ — join may fail"
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
# STEP 19 — JOIN EXISTING SAMBA AD DOMAIN
# (ported from DC1-Install.sh's configure_samba_provisioning join tail —
# replaces FirstServer's provision_samba_ad(). Reuses FirstServer's
# systemd-run wrapper, krb5.conf/kdc.conf recovery, and DNS-to-self logic,
# since a join can hit the same TALLOC mmap-fragmentation MemoryError as a
# fresh provision after 20-30 minutes of installer activity.)
# =============================================================
join_samba_ad() {
  section "Samba AD Domain Join"
  local log="$LOGDIR/samba-join.log"; : > "$log"
  local FQDN; FQDN=$(hostname)
  step_info "Joining ${FQDN} to ${AD_REALM} as an additional Domain Controller..."
  step_info "Existing DC: ${ADDC} (${DC_IP_ADDRESS})"

  systemctl stop samba smb nmb winbind 2>/dev/null || true
  pkill -9 -x smbd   2>/dev/null || true
  pkill -9 -x nmbd   2>/dev/null || true
  pkill -9 -x samba  2>/dev/null || true
  sleep 1

  local _mnt _fstype
  _mnt=$(df /var/lib/samba 2>/dev/null | awk 'NR==2{print $NF}')
  [[ -z "$_mnt" ]] && _mnt=$(df /var 2>/dev/null | awk 'NR==2{print $NF}')
  [[ -z "$_mnt" ]] && _mnt="/"
  _fstype=$(findmnt -n -o FSTYPE "$_mnt" 2>/dev/null)
  if [[ "$_fstype" == "ext4" || "$_fstype" == "ext3" || "$_fstype" == "ext2" ]]; then
    step_info "Enabling ACL+xattr on ${_mnt} (${_fstype})..."
    mount -o remount,acl,user_xattr "$_mnt" >>"$log" 2>&1 && step_ok "Remounted ${_mnt} with acl,user_xattr" || true
    if ! grep -qP "^\S+\s+${_mnt}\s+\S+\s+[^#]*\bacl\b" /etc/fstab 2>/dev/null; then
      sed -i -E "s|^([^#]\S+\s+${_mnt}\s+\S+\s+)(\S+)|\1\2,acl,user_xattr|" /etc/fstab
      step_ok "Updated /etc/fstab with acl,user_xattr for ${_mnt}"
    fi
  fi

  [[ -f /etc/samba/smb.conf ]] && mv -f /etc/samba/smb.conf /etc/samba/smb.bak.orig

  local _join_log="${log%/*}/samba-join.log"
  echo "[join] realm=${AD_REALM} existing_dc=${ADDC}" > "$_join_log"
  systemd-run --wait \
    --unit="samba-join-$$" \
    --description="Samba AD domain join" \
    --property="StandardOutput=append:${_join_log}" \
    --property="StandardError=append:${_join_log}" \
    -- samba-tool domain join "${AD_REALM}" DC \
      -U"administrator%${AD_ADMIN_PASS}" \
      --realm="${AD_REALM}"
  local JOIN_RC=$?
  [[ "$_join_log" != "$log" ]] && cat "$_join_log" >> "$log"

  if [[ $JOIN_RC -ne 0 ]] || grep -qi "^ERROR" "$_join_log"; then
    step_fail "Samba AD domain join failed — see ${_join_log}"
    dialog --title "Join Failed" --msgbox "Samba AD domain join failed.\nSee: ${_join_log}" 8 65
    exit 1
  fi
  step_ok "Joined domain ${AD_REALM} as additional DC"

  # ── Kerberos — install krb5.conf before starting Samba ─────────────────
  # Same MemoryError-during-a-long-installer-run rationale as FirstServer's
  # provision_samba_ad(): join can also die mid-way through writing
  # private/krb5.conf, so fall back to the Samba setup template if needed.
  if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    \cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
    step_ok "Kerberos config installed from join output"
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
  if [[ -f /etc/krb5.conf ]]; then
    if grep -q "^\s*#\s*default_realm\|^\s*default_realm" /etc/krb5.conf; then
      sed -i "s|^\s*#\?\s*default_realm\s*=.*|\\tdefault_realm = ${AD_REALM}|" /etc/krb5.conf
    else
      sed -i "/^\[libdefaults\]/a\\\\tdefault_realm = ${AD_REALM}" /etc/krb5.conf
    fi
    step_ok "Verified default_realm = ${AD_REALM} in /etc/krb5.conf"
  fi
  if [[ ! -f /var/lib/samba/private/krb5.conf ]]; then
    \cp -f /etc/krb5.conf /var/lib/samba/private/krb5.conf
    step_ok "Copied krb5.conf into samba private dir for MIT KDC"
  fi
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

  # ── DNS forwarder ─────────────────────────────────────────────────────
  # samba-tool domain join, unlike domain provision, does not auto-detect
  # and write a "dns forwarder" into smb.conf. Without one, this DC's own
  # internal DNS server — which the NIC gets pointed at next, so every
  # subsequent resolve on this box goes through it — can only answer
  # AD-zone queries. Public names (pypi.org, github.com, ...) fail with
  # "Name or service not known" for every later step: pip installs, the
  # RADS-WEB tarball fetch, dnf, all of it. Point it at the DC we just
  # joined through — already validated reachable in validate_ad_server().
  if [[ -f /etc/samba/smb.conf ]]; then
    if grep -q '^\s*dns forwarder\s*=' /etc/samba/smb.conf; then
      sed -i "s|^\s*dns forwarder\s*=.*|\tdns forwarder = ${DC_IP_ADDRESS}|" /etc/samba/smb.conf
    else
      sed -i "/^\[global\]/a\\\\tdns forwarder = ${DC_IP_ADDRESS}" /etc/samba/smb.conf
    fi
    step_ok "DNS forwarder set to ${DC_IP_ADDRESS} (existing DC) in smb.conf"
  fi

  # ── DNS — point NIC at itself, same as FirstServer ──────────────────────
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

  systemctl enable samba >>"$log" 2>&1 || systemctl enable smb >>"$log" 2>&1
  systemctl start  samba >>"$log" 2>&1 || systemctl start  smb >>"$log" 2>&1
  sleep 3
  if systemctl is-active --quiet samba || systemctl is-active --quiet smb; then
    step_ok "Samba service running"
    samba-tool ntacl sysvolreset >>"$log" 2>&1 && step_ok "Sysvol ACLs reset" || true
  else
    step_fail "Samba failed to start — check ${log} and /var/log/samba/"
  fi
  sleep 1
}
# =============================================================
# STEP 20 — DOMAIN JOIN VERIFICATION
# (combines FirstServer's verify_ad() style output with DC1's DRS
# replication + computer-list checks, which matter specifically for a join)
# =============================================================
verify_join() {
  section "Domain Join Verification"
  local log="$LOGDIR/ad-verify.log"; : > "$log"
  local FQDN; FQDN=$(hostname)
  local HOSTNAME_UPPER; HOSTNAME_UPPER=$(hostname -s | tr '[:lower:]' '[:upper:]')
  step_info "Allowing replication and service initialization to settle..."
  sleep 10
  local all_pass=1

  echo "${AD_ADMIN_PASS}" | kinit "Administrator@${AD_REALM}" >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "Kerberos TGT obtained"
  else step_fail "Kerberos TGT failed"; all_pass=0; fi

  local drs_out; drs_out=$(samba-tool drs showrepl 2>&1); echo "$drs_out" >>"$log"
  if echo "$drs_out" | grep -q "${HOSTNAME_UPPER}"; then
    step_ok "This DC appears in the DRS replication topology"
  else
    step_fail "This DC not found in DRS replication topology"; all_pass=0
  fi
  if echo "$drs_out" | grep -q "Last success"; then
    step_ok "Inbound replication has succeeded at least once"
  else
    step_fail "No successful inbound replication detected yet"; all_pass=0
  fi

  if samba-tool computer list 2>>"$log" | grep -qi "^${HOSTNAME_UPPER}\\\$$"; then
    step_ok "This DC is registered in the domain's computer list"
  else
    step_fail "This DC not found in samba-tool computer list"; all_pass=0
  fi

  ldapsearch -H "ldap://${FQDN}" -x -b "" -s base >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "Anonymous LDAP query successful"
  else step_fail "Anonymous LDAP query failed"; all_pass=0; fi

  samba-tool user list >>"$log" 2>&1
  if [[ $? -eq 0 ]]; then step_ok "samba-tool user list successful"
  else step_fail "samba-tool user list failed"; all_pass=0; fi

  if [[ $all_pass -eq 1 ]]; then
    step_ok "All domain join verification checks passed"
  else
    step_info "Some checks failed — replication may still be catching up, check ${log}"
  fi
  sleep 2
}
# =============================================================
# STEP 20.5 — FORCE INITIAL REPLICATION (inbound to this DC only)
#
# Background (found the hard way on a live join): after a new DC joins,
# the *existing* DC's KCC often auto-discovers it and attempts to open a
# replication link before the new DC has fully settled (SYSVOL reset,
# services up, DNS propagated). If that premature attempt happens, the
# existing DC's long-running samba daemon can cache a bad DRS credential
# for the new DC and keep replaying it — every later
# `samba-tool drs replicate <existingDC> <newDC> <NC>` then fails with
# WERR_GEN_FAILURE, silently, with nothing useful in either side's logs.
# The only fix found was `systemctl restart samba` on the EXISTING DC to
# force it to drop that cached credential and re-authenticate fresh.
#
# This installer runs on the NEW DC and has no remote-exec access to the
# existing DC ($ADDC), so it can't detect or fix that side. What it CAN
# do reliably is force the INBOUND direction — this DC pulling from
# $ADDC — since that only depends on this box's own daemon, which
# join_samba_ad() just (re)started fresh a few steps up and so can't yet
# be carrying stale cached credentials. Forcing it here catches problems
# early and shaves time off the KCC's natural settle period, rather than
# just hoping verify_join()'s 10-second sleep was long enough.
#
# The OUTBOUND direction ($ADDC pulling from this DC) is deliberately NOT
# forced from here — that's the exact direction that broke in testing,
# and forcing it from the new DC's side wouldn't fix a stale cache on
# $ADDC's daemon anyway. That gets called out explicitly to the operator
# in final_status_report() instead of silently assumed fixed.
# =============================================================
force_initial_replication() {
  section "Forcing Initial Replication (inbound)"
  local log="$LOGDIR/drs-force-replicate.log"; : > "$log"
  local SELF; SELF=$(hostname -s)
  local ADDC_SHORT="${ADDC%%.*}"
  local BASE_DN="DC=${DOMAIN//./,DC=}"
  local NCS=(
    "${BASE_DN}"
    "CN=Configuration,${BASE_DN}"
    "CN=Schema,CN=Configuration,${BASE_DN}"
    "DC=DomainDnsZones,${BASE_DN}"
    "DC=ForestDnsZones,${BASE_DN}"
  )
  local all_ok=1
  for nc in "${NCS[@]}"; do
    if samba-tool drs replicate "${SELF}" "${ADDC_SHORT}" "${nc}" >>"$log" 2>&1; then
      step_ok "Replicated inbound: ${nc}"
    else
      step_fail "Inbound replication failed for: ${nc} (see ${log})"
      all_ok=0
    fi
  done
  if [[ $all_ok -eq 1 ]]; then
    step_ok "All 5 naming contexts replicated inbound successfully"
  else
    step_info "Some NCs failed to force-replicate — KCC will retry automatically, but check ${log}"
  fi
  sleep 1
}
# =============================================================
# STEP 21 — INSTALL PYTHON + FASTAPI
# =============================================================
install_python_packages() {
  section "Python / FastAPI"
  local log="$LOGDIR/python.log"; : > "$log"
  cd /root || cd /tmp
  step_info "Upgrading pip..."
  python3 -m pip install --upgrade pip setuptools wheel --break-system-packages >>"$log" 2>&1
  local PACKAGES=(
    "fastapi"
    "uvicorn[standard]"
    "python-multipart"
    "python-pam"
    "aiofiles"
    "python-dotenv"
  )
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
# STEP 22 — DEPLOY RADS-WEB APP
# =============================================================
deploy_rads_web() {
  section "Deploy RADS-WEB Application"
  local log="$LOGDIR/deploy.log"; : > "$log"
  local TARBALL_URL="https://github.com/fumatchu/RADS_WEB/releases/latest/download/rads-web.tar.gz"
  local TARBALL="/tmp/rads-web.tar.gz"
  step_info "Downloading application package from GitHub Releases..."
  wget -q -O "$TARBALL" "$TARBALL_URL" 2>>"$log"
  if [[ $? -ne 0 || ! -s "$TARBALL" ]]; then
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
  mkdir -p "${INSTALL_BASE}/data" "${INSTALL_BASE}/logs" "${INSTALL_BASE}/state" "${INSTALL_BASE}/tools"
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
# STEP 23 — SELINUX FOR RADS-WEB
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
# STEP 24 — GENERATE SELF-SIGNED TLS CERTIFICATE
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

  local DEFAULT_SSL="/etc/httpd/conf.d/ssl.conf"
  local OLD_DISABLED="${DEFAULT_SSL}.disabled"

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

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -v "$CERT" "$KEY" >>"$log" 2>&1 || true
    step_ok "SELinux context restored on cert/key"
  fi

  sleep 1
}
# =============================================================
# STEP 25 — APACHE VIRTUALHOST (HTTPS)
# =============================================================
configure_apache() {
  section "Apache VirtualHost (HTTPS)"
  local log="$LOGDIR/apache.log"; : > "$log"
  local CONF="/etc/httpd/conf.d/rads-web.conf"

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
# STEP 26 — RADS-WEB SYSTEMD SERVICE
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
# STEP 27 — FAIL2BAN
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
# STEP 28 — RADS-WEB PLATFORM UPDATE CHECK
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

  bash "$CHECK_SCRIPT" >>"$log" 2>&1 || true
  sleep 1
}
# =============================================================
# STEP 29 — MONITORING SCRIPT
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
AVAIL_VER=$(dnf info --available samba 2>/dev/null \
  | awk '/^Version[[:space:]]*:/{ver=$3} /^Release[[:space:]]*:/{rel=$3} END{if(ver && rel) print "samba-"ver"-"rel}')
if [[ -z "$AVAIL_VER" ]]; then
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
# STEP 30 — DNF AUTOMATIC SECURITY UPDATES
# =============================================================
configure_dnf_automatic() {
  section "DNF Automatic Security Updates"
  local log="$LOGDIR/dnf-automatic.log"
  : > "$log"

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

  systemctl enable --now dnf-automatic-install.timer >>"$log" 2>&1

  if systemctl is-active --quiet dnf-automatic-install.timer; then
    step_ok "dnf-automatic-install.timer enabled (runs daily)"
  else
    step_fail "dnf-automatic-install.timer failed to start — see ${log}"
  fi

  sleep 1
}
# =============================================================
# STEP 31 — LOGIN BANNER
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
# STEP 32 — FINAL REPORT
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
  echo -e "  ${YELLOW}→${TEXTRESET}  Realm:       ${AD_REALM}"
  echo -e "  ${YELLOW}→${TEXTRESET}  DC FQDN:     ${FQDN}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Joined via:  ${ADDC}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Admin:       Administrator@${AD_REALM}"
  echo ""; echo -e "  ${CYAN}Access Points:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  RADS-WEB:  https://${MY_IP}/"
  echo -e "  ${YELLOW}→${TEXTRESET}  API logs:  journalctl -u rads-web -f"
  echo -e "  ${YELLOW}→${TEXTRESET}  Installer: ${LOGDIR}/"
  echo ""; echo -e "  ${CYAN}Next Steps:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Log in at https://${MY_IP}/ with your root credentials"
  echo -e "  ${YELLOW}→${TEXTRESET}  Allow a few minutes for sysvol/AD replication to fully catch up"
  echo ""; echo -e "  ${CYAN}Replication — one manual check recommended:${TEXTRESET}"
  echo -e "  ${YELLOW}→${TEXTRESET}  Inbound replication (this DC <- ${ADDC}) was forced and verified above."
  echo -e "  ${YELLOW}→${TEXTRESET}  The reverse direction (${ADDC} -> this DC) depends on ${ADDC}'s own"
  echo -e "  ${YELLOW}→${TEXTRESET}  running daemon state, which this installer can't reach or force from"
  echo -e "  ${YELLOW}→${TEXTRESET}  here. On ${ADDC}, run:  samba-tool drs showrepl"
  echo -e "  ${YELLOW}→${TEXTRESET}  If it shows consecutive failures replicating TO this new DC, it means"
  echo -e "  ${YELLOW}→${TEXTRESET}  ${ADDC} cached a stale credential when it first noticed this DC join —"
  echo -e "  ${YELLOW}→${TEXTRESET}  fix is to run 'systemctl restart samba' on ${ADDC}, then re-check"
  echo -e "  ${YELLOW}→${TEXTRESET}  'samba-tool drs showrepl' on both DCs for 0 consecutive failures."
  echo ""
  echo -e "  ${GREEN}RADS-WEB secondary/tertiary DC installation complete.${TEXTRESET}"
  echo ""
  # Clean up auto-resume from .bash_profile
  sed -i '/## RADS-WEB Installer — auto-resume after reboot ##/,/^fi$/d' /root/.bash_profile 2>/dev/null || true
}
# =============================================================
# STEP 33 — CLEANUP
# =============================================================
cleanup_install_artifacts() {
  section "Cleanup"
  # Same rationale as RADS_WEBInstallFirstServer.sh — only reached after
  # every prior step succeeded. Deliberately NOT touched: /var/lib/mock/*
  # (build cache, used by the Samba Updates rebuild/rollback pipeline),
  # /var/log/rads-installer (this run's logs), /root/anaconda-ks.cfg
  # (not ours).
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
  install_validation_deps
  gather_secondary_ad_config
  enable_repos
  run_system_upgrade
  install_base_packages
  vm_detection
  configure_ntp
  configure_firewall
  configure_selinux_samba
  build_samba_from_srpm
  join_samba_ad
  verify_join
  force_initial_replication
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
