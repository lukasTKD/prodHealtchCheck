# Struktura plikow JSON dla sekcji "Status infrastruktury"

Strona czyta pliki z katalogu `dataPath` (D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\).
Nazwy plikow: `infra_` + nazwa_zakladki + `.json`

---

## 1. infra_ClustersWindows.json

```json
{
    "LastUpdate": "2025-02-13 18:00:00",
    "CollectionDuration": "5.2",
    "TotalClusters": 3,
    "OnlineCount": 3,
    "FailedCount": 0,
    "Clusters": [
        {
            "ClusterName": "CLUSTER-SQL01",
            "ClusterType": "SQL",
            "Error": null,
            "Nodes": [
                {
                    "Name": "NODE1",
                    "State": "Up",
                    "IPAddresses": "10.0.0.1"
                },
                {
                    "Name": "NODE2",
                    "State": "Up",
                    "IPAddresses": "10.0.0.2"
                }
            ],
            "Roles": [
                {
                    "Name": "SQL Server (MSSQLSERVER)",
                    "State": "Online",
                    "OwnerNode": "NODE1",
                    "IPAddresses": "10.0.0.10"
                }
            ]
        }
    ]
}
```

**Wymagane pola:**
- `LastUpdate` - string, data ostatniej aktualizacji
- `CollectionDuration` - string, czas zbierania danych w sekundach
- `TotalClusters` - int, liczba klastrow
- `OnlineCount` - int, liczba online
- `FailedCount` - int, liczba z bledami
- `Clusters[]` - tablica klastrow
  - `ClusterName` - string
  - `ClusterType` - string (SQL, FileShare, MQ)
  - `Error` - string|null
  - `Nodes[]` - tablica wezlow
    - `Name` - string
    - `State` - string (Up/Down)
    - `IPAddresses` - string
  - `Roles[]` - tablica rol
    - `Name` - string
    - `State` - string (Online/Offline)
    - `OwnerNode` - string (nazwa wezla)
    - `IPAddresses` - string

---

## 2. infra_UdzialySieciowe.json

```json
{
    "LastUpdate": "2025-02-13 18:00:00",
    "CollectionDuration": "2.1",
    "TotalServers": 2,
    "FileServers": [
        {
            "ServerName": "FILESERVER01",
            "ShareCount": 5,
            "Error": null,
            "Shares": [
                {
                    "ShareName": "Dane",
                    "SharePath": "D:\\Shares\\Dane",
                    "ShareState": "Online"
                },
                {
                    "ShareName": "Backup",
                    "SharePath": "E:\\Backup",
                    "ShareState": "Online"
                }
            ]
        }
    ]
}
```

**Wymagane pola:**
- `LastUpdate` - string
- `CollectionDuration` - string
- `TotalServers` - int
- `FileServers[]` - tablica serwerow
  - `ServerName` - string
  - `ShareCount` - int
  - `Error` - string|null
  - `Shares[]` - tablica udzialow
    - `ShareName` - string
    - `SharePath` - string
    - `ShareState` - string (Online/Offline)

---

## 3. infra_InstancjeSQL.json

```json
{
    "LastUpdate": "2025-02-13 18:00:00",
    "CollectionDuration": "3.5",
    "TotalInstances": 2,
    "Instances": [
        {
            "ServerName": "SQLSERVER01",
            "SQLVersion": "Microsoft SQL Server 2019",
            "DatabaseCount": 10,
            "TotalSizeMB": 51200,
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

**Wymagane pola:**
- `LastUpdate` - string
- `CollectionDuration` - string
- `TotalInstances` - int
- `Instances[]` - tablica instancji
  - `ServerName` - string
  - `SQLVersion` - string
  - `DatabaseCount` - int
  - `TotalSizeMB` - int (opcjonalne, do statystyk)
  - `Error` - string|null
  - `Databases[]` - tablica baz
    - `DatabaseName` - string
    - `CompatibilityLevel` - int
    - `DataFileSizeMB` - int
    - `LogFileSizeMB` - int
    - `TotalSizeMB` - int

---

## 4. infra_KolejkiMQ.json

```json
{
    "LastUpdate": "2025-02-13 18:00:00",
    "CollectionDuration": "4.0",
    "TotalServers": 6,
    "Servers": [
        {
            "ServerName": "MQSERVER01",
            "Error": null,
            "QueueManagers": [
                {
                    "QueueManager": "QM1",
                    "Status": "Running",
                    "Port": "1414",
                    "Queues": [
                        {
                            "QueueName": "APP.QUEUE.IN",
                            "CurrentDepth": 0,
                            "MaxDepth": 5000
                        }
                    ]
                }
            ]
        }
    ]
}
```

**Wymagane pola:**
- `LastUpdate` - string
- `CollectionDuration` - string
- `TotalServers` - int
- `Servers[]` - tablica serwerow
  - `ServerName` - string
  - `Error` - string|null
  - `QueueManagers[]` - tablica queue managerow
    - `QueueManager` - string
    - `Status` - string (Running/Stopped)
    - `Port` - string
    - `Queues[]` - tablica kolejek
      - `QueueName` - string
      - `CurrentDepth` - int (opcjonalne)
      - `MaxDepth` - int (opcjonalne)

---

## 5. infra_PrzelaczeniaRol.json

```json
{
    "LastUpdate": "2025-02-13 18:00:00",
    "CollectionDuration": "1.5",
    "TotalEvents": 15,
    "DaysBack": 30,
    "Switches": [
        {
            "TimeCreated": "2025-02-13 12:30:00",
            "ClusterName": "CLUSTER-SQL01",
            "ClusterType": "SQL",
            "EventType": "RoleMoved",
            "RoleName": "SQL Server",
            "SourceNode": "NODE1",
            "TargetNode": "NODE2"
        }
    ]
}
```

---

## Lokalizacja plikow konfiguracyjnych

Skrypty czytaja konfiguracje z: `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config\`

- `clusters.json` - definicja klastrow (SQL, FileShare)
- `mq_servers.json` - serwery MQ
- `databases.json` - serwery SQL (opcjonalne, mozna uzyc clusters.json)

