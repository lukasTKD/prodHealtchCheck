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
- **Udziały sieciowe** — nazwa udziału, ścieżka, stan (Online/Offline)
- **Instancje SQL** — wersja SQL Server, ilość baz; per baza: nazwa, stan, compatibility level
- **Kolejki MQ** — QManager, status (Running/inne), port listenera, nazwy kolejek, serwer

### Ogólne
- Wyszukiwarka z podświetlaniem wyników (działa we wszystkich zakładkach)
- Auto-odświeżanie przy zmianie danych (sprawdzanie co 60s)
- Logowanie do pliku z rollowaniem co 48h

## Struktura projektu

```
prodHealtchCheck/
├── index.html                 # Frontend - dashboard
├── app.js                     # Logika JavaScript (serwery + infrastruktura)
├── styles.css                 # Style CSS
├── api.aspx                   # Backend - API zwracające JSON
├── web.config                 # Konfiguracja IIS
├── images/
│   ├── logo.jpg
│   ├── favicon.png
│   └── icon.png
├── scripts/
│   ├── Collect-ServerHealth.ps1      # Zbieranie danych serwerów (grupy LAN)
│   ├── Collect-ServerHealth-DMZ.ps1  # Zbieranie danych serwerów (grupy DMZ)
│   ├── Collect-ClusterStatus.ps1     # Status klastrów Windows (co 5 min)
│   ├── Collect-InfraDaily.ps1        # Dane infrastruktury (raz dziennie)
│   ├── Collect-AllGroups.ps1         # Skrypt zbiorczy (LAN + DMZ + Klastry)
│   ├── Encrypt-Password.ps1          # Szyfrowanie haseł dla DMZ
│   └── Create-ServerListTemplates.ps1
├── README.md
└── INSTRUKCJA_ZAKLADKI.md
```

## Pliki danych (poza repozytorium)

```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\
├── data/
│   ├── serverHealth_DCI.json
│   ├── serverHealth_Ferryt.json
│   ├── serverHealth_MarketPlanet.json
│   ├── serverHealth_MQ.json
│   ├── serverHealth_FileTransfer.json
│   ├── serverHealth_Klastry.json
│   ├── serverHealth_DMZ.json          # Dane z serwerów DMZ
│   ├── infra_ClustersWindows.json     # Status klastrów (co 5 min)
│   ├── infra_UdzialySieciowe.json     # Udziały sieciowe (raz dziennie)
│   ├── infra_InstancjeSQL.json        # Instancje SQL (raz dziennie)
│   └── infra_KolejkiMQ.json          # Kolejki MQ (raz dziennie)
├── serverList_DCI.txt                  # Lista serwerów LAN
├── serverList_Ferryt.txt
├── serverList_MarketPlanet.txt
├── serverList_MQ.txt
├── serverList_FileTransfer.txt
├── serverList_Klastry.txt
├── serverList_DMZ.json                 # Konfiguracja DMZ (JSON z grupami)
├── config_mq.json                      # Konfiguracja kolejek MQ (opcjonalna)
└── ServerHealthMonitor.log             # Plik logu (rollowany co 48h)

D:\PROD_REPO_DATA\IIS\Cluster\
└── clusters.json                       # Konfiguracja klastrów (SQL + FileShare)
```

## Instalacja

1. Sklonuj repozytorium do folderu IIS:
   ```
   git clone https://github.com/lukasTKD/prodHealtchCheck.git D:\PROD_REPO\IIS\prodHealtchCheck
   ```

2. Utwórz folder na dane:
   ```powershell
   New-Item -Path "D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data" -ItemType Directory -Force
   ```

3. Utwórz szablony list serwerów:
   ```powershell
   D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Create-ServerListTemplates.ps1
   ```

4. Edytuj pliki `serverList_*.txt` i dodaj nazwy serwerów (każdy w nowej linii)

5. Uruchom zbieranie danych:
   ```powershell
   D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-AllGroups.ps1
   ```

6. Skonfiguruj IIS:
   - Utwórz aplikację wskazującą na `D:\PROD_REPO\IIS\prodHealtchCheck`
   - Upewnij się, że .NET Framework 4.8 jest zainstalowany

## Użycie

### Zbieranie danych

**Pojedyncza grupa:**
```powershell
.\scripts\Collect-ServerHealth.ps1 -Group DCI
```

**Wszystkie grupy (LAN + DMZ + Klastry):**
```powershell
.\scripts\Collect-AllGroups.ps1
```

