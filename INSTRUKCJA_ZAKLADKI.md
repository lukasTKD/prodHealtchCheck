# Instrukcja konfiguracji Server Health Monitor

## Spis treści

1. [Struktura katalogów](#struktura-katalogów)
2. [Centralny plik konfiguracyjny](#centralny-plik-konfiguracyjny)
3. [Konfiguracja plików CSV](#konfiguracja-plików-csv)
4. [Dodawanie zakładek LAN](#dodawanie-zakładek-lan)
5. [Dodawanie grup DMZ](#dodawanie-grup-dmz)
6. [Konfiguracja klastrów](#konfiguracja-klastrów)
7. [Konfiguracja Event Log](#konfiguracja-event-log)
8. [Konfiguracja MQ](#konfiguracja-mq)
9. [Rozwiązywanie problemów](#rozwiązywanie-problemów)

---

## Struktura katalogów

System używa następującej struktury katalogów:

```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\
├── config/        # Pliki konfiguracyjne
├── data/          # Dane JSON generowane przez skrypty
├── logs/          # Logi skryptów
└── EventLogs/     # Pobrane logi Windows Event Log
```

### Inicjalizacja struktury

Po pierwszej instalacji lub aktualizacji uruchom:

```powershell
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Initialize-Folders.ps1
```

Skrypt:
- Utworzy brakujące katalogi
- Skopiuje pliki konfiguracyjne ze starych lokalizacji
- Wyświetli listę brakujących plików do utworzenia

---

## Centralny plik konfiguracyjny

Plik `app-config.json` w głównym katalogu repozytorium zawiera wszystkie ścieżki.

### Lokalizacja
```
D:\PROD_REPO\IIS\prodHealtchCheck\app-config.json
```

### Struktura

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
    "Collect-ServerHealth": {
      "description": "Zbiera kondycję serwerów LAN",
      "sourceFile": "serverList_{Group}.txt",
      "destFile": "serverHealth_{Group}.json"
    },
    "Collect-InfraDaily": {
      "description": "Zbiera dane infrastruktury",
      "sources": {
        "fileShares": "fileshare.csv",
        "sqlInstances": "sql_db_details.csv",
        "mqConfig": "config_mq.json"
      },
      "destinations": {
        "fileShares": "infra_UdzialySieciowe.json",
        "sqlInstances": "infra_InstancjeSQL.json",
        "mqQueues": "infra_KolejkiMQ.json"
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

1. Edytuj `app-config.json`
2. Zmień wartości w sekcji `paths`
3. Uruchom `Initialize-Folders.ps1` żeby utworzyć nowe katalogi
4. Przenieś pliki do nowych lokalizacji

---

## Konfiguracja plików CSV

Zakładki "Udziały sieciowe" i "Instancje SQL" czytają dane z plików CSV zamiast odpytywać serwery.

### fileshare.csv (Udziały sieciowe)

**Lokalizacja:** `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\fileshare.csv`

**Format:**
```csv
ShareName,SharePath,ShareState,ShareClusterRole
```

**Przykład:**
```csv
ShareName,SharePath,ShareState,ShareClusterRole
Backup,D:\Backup,Online,FileServer1
Public,E:\Public,Online,FileServer1
Archive,F:\Archive,Online,FileServer2
Users,G:\Users,Online,FileServer2
```

**Kolumny:**
| Kolumna | Wymagana | Opis |
|---------|----------|------|
| `ShareName` | Tak | Nazwa udziału sieciowego |
| `SharePath` | Tak | Ścieżka lokalna na serwerze |
| `ShareState` | Nie | Stan udziału (domyślnie: Online) |
| `ShareClusterRole` | Tak | Nazwa serwera/roli (używana do grupowania) |

### sql_db_details.csv (Instancje SQL)

**Lokalizacja:** `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\sql_db_details.csv`

**Format:**
```csv
DatabaseName,sql_server,CompatibilityLevel,SQLServerVersion,State
```

**Przykład:**
```csv
DatabaseName,sql_server,CompatibilityLevel,SQLServerVersion,State
master,SQLSERVER1,150,15.0.4312.2,ONLINE
tempdb,SQLSERVER1,150,15.0.4312.2,ONLINE
mydb,SQLSERVER1,140,15.0.4312.2,ONLINE
master,SQLSERVER2,150,15.0.4312.2,ONLINE
appdb,SQLSERVER2,150,15.0.4312.2,ONLINE
```

**Kolumny:**
| Kolumna | Wymagana | Opis |
|---------|----------|------|
| `DatabaseName` | Tak | Nazwa bazy danych |
| `sql_server` | Tak | Nazwa instancji SQL (używana do grupowania) |
| `CompatibilityLevel` | Nie | Poziom kompatybilności (np. 150 = SQL 2019) |
| `SQLServerVersion` | Nie | Pełna wersja SQL Server |
| `State` | Nie | Stan bazy (domyślnie: ONLINE) |

### Aktualizacja danych CSV

Po edycji plików CSV uruchom:
```powershell
D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-InfraDaily.ps1
```

Dane zostaną przetworzone i zapisane do odpowiednich plików JSON w `data/`.

---

## Dodawanie zakładek LAN

> **Uwaga:** Ta sekcja dotyczy zakładek kondycji serwerów LAN. Dla DMZ zobacz [Dodawanie grup DMZ](#dodawanie-grup-dmz).

### Krok 1: Dodaj grupę do skryptu PowerShell

Edytuj `scripts\Collect-ServerHealth.ps1`

Znajdź linię z `ValidateSet`:
```powershell
[ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")]
```

Dodaj nową grupę:
```powershell
[ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "NowaGrupa")]
```

### Krok 2: Dodaj grupę do skryptu zbiorczego

Edytuj `scripts\Collect-AllGroups.ps1`

Znajdź tablicę `$Groups`:
```powershell
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")
```

Dodaj nową grupę:
```powershell
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "NowaGrupa")
```

### Krok 3: Dodaj zakładkę w HTML

Edytuj `index.html`

Znajdź sekcję z zakładkami "Kondycja serwerów":
```html
<div class="tabs">
    <button class="tab active" data-group="DCI" onclick="switchTab('DCI')">DCI</button>
    ...
</div>
```

Dodaj nową zakładkę:
```html
<button class="tab" data-group="NowaGrupa" onclick="switchTab('NowaGrupa')">NowaGrupa</button>
```

### Krok 4: Utwórz plik z listą serwerów

Utwórz plik: `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\serverList_NowaGrupa.txt`

```
# Lista serwerów dla grupy: NowaGrupa
SERVER1
SERVER2
SERVER3
```

### Krok 5: Uruchom zbieranie danych

```powershell
.\scripts\Collect-ServerHealth.ps1 -Group NowaGrupa
# lub
.\scripts\Collect-AllGroups.ps1
```

### Podsumowanie zmian

| Plik | Co zmienić |
|------|------------|
| `scripts\Collect-ServerHealth.ps1` | Dodaj do `ValidateSet` |
| `scripts\Collect-AllGroups.ps1` | Dodaj do tablicy `$Groups` |
| `index.html` | Dodaj `<button class="tab">` |
| `config\serverList_NowaGrupa.txt` | Utwórz nowy plik z listą serwerów |

---

## Dodawanie grup DMZ

Serwery w strefie DMZ wymagają uwierzytelnienia SSL/Negotiate.

### Krok 1: Zaszyfruj hasło

Uruchom w PowerShell:
```powershell
.\scripts\Encrypt-Password.ps1
```

1. Wpisz hasło (ukryte wprowadzanie)
2. Skopiuj zaszyfrowany string

> **WAŻNE:** Hasło musi być zaszyfrowane na tym samym komputerze i przez tego samego użytkownika Windows, który będzie uruchamiał skrypt!

### Krok 2: Edytuj serverList_DMZ.json

**Lokalizacja:** `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\serverList_DMZ.json`

```json
{
    "groups": [
        {
            "name": "Istniejaca Grupa",
            "login": "DOMAIN\\svc_existing",
            "password": "...",
            "servers": ["192.168.1.10"]
        },
        {
            "name": "Nowa Grupa DMZ",
            "login": "DOMAIN\\svc_nowa_dmz",
            "password": "ZASZYFROWANE_HASLO",
            "servers": [
                "10.0.0.50",
                "10.0.0.51"
            ]
        }
    ]
}
```

**Pola:**
| Pole | Opis |
|------|------|
| `name` | Nazwa grupy wyświetlana jako badge przy serwerze |
| `login` | Login do serwerów (format: `DOMAIN\username`) |
| `password` | Hasło zaszyfrowane przez `Encrypt-Password.ps1` |
| `servers` | Lista adresów IP serwerów |

### Krok 3: Uruchom zbieranie

```powershell
.\scripts\Collect-ServerHealth-DMZ.ps1
# lub
.\scripts\Collect-AllGroups.ps1
```

### Krok 4: Sprawdź wyniki

Otwórz zakładkę **DMZ** w przeglądarce. Nowa grupa pojawi się jako badge przy nazwie serwera.

### Podsumowanie: LAN vs DMZ

| Cecha | LAN | DMZ |
|-------|-----|-----|
| Plik konfiguracji | `serverList_GRUPA.txt` | `serverList_DMZ.json` |
| Format | Lista nazw (TXT) | JSON z grupami |
| Uwierzytelnienie | Kerberos (domyślne) | SSL + Negotiate + Credential |
| Hasło | Brak | Zaszyfrowane DPAPI |
| Skrypt | `Collect-ServerHealth.ps1` | `Collect-ServerHealth-DMZ.ps1` |
| Zakładka | Osobna dla każdej grupy | Jedna zakładka DMZ dla wszystkich grup |

---

## Konfiguracja klastrów

Plik `clusters.json` jest używany przez:
- `Collect-ClusterStatus.ps1` — pobiera węzły i role (co 5 min)
- `Collect-ClusterRoleSwitches.ps1` — pobiera historię przełączeń (raz dziennie)

### Lokalizacja
```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\clusters.json
```

### Format

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

**Pola:**
| Pole | Opis |
|------|------|
| `cluster_type` | Typ klastra: `SQL`, `FileShare`, `MQ` (używany do kolorowania w UI) |
| `servers` | Lista nazw FQDN lub NetBIOS klastrów |

### Typy klastrów

| Typ | Kolor w UI | Opis |
|-----|-----------|------|
| `SQL` | Niebieski | Klastry SQL Server |
| `FileShare` | Zielony | Klastry udziałów plików |
| `MQ` | Pomarańczowy | Klastry IBM MQ |

### Dodawanie klastra

1. Edytuj `clusters.json`
2. Dodaj nowy obiekt do tablicy `clusters`
3. Uruchom:
   ```powershell
   .\scripts\Collect-ClusterStatus.ps1
   .\scripts\Collect-ClusterRoleSwitches.ps1
   ```

---

## Konfiguracja Event Log

Zakładka **Event Log** pozwala przeglądać Windows Event Log z dowolnych serwerów.

### Plik konfiguracji typów logów

**Lokalizacja:** `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\EventLogsConfig.json`

### Format

```json
[
    {"name": "Application", "displayName": "Application"},
    {"name": "System", "displayName": "System"},
    {"name": "Security", "displayName": "Security"},
    {"name": "Microsoft-Windows-TaskScheduler/Operational", "displayName": "Task Scheduler"}
]
```

**Pola:**
| Pole | Opis |
|------|------|
| `name` | Techniczna nazwa logu Windows (dla `Get-WinEvent -LogName`) |
| `displayName` | Nazwa wyświetlana w liście rozwijanej |

### Jak znaleźć nazwę logu

Na docelowym serwerze uruchom:
```powershell
# Wszystkie logi:
Get-WinEvent -ListLog * | Select-Object LogName | Sort-Object LogName

# Szukaj konkretnego:
Get-WinEvent -ListLog *IIS* | Select-Object LogName
```

### Przykładowe nazwy logów

| Nazwa logu | Opis |
|------------|------|
| `Application` | Logi aplikacji |
| `System` | Logi systemowe |
| `Security` | Logi zabezpieczeń (wymaga uprawnień) |
| `Microsoft-Windows-IIS-Configuration/Operational` | Konfiguracja IIS |
| `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` | Logowania RDP |
| `Microsoft-Windows-Windows Defender/Operational` | Windows Defender |
| `Microsoft-Windows-PowerShell/Operational` | PowerShell |

### Dodawanie nowego typu

1. Edytuj `EventLogsConfig.json`
2. Dodaj nowy obiekt na końcu tablicy:
   ```json
   {
       "name": "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational",
       "displayName": "Logowania RDP"
   }
   ```
3. Odśwież stronę (F5) — nie trzeba restartować IIS

### Zapis pobranych logów

Pobrane logi są automatycznie zapisywane do:
```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\EventLogs\
```

Format nazwy pliku:
```
SERWER_TypLogu_RRRRMMDD_GGMMSS.json
```

---

## Konfiguracja MQ

Serwery IBM MQ są odpytywane zdalnie przez skrypt `Collect-InfraDaily.ps1`.

### Plik konfiguracji

**Lokalizacja:** `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\config_mq.json`

### Format

```json
{
    "servers": [
        {"name": "mqserver1", "description": "MQ Produkcja"},
        {"name": "mqserver2", "description": "MQ Test"},
        {"name": "mqserver3.domain.pl", "description": "MQ DR"}
    ]
}
```

**Pola:**
| Pole | Opis |
|------|------|
| `name` | Nazwa serwera (NetBIOS lub FQDN) |
| `description` | Opis wyświetlany w UI |

### Wymagania

- Serwery muszą mieć zainstalowane IBM MQ
- PowerShell Remoting musi być włączony
- Konto uruchamiające skrypt musi mieć dostęp do serwerów

### Zbierane dane

- Queue Managery (status, port listenera)
- Kolejki lokalne (głębokość, max głębokość)
- Kolejki systemowe (`SYSTEM.*`) są pomijane

---

## Rozwiązywanie problemów

### "Brak pliku konfiguracji"

**Problem:** Skrypt nie może znaleźć `app-config.json`

**Rozwiązanie:**
1. Sprawdź czy plik istnieje: `D:\PROD_REPO\IIS\prodHealtchCheck\app-config.json`
2. Jeśli nie, skopiuj z repozytorium lub utwórz ręcznie

### "Brak pliku serverList_*.txt"

**Problem:** Brak listy serwerów dla grupy

**Rozwiązanie:**
1. Utwórz plik w `config\serverList_GRUPA.txt`
2. Dodaj nazwy serwerów (każdy w nowej linii)

### "Nie można odszyfrować hasła" (DMZ)

**Problem:** Hasło DPAPI nie działa

**Przyczyna:** Hasło zostało zaszyfrowane na innym komputerze lub przez innego użytkownika

**Rozwiązanie:**
1. Uruchom `Encrypt-Password.ps1` na maszynie docelowej
2. Zaktualizuj `serverList_DMZ.json` nowym hasłem

### "Timeout/Niedostępny" (DMZ)

**Problem:** Serwer DMZ nie odpowiada

**Sprawdź:**
```powershell
# Test portu 5986 (WinRM HTTPS)
Test-NetConnection -ComputerName IP -Port 5986

# Sprawdź konfigurację WinRM
winrm get winrm/config/client
```

**Rozwiązanie:**
- Włącz WinRM over HTTPS na serwerze DMZ
- Sprawdź firewall (port 5986)

### "Brak danych" w zakładce

**Problem:** Zakładka pokazuje "Brak danych" lub błąd

**Rozwiązanie:**
1. Uruchom odpowiedni skrypt:
   - Kondycja serwerów: `Collect-AllGroups.ps1`
   - Infrastruktura: `Collect-InfraDaily.ps1`
   - Przełączenia ról: `Collect-ClusterRoleSwitches.ps1`
2. Sprawdź logi: `logs\ServerHealthMonitor.log`
3. Sprawdź czy plik JSON istnieje w `data\`

### Błąd JSON w Event Log

**Problem:** "Bad escaped character in JSON"

**Przyczyna:** Logi zawierają znaki kontrolne lub nieprawidłowe

**Rozwiązanie:** Zaktualizuj `GetLogs.ps1` do najnowszej wersji (zawiera escape znaków kontrolnych)

### Logi nie są widoczne

**Problem:** W `Collect-AllGroups.ps1` nie widać uruchomienia innych skryptów

**Rozwiązanie:**
1. Zaktualizuj `Collect-AllGroups.ps1` do najnowszej wersji
2. Sprawdź plik logu: `logs\ServerHealthMonitor.log`
3. Każde uruchomienie powinno być logowane z try/catch

### Stare ścieżki po aktualizacji

**Problem:** Skrypty szukają plików w starych lokalizacjach

**Rozwiązanie:**
1. Uruchom `Initialize-Folders.ps1`
2. Przenieś pliki do nowych lokalizacji
3. Sprawdź czy `app-config.json` ma poprawne ścieżki
