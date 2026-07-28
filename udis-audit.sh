#!/usr/bin/env bash

set -uo pipefail

export LC_ALL=C

pass_count=0
warn_count=0
fail_count=0

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  color_green=$'\033[32m'
  color_yellow=$'\033[33m'
  color_red=$'\033[31m'
  color_cyan=$'\033[36m'
  color_reset=$'\033[0m'
else
  color_green=
  color_yellow=
  color_red=
  color_cyan=
  color_reset=
fi

section() {
  printf '\n%s== %s ==%s\n' "$color_cyan" "$1" "$color_reset"
}

pass() {
  ((pass_count += 1))
  printf '%s[OK]%s %s\n' "$color_green" "$color_reset" "$1"
}

warn() {
  ((warn_count += 1))
  printf '%s[WARN]%s %s\n' "$color_yellow" "$color_reset" "$1"
}

fail() {
  ((fail_count += 1))
  printf '%s[FAIL]%s %s\n' "$color_red" "$color_reset" "$1"
}

check_command() {
  local command_name=$1

  if command -v "$command_name" > /dev/null 2>&1; then
    return 0
  fi

  fail "Brak wymaganego polecenia: ${command_name}"
  return 1
}

check_service_active() {
  local unit=$1

  if systemctl is-active --quiet "$unit"; then
    pass "Usługa ${unit} jest aktywna."
  else
    fail "Usługa ${unit} nie jest aktywna."
  fi
}

check_service_enabled() {
  local unit=$1

  if systemctl is-enabled --quiet "$unit"; then
    pass "Usługa ${unit} jest włączona przy starcie."
  else
    fail "Usługa ${unit} nie jest włączona przy starcie."
  fi
}

check_managed_file() {
  local label=$1
  local path=$2
  local expected_hash=$3
  local actual_hash
  local metadata

  if [[ ! -f $path ]]; then
    fail "${label}: brak pliku ${path}."
    return
  fi

  if ! actual_hash=$(sha256sum -- "$path" 2> /dev/null); then
    fail "${label}: nie można obliczyć SHA-256 pliku ${path}."
    return
  fi
  actual_hash=${actual_hash%% *}

  if [[ $actual_hash == "$expected_hash" ]]; then
    pass "${label}: treść pliku jest zgodna z UDIS."
  else
    fail "${label}: treść pliku różni się od wersji UDIS."
  fi

  if metadata=$(stat -c '%U:%G %a' -- "$path" 2> /dev/null) &&
    [[ $metadata == "root:root 644" ]]; then
    pass "${label}: właściciel i tryb to root:root 644."
  else
    fail "${label}: oczekiwano właściciela i trybu root:root 644."
  fi
}

check_exact_line() {
  local label=$1
  local expected_line=$2
  local content=$3

  if grep -Fqx -- "$expected_line" <<< "$content"; then
    pass "${label}: ${expected_line}"
  else
    fail "${label}: brak wartości ${expected_line}"
  fi
}

check_fail2ban_value() {
  local jail=$1
  local setting=$2
  local expected=$3
  local actual

  if ! actual=$(fail2ban-client get "$jail" "$setting" 2> /dev/null); then
    fail "Fail2ban ${jail}: nie można odczytać ${setting}."
  elif [[ $actual == "$expected" ]]; then
    pass "Fail2ban ${jail}: ${setting}=${expected}."
  else
    fail "Fail2ban ${jail}: ${setting} ma wartość inną niż ${expected}."
  fi
}

check_sysctl_value() {
  local key=$1
  local expected=$2
  local actual

  if ! actual=$(sysctl -n "$key" 2> /dev/null); then
    fail "sysctl: nie można odczytać ${key}."
  elif [[ $actual == "$expected" ]]; then
    pass "sysctl: ${key}=${expected}."
  else
    fail "sysctl: ${key} ma wartość ${actual}, oczekiwano ${expected}."
  fi
}

