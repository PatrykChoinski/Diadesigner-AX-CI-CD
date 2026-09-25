# Changelog

## 2026-09-25 (2)

### Naprawione
- CI: priming z `.projectarchive` padał na czystym runnerze -
  `projects.open_archive()` zwracał `None` (headless anuluje dialog
  wyboru urządzeń/bibliotek do instalacji). Teraz
  `Expand-ProjectArchive.ps1` wypakowuje z archiwum opisy urządzeń (22) i
  biblioteki (142), a `dia_build.py` instaluje je przez
  `device_repository.import_device()` / `librarymanager.install_library()`.
- CI: instalacja runtime SoftMotion kończyła się `msiexec` 1603 - domyślny
  katalog MSI leży pod `Program Files (x86)`, który odrzuca jego akcja
  `CDSCheckTargetdir`. `INSTALLDIR` podawany jawnie (jak `<InstallPath>`
  w manifeście Delty).

## 2026-09-25

### Dodane
- Pipeline CI dla DIADesigner-AX 1.10 (`.github/workflows/diadesigner-ci.yml`),
  wzorowany na [Codesys-CI-CD](https://github.com/PatrykChoinski/Codesys-CI-CD):
  1 job na `windows-latest` - instalacja DIADesigner-AX z paczki Delty
  (GitHub Release `Installers`), priming urządzeń/bibliotek z
  `PilaJednosuportowaSoftmotion.projectarchive` (GitHub Release
  `ProjectArchive`), kompilacja `PilaJednosuportowaSoftmotion.project`,
  download + Start na lokalnym CODESYS Control Win V3 x64 SoftMotion
  3.5.18.50 i 30 s obserwacji (RUN, bez STOP/exception).
- Cicha instalacja paczki Delty (`Install-DIADesignerAX.ps1`,
  `Install-SoftMotionRuntime.ps1`) odtworzona z manifestów instalatora
  (`Data\*.zip`), bo `Setup.exe` Delty nie ma trybu cichego.
- Runtime SoftMotion uruchamiany jak skrót Delty (`CODESYSControlService.exe -d
  "CODESYSSoftMotion.cfg"`), przez `Win32_Process.Create` (bez dziedziczenia
  uchwytów - inaczej krok CI czekałby na zamknięcie stdout), z
  `SECURITY.UserMgmtEnforce=NO` i włączonym plikowym loggerem CmpLog
  (`StdLogger.csv`).
- Wybór urządzenia po skanie sieci filtrowany do nazwy tego komputera i
  typu SoftMotion (4102) - skan na maszynie deweloperskiej widzi też
  prawdziwe sterowniki w LAN.
- Test sprawdza też logi runtime (`StdLogger.csv` - wyjątki IEC,
  `.Audit*.log` - stop/reset) od chwili Startu: projekt ma własny handler
  wyjątków (`RestartApp`: reset + restart), który mógłby ukryć crash
  między próbkami stanu.
- Hasło projektu ze zmiennej `PROJECT_PASSWORD` (w CI z sekretu
  `PROJECT_PASSWORD`).
- `Invoke-LocalPipeline.ps1` - cały pipeline lokalnie.

### Ustalenia z testów lokalnych
- Deploy i test muszą być w jednej sesji online: ponowny login z nowego
  procesu DIADesigner-AX robi `Reinitialize for Download` (inny CodeGUID +
  domyślna odpowiedź na prompt) i zostawia aplikację w STOP.
- Drugi parametr `login()` to `delete_foreign_apps`, a nie "always
  update"; login bez downloadu to `OnlineChangeOption.Keep`.
- Tuż po pełnym downloadzie `start()` potrafi przekroczyć limit czasu -
  ponawiany do 5 razy.
- Windows PowerShell 5.1 gubi `ExitCode` procesu z `Start-Process -PassThru`
  + `WaitForExit(timeout)`, jeśli wcześniej nie odczyta się `$proc.Handle`.
