#!/bin/bash
# install-borgmatic.sh
# Instaluje borgmatic 2.1 + konfiguruje backupy (files + mysql)
# dla serwerow z DirectAdmin
#
# Co robi:
#   1. Instaluje borgmatic 2.1 via pipx
#   2. Pobiera dane z DirectAdmin (users.list, mysql.conf)
#   3. Generuje /etc/borgmatic/files.yaml i mysql.yaml
#   4. Ustawia passcommand.sh z wygenerowanym haslem
#   5. Inicjalizuje repozytoria borg na serwerze backupowym
#   6. Ustawia cron (co godzine)
#
# Uzycie:
#   ./install-borgmatic.sh                              # interaktywny
#   BACKUP_SERVER=user@host BACKUP_PASS=xxx ./install-borgmatic.sh  # z env
#
set -euo pipefail

# ============================================================================
# KONFIGURACJA — zmien wedlug potrzeb
# ============================================================================

BACKUP_USER="${BACKUP_USER:-backup_new}"
BACKUP_HOST="${BACKUP_HOST:-57.128.229.138}"
SSH_CMD="ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o ConnectTimeout=30"

DA_USERS_LIST="/usr/local/directadmin/data/users/admin/users.list"
DA_MYSQL_CONF="/usr/local/directadmin/conf/mysql.conf"

BORGMATIC_CONFIG_DIR="/etc/borgmatic"
BORG_CONFIG_DIR="/root/.config/borg"
PASSCOMMAND_FILE="${BORG_CONFIG_DIR}/passcommand.sh"

MYSQL_TMP_DIR="/home/backup/mysql-borg-tmp"

# Retencja
KEEP_HOURLY_FILES=10000
KEEP_HOURLY_MYSQL=8760

# ============================================================================
# KOLORY
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
die()   { err "$*"; exit 1; }

# ============================================================================
# SPRAWDZENIA WSTEPNE
# ============================================================================

echo ""
echo "==========================================="
echo " Instalacja borgmatic 2.1 + konfiguracja"
echo " (DirectAdmin + borg backup)"
echo "==========================================="
echo ""

# Root?
[[ "$(id -u)" -eq 0 ]] || die "Uruchom jako root"

# DirectAdmin?
[[ -d /usr/local/directadmin ]] || die "DirectAdmin nie znaleziony w /usr/local/directadmin"

# ============================================================================
# 1. ZBIERZ DANE O SERWERZE
# ============================================================================

info "[1/7] Zbieranie danych o serwerze..."

HOSTNAME_FULL=$(hostname -f)
HOSTNAME_SHORT=$(hostname -s)

# IP serwera — glowny IP
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}')
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# 3 znaki identyfikatora — pierwsze 3 znaki MD5 z hostname
ID_SHORT=$(echo -n "${HOSTNAME_FULL}" | md5sum | cut -c1-3)

REPO_PREFIX="${HOSTNAME_FULL}-${SERVER_IP}-${ID_SHORT}"

ok "Hostname: ${HOSTNAME_FULL}"
ok "IP: ${SERVER_IP}"
ok "Prefix repo: ${REPO_PREFIX}"

# ============================================================================
# 2. POBIERZ DANE Z DIRECTADMIN
# ============================================================================

info "[2/7] Pobieranie danych z DirectAdmin..."

# --- Uzytkownicy ---
DA_USERS=()

if [[ -f "${DA_USERS_LIST}" ]]; then
  while IFS= read -r user; do
    user=$(echo "${user}" | tr -d '[:space:]')
    [[ -z "${user}" ]] && continue
    DA_USERS+=("${user}")
  done < "${DA_USERS_LIST}"
fi

