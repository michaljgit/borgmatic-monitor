# borgmatic-monitor

Monitoring backupów [borgmatic](https://torsion.org/borgmatic/) z alertami Telegram i HTML dashboardem.

## Funkcje

- **Sprawdza wiek archiwów** — alert jeśli backup jest starszy niż próg (domyślnie 2h)
- **Wykrywa anomalie rozmiaru repo** — alert jeśli rozmiar zmienił się o >20% (warning) lub >50% (error)
- **Natychmiastowy alert on_error** — hook borgmatic wysyła Telegram w momencie błędu
- **HTML dashboard** — auto-refreshujący status page do podpięcia pod Nginx
- **Inteligentne alerty** — powiadamia tylko przy zmianie stanu (nie spamuje)
- **Recovery notification** — informuje gdy backupy wracają do normy
- **`borg_exit_codes`** — podnosi ukryte warningi Borg do pełnych błędów

## Pliki

| Plik | Opis |
|------|------|
| `borgmatic-monitor.sh` | Główny skrypt (cron co 30 min) |
| `borgmatic-notify.sh` | Wysyłka alertów do Telegram |
| `borgmatic-on-error.sh` | Hook borgmatic — natychmiastowy alert |
| `install-borgmatic-monitor.sh` | Installer (kopiuje, konfiguruje cron, dopisuje hooki) |
| `.env.example` | Szablon konfiguracji (token + chat_id) |

## Instalacja

```bash
git clone https://github.com/TWOJE-KONTO/borgmatic-monitor.git
cd borgmatic-monitor

# Uzupełnij dane Telegram
cp .env.example /etc/borgmatic-monitor.env
nano /etc/borgmatic-monitor.env

# Zainstaluj
bash install-borgmatic-monitor.sh
```

## Konfiguracja Telegram

1. Napisz do [@BotFather](https://t.me/BotFather) → `/newbot`
2. Skopiuj token bota
3. Dodaj bota do grupy lub napisz do niego bezpośrednio
4. Pobierz `chat_id`:
   ```
   curl https://api.telegram.org/bot<TOKEN>/getUpdates | python3 -m json.tool
   ```
5. Wpisz dane do `/etc/borgmatic-monitor.env`:
   ```
   BORGMATIC_TG_TOKEN="123456:ABC..."
   BORGMATIC_TG_CHAT_ID="-100..."
   ```

## Test

```bash
# Test powiadomienia Telegram
/usr/local/bin/borgmatic-notify.sh '🧪' 'Test' 'Testowa wiadomość'

# Pierwszy pełny check (wymusza alert)
/usr/local/bin/borgmatic-monitor.sh --force

# Sprawdź log
tail -20 /var/log/borgmatic-monitor/monitor.log

# Otwórz dashboard
# http://twoj-serwer/backup-status (jeśli podpięty pod Nginx)
```

## Progi alertów

### Wiek archiwum
| Warunek | Status |
|---------|--------|
| `< max_age` | ✅ OK |
| `> max_age` | ⚠️ WARNING |
| `> max_age × 3` | 🔴 ERROR |

Domyślnie `max_age = 7200s (2h)`. Konfiguruj tablicę `THRESHOLDS` w `borgmatic-monitor.sh`.

### Zmiana rozmiaru repo
| Zmiana | Status |
|--------|--------|
| `< 20%` | ✅ OK |
| `> 20%` | ⚠️ WARNING |
| `> 50%` | 🔴 ERROR |

Konfiguruj `SIZE_CHANGE_WARNING_PCT` / `SIZE_CHANGE_ERROR_PCT` w `borgmatic-monitor.sh`.

## Nginx (opcjonalnie)

```nginx
location /backup-status {
    alias /var/log/borgmatic-monitor/status.html;
    auth_basic "Backup Monitor";
    auth_basic_user_file /etc/nginx/.htpasswd-backup;
}
```

## Wymagania

- borgmatic 2.x
- Python 3
- curl
- bash 4+

## Kompatybilność borgmatic

Skrypt używa:
- `borgmatic repo-list --json` — wiek archiwów
- `borgmatic repo-info --json` — rozmiar repo
- `on_error` hook (deprecated ale wspierany w 2.x)
- `borg_exit_codes` (borgmatic 2.1.0+)

## Licencja

MIT
