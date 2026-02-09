# Instrukcja dodawania nowych zakładek

## Krok 1: Dodaj grupę do skryptu PowerShell

Edytuj plik `scripts\Collect-ServerHealth.ps1`

Znajdź linię z `ValidateSet` (około linii 4):
```powershell
[ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")]
```

Dodaj nową grupę:
```powershell
[ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "NowaGrupa")]
```

## Krok 2: Dodaj grupę do skryptu zbiorczego

Edytuj plik `scripts\Collect-AllGroups.ps1`

Znajdź tablicę `$Groups`:
```powershell
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry")
```

Dodaj nową grupę:
```powershell
$Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "NowaGrupa")
```

## Krok 3: Dodaj zakładkę w HTML

Edytuj plik `index.html`

Znajdź sekcję z zakładkami (około linii 289-296):
```html
<div class="tabs">
    <button class="tab active" data-group="DCI" onclick="switchTab('DCI')">DCI</button>
    <button class="tab" data-group="Ferryt" onclick="switchTab('Ferryt')">Ferryt</button>
    ...
</div>
```

Dodaj nową zakładkę:
```html
<button class="tab" data-group="NowaGrupa" onclick="switchTab('NowaGrupa')">NowaGrupa</button>
```

## Krok 4: Utwórz plik z listą serwerów

Utwórz plik `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\serverList_NowaGrupa.txt`

Zawartość:
```
# Lista serwerów dla grupy: NowaGrupa
SERVER1
SERVER2
SERVER3
```

## Krok 5: Uruchom zbieranie danych

```powershell
.\scripts\Collect-ServerHealth.ps1 -Group NowaGrupa
```

Lub dla wszystkich grup:
```powershell
.\scripts\Collect-AllGroups.ps1
```

## Krok 6: Odśwież stronę

Otwórz stronę w przeglądarce - nowa zakładka powinna być widoczna.

---

## Podsumowanie zmian

| Plik | Co zmienić |
|------|------------|
| `scripts\Collect-ServerHealth.ps1` | Dodaj do `ValidateSet` |
| `scripts\Collect-AllGroups.ps1` | Dodaj do tablicy `$Groups` |
| `index.html` | Dodaj `<button class="tab">` |
| `serverList_NowaGrupa.txt` | Utwórz nowy plik z listą serwerów |

## Przykład: Dodanie grupy "Bazy"

1. **Collect-ServerHealth.ps1:**
   ```powershell
   [ValidateSet("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "Bazy")]
   ```

2. **Collect-AllGroups.ps1:**
   ```powershell
   $Groups = @("DCI", "Ferryt", "MarketPlanet", "MQ", "FileTransfer", "Klastry", "Bazy")
   ```

3. **index.html:**
   ```html
   <button class="tab" data-group="Bazy" onclick="switchTab('Bazy')">Bazy</button>
   ```

4. **Utwórz plik:**
   ```
   D:\PROD_REPO_DATA\IIS\prodHealtchCheck\serverList_Bazy.txt
   ```

5. **Uruchom:**
   ```powershell
   .\scripts\Collect-AllGroups.ps1
   ```
