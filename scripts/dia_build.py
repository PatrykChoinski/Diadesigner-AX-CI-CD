"""
CODESYS Scripting entry point for the BUILD stage (run inside DIADesigner-AX):

    DIADesigner-AX.exe --profile="DIADesigner-AX 1.10" --runscript="scripts\\dia_build.py" ^
        --scriptargs:'"<archive_path>" "<prime_extract_dir>" "<project_path>" "<report_path>" "<password>"' --noUI

  1. "Prime" the machine: open PilaJednosuportowaSoftmotion.projectarchive
     once and close it again right away. Opening an archive installs the
     device descriptions and libraries bundled in it into the machine-wide
     repositories - which a fresh DIADesigner-AX install on a CI runner
     doesn't have (Delta's device repository / extra libraries are separate
     downloads). The archive's own copy of the code is discarded.
  2. Open the live PilaJednosuportowaSoftmotion.project and generate code
     for the active application.
  3. Write a JUnit report; exit code != 0 on compile errors.

The project is never saved - the file in git stays exactly as committed.
"""

import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scriptengine import *
from dia_common import write_junit, format_compile_message, open_project

CompileCategory = Guid("{97F48D64-A2A3-4856-B640-75C046E37EA9}")


def main():
    archive_path, prime_extract_dir, project_path, report_path = sys.argv[1:5]
    password = sys.argv[5] if len(sys.argv) > 5 else ""

    cases = []
    exit_code = 1

    t0 = time.time()
    try:
        if archive_path and os.path.exists(archive_path):
            # Answer "install missing devices/libraries?" style prompts with
            # their defaults instead of blocking.
            previous = system.prompt_handling
            system.prompt_handling = PromptHandling.LogMessageKeys | PromptHandling.LogSimplePrompts
            try:
                primer = projects.open_archive(archive_path, prime_extract_dir, overwrite=True,
                                                encryption_password=password)
                primer.close()
            finally:
                system.prompt_handling = previous
            cases.append({"name": "prime_from_projectarchive", "status": "pass",
                          "message": "Opened and closed %s" % os.path.basename(archive_path),
                          "time": time.time() - t0})
        else:
            cases.append({"name": "prime_from_projectarchive", "status": "pass",
                          "message": "No project archive at '%s' - skipped" % archive_path,
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
