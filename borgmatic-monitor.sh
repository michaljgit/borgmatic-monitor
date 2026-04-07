#!/bin/bash
# /usr/local/bin/borgmatic-monitor.sh
# Monitoring backupów borgmatic
#   — sprawdza wiek archiwów
#   — sprawdza rozmiar repo + wykrywa anomalie rozmiaru
#   — alertuje do Telegram
#   — generuje HTML status page
#
# Użycie:
#   borgmatic-monitor.sh              # pełny check + alerty
#   borgmatic-monitor.sh --quiet      # tylko zapis statusu
#   borgmatic-monitor.sh --status     # wyświetl ostatni status
#   borgmatic-monitor.sh --force      # wymuś alert niezależnie od stanu
#
# Cron (co 30 min):
#   */30 * * * * /usr/local/bin/borgmatic-monitor.sh 2>&1 | logger -t borgmatic-monitor

set -uo pipefail

# ============================================================================
# KONFIGURACJA
# ============================================================================

DEFAULT_MAX_AGE=7200  # 2h w sekundach

# Próg zmiany rozmiaru repo (procentowo) — alarmuj jeśli zmiana > X%
SIZE_CHANGE_WARNING_PCT=20   # 20% = warning
SIZE_CHANGE_ERROR_PCT=50     # 50% = error (np. repo nagle o połowę mniejsze)

STATUS_DIR="/var/log/borgmatic-monitor"
STATUS_FILE="${STATUS_DIR}/status.json"
STATUS_HTML="${STATUS_DIR}/status.html"
SIZE_HISTORY="${STATUS_DIR}/size_history.json"
LOG_FILE="${STATUS_DIR}/monitor.log"
ALERT_LOCK="${STATUS_DIR}/.last_alert_status"

CONFIG_DIR="/etc/borgmatic"

# Progi wiekowe per config (nazwa pliku bez .yaml => sekundy)
declare -A THRESHOLDS=(
  ["crm-sql"]=7200
  ["crm"]=7200
  ["files-admin"]=7200
  ["files"]=7200
  ["mysql"]=7200
)

CONFIGS=(
  "crm-sql"
  "crm"
  "files-admin"
  "files"
  "mysql"
)

# ============================================================================
# FUNKCJE POMOCNICZE
# ============================================================================

mkdir -p "${STATUS_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

# Obetnij log do 10000 linii
truncate_log() {
  if [[ -f "${LOG_FILE}" ]] && [[ $(wc -l < "${LOG_FILE}") -gt 10000 ]]; then
    tail -5000 "${LOG_FILE}" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "${LOG_FILE}"
  fi
}

notify_error() {
  /usr/local/bin/borgmatic-notify.sh "🔴" "$1" "$2"
}

notify_warning() {
  /usr/local/bin/borgmatic-notify.sh "🟡" "$1" "$2"
}

notify_ok() {
  /usr/local/bin/borgmatic-notify.sh "✅" "$1" "$2"
}

notify_info() {
  BORGMATIC_TG_SILENT=1 /usr/local/bin/borgmatic-notify.sh "📊" "$1" "$2"
}

# ============================================================================
# ROZMIAR REPO — historia i wykrywanie anomalii
# ============================================================================

# Pobierz poprzedni rozmiar z historii
get_prev_size() {
  local config_name="$1"
  if [[ -f "${SIZE_HISTORY}" ]]; then
    python3 -c "
import json, sys
try:
    with open('${SIZE_HISTORY}') as f:
        data = json.load(f)
    print(data.get('${config_name}', {}).get('size_bytes', 0))
except:
    print(0)
" 2>/dev/null
  else
    echo 0
  fi
}

# Zapisz aktualny rozmiar do historii
save_size() {
  local config_name="$1"
  local size_bytes="$2"

  python3 -c "
import json, os
path = '${SIZE_HISTORY}'
try:
    with open(path) as f:
        data = json.load(f)
except:
    data = {}
data['${config_name}'] = {
    'size_bytes': ${size_bytes},
    'updated': '$(date -Iseconds)'
}
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
}