# Fallback: skanuj /home szukajac folderow z domains/
if [[ ${#DA_USERS[@]} -eq 0 ]]; then
  warn "users.list pusty lub nie istnieje — skanuje /home/*/domains/"
  for domains_dir in /home/*/domains; do
    [[ -d "${domains_dir}" ]] || continue
    user=$(basename "$(dirname "${domains_dir}")")
    # Pomin systemowych
    [[ "${user}" == "backup" || "${user}" == "lost+found" ]] && continue
    DA_USERS+=("${user}")
  done
fi

if [[ ${#DA_USERS[@]} -eq 0 ]]; then
  die "Nie znaleziono uzytkownikow ani w ${DA_USERS_LIST} ani w /home/*/domains/"
fi

ok "Znaleziono ${#DA_USERS[@]} uzytkownikow DA: ${DA_USERS[*]}"

# --- MySQL ---
if [[ ! -f "${DA_MYSQL_CONF}" ]]; then
  die "Plik mysql.conf nie istnieje: ${DA_MYSQL_CONF}"
fi

# Parsuj mysql.conf (format: key=value)
MYSQL_HOST=""
MYSQL_USER=""
MYSQL_PASS=""

while IFS='=' read -r key value; do
  key=$(echo "${key}" | tr -d '[:space:]')
  value=$(echo "${value}" | tr -d '[:space:]')
  case "${key}" in
    host)   MYSQL_HOST="${value}" ;;
    user)   MYSQL_USER="${value}" ;;
    passwd) MYSQL_PASS="${value}" ;;
  esac
done < "${DA_MYSQL_CONF}"

[[ -z "${MYSQL_USER}" ]] && die "Nie mozna odczytac usera MySQL z ${DA_MYSQL_CONF}"
[[ -z "${MYSQL_PASS}" ]] && die "Nie mozna odczytac hasla MySQL z ${DA_MYSQL_CONF}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"

ok "MySQL: ${MYSQL_USER}@${MYSQL_HOST}"

# ============================================================================
# 3. INSTALACJA BORGMATIC 2.1
# ============================================================================

info "[3/7] Instalacja borgmatic..."

# Zainstaluj wymagane pakiety
if command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq python3 python3-pip python3-venv pipx borgbackup >/dev/null 2>&1
  ok "Pakiety zainstalowane (apt)"
elif command -v dnf &>/dev/null; then
  dnf install -y -q python3 python3-pip borgbackup >/dev/null 2>&1
  pip3 install pipx >/dev/null 2>&1
  ok "Pakiety zainstalowane (dnf)"
elif command -v yum &>/dev/null; then
  yum install -y -q python3 python3-pip borgbackup >/dev/null 2>&1
  pip3 install pipx >/dev/null 2>&1
  ok "Pakiety zainstalowane (yum)"
else
  warn "Nieznany package manager — zakladam ze python3/pipx/borg juz sa"
fi

# Upewnij sie ze pipx jest dostepny
if ! command -v pipx &>/dev/null; then
  python3 -m pip install --user pipx >/dev/null 2>&1
  export PATH="${PATH}:${HOME}/.local/bin"
fi

# Zainstaluj borgmatic 2.1.x
if command -v borgmatic &>/dev/null; then
  CURRENT_VERSION=$(borgmatic --version 2>/dev/null || echo "unknown")
  if [[ "${CURRENT_VERSION}" == 2.1.* ]]; then
    ok "borgmatic ${CURRENT_VERSION} juz zainstalowany"
  else
    info "Aktualizacja borgmatic z ${CURRENT_VERSION} do 2.1..."
    pipx install --force 'borgmatic>=2.1,<2.2' >/dev/null 2>&1
    ok "borgmatic zaktualizowany do $(borgmatic --version 2>/dev/null)"
  fi
else
  pipx install 'borgmatic>=2.1,<2.2' >/dev/null 2>&1
  export PATH="${PATH}:${HOME}/.local/bin"
  ok "borgmatic $(borgmatic --version 2>/dev/null) zainstalowany"
fi

# Upewnij sie ze borgmatic jest w PATH
if ! command -v borgmatic &>/dev/null; then
  pipx ensurepath >/dev/null 2>&1
  export PATH="${PATH}:${HOME}/.local/bin:/root/.local/bin"
fi

command -v borgmatic &>/dev/null || die "borgmatic nie znaleziony po instalacji!"

# Dodaj ~/.local/bin do PATH na stale jesli brak
BASHRC="/root/.bashrc"
if ! grep -q '\.local/bin' "${BASHRC}" 2>/dev/null; then
  echo 'export PATH="$PATH:/root/.local/bin"' >> "${BASHRC}"
  ok "Dodano /root/.local/bin do PATH w ${BASHRC}"