valid_key_account() {
  local username=$1
  local home_directory
  local ssh_directory
  local authorized_keys

  home_directory=$(getent passwd "$username" | cut -d: -f6)
  [[ -n $home_directory ]] || return 1

  ssh_directory="${home_directory}/.ssh"
  authorized_keys="${ssh_directory}/authorized_keys"

  [[ -d $ssh_directory ]] || return 1
  [[ -s $authorized_keys ]] || return 1
  [[ $(stat -c '%U:%G %a' -- "$ssh_directory" 2> /dev/null) == "${username}:${username} 700" ]] || return 1
  [[ $(stat -c '%U:%G %a' -- "$authorized_keys" 2> /dev/null) == "${username}:${username} 600" ]] || return 1
}

if [[ $EUID -ne 0 ]]; then
  printf '[FAIL] Uruchom skrypt przez sudo lub jako root.\n' >&2
  exit 2
fi

if [[ ! -r /etc/os-release ]]; then
  printf '[FAIL] Nie można odczytać /etc/os-release.\n' >&2
  exit 2
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ ${ID:-} != ubuntu || ! ${VERSION_ID:-} =~ ^([0-9]{2})\.04$ ]]; then
  printf '[FAIL] Audyt obsługuje Ubuntu LTS od wersji 24.04.\n' >&2
  exit 2
fi

