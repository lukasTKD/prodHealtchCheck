# Server Health Monitor

System monitorowania stanu serwerów Windows z interfejsem webowym.

## Funkcje

### Kondycja serwerów
- Monitorowanie CPU, RAM, dysków
- Top 3 procesy zużywające CPU i RAM
- Status usług z dysku D:\ i E:\
- Status Trellix (antywirus)
- Status Windows Firewall
- Status IIS (Application Pools, Sites)
- Grupowanie serwerów w zakładki (LAN + DMZ)
- Obsługa serwerów w strefie DMZ (SSL/Negotiate)
- Filtrowanie serwerów krytycznych (CPU/RAM >90%)

### Infrastruktura
- **Klastry Windows** — węzły, role, IP, status (Online/Offline) z podziałem na typy (SQL/FileShare/MQ)
- **Udziały sieciowe** — dane z pliku CSV (fileshare.csv)
- **Instancje SQL** — dane z pliku CSV (sql_db_details.csv)
- **Kolejki MQ** — QManager, status (Running/inne), port listenera, nazwy kolejek, serwer
- **Przełączenia ról** — historia failover/failback klastrów Windows z ostatnich 30 dni

### Logi systemowe (Event Log)
- Przeglądarka Windows Event Log z dowolnych serwerów
- Formularz: nazwy serwerów, typ logów, okres czasowy
- Zakładki per serwer z liczbą zdarzeń
- Sortowanie po wszystkich kolumnach (data, typ, kod, źródło, opis)
- Wyszukiwanie w logach z podświetlaniem i licznikiem wyników
- Kolorowanie wierszy wg poziomu (Error/Warning/Information/Critical)
- Konfiguracja typów logów z zewnętrznego pliku JSON
- Zapis pobranych logów do pliku na serwerze
- **Izolacja wielu użytkowników** — każda przeglądarka ma własny stan (dane, filtr, sortowanie)

### Ogólne
- **Centralny plik konfiguracyjny** `app-config.json` — wszystkie ścieżki w jednym miejscu
- Wyszukiwarka z podświetlaniem wyników (działa we wszystkich zakładkach)
- Auto-odświeżanie przy zmianie danych (sprawdzanie co 60s)
- Logowanie do pliku z rollowaniem co 48h

---

## Struktura projektu

```
D:\PROD_REPO\IIS\prodHealtchCheck\              <- Repozytorium (kod)
├── index.html                 # Frontend - dashboard
├── app.js                     # Logika JavaScript
├── styles.css                 # Style CSS
├── api.aspx                   # Backend - API zwracające JSON
├── web.config                 # Konfiguracja IIS
├── app-config.json            # CENTRALNY PLIK KONFIGURACYJNY
├── images/
│   ├── logo.jpg
│   └── favicon.png
├── scripts/
│   ├── Collect-AllGroups.ps1           # Skrypt zbiorczy (LAN + DMZ + Klastry)
│   ├── Collect-ServerHealth.ps1        # Zbieranie danych serwerów LAN
│   ├── Collect-ServerHealth-DMZ.ps1    # Zbieranie danych serwerów DMZ
│   ├── Collect-ClusterStatus.ps1       # Status klastrów Windows (co 5 min)
│   ├── Collect-InfraDaily.ps1          # Dane infrastruktury z CSV (raz dziennie)
│   ├── Collect-ClusterRoleSwitches.ps1 # Historia przełączeń ról (raz dziennie)
│   ├── GetLogs.ps1                     # Pobieranie logów Windows Event Log
│   ├── Encrypt-Password.ps1            # Szyfrowanie haseł dla DMZ
│   ├── Initialize-Folders.ps1          # Inicjalizacja struktury katalogów
│   └── *.txt                           # Kopie skryptów w formacie TXT
├── README.md
└── INSTRUKCJA_ZAKLADKI.md
```

---

## Struktura danych (poza repozytorium)