fi

# ============================================================================
# 4. HASLO BORG + PASSCOMMAND
# ============================================================================

info "[4/7] Konfiguracja hasla borg..."

mkdir -p "${BORG_CONFIG_DIR}"

if [[ -n "${BACKUP_PASS:-}" ]]; then
  BORG_PASSPHRASE="${BACKUP_PASS}"
  ok "Haslo borg pobrane z BACKUP_PASS"
elif [[ -f "${PASSCOMMAND_FILE}" ]]; then
  # Passcommand juz istnieje — wyciagnij haslo z niego
  BORG_PASSPHRASE=$(bash "${PASSCOMMAND_FILE}" 2>/dev/null || true)
  if [[ -n "${BORG_PASSPHRASE}" ]]; then
    ok "Haslo borg odczytane z istniejacego ${PASSCOMMAND_FILE}"
  else
    # Wygeneruj nowe
    BORG_PASSPHRASE=$(openssl rand -base64 32)
    warn "Nie mozna odczytac hasla z passcommand — wygenerowano nowe"
  fi
else
  # Wygeneruj nowe haslo
  BORG_PASSPHRASE=$(openssl rand -base64 32)
  ok "Wygenerowano nowe haslo borg"
fi

# Zapisz passcommand.sh
cat > "${PASSCOMMAND_FILE}" <<PASSEOF
#!/bin/bash
echo '${BORG_PASSPHRASE}'
PASSEOF
chmod 700 "${PASSCOMMAND_FILE}"

ok "Passcommand: ${PASSCOMMAND_FILE}"

# WAZNE: zapisz haslo do pliku awaryjnego
PASS_BACKUP_FILE="${BORG_CONFIG_DIR}/passphrase.backup"
echo "${BORG_PASSPHRASE}" > "${PASS_BACKUP_FILE}"
chmod 600 "${PASS_BACKUP_FILE}"
warn "HASLO ZAPISANE W: ${PASS_BACKUP_FILE} — SKOPIUJ I ZABEZPIECZ!"

# ============================================================================
# 5. GENEROWANIE KONFIGOW BORGMATIC
# ============================================================================

info "[5/7] Generowanie konfigow borgmatic..."

mkdir -p "${BORGMATIC_CONFIG_DIR}"
mkdir -p "${MYSQL_TMP_DIR}"

REPO_FILES="ssh://${BACKUP_USER}@${BACKUP_HOST}/./${REPO_PREFIX}/BORG-FILES"
REPO_MYSQL="ssh://${BACKUP_USER}@${BACKUP_HOST}/./${REPO_PREFIX}/BORG-MYSQL"

# --- files.yaml ---
FILES_YAML="${BORGMATIC_CONFIG_DIR}/files.yaml"

# Buduj liste source_directories
SOURCE_DIRS="source_directories:"
SOURCE_DIRS+="\n  - /etc"

for user in "${DA_USERS[@]}"; do
  if [[ -d "/home/${user}/domains" ]]; then
    SOURCE_DIRS+="\n  - /home/${user}/domains"
  else
    warn "Pomijam /home/${user}/domains — katalog nie istnieje"
  fi
done

SOURCE_DIRS+="\n  - /usr/local/directadmin"

# Dodaj foldery PHP jesli istnieja
for phpdir in /usr/local/php*; do
  if [[ -d "${phpdir}" ]]; then
    SOURCE_DIRS+="\n  - ${phpdir}"
  fi
done

cat > "${FILES_YAML}" <<FILESEOF
$(echo -e "${SOURCE_DIRS}")

repositories:
  - path: ${REPO_FILES}

exclude_patterns:
  - '*/logs'
  - '*/tmp'
  - '*/cache'
  - '*/sess_*'
  - /usr/local/directadmin/logs
  - /usr/local/php*/man
  - /usr/local/php*/doc

encryption_passcommand: ${PASSCOMMAND_FILE}
archive_name_format: "{hostname}-files-{now:%Y-%m-%d_%H-%M}"
compression: lz4
ssh_command: ${SSH_CMD}

keep_hourly: ${KEEP_HOURLY_FILES}

commands:
  - after: error
    run:
      - "/usr/local/bin/borgmatic-on-error.sh {configuration_filename} {repository} {error}"

