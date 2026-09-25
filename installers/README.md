# Instalator DIADesigner-AX

Ten katalog jest miejscem docelowym dla pobranego instalatora w trakcie CI
(git-ignored - nic poza tym plikiem nie trafia do repo).

## Skąd workflow bierze plik

Oficjalna paczka Delty `DIADesigner-AX-x64-1.10.0.9242.zip` (~2 GB) jest
wgrana jako asset do GitHub Release w tym repozytorium, tag
**`Installers`**. Workflow ściąga ją przez `gh release download` z
wbudowanym `GITHUB_TOKEN` i cache'uje (`actions/cache`, klucz oparty o
`DIA_VERSION`).

⚠️ Release i jego assety dziedziczą widoczność repozytorium - w
publicznym repo są publicznie pobieralne.

## Co jest w paczce i jak jest instalowana

`Setup.exe` z paczki to instalator WPF Delty ("DIAInstaller") bez
udokumentowanego trybu cichego. To, co robi, opisują manifesty w
`Data\*.zip` (`Manifest.xml`: `<ExecuteFileName>` / `<SilentCommandLine>`) -
[`scripts/Install-DIADesignerAX.ps1`](../scripts/Install-DIADesignerAX.ps1)
i [`scripts/Install-SoftMotionRuntime.ps1`](../scripts/Install-SoftMotionRuntime.ps1)
odtwarzają dokładnie to samo, bez UI:

| Komponent                                   | Plik w `Redist\`                              | Instalacja                                                        |
|---------------------------------------------|-----------------------------------------------|-------------------------------------------------------------------|
| VC++ 2013 / 2015-2019 (x86, x64)            | `vcredist_*.exe`, `VC_redist.*.exe`           | `/q /norestart`                                                   |
| CodeMeter Runtime 7.50                      | `CodeMeterRuntime_7.50.exe`                   | `/ComponentArgs "*":"/qn /norestart"`                             |
| DIADesigner-AX 1.10                         | `DIADesigner-AX-x64-1.10.0-9242.zip`          | `msiexec /i "DIADesigner-AX 1.10.msi" SETUPEXEDIR=<dir> ARPSYSTEMCOMPONENT=1 /qn` |
| Control Win (SoftMotion Win V3 x64 3.5.18.50) | `CODESYS_CtrlWin_64-3.5.18.50-Latest.zip`   | `msiexec /i "CODESYS Control Win 64 3.5.18.50.msi" SETUPEXEDIR=<dir> /qn` |

Pominięte (niepotrzebne w CI): Launcher, DIADesigner-AX Tool, Diagnosis
Tool, GeneralPackage oraz pobierane z sieci Device Repository /
Globalization - opisy urządzeń i biblioteki potrzebne projektowi
dostarcza `PilaJednosuportowaSoftmotion.projectarchive` (patrz README).

## Aktualizacja wersji

1. Pobierz nową paczkę z Delta Download Center.
2. Wgraj ją jako asset do Release `Installers`:
   `gh release upload Installers DIADesigner-AX-x64-<wersja>.zip --clobber`
3. Zaktualizuj w `.github/workflows/diadesigner-ci.yml` `DIA_VERSION` i
   `DIA_BUNDLE_ASSET`, a w skryptach ścieżki instalacji
   (`DIADesigner-AX 1.10`, `CODESYS Win Control\3.5.18.50`) i profil
   (`DIADesigner-AX 1.10` w `Invoke-DiaCli.ps1`), jeśli się zmieniły.
