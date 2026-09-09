#!/bin/bash
# /usr/local/bin/borgmatic-on-error.sh
# Hook wywoływany natychmiast przez borgmatic przy błędzie
#
# Zmienne interpolowane przez borgmatic:
#   {configuration_filename}  — ścieżka configa
#   {repository}              — ścieżka repozytorium
#   {error}                   — treść błędu
#   {output}                  — output borg
#
# Użycie w borgmatic YAML (deprecated ale działa w 2.x):
#   on_error:
#     - "/usr/local/bin/borgmatic-on-error.sh {configuration_filename} {repository} {error}"
#
# Lub nowy format commands:
#   commands:
#     - after: error
#       run:
#         - "/usr/local/bin/borgmatic-on-error.sh {configuration_filename} {repository} {error}"

CONFIG_FILE="${1:-unknown}"
REPOSITORY="${2:-unknown}"
ERROR_MSG="${3:-Nieznany błąd}"

# Ignoruj bledy z lockiem (backup w toku — nie alarmuj)
# Borg exit 2 z list/info podczas create = prawie zawsze lock
if echo "${ERROR_MSG}" | grep -qiE "lock\.exclusive|Failed to (create|acquire) the lock"; then
  exit 0
fi
if echo "${ERROR_MSG}" | grep -qE "borg (list|info|create|prune|compact|check).*returned non-zero exit status 2"; then
  exit 0
fi

CONFIG_NAME=$(basename "${CONFIG_FILE}" .yaml)

# Ogranicz error message do 800 znaków (Telegram limit + czytelność)
if [[ ${#ERROR_MSG} -gt 800 ]]; then
  ERROR_MSG="${ERROR_MSG:0:800}..."
fi

TEXT="<b>Config:</b> ${CONFIG_NAME}
<b>Repo:</b> ${REPOSITORY}

<code>${ERROR_MSG}</code>"

/usr/local/bin/borgmatic-notify.sh "🚨" "Borgmatic ERROR: ${CONFIG_NAME}" "${TEXT}"