borg_exit_codes:
  - code: 100
    treat_as: error
  - code: 105
    treat_as: error
FILESEOF

ok "Wygenerowano: ${FILES_YAML}"

# --- mysql.yaml ---
MYSQL_YAML="${BORGMATIC_CONFIG_DIR}/mysql.yaml"

cat > "${MYSQL_YAML}" <<MYSQLEOF
source_directories:
  - ${MYSQL_TMP_DIR}

repositories:
  - path: ${REPO_MYSQL}

encryption_passcommand: ${PASSCOMMAND_FILE}
archive_name_format: "{hostname}-mysql-{now:%Y-%m-%d_%H-%M}"
compression: none
ssh_command: ${SSH_CMD}

keep_hourly: ${KEEP_HOURLY_MYSQL}

mysql_databases:
  - name: all
    username: ${MYSQL_USER}
    password: ${MYSQL_PASS}

commands:
  - after: error
    run:
      - "/usr/local/bin/borgmatic-on-error.sh {configuration_filename} {repository} {error}"

borg_exit_codes:
  - code: 100
    treat_as: error
  - code: 105
    treat_as: error
MYSQLEOF

ok "Wygenerowano: ${MYSQL_YAML}"

# Walidacja
for cfg in "${FILES_YAML}" "${MYSQL_YAML}"; do
  if borgmatic config validate -c "${cfg}" >/dev/null 2>&1; then
    ok "Walidacja OK: ${cfg}"
  else
    warn "Walidacja FAILED: ${cfg} — sprawdz recznie!"
  fi
done

# ============================================================================
# 6. INICJALIZACJA REPOZYTORIOW BORG
# ============================================================================

info "[6/7] Inicjalizacja repozytoriow borg na serwerze backupowym..."

