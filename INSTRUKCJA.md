# Server Health Monitor - Kompletna Instrukcja

## Spis tresci

1. [Struktura katalogow](#1-struktura-katalogow)
2. [Pliki konfiguracyjne](#2-pliki-konfiguracyjne)
3. [Skrypty PowerShell](#3-skrypty-powershell)
4. [Pliki wyjsciowe JSON](#4-pliki-wyjsciowe-json)
5. [Zakladki aplikacji](#5-zakladki-aplikacji)
6. [Harmonogram uruchamiania](#6-harmonogram-uruchamiania)

---

## 1. Struktura katalogow

```
D:\PROD_REPO\IIS\prodHealtchCheck\          <- Repozytorium (kod zrodlowy)
├── scripts\                                 <- Skrypty PowerShell
│   ├── Collect-ServerHealth.ps1
│   ├── Collect-ServerHealth-DMZ.ps1
│   ├── Collect-ClusterData.ps1
│   ├── Collect-MQData.ps1
│   ├── Collect-InfraData.ps1
│   └── Collect-AllGroups.ps1
├── app-config.json                          <- Konfiguracja sciezek
├── index.html                               <- Interfejs webowy
├── app.js                                   <- Logika JavaScript
├── styles.css                               <- Style CSS
└── api.aspx                                 <- Backend API

D:\PROD_REPO_DATA\IIS\prodHealtchCheck\     <- Dane (poza repozytorium)
├── config\                                  <- Pliki konfiguracyjne
│   ├── clusters.json                        <- Definicje klastrow
│   ├── serverList_DCI.txt                   <- Lista serwerow DCI
│   ├── serverList_Ferryt.txt
│   ├── serverList_MarketPlanet.txt
│   ├── serverList_MQ.txt
│   ├── serverList_FileTransfer.txt
│   ├── serverList_Klastry.txt
│   └── dmz_servers.json                     <- Serwery DMZ
├── data\                                    <- Pliki JSON z danymi
│   ├── serverHealth_DCI.json
│   ├── serverHealth_Ferryt.json
│   ├── serverHealth_MarketPlanet.json
│   ├── serverHealth_MQ.json
│   ├── serverHealth_FileTransfer.json
│   ├── serverHealth_Klastry.json
│   ├── serverHealth_DMZ.json
│   ├── infra_ClustersSQL.json
│   ├── infra_ClustersFileShare.json
│   ├── infra_ClustersWMQ.json
│   ├── infra_InstancjeSQL.json
│   ├── infra_UdzialySieciowe.json
│   ├── infra_KolejkiMQ.json
│   └── infra_PrzelaczeniaRol.json
└── logs\                                    <- Logi
    └── ServerHealthMonitor.log
```

---

## 2. Pliki konfiguracyjne

### 2.1. app-config.json

Glowny plik konfiguracyjny definiujacy sciezki i nazwy plikow wyjsciowych.

```json
{
  "paths": {
    "basePath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck",
    "dataPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\data",
    "logsPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\logs",
    "configPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\config",
    "eventLogsPath": "D:\\PROD_REPO_DATA\\IIS\\prodHealtchCheck\\EventLogs"
  },
  "outputs": {
    "clusters": {
      "sql": "infra_ClustersSQL.json",
      "fileShare": "infra_ClustersFileShare.json",
      "wmq": "infra_ClustersWMQ.json"
    },
    "infra": {
      "udzialySieciowe": "infra_UdzialySieciowe.json",
      "instancjeSQL": "infra_InstancjeSQL.json",
      "kolejkiMQ": "infra_KolejkiMQ.json",
      "przelaczeniaRol": "infra_PrzelaczeniaRol.json"
    },
    "serverHealth": {
      "pattern": "serverHealth_{Group}.json",
      "dmz": "serverHealth_DMZ.json"
    }
  }
}
```

### 2.2. clusters.json

Centralny plik konfiguracyjny dla wszystkich klastrow i infrastruktury.

**Lokalizacja:** `{configPath}\clusters.json`

```json
{
  "clusters": [
    {
      "cluster_name": "Klaster SQL Produkcja",
      "cluster_type": "SQL",
      "servers": ["SQLCL01-N1", "SQLCL01-N2"]
    },
    {
      "cluster_name": "Klaster SQL Test",
      "cluster_type": "SQL",
      "servers": ["SQLCL02-N1", "SQLCL02-N2"]
    },
    {
      "cluster_name": "Klaster FileShare",
      "cluster_type": "FileShare",
      "servers": ["FSCL01-N1", "FSCL01-N2"]
    },
    {
      "cluster_name": "WMQ 1-2",
      "cluster_type": "WMQ",
      "servers": ["MQPROD01", "MQPROD02"]
    },
    {
      "cluster_name": "WMQ 3-4",
      "cluster_type": "WMQ",
      "servers": ["MQPROD03", "MQPROD04"]
    },
    {
      "cluster_name": "MQ FileTransfer",
      "cluster_type": "WMQ",
      "servers": ["MQFT01", "MQFT02"]
    },
    {
      "cluster_name": "Role SQL",
      "cluster_type": "SQL_Roles",
      "servers": ["warsq21.ebre.pl,1520", "warsq23.ebre.pl,1530"]
    },
    {
      "cluster_name": "Role FileShare",
      "cluster_type": "FileShare_Roles",
      "servers": ["warpolarisw", "tytania"]
    }
  ]
}
```

#### Typy klastrow (cluster_type)

| Typ | Skrypt | Opis |
|-----|--------|------|
| `SQL` | Collect-ClusterData.ps1 | Klaster Windows Failover z SQL Server |
| `FileShare` | Collect-ClusterData.ps1 | Klaster Windows Failover z udzialami plikowymi |
| `WMQ` | Collect-MQData.ps1 | Klaster IBM MQ (WebSphere MQ) |
| `SQL_Roles` | Collect-InfraData.ps1 | Role SQL - instancje baz danych (VIP/DNS) |
| `FileShare_Roles` | Collect-InfraData.ps1 | Serwery z udzialami sieciowymi SMB |

#### Format serwerow

| Typ | Format | Przyklad |
|-----|--------|----------|
| SQL, FileShare | Nazwa wezla klastra | `SQLCL01-N1` |
| WMQ | Nazwa serwera MQ | `MQPROD01` |
| SQL_Roles | `host,port` lub `host` | `warsq21.ebre.pl,1520` |
| FileShare_Roles | Nazwa serwera | `warpolarisw` |

### 2.3. serverList_*.txt

Pliki tekstowe z lista serwerow dla poszczegolnych grup.

**Lokalizacja:** `{configPath}\serverList_{Group}.txt`

**Format:**
```
# Komentarz (ignorowany)
SERVER01
SERVER02
SERVER03
```

**Grupy:**
- `serverList_DCI.txt`
- `serverList_Ferryt.txt`
- `serverList_MarketPlanet.txt`
- `serverList_MQ.txt`
- `serverList_FileTransfer.txt`
- `serverList_Klastry.txt`

### 2.4. dmz_servers.json

Konfiguracja serwerow DMZ (laczenie przez Jump Host).

**Lokalizacja:** `{configPath}\dmz_servers.json`

```json
{
  "jumpHost": "JUMPHOST01",
  "groups": {
    "WebServers": ["DMZWEB01", "DMZWEB02"],
    "AppServers": ["DMZAPP01"]
  }
}
```

---

## 3. Skrypty PowerShell

### 3.1. Collect-ServerHealth.ps1

**Cel:** Zbiera dane o kondycji serwerow (CPU, RAM, dyski, uslugi, IIS, firewall).

**Parametry:**
```powershell
.\Collect-ServerHealth.ps1 -Group "DCI" [-ThrottleLimit 50]
```

**Zrodlo danych:** `serverList_{Group}.txt`

**Plik wyjsciowy:** `serverHealth_{Group}.json`

**Zbierane dane:**
- CPU (% uzycia)
- RAM (Total, Free, Used, % uzycia)
- Dyski (litera, rozmiar, wolne miejsce, %)
- Top 3 procesy CPU
- Top 3 procesy RAM
- Uslugi z dysku D:/E:
- Status Trellix
- Firewall (Domain, Private, Public)
- IIS (AppPools, Sites)

### 3.2. Collect-ServerHealth-DMZ.ps1

**Cel:** Zbiera dane o kondycji serwerow DMZ przez Jump Host.

**Zrodlo danych:** `dmz_servers.json`

**Plik wyjsciowy:** `serverHealth_DMZ.json`

### 3.3. Collect-ClusterData.ps1

**Cel:** Zbiera status klastrow Windows + historie przelaczen rol.

**Parametry:**
```powershell
.\Collect-ClusterData.ps1 [-ThrottleLimit 50] [-DaysBack 30]
```

**Zrodlo danych:** `clusters.json` (cluster_type: `SQL`, `FileShare`)

**Pliki wyjsciowe:**
- `infra_ClustersSQL.json` - klastry SQL
- `infra_ClustersFileShare.json` - klastry FileShare
- `infra_PrzelaczeniaRol.json` - historia przelaczen (30 dni)

**Zbierane dane:**
- Nazwa klastra
- Wezly (Name, State, IPAddresses)
- Role (Name, State, OwnerNode, IPAddresses)
- Eventy przelaczen rol (EventID: 1069, 1070, 1071, 1201, 1202, 1205, 1564, 1566)

**Eventy przelaczen:**

| EventID | EventType | Opis |
|---------|-----------|------|
| 1069 | ResourceOnline | Zasob uruchomiony |
| 1070 | ResourceOffline | Zasob zatrzymany |
| 1071 | ResourceFailed | Zasob awaria |
| 1201 | GroupOnline | Rola uruchomiona (START) |
| 1202 | GroupOffline | Rola zatrzymana (STOP) |
| 1205 | GroupMoved | Rola przeniesiona (FAILOVER) |
| 1564 | FailoverStarted | Failover rozpoczety |
| 1566 | FailoverCompleted | Failover zakonczony |

### 3.4. Collect-MQData.ps1

**Cel:** Zbiera dane o kolejkach MQ + status klastrow WMQ.

**Parametry:**
```powershell
.\Collect-MQData.ps1 [-ThrottleLimit 50]
```

**Zrodlo danych:** `clusters.json` (cluster_type: `WMQ`)

**Pliki wyjsciowe:**
- `infra_KolejkiMQ.json` - kolejki MQ
- `infra_ClustersWMQ.json` - klastry WMQ

**Zbierane dane:**
- Serwer (ServerName, IPAddress, ClusterName)
- QueueManagery (QueueManager, Status, Port)
- Kolejki (QueueName)

**Statusy QueueManager:**

| Status | Opis |
|--------|------|
| Running | QM dziala |
| Standby | QM w trybie standby (klaster HA) |
| Starting | QM sie uruchamia |
| Quiescing | QM sie wylacza |
| Stopped | QM zatrzymany |

### 3.5. Collect-InfraData.ps1

**Cel:** Zbiera dane o instancjach SQL + udzialach sieciowych.

**Parametry:**
```powershell
.\Collect-InfraData.ps1 [-ThrottleLimit 50]
```

**Zrodlo danych:** `clusters.json` (cluster_type: `SQL_Roles`, `FileShare_Roles`)

**Pliki wyjsciowe:**
- `infra_InstancjeSQL.json` - bazy danych SQL
- `infra_UdzialySieciowe.json` - udzialy sieciowe SMB

**Zbierane dane SQL:**
- ServerName
- SQLVersion
- DatabaseCount
- TotalSizeMB
- Databases (DatabaseName, CompatibilityLevel, DataFileSizeMB, LogFileSizeMB, TotalSizeMB)

**Zbierane dane FileShare:**
- ServerName
- ShareCount
- Shares (ShareName, SharePath, ShareState)

### 3.6. Collect-AllGroups.ps1

**Cel:** Skrypt zbiorczy uruchamiajacy wszystkie skrypty kolekcji.

**Kolejnosc wykonania:**
1. Collect-ServerHealth.ps1 dla kazdej grupy (DCI, Ferryt, MarketPlanet, MQ, FileTransfer, Klastry)
2. Collect-ServerHealth-DMZ.ps1
3. Collect-ClusterData.ps1
4. Collect-MQData.ps1
5. Collect-InfraData.ps1

---

## 4. Pliki wyjsciowe JSON

### 4.1. serverHealth_{Group}.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": 5.2,
  "TotalServers": 10,
  "SuccessCount": 9,
  "FailedCount": 1,
  "Group": "DCI",
  "Servers": [
    {
      "ServerName": "SERVER01",
      "CollectedAt": "2026-02-15 12:30:45",
      "CPU": 45,
      "RAM": {
        "TotalGB": 32.0,
        "FreeGB": 12.5,
        "UsedGB": 19.5,
        "PercentUsed": 61
      },
      "Disks": [
        {
          "Drive": "C:",
          "TotalGB": 100.0,
          "FreeGB": 35.2,
          "PercentFree": 35
        }
      ],
      "TopCPUServices": [
        { "Name": "sqlservr", "CPUPercent": 25 }
      ],
      "TopRAMServices": [
        { "Name": "sqlservr", "MemoryMB": 8192 }
      ],
      "DServices": [
        { "Name": "MyService", "DisplayName": "My Service", "State": "Running" }
      ],
      "TrellixStatus": [
        { "Name": "Trellix Endpoint Security", "State": "Running" }
      ],
      "Firewall": {
        "Domain": true,
        "Private": true,
        "Public": true
      },
      "IIS": {
        "Installed": true,
        "ServiceState": "Running",
        "AppPools": [
          { "Name": "DefaultAppPool", "State": "Started" }
        ],
        "Sites": [
          { "Name": "Default Web Site", "State": "Started", "Bindings": "*:80:" }
        ]
      },
      "Error": null
    }
  ]
}
```

### 4.2. infra_ClustersSQL.json / infra_ClustersFileShare.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": "3.5",
  "TotalClusters": 2,
  "OnlineCount": 2,
  "FailedCount": 0,
  "Clusters": [
    {
      "ClusterName": "SQLCLUSTER01",
      "ConfigName": "Klaster SQL Produkcja",
      "ClusterType": "SQL",
      "Error": null,
      "Nodes": [
        {
          "Name": "SQLCL01-N1",
          "State": "Up",
          "IPAddresses": "10.0.1.10"
        },
        {
          "Name": "SQLCL01-N2",
          "State": "Up",
          "IPAddresses": "10.0.1.11"
        }
      ],
      "Roles": [
        {
          "Name": "SQL Server (MSSQLSERVER)",
          "State": "Online",
          "OwnerNode": "SQLCL01-N1",
          "IPAddresses": "10.0.1.100"
        }
      ]
    }
  ]
}
```

### 4.3. infra_ClustersWMQ.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": "4.2",
  "TotalClusters": 3,
  "OnlineCount": 3,
  "FailedCount": 0,
  "Clusters": [
    {
      "ClusterName": "WMQ 1-2",
      "ClusterType": "WMQ",
      "Error": null,
      "Nodes": [
        {
          "Name": "MQPROD01",
          "State": "Up",
          "IPAddresses": "10.0.2.10"
        },
        {
          "Name": "MQPROD02",
          "State": "Up",
          "IPAddresses": "10.0.2.11"
        }
      ],
      "Roles": [
        {
          "Name": "QM.PROD01",
          "State": "Online",
          "OwnerNode": "MQPROD01",
          "IPAddresses": "10.0.2.10",
          "Port": "1414"
        },
        {
          "Name": "QM.PROD02",
          "State": "Standby",
          "OwnerNode": "MQPROD02",
          "IPAddresses": "10.0.2.11",
          "Port": ""
        }
      ]
    }
  ]
}
```

### 4.4. infra_KolejkiMQ.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": "4.2",
  "TotalServers": 6,
  "Servers": [
    {
      "ServerName": "MQPROD01",
      "ClusterName": "WMQ 1-2",
      "IPAddress": "10.0.2.10",
      "Error": null,
      "QueueManagers": [
        {
          "QueueManager": "QM.PROD01",
          "Status": "Running",
          "Port": "1414",
          "Queues": [
            { "QueueName": "APP.INPUT.QUEUE" },
            { "QueueName": "APP.OUTPUT.QUEUE" }
          ]
        }
      ]
    }
  ]
}
```

### 4.5. infra_InstancjeSQL.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": "2.8",
  "TotalInstances": 5,
  "Instances": [
    {
      "ServerName": "warsq21.ebre.pl,1520",
      "SQLVersion": "SQL Server 15.0.4123.1",
      "DatabaseCount": 12,
      "TotalSizeMB": 45678,
      "Error": null,
      "Databases": [
        {
          "DatabaseName": "AppDB",
          "CompatibilityLevel": 150,
          "DataFileSizeMB": 1024,
          "LogFileSizeMB": 256,
          "TotalSizeMB": 1280
        }
      ]
    }
  ]
}
```

### 4.6. infra_UdzialySieciowe.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "CollectionDuration": "1.5",
  "TotalServers": 3,
  "FileServers": [
    {
      "ServerName": "warpolarisw",
      "ShareCount": 5,
      "Error": null,
      "Shares": [
        {
          "ShareName": "Data",
          "SharePath": "D:\\Shares\\Data",
          "ShareState": "Online"
        }
      ]
    }
  ]
}
```

### 4.7. infra_PrzelaczeniaRol.json

```json
{
  "LastUpdate": "2026-02-15 12:30:45",
  "DaysBack": 30,
  "TotalEvents": 15,
  "Switches": [
    {
      "TimeCreated": "2026-02-14 10:30:15",
      "EventId": 1205,
      "EventType": "GroupMoved",
      "ClusterName": "SQLCLUSTER01",
      "ClusterType": "SQL",
      "RoleName": "SQL Server (MSSQLSERVER)",
      "SourceNode": "SQLCL01-N1",
      "TargetNode": "SQLCL01-N2",
      "ReportedBy": "SQLCL01-N2"
    },
    {
      "TimeCreated": "2026-02-14 10:30:10",
      "EventId": 1202,
      "EventType": "GroupOffline",
      "ClusterName": "SQLCLUSTER01",
      "ClusterType": "SQL",
      "RoleName": "SQL Server (MSSQLSERVER)",
      "SourceNode": "",
      "TargetNode": "SQLCL01-N1",
      "ReportedBy": "SQLCL01-N1"
    },
    {
      "TimeCreated": "2026-02-14 10:30:20",
      "EventId": 1201,
      "EventType": "GroupOnline",
      "ClusterName": "SQLCLUSTER01",
      "ClusterType": "SQL",
      "RoleName": "SQL Server (MSSQLSERVER)",
      "SourceNode": "",
      "TargetNode": "SQLCL01-N2",
      "ReportedBy": "SQLCL01-N2"
    }
  ]
}
```

---

## 5. Zakladki aplikacji

### 5.1. Kondycja serwerow

| Zakladka | Plik zrodlowy | Dane |
|----------|---------------|------|
| DCI | serverHealth_DCI.json | CPU, RAM, dyski, uslugi, IIS |
| Ferryt | serverHealth_Ferryt.json | CPU, RAM, dyski, uslugi, IIS |
| MarketPlanet | serverHealth_MarketPlanet.json | CPU, RAM, dyski, uslugi, IIS |
| MQ | serverHealth_MQ.json | CPU, RAM, dyski, uslugi, IIS |
| FileTransfer | serverHealth_FileTransfer.json | CPU, RAM, dyski, uslugi, IIS |
| Klastrowe | serverHealth_Klastry.json | CPU, RAM, dyski, uslugi, IIS |
| DMZ | serverHealth_DMZ.json | CPU, RAM, dyski, uslugi, IIS |

### 5.2. Status infrastruktury

| Zakladka | Pliki zrodlowe | Dane |
|----------|----------------|------|
| Klastry Windows | infra_ClustersSQL.json, infra_ClustersFileShare.json, infra_ClustersWMQ.json | Wezly, role, stan klastra |
| Udzialy sieciowe | infra_UdzialySieciowe.json | Nazwa, sciezka, stan udzialu |
| Instancje SQL | infra_InstancjeSQL.json | Wersja SQL, bazy danych, rozmiary |
| Kolejki MQ | infra_KolejkiMQ.json | QManager, status, port, nazwy kolejek |
| Przelaczenia rol | infra_PrzelaczeniaRol.json | Historia start/stop/failover (30 dni) |

### 5.3. Logi systemowe

| Zakladka | Dane |
|----------|------|
| Event Log | Dynamiczne pobieranie z serwerow (Application, System) |

---

## 6. Harmonogram uruchamiania

### Windows Task Scheduler

**Task:** `Collect-AllGroups`
**Trigger:** Co 5 minut
**Action:**
```
powershell.exe -ExecutionPolicy Bypass -File "D:\PROD_REPO\IIS\prodHealtchCheck\scripts\Collect-AllGroups.ps1"
```

### Szacowany czas wykonania

| Skrypt | Dla 40 serwerow |
|--------|-----------------|
| Collect-ServerHealth.ps1 (per grupa) | 3-8 sek |
| Collect-ClusterData.ps1 | 3-10 sek |
| Collect-MQData.ps1 | 5-15 sek |
| Collect-InfraData.ps1 | 3-12 sek |
| **Collect-AllGroups.ps1 (wszystko)** | **30-60 sek** |

---

## Troubleshooting

### Brak danych w zakladce

1. Sprawdz czy plik JSON istnieje w `{dataPath}`
2. Sprawdz logi: `{logsPath}\ServerHealthMonitor.log`
3. Uruchom skrypt reczenie i sprawdz bledy

### Timeout/Niedostepny serwer

- Connection timeout: 10 sekund
- Serwer zostanie oznaczony jako "Niedostepny" z bledem

### Puste dane MQ

1. Sprawdz czy `dspmq` i `runmqsc` sa dostepne na serwerach
2. Sprawdz uprawnienia konta uruchamiajacego skrypty

### Brak przelaczen rol

- Eventy sa zbierane z ostatnich 30 dni
- Sprawdz czy log `Microsoft-Windows-FailoverClustering/Operational` jest wlaczony
