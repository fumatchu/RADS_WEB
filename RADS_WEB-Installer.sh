#!/usr/bin/env bash
# RADS_WEB Bootstrap Installer
# Rocky Active Directory Server — Web Edition
# Requires: Rocky Linux 10.0+, run as root

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
TEXTRESET="\033[0m"
CYAN="\e[36m"
RESET="\e[0m"

clear
echo -e "${CYAN}RADS-WEB${TEXTRESET} ${YELLOW}Bootstrap${TEXTRESET}"

# =============================================================
# ROOT CHECK
# =============================================================
if [[ $EUID -eq 0 ]]; then
  echo -e "  [${GREEN}✓${TEXTRESET}] Running as root"
else
  echo -e "  [${RED}✗${TEXTRESET}] Must be run as root"
  exit 1
fi

# =============================================================
# OS VERSION CHECK  (Rocky 10.0+)
# =============================================================
OSVER_RAW=""
if [[ -f /etc/os-release ]]; then
  OSVER_RAW=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null)
elif [[ -f /etc/redhat-release ]]; then
  OSVER_RAW=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1)
fi

if [[ -z "$OSVER_RAW" ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Unable to detect Rocky Linux version"
  exit 1
fi

OSVER_MAJOR=$(echo "$OSVER_RAW" | awk -F. '{print $1}')
OSVER_MINOR=$(echo "$OSVER_RAW" | awk -F. '{print ($2==""?0:$2)}')

if ! [[ "$OSVER_MAJOR" =~ ^[0-9]+$ ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Cannot parse OS version: ${OSVER_RAW}"
  exit 1
fi

if (( OSVER_MAJOR >= 10 )); then
  echo -e "  [${GREEN}✓${TEXTRESET}] Rocky Linux ${OSVER_MAJOR}.${OSVER_MINOR} detected"
else
  echo -e "  [${RED}✗${TEXTRESET}] Rocky Linux 10.0+ required (detected: ${OSVER_MAJOR}.${OSVER_MINOR})"
  echo -e "  Please upgrade to ${GREEN}Rocky 10.x${TEXTRESET} or later"
  exit 1
fi

# =============================================================
# INSTALL BOOTSTRAP DEPS
# =============================================================
echo -e "${CYAN}==> Installing bootstrap dependencies...${TEXTRESET}"

spinner() {
  local pid=$1 delay=0.1 spinstr='|/-\'
  while ps -p $pid > /dev/null 2>&1; do
    for i in $(seq 0 3); do
      printf "\r  [${YELLOW}INFO${TEXTRESET}] Installing... ${spinstr:$i:1}"
      sleep $delay
    done
  done
  printf "\r  [${GREEN}✓${TEXTRESET}] Bootstrap packages installed   \n"
}

dnf -y install wget git ipcalc dialog >/dev/null 2>&1 &
spinner $!

# =============================================================
# CLONE RADS_WEB REPO
# =============================================================
echo -e "${CYAN}==> Cloning RADS_WEB from GitHub...${TEXTRESET}"

INSTALL_DIR="/root/RADS_WEBInstaller"
rm -rf "$INSTALL_DIR"
git clone https://github.com/fumatchu/RADS_WEB.git "$INSTALL_DIR" >/dev/null 2>&1

if [[ $? -ne 0 ]]; then
  echo -e "  [${RED}✗${TEXTRESET}] Failed to clone RADS_WEB repository"
  echo -e "  Check internet connectivity and try again."
  exit 1
fi

chmod 700 "${INSTALL_DIR}"/*.sh 2>/dev/null || true
echo -e "  [${GREEN}✓${TEXTRESET}] Repository cloned to ${INSTALL_DIR}"

dnf -y remove git >/dev/null 2>&1

# =============================================================
# LAUNCH MAIN INSTALLER
# =============================================================
clear
echo -e "${GREEN}
                               .*((((((((((((((((*
                         .(((((((((((((((((((((((((((/
                      ,((((((((((((((((((((((((((((((((((.
                    (((((((((((((((((((((((((((((((((((((((/
                  (((((((((((((((((((((((((((((((((((((((((((/
                .(((((((((((((((((((((((((((((((((((((((((((((
               ,((((((((((((((((((((((((((((((((((((((((((((((((.
               ((((((((((((((((((((((((((((((/   ,(((((((((((((((
              /((((((((((((((((((((((((((((.        /((((((((((((*
              ((((((((((((((((((((((((((/              ((((((((((
              ((((((((((((((((((((((((                   *((((((/
              /((((((((((((((((((((*                        (((((*
               ((((((((((((((((((             (((*            ,((
               .((((((((((((((.            /(((((((
                 ((((((((((/             (((((((((((((/
                  *((((((.            /((((((((((((((((((.
                    *(*)            ,(((((((((((((((((((((((,
                                 (((((((((((((((((((((((/
                              /((((((((((((((((((((((.
                                ,((((((((((((((,
${RESET}"
echo -e "        ${GREEN}Rocky Linux${RESET} ${CYAN}RADS-WEB${RESET} ${YELLOW}Active Directory Server — Web Edition${TEXTRESET}"
echo ""
sleep 2

# =============================================================
# INSTALL TYPE SELECTION
# =============================================================
INSTALL_CHOICE=$(dialog --backtitle "RADS-WEB Installer" \
  --title "Select Installation Type" \
  --menu "Choose what to install on this server:" 13 72 4 \
  1 "Install First Domain Controller (new AD forest)" \
  3>&1 1>&2 2>&3)
DIALOG_RC=$?
clear

if [[ $DIALOG_RC -ne 0 || -z "$INSTALL_CHOICE" ]]; then
  echo -e "  [${YELLOW}→${TEXTRESET}] Installation cancelled."
  exit 1
fi

case "$INSTALL_CHOICE" in
  1)
    bash "${INSTALL_DIR}/RADS_WEBInstallFirstServer.sh"
    ;;
  *)
    echo -e "  [${YELLOW}→${TEXTRESET}] Installation cancelled."
    exit 1
    ;;
esac