# Utworz katalog nadrzedny na serwerze backupowym (borg nie tworzy go sam)
info "  Tworzenie katalogu zdalnego: ~/${REPO_PREFIX}"
if ssh ${SSH_CMD#ssh } "${BACKUP_USER}@${BACKUP_HOST}" "mkdir -p ~/${REPO_PREFIX}" 2>&1; then
  ok "  Katalog zdalny utworzony: ~/${REPO_PREFIX}"
else
  warn "  Nie udalo sie utworzyc katalogu zdalnego — moze juz istnieje lub brak dostepu"
fi

export BORG_PASSPHRASE

init_repo() {
  local repo_path="$1"
  local repo_name="$2"

  info "  Inicjalizacja ${repo_name}: ${repo_path}"

  # Sprawdz czy repo juz istnieje
  if BORG_RSH="${SSH_CMD}" borg info "${repo_path}" >/dev/null 2>&1; then
    ok "  ${repo_name}: repozytorium juz istnieje"
    return 0
  fi

  # Inicjalizuj z szyfrowaniem repokey-blake2
  if BORG_RSH="${SSH_CMD}" borg init --encryption=repokey-blake2 "${repo_path}" 2>&1; then
    ok "  ${repo_name}: repozytorium zainicjalizowane"
  else
    err "  ${repo_name}: BLAD inicjalizacji! Sprawdz:"
    err "    - Czy klucz SSH jest na serwerze backupowym?"
    err "    - Czy ${BACKUP_USER}@${BACKUP_HOST} jest dostepny?"
    err "    - ssh ${BACKUP_USER}@${BACKUP_HOST} 'echo ok'"
    return 1
  fi
}

INIT_ERRORS=0
init_repo "${REPO_FILES}" "BORG-FILES" || INIT_ERRORS=$((INIT_ERRORS + 1))
init_repo "${REPO_MYSQL}" "BORG-MYSQL" || INIT_ERRORS=$((INIT_ERRORS + 1))

unset BORG_PASSPHRASE

if [[ ${INIT_ERRORS} -gt 0 ]]; then
  warn "Nie udalo sie zainicjalizowac ${INIT_ERRORS} repo — moze byc problem z SSH"
  warn "Mozesz zainicjalizowac recznie:"
  warn "  BORG_PASSCOMMAND='${PASSCOMMAND_FILE}' BORG_RSH='${SSH_CMD}' borg init --encryption=repokey-blake2 ${REPO_FILES}"
  warn "  BORG_PASSCOMMAND='${PASSCOMMAND_FILE}' BORG_RSH='${SSH_CMD}' borg init --encryption=repokey-blake2 ${REPO_MYSQL}"
fi

# ============================================================================
# 7. CRON
# ============================================================================

info "[7/7] Konfiguracja cron..."

# Borgmatic cron — codziennie o 7:00 i 17:00
BORGMATIC_BIN="/root/.local/bin/borgmatic"
CRON_MYSQL="0 7,17 * * * ${BORGMATIC_BIN} create --verbosity -2 --syslog-verbosity 1 -c /etc/borgmatic/mysql.yaml 2>&1 | logger -t borgmatic-mysql"
CRON_FILES="15 7,17 * * * ${BORGMATIC_BIN} create --verbosity -2 --syslog-verbosity 1 -c /etc/borgmatic/files.yaml 2>&1 | logger -t borgmatic-files"

if crontab -l 2>/dev/null | grep -v "borgmatic-monitor" | grep -q "borgmatic"; then
  ok "Cron borgmatic juz skonfigurowany"
else
  (crontab -l 2>/dev/null
   echo ""
   echo "# Borgmatic backup MySQL (codziennie 7:00 i 17:00)"
   echo "${CRON_MYSQL}"
   echo "# Borgmatic backup FILES (codziennie 7:15 i 17:15)"
   echo "${CRON_FILES}"
  ) | crontab -
  ok "Dodano cron: mysql o 7:00/17:00, files o 7:15/17:15"
fi

# ============================================================================
# PODSUMOWANIE
# ============================================================================

echo ""
echo "==========================================="
echo -e " ${GREEN}INSTALACJA ZAKONCZONA${NC}"
echo "==========================================="
echo ""
echo "  Serwer:      ${HOSTNAME_FULL} (${SERVER_IP})"
echo "  Prefix repo: ${REPO_PREFIX}"
echo ""
echo "  Konfigi borgmatic:"
echo "    ${FILES_YAML}"
echo "    ${MYSQL_YAML}"
echo ""
echo "  Repozytoria borg:"
echo "    FILES: ${REPO_FILES}"
echo "    MYSQL: ${REPO_MYSQL}"
echo ""
echo "  Haslo borg:"
echo "    Passcommand: ${PASSCOMMAND_FILE}"
echo -e "    ${RED}Backup hasla: ${PASS_BACKUP_FILE}${NC}"
echo ""
echo "==========================================="
echo " CO TERAZ:"
echo "==========================================="
echo ""
echo "1. ZABEZPIECZ HASLO BORG:"
echo "   cat ${PASS_BACKUP_FILE}"
echo "   Skopiuj i zapisz w bezpiecznym miejscu!"
echo ""
echo "2. Sprawdz czy SSH do serwera backupowego dziala:"
echo "   ssh ${BACKUP_USER}@${BACKUP_HOST} 'echo OK'"
echo ""
echo "3. Uruchom pierwszy backup recznie:"
echo "   borgmatic create --verbosity 1 -c ${FILES_YAML}"
echo "   borgmatic create --verbosity 1 -c ${MYSQL_YAML}"
echo ""
echo "4. Sprawdz repozytoria:"
echo "   borgmatic repo-list -c ${FILES_YAML}"
echo "   borgmatic repo-list -c ${MYSQL_YAML}"
echo ""
echo "5. Zainstaluj monitoring Telegram:"
echo "   ./install-borgmatic-monitor.sh"
echo ""
echo "==========================================="

# Jesli install-borgmatic-monitor.sh jest obok — zaproponuj uruchomienie
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "${SCRIPT_DIR}/install-borgmatic-monitor.sh" ]]; then
  echo ""
  read -rp "Zainstalowac monitoring Telegram teraz? [Y/n] " INSTALL_MONITOR
  INSTALL_MONITOR="${INSTALL_MONITOR:-Y}"
  if [[ "${INSTALL_MONITOR}" =~ ^[Yy]$ ]]; then
    bash "${SCRIPT_DIR}/install-borgmatic-monitor.sh"
  fi
fi