# Sprawdź zmianę rozmiaru, zwraca: OK|WARNING|ERROR i opis
check_size_change() {
  local config_name="$1"
  local current_bytes="$2"
  local prev_bytes
  prev_bytes=$(get_prev_size "${config_name}")

  # Zapisz nowy rozmiar
  save_size "${config_name}" "${current_bytes}"

  # Jeśli brak historii lub zero — skip
  if [[ "${prev_bytes}" -eq 0 ]] || [[ "${current_bytes}" -eq 0 ]]; then
    echo "OK|Pierwsza obserwacja rozmiaru"
    return 0
  fi

  # Oblicz zmianę procentową
  local change_pct
  change_pct=$(python3 -c "
prev = ${prev_bytes}
curr = ${current_bytes}
if prev == 0:
    print(0)
else:
    pct = abs(curr - prev) / prev * 100
    print(f'{pct:.1f}')
" 2>/dev/null)

  local direction="wzrost"
  [[ "${current_bytes}" -lt "${prev_bytes}" ]] && direction="spadek"

  local human_prev human_curr
  human_prev=$(python3 -c "s=${prev_bytes}; print(f'{s/1073741824:.2f} GB') if s>1073741824 else print(f'{s/1048576:.1f} MB')" 2>/dev/null)
  human_curr=$(python3 -c "s=${current_bytes}; print(f'{s/1073741824:.2f} GB') if s>1073741824 else print(f'{s/1048576:.1f} MB')" 2>/dev/null)

  local change_float
  change_float=$(echo "${change_pct}" | tr -d '-')

  if python3 -c "exit(0 if ${change_float} > ${SIZE_CHANGE_ERROR_PCT} else 1)" 2>/dev/null; then
    echo "ERROR|Rozmiar repo: ${direction} o ${change_pct}% (${human_prev} → ${human_curr})"
    return 2
  elif python3 -c "exit(0 if ${change_float} > ${SIZE_CHANGE_WARNING_PCT} else 1)" 2>/dev/null; then
    echo "WARNING|Rozmiar repo: ${direction} o ${change_pct}% (${human_prev} → ${human_curr})"
    return 1
  else
    echo "OK|Rozmiar stabilny: ${human_curr} (zmiana ${change_pct}%)"
    return 0
  fi
}

# ============================================================================
# CHECK POJEDYNCZEGO CONFIGA
# ============================================================================

check_config() {
  local config_name="$1"
  local config_file="${CONFIG_DIR}/${config_name}.yaml"
  local max_age="${THRESHOLDS[${config_name}]:-${DEFAULT_MAX_AGE}}"

  if [[ ! -f "${config_file}" ]]; then
    log "ERROR: Config ${config_file} nie istnieje"
    echo '{"config":"'"${config_name}"'","status":"ERROR","message":"Config nie istnieje","last_archive":"N/A","age_seconds":-1,"age_human":"N/A","repo_size":"N/A","repo_size_bytes":0,"size_status":"N/A","size_message":"N/A"}'
    return 2
  fi

  # === Pobierz listę archiwów ===
  local repo_list_json
  if ! repo_list_json=$(borgmatic repo-list --json -c "${config_file}" 2>/dev/null); then
    log "ERROR: borgmatic repo-list failed dla ${config_name}"
    echo '{"config":"'"${config_name}"'","status":"ERROR","message":"repo-list failed","last_archive":"N/A","age_seconds":-1,"age_human":"N/A","repo_size":"N/A","repo_size_bytes":0,"size_status":"N/A","size_message":"N/A"}'
    return 2
  fi

  # === Parsuj najnowsze archiwum ===
  local latest_info
  latest_info=$(echo "${repo_list_json}" | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
latest_time = None
latest_name = ''
for repo in data:
    for archive in repo.get('archives', []):
        ts_str = archive.get('start', archive.get('time', ''))
        if not ts_str:
            continue
        try:
            ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        except:
            try:
                ts = datetime.strptime(ts_str[:19], '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
            except:
                continue
        if latest_time is None or ts > latest_time:
            latest_time = ts
            latest_name = archive.get('name', archive.get('archive', 'unknown'))
if latest_time:
    now = datetime.now(timezone.utc)
    age = int((now - latest_time).total_seconds())
    print(f'{latest_name}|{latest_time.strftime(\"%Y-%m-%d %H:%M:%S\")}|{age}')
else:
    print('unknown|unknown|-1')
" 2>/dev/null || echo "unknown|unknown|-1")

  local archive_name age_str age_seconds
  IFS='|' read -r archive_name age_str age_seconds <<< "${latest_info}"

  # Ludzki format wieku
  local age_human
  if [[ "${age_seconds}" -lt 0 ]]; then
    age_human="nieznany"
  elif [[ "${age_seconds}" -lt 60 ]]; then
    age_human="${age_seconds}s"
  elif [[ "${age_seconds}" -lt 3600 ]]; then
    age_human="$((age_seconds / 60))m"
  elif [[ "${age_seconds}" -lt 86400 ]]; then
    age_human="$((age_seconds / 3600))h $((age_seconds % 3600 / 60))m"
  else
    age_human="$((age_seconds / 86400))d $((age_seconds % 86400 / 3600))h"
  fi

  # === Rozmiar repo ===
  local repo_size="N/A"
  local repo_size_bytes=0
  local repo_info_json
  if repo_info_json=$(borgmatic repo-info --json -c "${config_file}" 2>/dev/null); then
    local size_data
    size_data=$(echo "${repo_info_json}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for repo in data:
    # Borg 1.x
    cache = repo.get('cache', {})
    if 'stats' in cache:
        size = cache['stats'].get('unique_csize', cache['stats'].get('total_csize', 0))
    else:
        # Borg 2.x
        size = repo.get('repository', {}).get('unique_csize', 0)
    if size > 0:
        if size > 1073741824:
            human = f'{size/1073741824:.2f} GB'
        elif size > 1048576:
            human = f'{size/1048576:.1f} MB'
        else:
            human = f'{size/1024:.1f} KB'
        print(f'{size}|{human}')
        sys.exit(0)
print('0|N/A')
" 2>/dev/null || echo "0|N/A")

    IFS='|' read -r repo_size_bytes repo_size <<< "${size_data}"
  fi

  # === Sprawdź zmianę rozmiaru ===
  local size_result size_status size_message
  size_result=$(check_size_change "${config_name}" "${repo_size_bytes}")
  IFS='|' read -r size_status size_message <<< "${size_result}"

  # === Ocena statusu (wiek) ===
  local status="OK"
  local message="OK"
  local retcode=0

  if [[ "${age_seconds}" -lt 0 ]]; then
    status="ERROR"
    message="Nie można odczytać wieku archiwum"
    retcode=2
  elif [[ "${age_seconds}" -gt $((max_age * 3)) ]]; then
    status="ERROR"
    message="Archiwum KRYTYCZNIE stare: ${age_human} (limit: $((max_age/3600))h)"
    retcode=2
  elif [[ "${age_seconds}" -gt "${max_age}" ]]; then
    status="WARNING"
    message="Archiwum za stare: ${age_human} (limit: $((max_age/3600))h)"
    retcode=1
  fi

  # Eskaluj status jeśli rozmiar jest gorszy
  if [[ "${size_status}" == "ERROR" ]] && [[ ${retcode} -lt 2 ]]; then
    status="ERROR"
    message="${message} + ${size_message}"
    retcode=2
  elif [[ "${size_status}" == "WARNING" ]] && [[ ${retcode} -lt 1 ]]; then
    status="WARNING"
    message="${message} + ${size_message}"
    retcode=1
  fi

  log "${status}: ${config_name} — backup: ${age_human} temu, repo: ${repo_size}, size: ${size_message}"

  # JSON output
  python3 -c "
import json
print(json.dumps({
    'config': '${config_name}',
    'status': '${status}',
    'message': '${message}',
    'last_archive': '${archive_name}',
    'last_archive_time': '${age_str}',
    'age_seconds': ${age_seconds},
    'age_human': '${age_human}',
    'repo_size': '${repo_size}',
    'repo_size_bytes': ${repo_size_bytes},
    'size_status': '${size_status}',
    'size_message': '${size_message}'
}, ensure_ascii=False))
"

  return ${retcode}
}

# ============================================================================
# GENERUJ HTML STATUS PAGE
# ============================================================================

generate_html() {
  local results_file="$1"

  python3 - "${results_file}" "${STATUS_HTML}" <<'PYEOF'
import json, sys
from datetime import datetime

results_file = sys.argv[1]
output_file = sys.argv[2]

results = []
with open(results_file) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                results.append(json.loads(line))
            except:
                pass

count_ok = sum(1 for r in results if r['status'] == 'OK')
count_warn = sum(1 for r in results if r['status'] == 'WARNING')
count_err = sum(1 for r in results if r['status'] == 'ERROR')

now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

badge = {
    'OK':      ('badge-ok', '✅'),
    'WARNING': ('badge-warn', '⚠️'),
    'ERROR':   ('badge-err', '🔴'),
}

rows = ''
for r in results:
    cls, icon = badge.get(r['status'], ('badge-ok', '?'))
    rows += f'''<tr>
  <td><strong>{r['config']}</strong></td>
  <td><span class="badge {cls}">{icon} {r['status']}</span></td>
  <td>{r.get('last_archive_time', 'N/A')}</td>
  <td class="{r['status'].lower()}">{r['age_human']}</td>
  <td>{r['repo_size']}</td>
  <td><span class="badge {badge.get(r['size_status'], ('badge-ok',''))[0]}">{r['size_status']}</span></td>
  <td class="msg">{r['size_message']}</td>
</tr>
'''

html = f'''<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="300">
<title>Borgmatic Status</title>
<style>
  *{{box-sizing:border-box}}
  body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:20px}}
  .c{{max-width:1100px;margin:0 auto}}
  h1{{color:#93c5fd;border-bottom:2px solid #1e3a5f;padding-bottom:10px;margin-bottom:5px}}
  .upd{{color:#64748b;font-size:.85em;margin-bottom:20px}}
  .cards{{display:flex;gap:16px;margin:16px 0}}
  .card{{flex:1;padding:16px;border-radius:10px;text-align:center}}
  .card h2{{margin:0;font-size:2.2em}}
  .card p{{margin:4px 0 0;color:#94a3b8;font-size:.85em}}
  .card-ok{{background:#064e3b33;border:1px solid #065f46}}
  .card-warn{{background:#78350f33;border:1px solid #92400e}}
  .card-err{{background:#7f1d1d33;border:1px solid #991b1b}}
  table{{width:100%;border-collapse:collapse;margin-top:12px;font-size:.9em}}
  th,td{{padding:10px 12px;text-align:left;border-bottom:1px solid #1e293b}}
  th{{background:#1e293b;color:#93c5fd;font-weight:600;position:sticky;top:0}}
  tr:hover{{background:#1e293b55}}
  .badge{{display:inline-block;padding:2px 10px;border-radius:12px;font-size:.8em;font-weight:600;white-space:nowrap}}
  .badge-ok{{background:#064e3b;color:#4ade80}}
  .badge-warn{{background:#78350f;color:#fbbf24}}
  .badge-err{{background:#7f1d1d;color:#f87171}}
  .ok{{color:#4ade80}}.warning{{color:#fbbf24}}.error{{color:#f87171}}
  .msg{{font-size:.82em;color:#94a3b8;max-width:280px}}
</style>
</head>
<body>
<div class="c">
<h1>🗄️ Borgmatic Backup Monitor</h1>
<p class="upd">Ostatnia aktualizacja: {now} · Auto-refresh co 5 min</p>
<div class="cards">
  <div class="card card-ok"><h2>{count_ok}</h2><p>OK</p></div>
  <div class="card card-warn"><h2>{count_warn}</h2><p>Ostrzeżenia</p></div>
  <div class="card card-err"><h2>{count_err}</h2><p>Błędy</p></div>
</div>
<table>
<thead><tr>
  <th>Backup</th><th>Status</th><th>Ostatni backup</th><th>Wiek</th>
  <th>Rozmiar</th><th>Δ Rozm.</th><th>Info</th>
</tr></thead>
<tbody>
{rows}
</tbody>
</table>
</div>
</body>
</html>'''

with open(output_file, 'w') as f:
    f.write(html)
PYEOF
}

# ============================================================================
# BUDUJ WIADOMOŚĆ TELEGRAM
# ============================================================================

build_telegram_message() {
  local results_file="$1"

  python3 - "${results_file}" <<'PYEOF'
import json, sys

results = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                results.append(json.loads(line))
            except:
                pass

icons = {'OK': '✅', 'WARNING': '⚠️', 'ERROR': '🔴'}
lines = []
for r in results:
    icon = icons.get(r['status'], '❓')
    line = f"{icon} <b>{r['config']}</b> — {r['age_human']}"
    if r['repo_size'] != 'N/A':
        line += f" · {r['repo_size']}"
    if r['status'] != 'OK':
        line += f"\n   ↳ {r['message']}"
    if r.get('size_status') not in ('OK', 'N/A') and r.get('size_message'):
        line += f"\n   ↳ 📏 {r['size_message']}"
    lines.append(line)

print('\n'.join(lines))
PYEOF
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-}" in
  --status)
    if [[ -f "${STATUS_HTML}" ]]; then
      echo "Status HTML: ${STATUS_HTML}"
      echo "---"
      [[ -f "${STATUS_FILE}" ]] && cat "${STATUS_FILE}"
    else
      echo "Brak pliku statusu. Uruchom: borgmatic-monitor.sh"
    fi
    exit 0
    ;;
  --quiet)  QUIET=1; FORCE=0 ;;
  --force)  QUIET=0; FORCE=1 ;;
  *)        QUIET=0; FORCE=0 ;;