ubuntu_year=${BASH_REMATCH[1]}
if ((10#$ubuntu_year < 24 || 10#$ubuntu_year % 2 != 0)); then
  printf '[FAIL] Audyt obsługuje Ubuntu LTS od wersji 24.04.\n' >&2
  exit 2
fi

printf 'UDIS — audyt konfiguracji po instalacji\n'
printf 'System: Ubuntu %s\n' "${VERSION_ID}"

section "Wymagania"

required_commands=(
  aide
  auditctl
  augenrules
  dig
  dpkg-query
  fail2ban-client
  getent
  grep
  journalctl
  locale
  sha256sum
  ss
  sshd
  stat
  sysctl
  systemctl
  systemd-analyze
  timedatectl
  ufw
)

missing_commands=0
for command_name in "${required_commands[@]}"; do
  if ! check_command "$command_name"; then
    missing_commands=1
  fi
done

if ((missing_commands != 0)); then
  printf '\nWynik: NIEPEŁNY — brakuje narzędzi wymaganych do audytu.\n'
  printf 'OK: %d | WARN: %d | FAIL: %d\n' "$pass_count" "$warn_count" "$fail_count"
  exit 2
fi

pass "Wszystkie narzędzia wymagane do audytu są dostępne."

required_packages=(
  aide
  aide-common
  auditd
  audispd-plugins
  bash-completion
  curl
  fail2ban
  git
  gnupg
  htop
  jq
  locales
  lsb-release
  ncdu
  rsync
  tar
  traceroute
  ufw
  unzip
  vim
  zsh
)

missing_packages=()
for package_name in "${required_packages[@]}"; do
  package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2> /dev/null || true)
  if [[ $package_status != installed ]]; then
    missing_packages+=("$package_name")
  fi
done

dnsutils_status=$(dpkg-query -W -f='${db:Status-Status}' dnsutils 2> /dev/null || true)
bind9_dnsutils_status=$(dpkg-query -W -f='${db:Status-Status}' bind9-dnsutils 2> /dev/null || true)
if [[ $dnsutils_status != installed && $bind9_dnsutils_status != installed ]]; then
  missing_packages+=("dnsutils/bind9-dnsutils")
fi

if ((${#missing_packages[@]} == 0)); then
  pass "Pakiety instalowane przez UDIS są obecne."
else
  fail "Brak pakietów instalowanych przez UDIS: ${missing_packages[*]}"
fi

unexpected_mail_packages=()
for package_name in postfix bsd-mailx mailutils; do
  package_status=$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2> /dev/null || true)
  if [[ $package_status == installed ]]; then
    unexpected_mail_packages+=("$package_name")
  fi
done

if ((${#unexpected_mail_packages[@]} == 0)); then
  pass "Pakiety pocztowe usuwane przez UDIS są nieobecne."
else
  fail "Pakiety pocztowe nadal zainstalowane: ${unexpected_mail_packages[*]}"
fi

section "Pliki zarządzane przez UDIS"

check_managed_file \
  "SSH" \
  "/etc/ssh/sshd_config.d/00-ssh-hardening.conf" \
  "e0b17491ea51775a11add14b7d02e33951ca75a0c66bdba139f46d8f9a442738"
check_managed_file \
  "Fail2ban global" \
  "/etc/fail2ban/fail2ban.local" \
  "f80fdafe4ef120bf1b642e77c888abcaf2ca8fddc18d37dcf63b02132decdc3c"
check_managed_file \
  "Fail2ban defaults" \
  "/etc/fail2ban/jail.d/00-defaults.local" \
  "90484d3412ff9fc096dd920c98419ba7ab50a072ed3400a26b14ce938cd536ac"
check_managed_file \
  "Fail2ban recidive" \
  "/etc/fail2ban/jail.d/recidive.local" \
  "de940c45f1087062d6acfa37fbf308786192b265a9b8438d698268ab1c041365"
check_managed_file \
  "Fail2ban SSH" \
  "/etc/fail2ban/jail.d/sshd.local" \
  "2352da6f85b485ea7102abea2e013eb409b133b45f7f0d05efb74f2fa17c23d2"
check_managed_file \
  "Auditd" \
  "/etc/audit/rules.d/audit.rules" \
  "1ecdca8899b99055c129f147c135a47232a2a1301cec0833cb2c32f9c0645501"
check_managed_file \
  "sysctl" \
  "/etc/sysctl.d/99-sysctl-hardening.conf" \
  "e76acf1d491d5a112da1e1e1adca06bc563ccbbf8109f2aed70e30cf2a128455"
check_managed_file \
  "journald" \
  "/etc/systemd/journald.conf.d/99-journald-hardening.conf" \
  "2498a50a69cd607ae5976e6b90c94438e5d081f04acb56299731578ee3d4bd78"

if [[ -e /etc/fail2ban/jail.d/apache.local ]]; then
  warn "Wykryto apache.local spoza bazowej konfiguracji UDIS."
else
  pass "Bazowa konfiguracja nie zawiera jaili Apache."
fi

section "System i konta"

if [[ $(timedatectl show -p Timezone --value 2> /dev/null) == Europe/Warsaw ]]; then
  pass "Strefa czasowa to Europe/Warsaw."
else
  fail "Strefa czasowa jest inna niż Europe/Warsaw."
fi

if [[ -r /etc/locale.conf ]]; then
  locale_config=$(< /etc/locale.conf)
  for expected_locale_line in \
    "LANG=en_US.UTF-8" \
    "LC_MESSAGES=C" \
    "LC_ADDRESS=pl_PL.UTF-8" \
    "LC_IDENTIFICATION=pl_PL.UTF-8" \
    "LC_MEASUREMENT=pl_PL.UTF-8" \
    "LC_MONETARY=pl_PL.UTF-8" \
    "LC_NAME=pl_PL.UTF-8" \
    "LC_NUMERIC=pl_PL.UTF-8" \
    "LC_PAPER=pl_PL.UTF-8" \
    "LC_TELEPHONE=pl_PL.UTF-8" \
    "LC_TIME=pl_PL.UTF-8"; do
    check_exact_line "locale.conf" "$expected_locale_line" "$locale_config"
  done
else
  fail "Brak czytelnego pliku /etc/locale.conf."
fi

available_locales=$(locale -a 2> /dev/null)
if grep -Eiq '^en_US\.utf-?8$' <<< "$available_locales" &&
  grep -Eiq '^pl_PL\.utf-?8$' <<< "$available_locales"; then
  pass "Locale en_US.UTF-8 i pl_PL.UTF-8 są wygenerowane."
else
  fail "Brakuje wygenerowanego locale en_US.UTF-8 lub pl_PL.UTF-8."
fi

sudo_members=$(getent group sudo | cut -d: -f4)
valid_admin_accounts=0
IFS=',' read -r -a sudo_usernames <<< "$sudo_members"
for username in "${sudo_usernames[@]}"; do
  [[ -n $username ]] || continue
  user_shell=$(getent passwd "$username" | cut -d: -f7)
  if [[ $user_shell == /usr/bin/zsh ]] && valid_key_account "$username"; then
    ((valid_admin_accounts += 1))
  fi
done

if ((valid_admin_accounts >= 1)); then
  pass "Istnieje konto sudo z zsh, niepustym authorized_keys i poprawnymi uprawnieniami."
else
  fail "Nie znaleziono konta sudo z zsh i poprawnie zabezpieczonym authorized_keys."
fi

if id ansible > /dev/null 2>&1; then
  if id -nG ansible | tr ' ' '\n' | grep -Fxq sudo &&
    valid_key_account ansible; then
    pass "Opcjonalne konto ansible ma sudo, klucz i poprawne uprawnienia."
  else
    fail "Konto ansible istnieje, ale nie spełnia konfiguracji UDIS."
  fi
else
  pass "Opcjonalne konto ansible nie zostało utworzone."
fi

if [[ -n $(hostnamectl --static 2> /dev/null) ]]; then
  pass "Hostname jest ustawiony."
else
  fail "Hostname jest pusty lub niedostępny."
fi

section "SSH"

check_service_active ssh.service
check_service_enabled ssh.service

if sshd -t > /dev/null 2>&1; then
  pass "Składnia konfiguracji SSH jest poprawna."
else
  fail "sshd -t wykrył błąd konfiguracji."
fi

if sshd_effective_config=$(sshd -T 2> /dev/null); then
  for expected_ssh_line in \
    "port 22122" \
    "permitrootlogin no" \
    "pubkeyauthentication yes" \
    "authorizedkeysfile .ssh/authorized_keys" \
    "passwordauthentication no" \
    "permitemptypasswords no" \
    "subsystem sftp internal-sftp"; do
    check_exact_line "SSH effective" "$expected_ssh_line" "$sshd_effective_config"
  done
else
  fail "Nie można odczytać efektywnej konfiguracji SSH."
fi

if ss -H -ltn | awk '$4 ~ /:22122$/ { found=1 } END { exit !found }'; then
  pass "SSH nasłuchuje na porcie 22122."
else
  fail "Nie wykryto nasłuchu TCP na porcie 22122."
fi

section "UFW"

check_service_active ufw.service
check_service_enabled ufw.service

ufw_status=$(ufw status verbose 2> /dev/null || true)
if grep -Fqx "Status: active" <<< "$ufw_status"; then
  pass "UFW jest aktywny."
else
  fail "UFW zgłasza stan inny niż active."
fi

if grep -Fq "Default: deny (incoming)" <<< "$ufw_status"; then
  pass "Domyślna polityka ruchu przychodzącego to deny."
else
  fail "Domyślna polityka ruchu przychodzącego nie jest deny."
fi

if grep -Eq '^22122/tcp[[:space:]]+ALLOW' <<< "$ufw_status"; then
  pass "UFW dopuszcza port 22122/tcp."
else
  fail "Brak reguły UFW dopuszczającej 22122/tcp."
fi

if grep -Eq '^22/tcp[[:space:]]+ALLOW' <<< "$ufw_status"; then
  warn "UFW zawiera dodatkową regułę dopuszczającą 22/tcp."
else
  pass "UFW nie zawiera dodatkowej reguły dla 22/tcp."
fi

if [[ -r /etc/ufw/sysctl.conf ]]; then
  ufw_sysctl_config=$(< /etc/ufw/sysctl.conf)
  check_exact_line \
    "UFW sysctl" \
    "net/ipv4/conf/all/log_martians=1" \
    "$ufw_sysctl_config"
  check_exact_line \
    "UFW sysctl" \
    "net/ipv4/conf/default/log_martians=1" \
    "$ufw_sysctl_config"
else
  fail "Brak czytelnego pliku /etc/ufw/sysctl.conf."
fi

section "Fail2ban"

check_service_active fail2ban.service
check_service_enabled fail2ban.service

if fail2ban-client -t > /dev/null 2>&1; then
  pass "Składnia konfiguracji Fail2ban jest poprawna."
else
  fail "Fail2ban wykrył błąd konfiguracji."
fi

if fail2ban-client ping > /dev/null 2>&1; then
  pass "Fail2ban odpowiada na ping."
else
  fail "Fail2ban nie odpowiada na ping."
fi

sshd_jail_status=$(fail2ban-client status sshd 2> /dev/null || true)
if [[ -n $sshd_jail_status ]] &&
  fail2ban-client status recidive > /dev/null 2>&1; then
  pass "Jaille sshd i recidive są aktywne."
else
  fail "Brakuje aktywnego jaila sshd lub recidive."
fi

if grep -Fq "Journal matches:" <<< "$sshd_jail_status"; then
  pass "Jail sshd korzysta z backendu systemd."
else
  fail "Jail sshd nie raportuje backendu systemd."
fi

check_fail2ban_value sshd maxretry "3"
check_fail2ban_value sshd findtime "600"
check_fail2ban_value sshd bantime "172800"
check_fail2ban_value recidive maxretry "5"
check_fail2ban_value recidive findtime "604800"
check_fail2ban_value recidive bantime "604800"

ignore_addresses=$(fail2ban-client get sshd ignoreip 2> /dev/null || true)
if grep -Eq '127\.0\.0\.(0|1)/8' <<< "$ignore_addresses" &&
  grep -Fq "::1" <<< "$ignore_addresses"; then
  pass "Fail2ban zawiera wymagane adresy lokalne w ignoreip."
else
  fail "Lista ignoreip Fail2ban nie zawiera wymaganych adresów lokalnych."
fi

section "Auditd"

check_service_active auditd.service
check_service_enabled auditd.service
check_service_enabled audit-rules.service

audit_rules_result=$(systemctl show audit-rules.service -p Result --value 2> /dev/null || true)
if [[ $audit_rules_result == success ]]; then
  pass "Ostatnie uruchomienie audit-rules.service zakończyło się sukcesem."
else
  fail "audit-rules.service ma wynik ${audit_rules_result:-nieznany}."
fi

if systemctl is-failed --quiet audit-rules.service; then
  fail "audit-rules.service pozostaje w stanie failed."
else
  pass "audit-rules.service nie jest w stanie failed."
fi

audit_journal_errors=$(journalctl -b -u audit-rules.service -p err -q --no-pager -o cat 2> /dev/null |
  sed '/^[[:space:]]*$/d' |
  wc -l)
if ((audit_journal_errors == 0)); then
  pass "Bieżący boot nie zawiera błędów audit-rules.service."
else
  warn "Bieżący boot zawiera ${audit_journal_errors} linii błędów audit-rules.service."
fi

if augenrules --check > /dev/null 2>&1; then
  pass "Wygenerowane reguły Auditd są aktualne."
else
  fail "augenrules --check wykrył nieaktualny lub błędny zestaw reguł."
fi

if audit_status=$(auditctl -s 2> /dev/null); then
  check_exact_line "Auditd status" "enabled 1" "$audit_status"
  check_exact_line "Auditd status" "failure 1" "$audit_status"
  check_exact_line "Auditd status" "lost 0" "$audit_status"
else
  fail "Nie można odczytać stanu Auditd."
fi

if audit_rules=$(auditctl -l 2> /dev/null); then
  audit_watch_rules=(
    "/etc/passwd|passwd_changes"
    "/etc/shadow|shadow_changes"
    "/etc/group|group_changes"
    "/etc/gshadow|gshadow_changes"
    "/etc/ssh/sshd_config|ssh_config"
    "/etc/ssh/sshd_config.d|ssh_config"
    "/etc/sudoers|sudo_changes"
    "/etc/sudoers.d|sudo_changes"
    "/bin|bin_changes"
    "/sbin|sbin_changes"
    "/usr/bin|usrbin_changes"
    "/usr/sbin|usrsbin_changes"
  )

  missing_audit_rules=0
  for expected_rule in "${audit_watch_rules[@]}"; do
    watched_path=${expected_rule%%|*}
    rule_key=${expected_rule#*|}
    if ! grep -F -- "-w ${watched_path} " <<< "$audit_rules" |
      grep -Fq -- "-k ${rule_key}"; then
      fail "Brak aktywnej reguły Auditd dla ${watched_path}."
      missing_audit_rules=1
    fi
  done

  if ((missing_audit_rules == 0)); then
    pass "Wszystkie reguły obserwacji plików Auditd są aktywne."
  fi

  if grep -Fq -- "-S init_module,delete_module" <<< "$audit_rules" &&
    grep -Fq -- "kernel_module" <<< "$audit_rules"; then
    pass "Reguła Auditd dla modułów kernela jest aktywna."
  else
    fail "Brak aktywnej reguły Auditd dla modułów kernela."
  fi
else
  fail "Nie można odczytać aktywnych reguł Auditd."
fi

section "sysctl"

sysctl_expectations=(
  "net.ipv4.conf.all.rp_filter=1"
  "net.ipv4.conf.default.rp_filter=1"
  "net.ipv4.tcp_syncookies=1"
  "net.ipv4.conf.all.accept_redirects=0"
  "net.ipv6.conf.all.accept_redirects=0"
  "net.ipv4.conf.all.send_redirects=0"
  "kernel.kptr_restrict=2"
  "kernel.dmesg_restrict=1"
  "net.ipv4.icmp_echo_ignore_broadcasts=1"
  "net.ipv4.icmp_ignore_bogus_error_responses=1"
  "net.ipv4.conf.all.log_martians=1"
  "net.ipv4.conf.default.log_martians=1"
  "net.ipv4.conf.all.accept_source_route=0"
  "net.ipv6.conf.all.accept_source_route=0"
)

for expectation in "${sysctl_expectations[@]}"; do
  sysctl_key=${expectation%%=*}
  sysctl_expected=${expectation#*=}
  check_sysctl_value "$sysctl_key" "$sysctl_expected"
done

section "journald"

check_service_active systemd-journald.service

if journald_effective_config=$(systemd-analyze cat-config systemd/journald.conf 2> /dev/null); then
  for expected_journald_line in \
    "SystemMaxUse=200M" \
    "RuntimeMaxUse=50M" \
    "MaxRetentionSec=1month" \
    "SystemMaxFileSize=50M"; do
    check_exact_line "journald effective" "$expected_journald_line" "$journald_effective_config"
  done
else
  fail "Nie można odczytać efektywnej konfiguracji journald."
fi

section "AIDE"

if [[ -s /var/lib/aide/aide.db ]]; then
  pass "Baza AIDE istnieje i nie jest pusta."
else
  fail "Brak gotowej bazy /var/lib/aide/aide.db."
fi

if [[ ! -r /etc/aide/aide.conf ]]; then
  fail "Brak czytelnej konfiguracji /etc/aide/aide.conf."
elif aide --config-check --config /etc/aide/aide.conf > /dev/null 2>&1; then
  pass "Konfiguracja /etc/aide/aide.conf przechodzi kontrolę składni."
else
  fail "Konfiguracja /etc/aide/aide.conf nie przechodzi kontroli składni."
fi

section "Stan końcowy"

relevant_failed_units=()
for unit in \
  ssh.service \
  ufw.service \
  fail2ban.service \
  auditd.service \
  audit-rules.service \
  systemd-journald.service; do
  if systemctl is-failed --quiet "$unit"; then
    relevant_failed_units+=("$unit")
  fi
done

if ((${#relevant_failed_units[@]} == 0)); then
  pass "Żadna usługa zarządzana przez UDIS nie jest w stanie failed."
else
  fail "Usługi w stanie failed: ${relevant_failed_units[*]}"
fi

if [[ -e /run/reboot-required ]]; then
  warn "System nadal zgłasza wymagany restart."
else
  pass "System nie zgłasza wymaganego restartu."
fi

printf '\n%s== PODSUMOWANIE ==%s\n' "$color_cyan" "$color_reset"
printf 'OK: %d | WARN: %d | FAIL: %d\n' "$pass_count" "$warn_count" "$fail_count"

if ((fail_count > 0)); then
  printf '%sWynik: NIEZGODNY%s\n' "$color_red" "$color_reset"
  exit 1
elif ((warn_count > 0)); then
  printf '%sWynik: POPRAWNY Z OSTRZEŻENIAMI%s\n' "$color_yellow" "$color_reset"
  exit 0
else
  printf '%sWynik: POPRAWNY%s\n' "$color_green" "$color_reset"
  exit 0
fi
