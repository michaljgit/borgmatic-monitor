#!/bin/bash
# install-borgmatic-monitor.sh
# Instaluje monitoring borgmatic z Telegram + borg_exit_codes
set -euo pipefail

echo "==========================================="
echo " Instalacja borgmatic-monitor (Telegram)"
echo "==========================================="

# 1. Kopiuj skrypty
echo ""
echo "[1/5] Kopiowanie skryptów do /usr/local/bin/ ..."
for script in borgmatic-notify.sh borgmatic-monitor.sh borgmatic-on-error.sh; do
  if [[ -f "${script}" ]]; then
    cp -v "${script}" "/usr/local/bin/${script}"
    chmod +x "/usr/local/bin/${script}"
  else
    echo "  BRAK: ${script} — pomiń"
  fi
done

# 2. Katalogi + env
echo ""
echo "[2/5] Tworzenie katalogów i konfiguracji..."
mkdir -p /var/log/borgmatic-monitor
echo "  OK: /var/log/borgmatic-monitor"

# Utwórz .env z danymi Telegram
ENV_FILE="/etc/borgmatic-monitor.env"
TG_TOKEN="${BORGMATIC_TG_TOKEN:-8234236760:AAGaaMBv2EPeB1Fa0CHbVImTkPOrN3F_TBE}"
TG_CHAT="${BORGMATIC_TG_CHAT_ID:--5127666651}"

cat > "${ENV_FILE}" <<ENVEOF
# /etc/borgmatic-monitor.env
BORGMATIC_TG_TOKEN="${TG_TOKEN}"
BORGMATIC_TG_CHAT_ID="${TG_CHAT}"
ENVEOF
chmod 600 "${ENV_FILE}"
echo "  OK: ${ENV_FILE} (token + chat_id skonfigurowane)"

# 3. Dodaj on_error hook + borg_exit_codes do configów borgmatic
echo ""
echo "[3/5] Aktualizacja configów borgmatic..."

# Automatyczne wykrycie configow borgmatic
CONFIGS=()
for cfg_file in /etc/borgmatic/*.yaml; do
  [[ -f "${cfg_file}" ]] || continue
  cfg_name=$(basename "${cfg_file}" .yaml)
  CONFIGS+=("${cfg_name}")
done

if [[ ${#CONFIGS[@]} -eq 0 ]]; then
  echo "  WARN: Brak configow w /etc/borgmatic/ — pomijam krok"
fi

ON_ERROR_BLOCK='
commands:
  - after: error
    run:
      - "/usr/local/bin/borgmatic-on-error.sh {configuration_filename} {repository} {error}"'

# borg_exit_codes — podnosi warningi o brakujących plikach do errorów
BORG_EXIT_CODES_BLOCK='
borg_exit_codes:
  - code: 100
    treat_as: error
  - code: 105
    treat_as: error'

for config_name in "${CONFIGS[@]}"; do
  config_file="/etc/borgmatic/${config_name}.yaml"
  if [[ ! -f "${config_file}" ]]; then
    echo "  SKIP: ${config_file} nie istnieje"
    continue
  fi

  CHANGED=0

  # Dodaj on_error jeśli brak
  if ! grep -q "borgmatic-on-error" "${config_file}" 2>/dev/null; then
    echo "${ON_ERROR_BLOCK}" >> "${config_file}"
    echo "  ADD:  ${config_file} — commands (on error) hook"
    CHANGED=1
  else
    echo "  OK:   ${config_file} — error hook już jest"
  fi

  # Dodaj borg_exit_codes jeśli brak
  if ! grep -q "borg_exit_codes" "${config_file}" 2>/dev/null; then
    echo "${BORG_EXIT_CODES_BLOCK}" >> "${config_file}"
    echo "  ADD:  ${config_file} — borg_exit_codes"
    CHANGED=1
  else
    echo "  OK:   ${config_file} — borg_exit_codes już jest"
  fi

  # Waliduj po zmianach
  if [[ ${CHANGED} -eq 1 ]]; then
    if borgmatic config validate -c "${config_file}" >/dev/null 2>&1; then
      echo "  ✓     ${config_file} — walidacja OK"
    else
      echo "  ✗     ${config_file} — UWAGA: walidacja FAILED! Sprawdź ręcznie"
    fi
  fi
done

# 4. Cron
echo ""
echo "[4/5] Konfiguracja cron..."
CRON_LINE="*/30 * * * * /usr/local/bin/borgmatic-monitor.sh 2>&1 | logger -t borgmatic-monitor"
if crontab -l 2>/dev/null | grep -q "borgmatic-monitor.sh"; then
  echo "  OK:   Cron już skonfigurowany"
else
  (crontab -l 2>/dev/null; echo ""; echo "# Borgmatic backup monitoring (co 30 min)"; echo "${CRON_LINE}") | crontab -
  echo "  ADD:  Cron co 30 min"
fi

# 5. Podsumowanie
echo ""
echo "[5/5] Podsumowanie..."
echo ""
echo "  Pliki:"
for f in /usr/local/bin/borgmatic-{notify,monitor,on-error}.sh; do
  echo -n "    ${f}: "
  [[ -x "${f}" ]] && echo "✓" || echo "✗"
done
echo -n "    /var/log/borgmatic-monitor/: "
[[ -d /var/log/borgmatic-monitor ]] && echo "✓" || echo "✗"

echo ""
echo "==========================================="
echo " CO TERAZ:"
echo "==========================================="
echo ""
echo "1. Skonfiguruj Telegram bota:"
echo "   nano /etc/borgmatic-monitor.env"
echo "   → BORGMATIC_TG_TOKEN=\"twój-token-bota\""
echo "   → BORGMATIC_TG_CHAT_ID=\"twój-chat-id\""
echo ""
echo "   Jak uzyskać:"
echo "   a) Napisz do @BotFather na Telegram → /newbot"
echo "   b) Skopiuj token"
echo "   c) Dodaj bota do grupy lub napisz do niego"
echo "   d) Chat ID: https://api.telegram.org/bot<TOKEN>/getUpdates"
echo ""
echo "2. Test powiadomienia:"
echo "   /usr/local/bin/borgmatic-notify.sh '🧪' 'Test' 'Testowa wiadomość'"
echo ""
echo "3. Pierwszy pełny check:"
echo "   /usr/local/bin/borgmatic-monitor.sh --force"
echo ""
echo "4. Status HTML (podepnij pod Nginx z auth):"
echo "   /var/log/borgmatic-monitor/status.html"
echo ""
echo "5. Opcjonalnie — Nginx config:"
echo '   location /backup-status {'
echo '       alias /var/log/borgmatic-monitor/status.html;'
echo '       auth_basic "Backup Monitor";'
echo '       auth_basic_user_file /etc/nginx/.htpasswd-backup;'
echo '   }'
echo ""
echo "==========================================="