esac

truncate_log
log "=== Start monitoringu borgmatic ==="

# Plik tymczasowy na wyniki
RESULTS_TMP=$(mktemp)
trap "rm -f ${RESULTS_TMP}" EXIT

GLOBAL_STATUS=0
HAS_ERRORS=0
HAS_WARNINGS=0

for config_name in "${CONFIGS[@]}"; do
  retcode=0
  result=$(check_config "${config_name}") || retcode=$?
  echo "${result}" >> "${RESULTS_TMP}"

  if [[ ${retcode} -eq 2 ]]; then
    GLOBAL_STATUS=2
    HAS_ERRORS=1
  elif [[ ${retcode} -eq 1 ]] && [[ ${GLOBAL_STATUS} -lt 2 ]]; then
    GLOBAL_STATUS=1
    HAS_WARNINGS=1
  fi
done

# Zapisz status
cp "${RESULTS_TMP}" "${STATUS_FILE}"

# Generuj HTML
generate_html "${RESULTS_TMP}"

# === Alerty Telegram ===
if [[ "${QUIET}" -eq 0 ]]; then
  LAST_STATUS=$(cat "${ALERT_LOCK}" 2>/dev/null || echo "INIT")
  CURRENT_STATUS="OK"
  [[ ${GLOBAL_STATUS} -eq 1 ]] && CURRENT_STATUS="WARNING"
  [[ ${GLOBAL_STATUS} -eq 2 ]] && CURRENT_STATUS="ERROR"

  SHOULD_ALERT=0

  # Alert przy zmianie stanu lub --force
  if [[ "${FORCE}" -eq 1 ]]; then
    SHOULD_ALERT=1
  elif [[ "${CURRENT_STATUS}" != "${LAST_STATUS}" ]]; then
    SHOULD_ALERT=1
  fi

  if [[ ${SHOULD_ALERT} -eq 1 ]]; then
    MSG=$(build_telegram_message "${RESULTS_TMP}")

    if [[ "${CURRENT_STATUS}" == "ERROR" ]]; then
      notify_error "BACKUP FAILURE" "${MSG}"
    elif [[ "${CURRENT_STATUS}" == "WARNING" ]]; then
      notify_warning "Backup Warning" "${MSG}"
    else
      if [[ "${LAST_STATUS}" != "OK" ]] && [[ "${LAST_STATUS}" != "INIT" ]]; then
        notify_ok "Backupy wróciły do normy" "${MSG}"
      fi
    fi

    echo "${CURRENT_STATUS}" > "${ALERT_LOCK}"
  fi
fi

STATUS_LABEL="OK"
[[ ${GLOBAL_STATUS} -eq 1 ]] && STATUS_LABEL="WARNING"
[[ ${GLOBAL_STATUS} -eq 2 ]] && STATUS_LABEL="ERROR"
log "=== Monitoring zakończony — status: ${STATUS_LABEL} ==="

exit ${GLOBAL_STATUS}
