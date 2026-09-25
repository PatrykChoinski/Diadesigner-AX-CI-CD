# CLAUDE.md

Zasady pracy Claude w tym repozytorium.

## Git

- Każdą zmianę wprowadzoną w repo commituj lokalnie (małe, opisowe commity).
- Nigdy nie rób `git push` bez wyraźnego polecenia użytkownika.
- Każdą zmianę odnotuj w [CHANGELOG.md](CHANGELOG.md).

## Projekt

- Jedyny projekt w repo: `PilaJednosuportowaSoftmotion.project`
  (DIADesigner-AX 1.10, urządzenie CODESYS Control Win V3 x64 SoftMotion
  3.5.18.50, `4102|0000 0004|3.5.18.50`). Inne projekty w folderze
  (`PilaJednosuportowa*`, `PilaJednosuportowaAI*`) są git-ignored i nie
  należą do repo.
- `.projectarchive` służy **tylko** do zaciągnięcia zależności (opisy
  urządzeń, biblioteki): build wypakowuje je (`Expand-ProjectArchive.ps1`)
  i instaluje przez API (nie `open_archive()` - na czystej maszynie
  headless zwraca `None`), a potem pracuje na `.project`.
- Nie uruchamiać lokalnie buildów/deployów bez pytania - użytkownik
  pracuje w DIADesigner-AX i na lokalnym runtime; weryfikacja przez CI. Archiwum nie jest commitowane (za duże) - leży
  w GitHub Release `ProjectArchive`.
- Instalator (`DIADesigner-AX-x64-1.10.0.9242.zip`) leży w GitHub Release
  `Installers`, szczegóły w `installers/README.md`.
- Hasło projektu: zmienna środowiskowa `PROJECT_PASSWORD` (w CI sekret
  `PROJECT_PASSWORD`). Nigdy nie zapisywać go w repo/logach.
- Headless: `DIADesigner-AX.exe --profile="DIADesigner-AX 1.10"
  --runscript=... --noUI --textPrompts` (CODESYS Scripting, IronPython 2.7).
- Runtime SoftMotion uruchamiany jako proces `CODESYSControlService.exe -d
  "CODESYSSoftMotion.cfg"` (nie usługa). Wybór urządzenia po skanie sieci
  jest filtrowany do nazwy tego komputera - nigdy nie wgrywać na
  sterowniki z LAN.
- Deploy i test muszą być w jednej sesji online (patrz README - ponowny
  login z nowego procesu robi ponowny download i zatrzymuje aplikację).
- Pełny opis architektury: `README.md`.