```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\
├── config/                              # PLIKI KONFIGURACYJNE
│   ├── clusters.json                    # Konfiguracja klastrów
│   ├── serverList_DCI.txt               # Lista serwerów LAN
│   ├── serverList_Ferryt.txt
│   ├── serverList_MarketPlanet.txt
│   ├── serverList_MQ.txt
│   ├── serverList_FileTransfer.txt
│   ├── serverList_Klastry.txt
│   ├── serverList_DMZ.json              # Konfiguracja DMZ (JSON z grupami)
│   ├── config_mq.json                   # Konfiguracja kolejek MQ
│   ├── EventLogsConfig.json             # Typy logów Event Log
│   ├── fileshare.csv                    # Dane udziałów sieciowych
│   └── sql_db_details.csv               # Dane instancji SQL
│
├── data/                                # DANE JSON (generowane przez skrypty)
│   ├── serverHealth_DCI.json
│   ├── serverHealth_Ferryt.json
│   ├── serverHealth_MarketPlanet.json
│   ├── serverHealth_MQ.json
│   ├── serverHealth_FileTransfer.json
│   ├── serverHealth_Klastry.json
│   ├── serverHealth_DMZ.json
│   ├── infra_ClustersWindows.json
│   ├── infra_UdzialySieciowe.json
│   ├── infra_InstancjeSQL.json
│   ├── infra_KolejkiMQ.json
│   └── infra_PrzelaczeniaRol.json       # Historia przełączeń ról
│
├── logs/                                # LOGI SKRYPTÓW
│   ├── ServerHealthMonitor.log          # Główny plik logu
│   └── ServerHealthMonitor_*.log        # Zarchiwizowane logi
│
└── EventLogs/                           # POBRANE LOGI EVENT LOG
    ├── SERVER1_Application_20260212_120000.json
    └── SERVER2_System_20260212_120500.json
```

---

## Centralny plik konfiguracyjny (app-config.json)

Plik `app-config.json` w głównym katalogu zawiera wszystkie ścieżki używane przez skrypty i stronę.

```json
{
  "paths": {
    "basePath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck",
    "dataPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\data",
    "logsPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\logs",
    "configPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\config",
    "eventLogsPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\EventLogs"
  },
  "scripts": {
    "Collect-AllGroups": {
      "description": "Skrypt zbiorczy",
      "logFile": "ServerHealthMonitor.log"
    },
    "Collect-ServerHealth": {
      "sourceFile": "serverList_{Group}.txt",
      "destFile": "serverHealth_{Group}.json"
    },
    "Collect-InfraDaily": {
      "sources": {
        "fileShares": "fileshare.csv",
        "sqlInstances": "sql_db_details.csv"
      }
    }
  },
  "tabs": {
    "serverHealth": [...],
    "infrastructure": [...],
    "logs": [...]
  }
}
```

### Zmiana ścieżek

Aby zmienić lokalizację danych:
1. Edytuj `app-config.json`
2. Uruchom `scripts\Initialize-Folders.ps1` żeby utworzyć nowe katalogi
3. Przenieś pliki do nowych lokalizacji

---

## Instalacja

### Krok 1: Sklonuj repozytorium

```powershell
git clone https://github.com/lukasTKD/prodHealtchCheck.git D:\PROD_REPO\IIS\prodHealtchCheck
```

### Krok 2: Zainicjalizuj strukturę katalogów

```powershell
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Initialize-Folders.ps1
```

Skrypt utworzy wymagane katalogi i poinformuje o brakujących plikach.

### Krok 3: Utwórz pliki konfiguracyjne

Skopiuj przykładowe pliki lub utwórz własne:

#### serverList_*.txt (listy serwerów LAN)
```
# Lista serwerów - każdy w nowej linii
SERVER1
SERVER2
SERVER3
```

#### clusters.json (konfiguracja klastrów)
```json
{
    "clusters": [
        {"cluster_type": "SQL", "servers": ["sqlcluster1.domain.pl"]},
        {"cluster_type": "FileShare", "servers": ["fscluster1.domain.pl"]}
    ]
}
```

#### fileshare.csv (udziały sieciowe)
```csv
ShareName,SharePath,ShareState,ShareClusterRole
Backup,D:\Backup,Online,FileServer1
Public,E:\Public,Online,FileServer1
```

