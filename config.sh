#!/usr/bin/env bash

#UDIS
#v1.0.2
#by mattrattus

set -Eeuo pipefail

handle_error() {
  local exit_code=$?
  local line_number=$1
  local failed_command=$2

  echo "Installation stopped at line ${line_number}: ${failed_command}" >&2
  if [[ -f config.sh || -f ftp.sh ]]; then
    echo "Bootstrap files were left in place." >&2
  else
    echo "Bootstrap files had already been removed during finalization." >&2
  fi
  exit "$exit_code"
}

trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify the operating system: /etc/os-release is unavailable." >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ ${ID:-} != ubuntu || ! ${VERSION_ID:-} =~ ^([0-9]{2})\.04$ ]]; then
  echo "This script supports Ubuntu LTS releases from 24.04 onward." >&2
  exit 1
fi

ubuntu_year=${BASH_REMATCH[1]}
if (( 10#$ubuntu_year < 24 || 10#$ubuntu_year % 2 != 0 )); then
  echo "This script supports Ubuntu LTS releases from 24.04 onward." >&2
  exit 1
fi

for required_file in \
  00-ssh-hardening.conf \
  00-defaults.local \
  recidive.local \
  sshd.local \
  fail2ban.local \
  99-auditd-hardening.rules \
  99-sysctl-hardening.conf \
  99-journald-hardening.conf \
  ftp.sh; do
  if [[ ! -f $required_file ]]; then
    echo "Required file is missing: ${required_file}" >&2
    exit 1
  fi
done

echo -e "\033[36m<<<<<===== Change the root password =====>>>>>\033[0m"
passwd

echo -e "\033[36m<<<<<===== timezone config =====>>>>>\033[0m"
timedatectl set-timezone Europe/Warsaw

echo -e "\033[36m<<<<<===== Update =====>>>>>\033[0m"
apt update
apt -y upgrade

echo -e "\033[36m<<<<<===== Installing additional software =====>>>>>\033[0m"
apt -y install --no-install-recommends \
  curl ufw fail2ban vim git zsh unzip htop tar rsync locales \
  gnupg lsb-release dnsutils traceroute ncdu jq bash-completion \
  aide aide-common auditd audispd-plugins
apt purge -y postfix bsd-mailx mailutils

echo -e "\033[36m<<<<<===== Locale config =====>>>>>\033[0m"
locale-gen en_US.UTF-8
locale-gen pl_PL.UTF-8

echo "LANG=en_US.UTF-8
LC_MESSAGES=C
LC_ADDRESS=pl_PL.UTF-8
LC_IDENTIFICATION=pl_PL.UTF-8
LC_MEASUREMENT=pl_PL.UTF-8
LC_MONETARY=pl_PL.UTF-8
LC_NAME=pl_PL.UTF-8
LC_NUMERIC=pl_PL.UTF-8
LC_PAPER=pl_PL.UTF-8
LC_TELEPHONE=pl_PL.UTF-8
LC_TIME=pl_PL.UTF-8" > /etc/locale.conf

echo -e "\033[36m<<<<<===== sshd config =====>>>>>\033[0m"
install -d -m 0755 -o root -g root /run/sshd
mv 00-ssh-hardening.conf /etc/ssh/sshd_config.d
sshd -t
sshd_effective_config=$(sshd -T)
grep -qx "port 22122" <<< "$sshd_effective_config"
grep -qx "permitrootlogin no" <<< "$sshd_effective_config"
grep -qx "pubkeyauthentication yes" <<< "$sshd_effective_config"
grep -qx "passwordauthentication no" <<< "$sshd_effective_config"
grep -qx "authorizedkeysfile .ssh/authorized_keys" <<< "$sshd_effective_config"
grep -E "^(port|permitrootlogin|pubkeyauthentication|passwordauthentication|authorizedkeysfile) " <<< "$sshd_effective_config"
systemctl restart ssh
systemctl enable --now ssh
systemctl is-active --quiet ssh

echo -e "\033[36m<<<<<===== UFW config =====>>>>>\033[0m"
ufw default deny
ufw allow 22122/tcp
sed -i \
  -e 's|^net/ipv4/conf/all/log_martians=.*$|net/ipv4/conf/all/log_martians=1|' \
  -e 's|^net/ipv4/conf/default/log_martians=.*$|net/ipv4/conf/default/log_martians=1|' \
  /etc/ufw/sysctl.conf
grep -qx "net/ipv4/conf/all/log_martians=1" /etc/ufw/sysctl.conf
grep -qx "net/ipv4/conf/default/log_martians=1" /etc/ufw/sysctl.conf
ufw --force enable
systemctl enable --now ufw
ufw status verbose

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== fail2ban config =====>>>>>\033[0m"
mv 00-defaults.local /etc/fail2ban/jail.d
mv recidive.local /etc/fail2ban/jail.d
mv sshd.local /etc/fail2ban/jail.d
mv fail2ban.local /etc/fail2ban
fail2ban-client -t
systemctl reload fail2ban
fail2ban-client ping
fail2ban-client status
fail2ban-client status sshd
fail2ban-client status recidive

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== Auditd config =====>>>>>\033[0m"
mv /etc/audit/rules.d/audit.rules /etc/audit/rules.d/audit.rules_backup
mv 99-auditd-hardening.rules /etc/audit/rules.d/audit.rules
augenrules --load
systemctl enable --now auditd
auditctl -s
auditctl -l

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== sysctl hardening =====>>>>>\033[0m"
mv 99-sysctl-hardening.conf /etc/sysctl.d/
sysctl --system

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== journald =====>>>>>\033[0m"
mkdir -p /etc/systemd/journald.conf.d
mv 99-journald-hardening.conf /etc/systemd/journald.conf.d
systemctl restart systemd-journald
systemctl is-active --quiet systemd-journald
journalctl --disk-usage
systemd-analyze cat-config systemd/journald.conf

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== Add and config sudo user =====>>>>>\033[0m"
while true; do
  read -r -p "User name: " user_sudo

  if [[ ! $user_sudo =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Enter a valid Linux user name."
  elif id "$user_sudo" &> /dev/null; then
    echo "User already exists: ${user_sudo}"
  else
    break
  fi
done

useradd -m -G sudo -s /usr/bin/zsh "$user_sudo"
passwd "$user_sudo"
mkdir -m 700 "/home/${user_sudo}/.ssh"
touch "/home/${user_sudo}/.ssh/authorized_keys"
vim "/home/${user_sudo}/.ssh/authorized_keys"

if [[ ! -s /home/${user_sudo}/.ssh/authorized_keys ]]; then
  echo "authorized_keys cannot be empty for ${user_sudo}." >&2
  exit 1
fi

chmod 700 "/home/${user_sudo}/.ssh"
chmod 600 "/home/${user_sudo}/.ssh/authorized_keys"
chown "$user_sudo:$user_sudo" \
  "/home/${user_sudo}/.ssh" \
  "/home/${user_sudo}/.ssh/authorized_keys"

read -r -p "Press enter to continue"
echo -e "\033[36m<<<<<===== Add ansible user? /// 'Y'es /// /// 'N'o /// =====>>>>>\033[0m"
while true; do
  read -r -p "Add?: " ansible_user

  case "$ansible_user" in
  Y | y)
    echo "You've decided: ${ansible_user}"
    useradd -m -G sudo ansible
    passwd ansible
    mkdir -m 700 /home/ansible/.ssh
    touch /home/ansible/.ssh/authorized_keys
    vim /home/ansible/.ssh/authorized_keys

    if [[ ! -s /home/ansible/.ssh/authorized_keys ]]; then
      echo "authorized_keys cannot be empty for ansible." >&2
      exit 1
    fi

    chmod 700 /home/ansible/.ssh
    chmod 600 /home/ansible/.ssh/authorized_keys
    chown ansible:ansible /home/ansible/.ssh /home/ansible/.ssh/authorized_keys
    break
    ;;
  N | n)
    echo "You've decided: ${ansible_user}"
    break
    ;;
  *)
    echo "Enter Y or N."
    ;;
  esac
done

echo -e "\033[36m<<<<<===== hostname config =====>>>>>\033[0m"
while true; do
  read -r -p "hostname: " hostname

  if [[ -z $hostname ]]; then
    echo "Hostname cannot be empty."
  elif hostnamectl set-hostname "$hostname"; then
    break
  else
    echo "Enter a valid hostname."
  fi
done

hostnamectl hostname

echo -e "\033[36m<<<<<===== Final config =====>>>>>\033[0m"
read -r -p "Press enter to remove bootstrap files"
rm -f -- config.sh ftp.sh

echo -e "\033[36m<<<<<===== AIDE config =====>>>>>\033[0m"
aideinit
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
