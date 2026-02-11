# Instrukcja dodawania nowych zakładek

> **Uwaga:** Ta instrukcja dotyczy zakładek LAN. Dla serwerów DMZ zobacz sekcję "Dodawanie grupy DMZ" na końcu dokumentu.

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

---

# Dodawanie grupy DMZ

Serwery w strefie DMZ wymagają osobnej konfiguracji z uwierzytelnieniem SSL/Negotiate.

## Krok 1: Zaszyfruj hasło

Uruchom w PowerShell ISE:
```powershell
.\scripts\Encrypt-Password.ps1
```

1. Wpisz hasło (ukryte wprowadzanie)
2. Skopiuj zaszyfrowany string

> **WAŻNE:** Hasło musi być zaszyfrowane na tym samym komputerze i przez tego samego użytkownika Windows, który będzie uruchamiał skrypt!

## Krok 2: Dodaj grupę do serverList_DMZ.json

Edytuj plik `D:\PROD_REPO_DATA\IIS\prodHealtchCheck\serverList_DMZ.json`

Dodaj nowy obiekt w tablicy `groups`:
```json
{
    "groups": [
        {
            "name": "Istniejaca Grupa",
            "login": "svc_existing",
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

## Krok 3: Uruchom zbieranie

```powershell
.\scripts\Collect-ServerHealth-DMZ.ps1
```

## Krok 4: Sprawdź wyniki

- Otwórz zakładkę **DMZ** w przeglądarce
- Nowa grupa pojawi się jako badge przy nazwie serwera

---

## Podsumowanie: LAN vs DMZ

| Cecha | LAN | DMZ |
|-------|-----|-----|
| Plik konfiguracji | `serverList_GRUPA.txt` | `serverList_DMZ.json` |
| Format | Lista nazw (TXT) | JSON z grupami |
| Uwierzytelnienie | Kerberos (domyślne) | SSL + Negotiate + Credential |
| Hasło | Brak | Zaszyfrowane DPAPI |
| Skrypt | `Collect-ServerHealth.ps1` | `Collect-ServerHealth-DMZ.ps1` |
| Zakładka | Osobna dla każdej grupy | Jedna zakładka DMZ dla wszystkich grup |

## Struktura serverList_DMZ.json

```json
{
    "groups": [
        {
            "name": "string",      // Nazwa wyświetlana w UI
            "login": "string",     // Login (DOMAIN\\user lub user)
            "password": "string",  // Hasło zaszyfrowane DPAPI
            "servers": [           // Lista adresów IP
                "192.168.1.10",
                "192.168.1.11"
            ]
        }
    ]
}
```

## Rozwiązywanie problemów DMZ

### Błąd: "Nie można odszyfrować hasła"
- Hasło zostało zaszyfrowane na innym komputerze lub przez innego użytkownika
- **Rozwiązanie:** Uruchom `Encrypt-Password.ps1` na maszynie docelowej i zaktualizuj JSON

### Błąd: "Timeout/Niedostępny"
- Serwer nie odpowiada na port 5986 (WinRM HTTPS)
- **Sprawdź:** `Test-NetConnection -ComputerName IP -Port 5986`
- **Sprawdź:** czy WinRM over HTTPS jest skonfigurowany na serwerze DMZ

### Błąd: "Access Denied"
- Nieprawidłowy login lub hasło
- Konto nie ma uprawnień do WinRM na serwerze docelowym
