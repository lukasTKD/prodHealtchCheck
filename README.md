# Server Health Monitor

System monitorowania stanu serwerów Windows z interfejsem webowym.

## Funkcje

- Monitorowanie CPU, RAM, dysków
- Top 3 procesy zużywające CPU i RAM
- Status usług z dysku D:\ i E:\
- Status Trellix (antywirus)
- Status Windows Firewall
- Status IIS (Application Pools, Sites)
- Grupowanie serwerów w zakładki (LAN + DMZ)
- Obsługa serwerów w strefie DMZ (SSL/Negotiate)
- Wyszukiwarka serwerów
- Filtrowanie serwerów krytycznych (CPU/RAM >90%)
- Auto-odświeżanie co 5 minut
- Logowanie do pliku z rollowaniem co 48h

## Struktura projektu

```
prodHealtchCheck/
├── index.html                 # Frontend - dashboard
├── app.js                     # Logika JavaScript
├── styles.css                 # Style CSS
├── api.aspx                   # Backend - API zwracające JSON
├── web.config                 # Konfiguracja IIS
├── images/
│   ├── logo.jpg
│   ├── favicon.png
│   └── icon.png
├── scripts/
│   ├── Collect-ServerHealth.ps1      # Skrypt zbierający dane (grupy LAN)
│   ├── Collect-ServerHealth-DMZ.ps1  # Skrypt zbierający dane (grupy DMZ)
│   ├── Collect-AllGroups.ps1         # Skrypt zbiorczy (LAN + DMZ)
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
│   └── serverHealth_DMZ.json          # Dane z serwerów DMZ
├── serverList_DCI.txt                  # Lista serwerów LAN
├── serverList_Ferryt.txt
├── serverList_MarketPlanet.txt
├── serverList_MQ.txt
├── serverList_FileTransfer.txt
├── serverList_Klastry.txt
├── serverList_DMZ.json                 # Konfiguracja DMZ (JSON z grupami)
└── ServerHealthMonitor.log             # Plik logu (rollowany co 48h)
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

**Wszystkie grupy:**
```powershell
.\scripts\Collect-AllGroups.ps1
```

### Harmonogram (Task Scheduler)

Utwórz zadanie uruchamiające `Collect-AllGroups.ps1` co X minut.

## Format pliku z listą serwerów

```
# Komentarz - linie zaczynające się od # są ignorowane
SERVER1
SERVER2
SERVER3
```

## API

Endpoint: `api.aspx?group=NAZWA_GRUPY`

Przykład: `api.aspx?group=DCI`

Zwraca JSON:
```json
{
  "LastUpdate": "2026-02-09 21:00:00",
  "CollectionDuration": 12.5,
  "TotalServers": 10,
  "SuccessCount": 9,
  "FailedCount": 1,
  "Group": "DCI",
  "Servers": [...]
}
```

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

## Zakładki

| Zakładka | Typ | Opis |
|----------|-----|------|
| DCI | LAN | Serwery DCI |
| Ferryt | LAN | Serwery Ferryt |
| MarketPlanet | LAN | Serwery MarketPlanet |
| MQ | LAN | Serwery kolejek |
| FileTransfer | LAN | Serwery transferu plików |
| Klastry | LAN | Klastry |
| DMZ | DMZ | Serwery w strefie DMZ (SSL/Negotiate) |
