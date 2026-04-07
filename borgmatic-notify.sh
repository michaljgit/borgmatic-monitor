#!/bin/bash
# /usr/local/bin/borgmatic-notify.sh
# Wysyła powiadomienia do Telegram
#
# Użycie:
#   borgmatic-notify.sh "emoji" "tytuł" "treść"
#   BORGMATIC_TG_SILENT=1 borgmatic-notify.sh ...   # bez dźwięku
#
# Konfiguracja (zmień poniżej lub ustaw env):
#   BORGMATIC_TG_TOKEN   — token bota Telegram
#   BORGMATIC_TG_CHAT_ID — chat_id (grupa lub user)

# Wczytaj konfigurację z .env (obok skryptu lub /etc/borgmatic-monitor.env)
ENV_FILE="${BORGMATIC_ENV_FILE:-/etc/borgmatic-monitor.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

TELEGRAM_TOKEN="${BORGMATIC_TG_TOKEN:-}"
TELEGRAM_CHAT_ID="${BORGMATIC_TG_CHAT_ID:-}"

if [[ -z "${TELEGRAM_TOKEN}" ]] || [[ -z "${TELEGRAM_CHAT_ID}" ]]; then
  echo "ERROR: Brak BORGMATIC_TG_TOKEN lub BORGMATIC_TG_CHAT_ID" >&2
  echo "Ustaw w ${ENV_FILE} lub jako zmienne środowiskowe" >&2
  exit 1
fi

EMOJI="${1:-⚠️}"
TITLE="${2:-Borgmatic Alert}"
TEXT="${3:-Brak treści}"

HOSTNAME=$(hostname -f)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SILENT="${BORGMATIC_TG_SILENT:-0}"

# Buduj wiadomość w MarkdownV2
# Escapujemy znaki specjalne MarkdownV2
escape_md() {
  local s="$1"
  # MarkdownV2 wymaga escape tych znaków: _ * [ ] ( ) ~ ` > # + - = | { } . !
  # Ale my chcemy zachować *bold* i `code`, więc escapujemy resztę
  s="${s//\\/\\\\}"
  s="${s//\[/\\[}"
  s="${s//\]/\\]}"
  s="${s//\(/\\(}"
  s="${s//\)/\\)}"
  s="${s//~/\\~}"
  s="${s//>/\\>}"
  s="${s//#/\\#}"
  s="${s//+/\\+}"
  s="${s//=/\\=}"
  s="${s//|/\\|}"
  s="${s//\{/\\{}"
  s="${s//\}/\\}}"
  s="${s//./\\.}"
  s="${s//!/\\!}"
  s="${s//-/\\-}"
  echo "$s"
}

# Prostsza wersja — HTML parse mode (łatwiejszy do escape)
MESSAGE="<b>${EMOJI} ${TITLE}</b>

${TEXT}

<i>🖥 ${HOSTNAME}  •  🕐 ${TIMESTAMP}</i>"

# Wyślij
DISABLE_NOTIFICATION="false"
[[ "${SILENT}" == "1" ]] && DISABLE_NOTIFICATION="true"

curl -s -X POST \
  "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  -d "disable_notification=${DISABLE_NOTIFICATION}" \
  --data-urlencode "text=${MESSAGE}" \
  >/dev/null 2>&1
