"""
CODESYS Scripting entry point for the DEPLOY + TEST stages (run inside
DIADesigner-AX), after Install-SoftMotionRuntime.ps1 has started CODESYS
Control Win V3 x64 SoftMotion on this machine:

    DIADesigner-AX.exe --profile="DIADesigner-AX 1.10" --runscript="scripts\\dia_deploy_test.py" ^
        --scriptargs:'"<project>" "<deploy_report>" "<test_report>" "<password>" "<observe_s>" "<runtime_work_dir>"' --noUI

DEPLOY (junit-deploy.xml):
  1. Open the live PilaJednosuportowaSoftmotion.project and point its
     Device at the local SoftMotion runtime (network scan, filtered to
     this machine - see dia_common.configure_device_gateway).
  2. Log in with a full download, Start the application, wait for RUN.

TEST (junit-test.xml), in the SAME online session:
  3. For <observe_s> seconds (default 30) poll the application once a
     second - every sample must be RUN with no exception flag.
  4. The project handles exceptions itself (RestartApp = exception event
     handler: AppReset + restart), which could hide a crash between two
     samples - so the runtime's own logs in <runtime_work_dir>
     (StdLogger.csv: IEC exceptions; .Audit*.log: stop/reset) are also
     checked for entries logged since the Start. Any = test failed.

Why one process and one session: logging in again from a second
DIADesigner-AX process makes the IDE see a different code GUID than the
one on the device and (answering the "download?" prompt with its default)
download the application again - which leaves it stopped, so a separate
TEST process would only ever observe a freshly downloaded, stopped
application instead of the one DEPLOY started.
"""

import glob
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scriptengine import *
from dia_common import write_junit, configure_device_gateway, open_project, runtime_state

_BUSY_FLAGS = (OperatingState.download, OperatingState.online_change,
               OperatingState.store_bootproject, OperatingState.store_bootproject_only,
               OperatingState.load_bootproject, OperatingState.reset, OperatingState.delete)

# Runtime log lines ("<UTC time>, <cmp id>, <class>, <error>, <info>, <text>")
# that mean the application crashed or was stopped/reset while it should
# have been running. Class 8 = LOG_EXCEPTION (StdLogger.csv, e.g.
# "#### *EXCEPTION* [AccessViolation] occurred: App=[Application], Task=[MainTask]");
# the audit log (.Audit*.log) only records the resulting reset/stop.
_LOG_CLASS_EXCEPTION = "8"
_BAD_WORDS = ("exception", "watchdog", "reset", "stop")


def _wait_download_finished(onlineapp, timeout=120):
    """
    login() returns while the runtime is still busy with the downloaded
    application (~100 MB of global data, plus the boot project written to
    disk) - wait until no download/boot-project flag is set.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        _, op_state, _ = runtime_state(onlineapp)
        if op_state is None or not any((op_state & f) == f for f in _BUSY_FLAGS):
            return
        print("Runtime still busy after download (operation_state=%s)" % op_state)
        time.sleep(2)
    print("Warning: runtime still busy after %ds, trying to start anyway" % timeout)


def _start_with_retry(onlineapp, attempts=5, pause=10):
    """
    Right after a full download, start() can hit the online service's
    timeout ("SystemError: The operation has timed out.") while the
    runtime is still initializing the application - the same call succeeds
    a bit later. Retry a few times before giving up.
    """
    for attempt in range(1, attempts + 1):
        try:
            onlineapp.start()
            return
        except Exception as e:  # noqa: BLE001
            if onlineapp.application_state == ApplicationState.run:
                return
            if attempt == attempts:
                raise
            print("start() attempt %d/%d failed (%s) - retrying in %ds" % (attempt, attempts, e, pause))
            time.sleep(pause)


def _utc_stamp():
    # Same format the runtime's audit log lines start with.
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())


def _log_entries_since(log_dir, since):
    """Timestamped lines of the runtime's logs (header lines start with ';')."""
    lines = []
    patterns = (".Audit*.log", "StdLogger*.csv")
    for pattern in patterns:
        for path in sorted(glob.glob(os.path.join(log_dir, pattern))):
            try:
                with open(path, "r") as f:
                    for line in f:
                        if line[:1].isdigit() and line[:19] >= since:
                            lines.append(line.rstrip())
            except IOError:
                pass
    return sorted(set(lines))


def _is_bad(line):
    parts = [p.strip() for p in line.split(",", 5)]
    if len(parts) == 6 and parts[2] == _LOG_CLASS_EXCEPTION:
        return True
    text = parts[-1].lower()
    # "App [Application] Stop successful" / "Reset Warm successful" /
    # "*EXCEPTION*" - but not the CODESYS Control "demo mode ... will
    # expire and stop" license notice.
    return any(w in text for w in _BAD_WORDS) and "demo mode" not in text


def _bad_log_entries(log_dir, since):
    if not log_dir or not os.path.isdir(log_dir):
        return None
    return [e for e in _log_entries_since(log_dir, since) if _is_bad(e)]


