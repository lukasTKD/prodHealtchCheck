# Konfiguracja clusters.json

Jeden centralny plik konfiguracyjny dla wszystkich skryptow zbierajacych dane o klastrach i infrastrukturze.

## Lokalizacja

Plik znajduje sie w katalogu zdefiniowanym w `app-config.json` pod kluczem `paths.configPath`:
```
{configPath}\clusters.json
```

---

## Struktura pliku

```json
{
  "clusters": [
    {
      "cluster_name": "Nazwa klastra",
      "cluster_type": "TYP",
      "servers": ["serwer1", "serwer2"]
    }
  ]
}
```

### Pola

| Pole | Typ | Opis |
|------|-----|------|
| `cluster_name` | string | Przyjazna nazwa klastra/grupy |
| `cluster_type` | string | Typ klastra (patrz tabela nizej) |
| `servers` | array[string] | Lista serwerow/instancji |

---

## Typy klastrow (cluster_type)

| Typ | Skrypt | Opis |
|-----|--------|------|
| `SQL` | Collect-ClusterData.ps1 | Klaster Windows Failover z SQL Server |
| `FileShare` | Collect-ClusterData.ps1 | Klaster Windows Failover z udzialami plikowymi |
| `WMQ` | Collect-MQData.ps1 | Klaster IBM MQ (WebSphere MQ) |
| `SQL_Roles` | Collect-InfraData.ps1 | Role SQL (instancje baz danych) |
| `FileShare_Roles` | Collect-InfraData.ps1 | Serwery z udzialami sieciowymi |

---

## Przyklad kompletny

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

---

## Skrypty i ich zrodla danych

### Collect-ClusterData.ps1
- **Czyta:** `cluster_type` = `SQL`, `FileShare`
- **Generuje:**
  - `infra_ClustersSQL.json` - status klastrow SQL
  - `infra_ClustersFileShare.json` - status klastrow FileShare
  - `infra_PrzelaczeniaRol.json` - historia przelaczen rol (30 dni)

### Collect-MQData.ps1
- **Czyta:** `cluster_type` = `WMQ`
- **Generuje:**
  - `infra_KolejkiMQ.json` - kolejki MQ na serwerach
  - `infra_ClustersWMQ.json` - status klastrow WMQ

### Collect-InfraData.ps1
- **Czyta:** `cluster_type` = `SQL_Roles`, `FileShare_Roles`
- **Generuje:**
  - `infra_InstancjeSQL.json` - bazy danych na instancjach SQL
  - `infra_UdzialySieciowe.json` - udzialy sieciowe SMB

---

## Format serwerow

### Klastry Windows (SQL, FileShare)
```json
"servers": ["NAZWANODE1", "NAZWANODE2"]
```
Podaj nazwy fizycznych wezlow klastra.

### Klastry WMQ
```json
"servers": ["MQSRV01", "MQSRV02"]
```
Podaj nazwy serwerow z zainstalowanym IBM MQ.

### Role SQL (SQL_Roles)
```json
"servers": ["serwer.domena.pl,port", "serwer2,1433"]
```
Podaj nazwy instancji SQL w formacie `host,port` lub `host` (domyslny port 1433).

### Role FileShare (FileShare_Roles)
```json
"servers": ["nazwaservera", "innyserwer"]
```
Podaj nazwy serwerow do odpytania o udzialy SMB.

---

## Wydajnosc

Wszystkie skrypty uzywaja rownoczesnego wykonania:
- **Invoke-Command** z `-ThrottleLimit 50` (Cluster, MQ, FileShare)
- **RunspacePool** (SQL_Roles - polaczenia SqlClient)

Typowy czas wykonania: 2-5 sekund dla 10+ serwerow.