**Tylko status klastrów:**
```powershell
.\scripts\Collect-ClusterStatus.ps1
```

**Dane infrastruktury (udziały, SQL, MQ):**
```powershell
.\scripts\Collect-InfraDaily.ps1
```

**Konwersja testowych CSV na JSON:**
```powershell
.\scripts\Convert-CSVToJSON.ps1
```
(Używane tylko do testowania - w produkcji dane są zbierane automatycznie przez skrypty)

### Harmonogram (Task Scheduler)

| Task | Skrypt | Częstotliwość |
|------|--------|---------------|
| Kondycja + Klastry | `Collect-AllGroups.ps1` | Co 5 minut |
| Infrastruktura | `Collect-InfraDaily.ps1` | Raz dziennie (np. 6:00) |

## Format pliku z listą serwerów

```
# Komentarz - linie zaczynające się od # są ignorowane
SERVER1
SERVER2
SERVER3
```

## API

### Dane kondycji serwerów
Endpoint: `api.aspx?group=NAZWA_GRUPY`

Przykład: `api.aspx?group=DCI`

### Dane infrastruktury
Endpoint: `api.aspx?type=infra&group=NAZWA`

| Grupa | Endpoint |
|-------|----------|
| Klastry Windows | `api.aspx?type=infra&group=ClustersWindows` |
| Udziały sieciowe | `api.aspx?type=infra&group=UdzialySieciowe` |
| Instancje SQL | `api.aspx?type=infra&group=InstancjeSQL` |
| Kolejki MQ | `api.aspx?type=infra&group=KolejkiMQ` |

## Konfiguracja DMZ

Serwery w strefie DMZ wymagają uwierzytelnienia przez SSL z credentials.

### Krok 1: Zaszyfruj hasła

Uruchom skrypt w PowerShell ISE:
```powershell
.\scripts\Encrypt-Password.ps1
```

Skrypt poprosi o hasło i zwróci zaszyfrowany string (DPAPI).

> **UWAGA:** Zaszyfrowane hasło działa tylko na tym samym komputerze i dla tego samego użytkownika Windows!

### Krok 2: Skonfiguruj serverList_DMZ.json

```json
{
    "groups": [
        {
            "name": "Nazwa Grupy",
            "login": "DOMAIN\\username",
            "password": "ZASZYFROWANE_HASLO_Z_ENCRYPT-PASSWORD",
            "servers": [
                "192.168.1.10",
                "192.168.1.11"
            ]
        }
    ]
}
```

| Pole | Opis |
|------|------|
| `name` | Nazwa grupy wyświetlana w interfejsie |
| `login` | Login do serwerów DMZ |
| `password` | Hasło zaszyfrowane przez `Encrypt-Password.ps1` |
| `servers` | Lista adresów IP serwerów |

### Krok 3: Uruchom zbieranie

```powershell
.\scripts\Collect-ServerHealth-DMZ.ps1
```

Lub wszystkie grupy (LAN + DMZ):
```powershell
.\scripts\Collect-AllGroups.ps1
```

## Logowanie

Wszystkie skrypty logują do pliku:
```
D:\PROD_REPO_DATA\IIS\prodHealtchCheck\ServerHealthMonitor.log
```

### Format logu
```
2026-02-11 18:45:00 [DCI] START zbierania z 15 serwerow
2026-02-11 18:45:02 [DCI] OK: SERVER1
2026-02-11 18:45:03 [DCI] FAIL: SERVER2
2026-02-11 18:45:10 [DCI] KONIEC: 10.2s (OK: 14, FAIL: 1)
2026-02-11 18:45:10 [DMZ] START zbierania danych DMZ
2026-02-11 18:45:15 [DMZ] [Express Elixir] OK: DMZSRV01
```

### Rollowanie
- Log jest automatycznie archiwizowany co 48 godzin
- Archiwum: `ServerHealthMonitor_YYYYMMDD_HHMMSS.log`

## Monitorowane dane

### Kondycja serwerów

| Kategoria | Dane |
|-----------|------|
| **CPU** | Użycie procesora (%) |
| **RAM** | Użycie pamięci (GB, %) |
| **Dyski** | Wolne/Całkowite miejsce (GB, %) |
| **Top CPU** | 3 procesy z największym zużyciem CPU |
| **Top RAM** | 3 procesy z największym zużyciem RAM |
| **Usługi D/E** | Usługi uruchamiane z dysków D:\ lub E:\ |
| **Trellix** | Status usług antywirusowych Trellix |
| **Firewall** | Status profili: Domain, Private, Public |
| **IIS** | Application Pools i Sites (jeśli zainstalowany) |