def main():
    project_path, deploy_report, test_report = sys.argv[1], sys.argv[2], sys.argv[3]
    password = sys.argv[4] if len(sys.argv) > 4 else ""
    observe_seconds = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 30
    log_dir = sys.argv[6] if len(sys.argv) > 6 else ""

    # ---- DEPLOY ---------------------------------------------------------
    deploy_cases = []
    t0 = time.time()
    onlineapp = None
    started_at = _utc_stamp()
    try:
        project = open_project(project_path, password)
        configure_device_gateway(project)

        onlineapp = online.create_online_application(project.active_application)
        # Headless: answer "application doesn't exist on the device /
        # download?" style prompts with their default instead of blocking.
        system.prompt_handling = PromptHandling.LogMessageKeys | PromptHandling.LogSimplePrompts
        # Never = no online change: full download whenever the code on the
        # device differs. Second argument = delete_foreign_apps.
        onlineapp.login(OnlineChangeOption.Never, True)
        _wait_download_finished(onlineapp)

        started_at = _utc_stamp()
        if onlineapp.application_state != ApplicationState.run:
            _start_with_retry(onlineapp)

        deadline = time.time() + 15
        app_state, op_state, has_exception = runtime_state(onlineapp)
        while app_state != ApplicationState.run and not has_exception and time.time() < deadline:
            time.sleep(1)
            app_state, op_state, has_exception = runtime_state(onlineapp)
        if app_state != ApplicationState.run or has_exception:
            raise RuntimeError("Application did not reach RUN after start() (application_state=%s, operation_state=%s)"
                               % (app_state, op_state))
        deploy_cases.append({"name": "login_download_start", "status": "pass",
                             "message": "application_state=%s, operation_state=%s" % (app_state, op_state),
                             "time": time.time() - t0})
    except Exception:  # noqa: BLE001
        message = traceback.format_exc()
        # A start() that times out is usually the application crashing
        # right after Start - say so, with the runtime's own log lines.
        bad = _bad_log_entries(log_dir, started_at)
        if bad:
            message += "\nRuntime log since Start (%sZ):\n%s" % (started_at, "\n".join(bad))
        deploy_cases.append({"name": "login_download_start", "status": "fail",
                             "message": message, "time": time.time() - t0})
        write_junit(deploy_report, "dia-deploy", deploy_cases)
        _logout(onlineapp)
        system.exit(1)
        return
    write_junit(deploy_report, "dia-deploy", deploy_cases)

    # ---- TEST -----------------------------------------------------------
    test_cases = []
    t0 = time.time()
    exit_code = 0
    run_case = "stays_in_run_%ds" % observe_seconds
    try:
        samples = []
        failure = None
        end = time.time() + observe_seconds
        while True:
            app_state, op_state, has_exception = runtime_state(onlineapp)
            elapsed = observe_seconds - max(0, end - time.time())
            samples.append("t=%5.1fs application_state=%s operation_state=%s" % (elapsed, app_state, op_state))
            if has_exception:
                failure = "Application is in EXCEPTION at t=%.1fs (operation_state=%s)" % (elapsed, op_state)
                break
            if app_state != ApplicationState.run:
                failure = "Application left RUN at t=%.1fs: application_state=%s (operation_state=%s)" % (
                    elapsed, app_state, op_state)
                break
            if time.time() >= end:
                break
            time.sleep(1)
        history = "\n".join(samples)
        if failure:
            test_cases.append({"name": run_case, "status": "fail",
                               "message": failure + "\n\n" + history, "time": time.time() - t0})
            exit_code = 1
        else:
            test_cases.append({"name": run_case, "status": "pass",
                               "message": "RUN, no exception, for %ds (%d samples)\n%s" % (
                                   observe_seconds, len(samples), history),
                               "time": time.time() - t0})
    except Exception:  # noqa: BLE001
        test_cases.append({"name": run_case, "status": "fail",
                           "message": traceback.format_exc(), "time": time.time() - t0})
        exit_code = 1

    t1 = time.time()
    bad = _bad_log_entries(log_dir, started_at)
    if bad is None:
        print("Runtime log directory '%s' not found - runtime log check skipped" % log_dir)
    elif bad:
        test_cases.append({"name": "no_exception_in_runtime_log", "status": "fail",
                           "message": "Runtime log since Start (%sZ) reports:\n%s" % (started_at, "\n".join(bad)),
                           "time": time.time() - t1})
        exit_code = 1
    else:
        test_cases.append({"name": "no_exception_in_runtime_log", "status": "pass",
                           "message": "No exception / stop / reset in the runtime log since Start (%sZ)" % started_at,
                           "time": time.time() - t1})

    _logout(onlineapp)
    write_junit(test_report, "dia-test", test_cases)
    system.exit(exit_code)


def _logout(onlineapp):
    if onlineapp is None:
        return
    try:
        onlineapp.logout()
    except Exception:  # noqa: BLE001
        pass


main()
