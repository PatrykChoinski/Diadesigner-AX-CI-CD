"""
CODESYS Scripting entry point for the BUILD stage (run inside DIADesigner-AX):

    DIADesigner-AX.exe --profile="DIADesigner-AX 1.10" --runscript="scripts\dia_build.py" ^
        --scriptargs:'"<deps_dir>" "<project_path>" "<report_path>" "<password>"' --noUI

  1. "Prime" the machine with the dependencies bundled in
     PilaJednosuportowaSoftmotion.projectarchive - device descriptions and
     compiled libraries, unpacked into <deps_dir> by
     Expand-ProjectArchive.ps1 - which a fresh DIADesigner-AX install on a
     CI runner doesn't have (Delta's device repository / extra libraries
     are separate downloads). Installed directly via
     device_repository.import_device() / librarymanager.install_library():
     projects.open_archive() would ask in a dialog which items to install,
     headless mode cancels it and the call just returns None.
  2. Open the live PilaJednosuportowaSoftmotion.project and generate code
     for the active application.
  3. Write a JUnit report; exit code != 0 on compile errors.

The project is never saved - the file in git stays exactly as committed.
"""

import glob
import io
import os
import re
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scriptengine import *
from dia_common import write_junit, format_compile_message, open_project

CompileCategory = Guid("{97F48D64-A2A3-4856-B640-75C046E37EA9}")


def _read_name(d):
    path = os.path.join(d, "_name.txt")
    if not os.path.exists(path):
        return d
    return io.open(path, encoding="utf-8-sig").read().strip()


def _device_present(name):
    """
    name = archive entry "<name>   <id>   <version>   <type>   .zip".
    Returns True/False, or None when it can't be told (then just import).
    """
    parts = re.split(r"\s{3,}", name)
    if len(parts) < 4:
        return None
    try:
        ident = device_repository.create_device_identification(int(parts[3]), parts[1], parts[2])
        return device_repository.get_device(ident) is not None
    except Exception:  # noqa: BLE001
        return None


def _import_devices(devices_dir):
    """Returns (imported, already present, failed messages)."""
    source = device_repository.sources[0]
    imported, present, failed = 0, 0, []
    for d in sorted(glob.glob(os.path.join(devices_dir, "*"))):
        xml = os.path.join(d, "device.xml")
        if not os.path.isfile(xml):
            continue
        name = _read_name(d)
        if _device_present(name):
            present += 1
            continue
        try:
            device_repository.import_device(xml, source, False)
            imported += 1
        except Exception as e:  # noqa: BLE001
            failed.append("%s: %s" % (name, e))
    if imported:
        device_repository.save_device_cache()
    return imported, present, failed


def _install_libraries(libraries_dir):
    """
    Returns (installed, already present, failed messages). Libraries
    already in the repository (matched by "Title, version (Company)" from
    _index.txt, written by Expand-ProjectArchive.ps1) are skipped without
    an install attempt - on a fresh runner that's ~135 of 142, and each
    failed "already installed" attempt is slow.
    """
    repo = librarymanager.repositories[0]
    installed_names = set()
    for r in librarymanager.repositories:
        for lib in librarymanager.get_all_libraries(r):
            installed_names.add(("%s" % lib).lower())

    display = {}
    index = os.path.join(libraries_dir, "_index.txt")
    if os.path.exists(index):
        for line in io.open(index, encoding="utf-8-sig"):
            if "\t" in line:
                fname, title = line.rstrip("\r\n").split("\t", 1)
                display[fname] = title

    installed, present, failed = 0, 0, []
    for path in sorted(glob.glob(os.path.join(libraries_dir, "*.compiled-library*"))):
        title = display.get(os.path.basename(path))
        if title and title.lower() in installed_names:
            present += 1
            continue
        try:
            librarymanager.install_library(path, repo, False)
            installed += 1
        except Exception as e:  # noqa: BLE001
            text = "%s" % e
            if "already" in text.lower() or "exist" in text.lower():
                present += 1
            else:
                failed.append("%s: %s" % (os.path.basename(path), text))
    return installed, present, failed


def main():
    deps_dir, project_path, report_path = sys.argv[1:4]
    password = sys.argv[4] if len(sys.argv) > 4 else ""

    cases = []
    exit_code = 1

    t0 = time.time()
    try:
        if deps_dir and os.path.isdir(deps_dir):
            t = time.time()
            n_dev, n_dev_present, dev_failed = _import_devices(os.path.join(deps_dir, "devices"))
            t_dev = time.time() - t
            t = time.time()
            n_lib, n_present, lib_failed = _install_libraries(os.path.join(deps_dir, "libraries"))
            t_lib = time.time() - t
            message = ("Devices imported: %d (already present: %d) in %.0fs, "
                       "libraries installed: %d (already present: %d) in %.0fs") % (
                n_dev, n_dev_present, t_dev, n_lib, n_present, t_lib)
            # A dependency that fails to install is only reported here - if
            # it matters, the compile below fails with the real reason.
            problems = dev_failed + lib_failed
            if problems:
                message += "\nNot installed:\n" + "\n".join(problems)
            print(message)
            cases.append({"name": "prime_from_projectarchive", "status": "pass",
                          "message": message, "time": time.time() - t0})
        else:
            cases.append({"name": "prime_from_projectarchive", "status": "pass",
                          "message": "No unpacked project archive at '%s' - skipped" % deps_dir,
                          "time": time.time() - t0})
    except Exception:  # noqa: BLE001
        cases.append({"name": "prime_from_projectarchive", "status": "fail",
                      "message": traceback.format_exc(), "time": time.time() - t0})
        write_junit(report_path, "dia-build", cases)
        system.exit(1)
        return

    t0 = time.time()
    try:
        project = open_project(project_path, password)
        system.clear_messages(CompileCategory)
        project.active_application.generate_code()

        errors = list(system.get_message_objects(CompileCategory, Severity.FatalError | Severity.Error))
        warnings = list(system.get_message_objects(CompileCategory, Severity.Warning))
        ok = len(errors) == 0
        if ok:
            message = "0 errors, %d warnings" % len(warnings)
        else:
            message = "\n".join(format_compile_message(m) for m in errors)
        cases.append({"name": "compile", "status": "pass" if ok else "fail",
                      "message": message, "time": time.time() - t0})
        project.close()
        exit_code = 0 if ok else 1
    except Exception:  # noqa: BLE001
        cases.append({"name": "compile", "status": "fail",
                      "message": traceback.format_exc(), "time": time.time() - t0})
        exit_code = 1

    write_junit(report_path, "dia-build", cases)
    system.exit(exit_code)


main()
