# DIADesigner-AX CI/CD

Projekt DIADesigner-AX (`PilaJednosuportowaSoftmotion.project`, sterownik
**CODESYS Control Win V3 x64 SoftMotion 3.5.18.50**) wraz z pipeline'em CI,
który automatycznie:

1. kompiluje projekt w DIADesigner-AX 1.10 (headless),
2. wgrywa go do runtime SoftMotion uruchomionego lokalnie na runnerze
   (localhost), robi **Start**,
3. przez **30 s** sprawdza, czy aplikacja nie wchodzi w STOP ani w
   exception - jeśli nie, test jest zaliczony.

Wzorowane na [Codesys-CI-CD](https://github.com/PatrykChoinski/Codesys-CI-CD),
przerobione pod DIADesigner-AX (nakładka Delta na CODESYS V3.5 SP18).

## Jak to działa

DIADesigner-AX to CODESYS Development System z profilem Delty -
`DIADesigner-AX.exe` przyjmuje te same parametry co `CODESYS.exe`, więc
sterujemy nim przez **CODESYS Scripting**:

```
DIADesigner-AX.exe --profile="DIADesigner-AX 1.10" --runscript="scripts\dia_build.py" --scriptargs:'"..." "..."' --noUI --textPrompts
```

Runtime do testów - **CODESYS Control Win V3 x64 SoftMotion 3.5.18.50** -
jest częścią paczki DIADesigner-AX (`Redist\CODESYS_CtrlWin_64-3.5.18.50-Latest.zip`).
Delta uruchamia go nie jako usługę, tylko jako proces konsolowy
(`CODESYSControlService.exe -d "CODESYSSoftMotion.cfg"`, skrót w menu Start
"CODESYS SoftMotion Win 64") - tak samo robi `scripts/Install-SoftMotionRuntime.ps1`.

```
windows-latest (hostowany runner GitHub Actions, świeża VM per job)
├── DIADesigner-AX 1.10 (kompilacja, CODESYS Scripting)
├── CODESYS Gateway V3 (TCP 1217)
└── CODESYS Control Win V3 x64 SoftMotion 3.5.18.50 (proces -d, TCP 11740)
```

## Struktura repo

```
PilaJednosuportowaSoftmotion.project   - projekt DIADesigner-AX (jedyny projekt w repo)
PilaJednosuportowaSoftmotion.projectarchive
                                       - archiwum projektu - TYLKO do "primingu" urządzeń/bibliotek,
                                         git-ignored, wgrywane do GitHub Release "ProjectArchive"
installers/README.md                   - skąd bierze się instalator (GitHub Release "Installers")
scripts/
  Assert-ValidZip.ps1                  - walidacja pobranego .zip (rozmiar, sygnatura PK)
  Expand-Zip.ps1                       - rozpakowanie .zip (tar.exe - paczka ma ~2 GB)
  Start-SilentInstall.ps1              - uruchomienie instalatora z twardym timeoutem
  Install-DIADesignerAX.ps1            - cicha instalacja DIADesigner-AX z paczki Delty
  Install-SoftMotionRuntime.ps1        - instalacja (jeśli brak) + start runtime SoftMotion i gatewaya
  Invoke-DiaCli.ps1                    - uruchomienie DIADesigner-AX.exe ze skryptem (headless)
  Invoke-DiaBuild.ps1 / dia_build.py   - etap BUILD
  Invoke-DiaDeployTest.ps1 / dia_deploy_test.py
                                       - etapy DEPLOY + TEST (jedna sesja online)
  dia_common.py                        - wspólne helpery (JUnit, gateway, wybór lokalnego runtime)
  Write-Summary.ps1                    - raport Markdown (GitHub Job Summary)
  Invoke-LocalPipeline.ps1             - cały pipeline lokalnie
.github/workflows/diadesigner-ci.yml   - workflow GitHub Actions (1 job)
reports/                               - raporty JUnit + logi (git-ignored)
work/                                  - katalog roboczy (git-ignored)
```

## Etapy

### 1. BUILD ([`dia_build.py`](scripts/dia_build.py))

- otwiera `PilaJednosuportowaSoftmotion.projectarchive` (`projects.open_archive`)
  i **od razu je zamyka** - to tylko "priming": otwarcie archiwum instaluje
  zawarte w nim opisy urządzeń i biblioteki do repozytoriów całej maszyny,
  których świeża instalacja DIADesigner-AX na runnerze nie ma (Device
  Repository Delty i dodatkowe biblioteki to osobne pakiety),
- otwiera **żywy `PilaJednosuportowaSoftmotion.project`** i kompiluje
  aktywną aplikację (`generate_code()`); błędy kompilacji (z POU i numerem
  linii) trafiają do raportu i jako adnotacje na stronie przebiegu,
- projekt **nie jest zapisywany** - plik w repo zostaje taki, jak w commicie.

Zwykła zmiana kodu **nie wymaga** regenerowania archiwum. Trzeba je
podmienić tylko, gdy zmienia się urządzenie projektu albo zestaw bibliotek
(patrz niżej).

### 2. DEPLOY + 3. TEST ([`dia_deploy_test.py`](scripts/dia_deploy_test.py))

- instaluje (jeśli trzeba) i uruchamia runtime SoftMotion + gateway;
  wcześniej ustawia `SECURITY.UserMgmtEnforce=NO` w `CODESYSSoftMotion.cfg`
  runtime (CODESYS Control >= SP17 wymaga inaczej założenia użytkownika
  przy pierwszym logowaniu - headless CI nie ma jak odpowiedzieć),
- skanuje sieć przez lokalny gateway i wybiera **tylko** runtime o nazwie
  tego komputera i typie SoftMotion (4102) - na maszynie deweloperskiej
  skan widzi też prawdziwe sterowniki w LAN, do których nic nie może
  zostać wgrane,
- login z pełnym downloadem, **Start**, oczekiwanie na RUN (`junit-deploy.xml`),
- w **tej samej sesji online** przez 30 s co sekundę: stan musi być RUN,
  bez flagi exception; dodatkowo sprawdzany jest dziennik audytu runtime
  (`.Audit*.log`) pod kątem wpisów o exception / stop / reset od chwili
  Startu - projekt ma własny handler wyjątków (`RestartApp`: reset +
  restart aplikacji), który mógłby "schować" wyjątek między próbkami
  (`junit-test.xml`).

Dlaczego deploy i test są w jednym procesie: ponowne zalogowanie się z
drugiego procesu DIADesigner-AX widzi inny CodeGUID niż ten na urządzeniu
i (domyślna odpowiedź na prompt) wgrywa aplikację jeszcze raz - po czym
jest ona w STOP, więc osobny etap testu obserwowałby świeżo wgraną,
zatrzymaną aplikację zamiast tej wystartowanej w deployu. Widać to w
dzienniku audytu runtime jako `Reinitialize for Download`.

## Hasło projektu

Projekt i archiwum są zaszyfrowane (Project Properties > Protection >
Encryption Password). Bez hasła `projects.open()`/`open_archive()`
pokazują modalny dialog, którego pod `--noUI` nikt nie obsłuży. Hasło
podawane jest przez zmienną środowiskową **`PROJECT_PASSWORD`**:

- w CI - z sekretu repo `PROJECT_PASSWORD` (`gh secret set PROJECT_PASSWORD`),
- lokalnie - ze zmiennej środowiskowej użytkownika `PROJECT_PASSWORD`.

Hasło nigdy nie jest zapisywane w repo.

## Uruchomienie lokalne

Wymaga zainstalowanego DIADesigner-AX 1.10 (razem z komponentem "Control Win").

```powershell
$env:PROJECT_PASSWORD = "..."     # albo trwała zmienna użytkownika PROJECT_PASSWORD
./scripts/Invoke-LocalPipeline.ps1
```

Uruchamia runtime SoftMotion na tej maszynie (zatrzymuje ewentualnie
działającą usługę `CODESYS Control*`, bo zajmuje te same porty), a na
końcu go wyłącza (`-KeepRuntime` zostawia go działającego).

## GitHub Release - instalator i archiwum projektu

Pliki są za duże na commit (limit 100 MB), więc leżą jako assety GitHub
Release w tym repo i workflow pobiera je przez `gh release download`:

| Release (tag)    | Asset                                           |
|------------------|-------------------------------------------------|
| `Installers`     | `DIADesigner-AX-x64-1.10.0.9242.zip` (~2 GB)    |
| `ProjectArchive` | `PilaJednosuportowaSoftmotion.projectarchive`   |

Podmiana archiwum po zmianie urządzenia/bibliotek (zapisz je w
DIADesigner-AX: File > Project Archive > Save/Send Archive):

```powershell
gh release upload ProjectArchive PilaJednosuportowaSoftmotion.projectarchive --clobber
```

Szczegóły instalatora: [`installers/README.md`](installers/README.md).

## Raport

Ostatni krok workflow ([`Write-Summary.ps1`](scripts/Write-Summary.ps1),
zawsze uruchamiany) składa wszystkie `reports/junit-*.xml` w jeden raport
Markdown w **Job Summary** przebiegu - widać od razu, który etap padł i
dlaczego (np. lista błędów kompilacji, historia stanów aplikacji podczas
30 s obserwacji). Raporty i logi (runtime, instalacja MSI) są też
dostępne jako artefakt `diadesigner-ci-reports`.

## Praca z repo

Zasady współpracy z Claude opisane są w [`CLAUDE.md`](CLAUDE.md), historia
zmian w [`CHANGELOG.md`](CHANGELOG.md).