#### sql_db_details.csv (instancje SQL)
```csv
DatabaseName,sql_server,CompatibilityLevel,SQLServerVersion,State
master,SQLSERVER1,150,15.0.4312.2,ONLINE
tempdb,SQLSERVER1,150,15.0.4312.2,ONLINE
```

### Krok 4: Uruchom zbieranie danych

```powershell
# Wszystkie grupy (kondycja + klastry)
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-AllGroups.ps1

# Dane infrastruktury (udziały, SQL, MQ)
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-InfraDaily.ps1

# Historia przełączeń ról
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-ClusterRoleSwitches.ps1
```

### Krok 5: Skonfiguruj IIS

1. Utwórz aplikację wskazującą na `D:\PROD_REPO\IIS\prodHealtchCheck`
2. Upewnij się, że .NET Framework 4.8 jest zainstalowany

---

## Harmonogram (Task Scheduler)

| Task | Skrypt | Częstotliwość |
|------|--------|---------------|
| Kondycja + Klastry | `Collect-AllGroups.ps1` | Co 5 minut |
| Infrastruktura | `Collect-InfraDaily.ps1` | Raz dziennie (np. 6:00) |
| Przełączenia ról | `Collect-ClusterRoleSwitches.ps1` | Raz dziennie (np. 6:30) |