### Infrastruktura

| Zakładka | Dane w tabeli/karcie |
|----------|---------------------|
| **Klastry Windows** | Karty klastrów z węzłami (nazwa, status, IP) i rolami (nazwa, status, IP) |
| **Udziały sieciowe** | Tabela: Nazwa udziału, Ścieżka, Stan |
| **Instancje SQL** | Karta serwera: Wersja SQL, Ilość baz · Tabela baz: Baza, Stan, Compat. Level |
| **Kolejki MQ** | Tabela: QManager, Status, Port, Kolejka, Serwer |

## Zakładki

Interfejs podzielony jest na dwie grupy zakładek oddzielone pionową linią:

### Kondycja serwerów (CPU, RAM, dyski, usługi, IIS)

Monitoring stanu serwerów - dane zbierane przez skrypty PowerShell.

| Zakładka | Typ | Opis |
|----------|-----|------|
| DCI | LAN | Serwery DCI |
| Ferryt | LAN | Serwery Ferryt |
| MarketPlanet | LAN | Serwery MarketPlanet |
| MQ | LAN | Serwery kolejek |
| FileTransfer | LAN | Serwery transferu plików |
| Klastrowe | LAN | Serwery klastrowe |
| DMZ | DMZ | Serwery w strefie DMZ (SSL/Negotiate) |

### Status infrastruktury

Status usług i komponentów infrastruktury. Dane pobierane z konfiguracji `clusters.json`.

| Zakładka | Skrypt | Częstotliwość | Wyświetlane dane |
|----------|--------|---------------|------------------|
| Klastry Windows | `Collect-ClusterStatus.ps1` | Co 5 min | Węzły (nazwa, status, IP) + role (nazwa, status, IP) |
| Udziały sieciowe | `Collect-InfraDaily.ps1` | Raz dziennie | Nazwa udziału, ścieżka, stan |
| Instancje SQL | `Collect-InfraDaily.ps1` | Raz dziennie | Wersja SQL, ilość baz; per baza: nazwa, stan, compat. level |
| Kolejki MQ | `Collect-InfraDaily.ps1` | Raz dziennie | QManager, status, port, kolejka, serwer |

### Konfiguracja infrastruktury

**clusters.json** (`D:\PROD_REPO_DATA\IIS\Cluster\clusters.json`):
```json
{
    "clusters": [
        {"cluster_type": "SQL", "servers": ["sqlcluster1.domain.pl"]},
        {"cluster_type": "FileShare", "servers": ["fscluster1.domain.pl"]}
    ]
}
```

Serwery SQL z klastrów typu "SQL" są odpytywane o bazy danych (nazwa, stan, compatibility level).
Serwery z klastrów typu "FileShare" są odpytywane o udziały SMB (nazwa, ścieżka, stan).

**config_mq.json** (opcjonalny, `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config_mq.json`):
```json
{
    "servers": [
        {"name": "mqserver1", "description": "MQ Produkcja"},
        {"name": "mqserver2", "description": "MQ Test"}
    ]
}
```

Serwery MQ są odpytywane o QManagery (status, port listenera) i kolejki lokalne (z pominięciem SYSTEM.*).

## Wyszukiwanie

Każda zakładka posiada pole wyszukiwania. Wyszukiwarka:
- Filtruje widoczne karty/wiersze na podstawie wpisanego tekstu
- **Podświetla** znaleziony tekst na żółto (`<mark>`) bezpośrednio w komórkach
- Pasujące wiersze tabel dostają żółte tło
- Pasujące karty serwerów dostają żółtą ramkę
- Automatycznie rozwija zwinięte sekcje gdy znajdzie dopasowanie wewnątrz

## Auto-odświeżanie

Strona automatycznie sprawdza co **60 sekund** czy dane zostały zaktualizowane:
- Porównuje `LastUpdate` z obecnymi danymi
- Jeśli data się zmieniła - automatycznie ładuje nowe dane
- Bez przeładowania całej strony (tylko dane)

Dzięki temu po uruchomieniu skryptu `Collect-AllGroups.ps1` strona pokaże nowe dane w ciągu max 60 sekund.
