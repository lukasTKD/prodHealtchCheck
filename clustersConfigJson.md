# Konfiguracja plikow JSON dla skryptow zbierajacych dane

## Pliki konfiguracyjne

Wszystkie pliki konfiguracyjne znajduja sie w katalogu zdefiniowanym w `app-config.json` pod kluczem `paths.configPath`.

---

## 1. clusters.json

Plik konfiguracyjny dla klastrow Windows (SQL, FileShare) oraz serwerow infrastrukturalnych.

**Uzywany przez:**
- `Collect-ClusterData.ps1` - status klastrow Windows + historia przelaczen rol
- `Collect-InfraData.ps1` - instancje SQL + udzialy sieciowe FileShare

### Struktura

```json
{
  "clusters": [
    {
      "cluster_type": "SQL",
      "servers": ["SQLNODE01", "SQLNODE02"]
    },
    {
      "cluster_type": "SQL",
      "servers": ["SQLNODE03", "SQLNODE04"]
    },
    {
      "cluster_type": "FileShare",
      "servers": ["FSNODE01", "FSNODE02"]
    }
  ]
}
```

### Pola

| Pole | Typ | Opis |
|------|-----|------|
| `clusters` | array | Lista definicji klastrow |
| `cluster_type` | string | Typ klastra: `SQL` lub `FileShare` |
| `servers` | array[string] | Lista nazw serwerow (wezlow) w klastrze |

### Uwagi

- Kazdy klaster moze miec 1 lub wiecej wezlow
- Skrypty automatycznie wykrywaja duplikaty (ten sam klaster z roznych wezlow)
- Dla SQL: pobierane sa informacje o bazach danych i instancjach
- Dla FileShare: pobierane sa udzialy sieciowe (SMB shares)

---

## 2. mq_servers.json

Plik konfiguracyjny dla serwerow IBM MQ.

**Uzywany przez:**
- `Collect-MQData.ps1` - kolejki MQ + status klastrow WMQ

### Struktura

```json
{
  "MQ_CLUSTER_PROD": ["MQPROD01", "MQPROD02"],
  "MQ_CLUSTER_TEST": ["MQTEST01", "MQTEST02"],
  "MQ_STANDALONE": ["MQSRV01"]
}
```

### Pola

| Pole | Typ | Opis |
|------|-----|------|
| `<nazwa_klastra>` | array[string] | Lista nazw serwerow nalezacych do klastra MQ |

### Uwagi

- Klucz JSON jest nazwa klastra/grupy MQ
- Wartosc to lista serwerow nalezacych do tego klastra
- Jeden serwer moze nalezec tylko do jednego klastra
- Skrypt pobiera dane rownocesnie ze wszystkich serwerow (Invoke-Command)

---

## Pliki wyjsciowe

Skrypty generuja pliki JSON w katalogu `paths.dataPath`:

### Collect-ClusterData.ps1
| Plik | Klucz w app-config.json | Opis |
|------|-------------------------|------|
| `infra_ClustersSQL.json` | `outputs.clusters.sql` | Status klastrow SQL |
| `infra_ClustersFileShare.json` | `outputs.clusters.fileShare` | Status klastrow FileShare |
| `infra_PrzelaczeniaRol.json` | `outputs.infra.przelaczeniaRol` | Historia przelaczen rol |

### Collect-MQData.ps1
| Plik | Klucz w app-config.json | Opis |
|------|-------------------------|------|
| `infra_KolejkiMQ.json` | `outputs.infra.kolejkiMQ` | Kolejki MQ |
| `infra_ClustersWMQ.json` | `outputs.clusters.wmq` | Status klastrow WMQ |

### Collect-InfraData.ps1
| Plik | Klucz w app-config.json | Opis |
|------|-------------------------|------|
| `infra_InstancjeSQL.json` | `outputs.infra.instancjeSQL` | Instancje i bazy SQL |
| `infra_UdzialySieciowe.json` | `outputs.infra.udzialySieciowe` | Udzialy sieciowe |

---

## Przyklad kompletnej konfiguracji

### clusters.json
```json
{
  "clusters": [
    {
      "cluster_type": "SQL",
      "servers": ["SQLCL01-N1", "SQLCL01-N2"]
    },
    {
      "cluster_type": "SQL",
      "servers": ["SQLCL02-N1", "SQLCL02-N2"]
    },
    {
      "cluster_type": "FileShare",
      "servers": ["FSCL01-N1", "FSCL01-N2"]
    }
  ]
}
```

### mq_servers.json
```json
{
  "PROD_MQ_CLUSTER": ["MQPROD01", "MQPROD02"],
  "TEST_MQ_CLUSTER": ["MQTEST01"],
  "DEV_MQ": ["MQDEV01"]
}
```

---

## Wydajnosc

Wszystkie skrypty uzywaja rownoczesnego wykonania zdalnego (`Invoke-Command` z `-ThrottleLimit 50`), co zapewnia szybkie zbieranie danych z wielu serwerow jednoczesnie - analogicznie do `Collect-ServerHealth.ps1`.

Typowy czas wykonania:
- Dla 10+ serwerow: 2-5 sekund
- Dla pojedynczego klastra: < 2 sekundy
