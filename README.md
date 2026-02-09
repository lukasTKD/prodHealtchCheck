# Server Health Monitor

System monitorowania stanu serwerów Windows z interfejsem webowym.

## Funkcje

- Monitorowanie CPU, RAM, dysków
- Top 3 procesy zużywające CPU i RAM
- Status usług z dysku D:\
- Status Trellix (antywirus)
- Status Windows Firewall
- Grupowanie serwerów w zakładki
- Wyszukiwarka serwerów
- Auto-odświeżanie co 5 minut

## Struktura projektu

```
prodHealtchCheck/
├── index.html                 # Frontend - dashboard
├── api.aspx                   # Backend - API zwracające JSON
├── web.config                 # Konfiguracja IIS
├── images/
│   ├── logo.jpg
│   └── icon.png
├── scripts/
│   ├── Collect-ServerHealth.ps1      # Skrypt zbierający dane (pojedyncza grupa)
│   ├── Collect-AllGroups.ps1         # Skrypt zbierający dane (wszystkie grupy)
│   └── Create-ServerListTemplates.ps1 # Tworzy szablony plików z listami
└── README.md
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
│   └── serverHealth_Klastry.json
├── serverList_DCI.txt
├── serverList_Ferryt.txt
├── serverList_MarketPlanet.txt
├── serverList_MQ.txt
├── serverList_FileTransfer.txt
└── serverList_Klastry.txt
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