### Przykład utworzenia taska

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-AllGroups.ps1`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName "Update II prodHealtchCheck" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

---

## Pliki konfiguracyjne - szczegóły

### clusters.json

Konfiguracja klastrów Windows używana przez:
- `Collect-ClusterStatus.ps1` — pobiera węzły i role
- `Collect-ClusterRoleSwitches.ps1` — pobiera historię przełączeń

```json
{
    "clusters": [
        {
            "cluster_type": "SQL",
            "servers": ["sqlcluster1.domain.pl", "sqlcluster2.domain.pl"]
        },
        {
            "cluster_type": "FileShare",
            "servers": ["fscluster1.domain.pl"]
        },
        {
            "cluster_type": "MQ",
            "servers": ["mqcluster1.domain.pl"]
        }
    ]
}
```

| Pole | Opis |
|------|------|
| `cluster_type` | Typ klastra (SQL/FileShare/MQ) - używany do kolorowania w UI |
| `servers` | Lista FQDN lub nazw klastrów |

### fileshare.csv

Dane udziałów sieciowych wyświetlane w zakładce "Udziały sieciowe".

```csv
ShareName,SharePath,ShareState,ShareClusterRole
Backup,D:\Backup,Online,FileServer1
Public,E:\Public,Online,FileServer1
Archive,F:\Archive,Online,FileServer2
```

| Kolumna | Opis |
|---------|------|
| `ShareName` | Nazwa udziału |
| `SharePath` | Ścieżka lokalna na serwerze |
| `ShareState` | Stan (Online/Offline) |
| `ShareClusterRole` | Nazwa serwera/roli (grupowanie) |

### sql_db_details.csv

Dane instancji SQL wyświetlane w zakładce "Instancje SQL".

```csv
DatabaseName,sql_server,CompatibilityLevel,SQLServerVersion,State
master,SQLSERVER1,150,15.0.4312.2,ONLINE
tempdb,SQLSERVER1,150,15.0.4312.2,ONLINE
mydb,SQLSERVER1,140,15.0.4312.2,ONLINE
```

| Kolumna | Opis |
|---------|------|
| `DatabaseName` | Nazwa bazy danych |
| `sql_server` | Nazwa instancji SQL (grupowanie) |
| `CompatibilityLevel` | Poziom kompatybilności |
| `SQLServerVersion` | Wersja SQL Server |
| `State` | Stan bazy (ONLINE/OFFLINE) |

### serverList_DMZ.json

Konfiguracja serwerów w strefie DMZ z uwierzytelnieniem SSL.

```json
{
    "groups": [
        {
            "name": "Aplikacje Zewnętrzne",
            "login": "DOMAIN\\svc_dmz",
            "password": "ZASZYFROWANE_HASLO_DPAPI",
            "servers": [
                "192.168.1.10",
                "192.168.1.11"
            ]
        }
    ]
}
```

> **UWAGA:** Hasło musi być zaszyfrowane przez `Encrypt-Password.ps1` na tym samym komputerze i przez tego samego użytkownika Windows!

### config_mq.json

Konfiguracja serwerów IBM MQ (opcjonalna).

```json
{
    "servers": [
        {"name": "mqserver1", "description": "MQ Produkcja"},
        {"name": "mqserver2", "description": "MQ Test"}
    ]
}
```

### EventLogsConfig.json

Lista typów logów dostępnych w zakładce Event Log.

```json
[
    {"name": "Application", "displayName": "Application"},
    {"name": "System", "displayName": "System"},
    {"name": "Security", "displayName": "Security"},
    {"name": "Microsoft-Windows-TaskScheduler/Operational", "displayName": "Task Scheduler"}
]
```

---

## Zakładki

### Kondycja serwerów

| Zakładka | Plik danych | Źródło |
|----------|-------------|--------|
| DCI | `serverHealth_DCI.json` | `serverList_DCI.txt` |
| Ferryt | `serverHealth_Ferryt.json` | `serverList_Ferryt.txt` |
| MarketPlanet | `serverHealth_MarketPlanet.json` | `serverList_MarketPlanet.txt` |
| MQ | `serverHealth_MQ.json` | `serverList_MQ.txt` |
| FileTransfer | `serverHealth_FileTransfer.json` | `serverList_FileTransfer.txt` |
| Klastrowe | `serverHealth_Klastry.json` | `serverList_Klastry.txt` |
| DMZ | `serverHealth_DMZ.json` | `serverList_DMZ.json` |

### Status infrastruktury

| Zakładka | Plik danych | Źródło danych | Częstotliwość |
|----------|-------------|---------------|---------------|
| Klastry Windows | `infra_ClustersWindows.json` | `clusters.json` (odpytywanie klastrów) | Co 5 min |
| Udziały sieciowe | `infra_UdzialySieciowe.json` | `fileshare.csv` | Raz dziennie |
| Instancje SQL | `infra_InstancjeSQL.json` | `sql_db_details.csv` | Raz dziennie |
| Kolejki MQ | `infra_KolejkiMQ.json` | `config_mq.json` (odpytywanie serwerów) | Raz dziennie |
| Przełączenia ról | `infra_PrzelaczeniaRol.json` | `clusters.json` (Event Log klastrów) | Raz dziennie |

### Logi systemowe

| Zakładka | Endpoint | Źródło |
|----------|----------|--------|
| Event Log | `api.aspx?action=getLogs` | Windows Event Log (na żądanie) |

---

## API

### Dane kondycji serwerów
```
GET api.aspx?group=NAZWA_GRUPY
```

### Dane infrastruktury
```
GET api.aspx?type=infra&group=NAZWA
```

| Nazwa | Endpoint |
|-------|----------|
| Klastry Windows | `api.aspx?type=infra&group=ClustersWindows` |
| Udziały sieciowe | `api.aspx?type=infra&group=UdzialySieciowe` |
| Instancje SQL | `api.aspx?type=infra&group=InstancjeSQL` |
| Kolejki MQ | `api.aspx?type=infra&group=KolejkiMQ` |
| Przełączenia ról | `api.aspx?type=infra&group=PrzelaczeniaRol` |

### Logi systemowe
```
GET api.aspx?action=getLogs&servers=SRV1,SRV2&logType=Application&period=1h
```

| Parametr | Wartości |
|----------|----------|
| `servers` | Nazwy serwerów (przecinek) |
| `logType` | `Application`, `System`, `Security`, ... |
| `period` | `10min`, `30min`, `1h`, `2h`, `6h`, `12h`, `24h` |

---

## Logowanie

Wszystkie skrypty logują do:
```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\logs\ServerHealthMonitor.log
```

### Format logu
```
2026-02-13 10:45:00 [ALL] === START zbierania dla wszystkich grup ===
2026-02-13 10:45:00 [ALL] Uruchamiam: Collect-ServerHealth.ps1 -Group DCI
2026-02-13 10:45:02 [DCI] OK: SERVER1
2026-02-13 10:45:03 [DCI] FAIL: SERVER2
2026-02-13 10:45:10 [ALL] Zakonczono: Collect-ServerHealth.ps1 -Group DCI
2026-02-13 10:45:10 [ALL] Uruchamiam: Collect-ClusterStatus.ps1
2026-02-13 10:45:15 [CLUSTERS] OK: Cluster1 (SQL) - 2 wezlow, 5 rol
2026-02-13 10:45:20 [ALL] Zakonczono: Collect-ClusterStatus.ps1
```

### Rollowanie
- Log jest automatycznie archiwizowany co 48 godzin
- Archiwum: `ServerHealthMonitor_YYYYMMDD_HHMMSS.log`

---

## Zakładka: Przełączenia ról

Nowa zakładka wyświetlająca historię przełączeń ról (failover/failback) w klastrach Windows.

### Zbierane zdarzenia

| Event ID | Typ | Opis |
|----------|-----|------|
| 1069 | ResourceOnline | Zasób przeszedł w stan Online |
| 1070 | ResourceOffline | Zasób przeszedł w stan Offline |
| 1071 | ResourceFailed | Zasób uległ awarii |
| 1201 | GroupOnline | Grupa przeszła w stan Online |
| 1202 | GroupOffline | Grupa przeszła w stan Offline |
| 1205 | GroupMoved | Grupa przeniesiona na inny węzeł |
| 1564 | FailoverStarted | Rozpoczęto failover |
| 1566 | FailoverCompleted | Zakończono failover |

### Wyświetlane dane

| Kolumna | Opis |
|---------|------|
| Data/Czas | Kiedy wystąpiło zdarzenie |
| Klaster | Nazwa klastra |
| Typ | Typ klastra (SQL/FileShare/MQ) |
| Zdarzenie | Typ zdarzenia (GroupMoved, FailoverCompleted, ...) |
| Rola | Nazwa roli/grupy która się przełączyła |
| Z węzła | Węzeł źródłowy |
| Na węzeł | Węzeł docelowy |

### Funkcje

- Sortowanie po każdej kolumnie (kliknij nagłówek)
- Wyszukiwanie w tabeli
- Kolorowanie wierszy wg typu zdarzenia:
  - Czerwony — błędy (Failed, Offline)
  - Żółty — przełączenia (Moved, Started)
  - Zielony — sukces (Completed, Online)

---

## Rozwiązywanie problemów

### Błąd: "Brak pliku konfiguracji"
- Upewnij się, że plik `app-config.json` istnieje w katalogu repozytorium
- Uruchom `Initialize-Folders.ps1` żeby utworzyć strukturę katalogów

### Błąd: "Brak pliku CSV"
- Utwórz plik `fileshare.csv` lub `sql_db_details.csv` w katalogu `config/`
- Sprawdź format pliku (nagłówki kolumn muszą się zgadzać)

### Błąd w logach: "BLAD: Brak pliku"
- Sprawdź ścieżkę w logu
- Utwórz brakujący plik lub zaktualizuj `app-config.json`

### Zakładka pokazuje "Brak danych"
- Uruchom odpowiedni skrypt (np. `Collect-InfraDaily.ps1`)
- Sprawdź czy plik JSON został utworzony w `data/`

### DMZ: "Nie można odszyfrować hasła"
- Hasło zaszyfrowane na innym komputerze/użytkowniku
- Uruchom `Encrypt-Password.ps1` na właściwej maszynie

---

## Migracja ze starej wersji

Jeśli używasz starej wersji bez centralnego configu:

1. Uruchom `Initialize-Folders.ps1` — utworzy nowe katalogi i skopiuje pliki
2. Przenieś ręcznie pliki których skrypt nie znalazł
3. Zaktualizuj Task Scheduler jeśli ścieżki się zmieniły

Stare lokalizacje → Nowe lokalizacje:
```
D:\PROD_REPO_DATA\IIS\Cluster\clusters.json       → config\clusters.json
D:\PROD_REPO_DATA\IIS\Cluster\data\fileShare.csv  → config\fileshare.csv
D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv → config\sql_db_details.csv
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\serverList_*.txt → config\serverList_*.txt
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\ServerHealthMonitor.log → logs\ServerHealthMonitor.log
```
