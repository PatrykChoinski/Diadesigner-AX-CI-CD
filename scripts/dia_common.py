"""
Shared helpers for the CODESYS Scripting entry points run inside
DIADesigner-AX (dia_build.py / dia_deploy.py / dia_test.py).
"""

import io
import os
import socket

from scriptengine import *

# CODESYS Control Win V3 x64 SoftMotion (the device the project targets):
# device type 4102, id "0000 0004" - what the network scan must report for
# a result to be treated as the local test runtime.
SOFTMOTION_DEVICE_TYPE = 4102


def write_junit(report_path, testsuite_name, cases):
    failures = sum(1 for c in cases if c["status"] != "pass")
    lines = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(
        '<testsuite name="%s" tests="%d" failures="%d">'
        % (testsuite_name, len(cases), failures)
    )
    for c in cases:
        lines.append('  <testcase name="%s" time="%.2f">' % (c["name"], c["time"]))
        if c["status"] != "pass":
            # Failure detail goes in the element's text content, not a
            # "message" attribute - attribute values get their newlines
            # normalized away on parse.
            lines.append("    <failure>%s</failure>" % escape(c["message"]))
        elif c.get("message"):
            lines.append("    <system-out>%s</system-out>" % escape(c["message"]))
        lines.append("  </testcase>")
    lines.append("</testsuite>")
    with io.open(report_path, "w", encoding="utf-8") as f:
        f.write(u"\n".join(lines))


def escape(text):
    return (text or u"").replace(u"&", u"&amp;").replace(u"<", u"&lt;")


_SEVERITY_NAMES = {
    Severity.FatalError: "Fatal error",
    Severity.Error: "Error",
    Severity.Warning: "Warning",
    Severity.Information: "Information",
    Severity.Text: "Text",
}


def _object_path(obj):
    # "Device/Plc Logic/Application/..." - the POU/object a message points
    # at, walked up to the project root.
    names = []
    while obj is not None and len(names) < 20:
        try:
            names.append(obj.get_name())
            obj = obj.parent
        except Exception:  # noqa: BLE001 - reached the project itself
            break
    return "/".join(reversed(names))


def format_compile_message(m):
    """
    "Error C4: 'x' is no component of 'y' [Device/.../POU, Line 7,
    Column 1 (Impl)]" - which POU and line, not just the error text.
    """
    text = "%s %s%s: %s" % (_SEVERITY_NAMES.get(m.severity, m.severity), m.prefix, m.number, m.text)
    try:
        where = [p for p in (_object_path(m.object), m.position_text) if p]
    except Exception:  # noqa: BLE001 - message not tied to an object
        where = []
    return "%s [%s]" % (text, ", ".join(where)) if where else text


def open_project(project_path, password):
    """
    The project is protected with an encryption password - without
    encryption_password, projects.open() shows a modal "Encryption
    Password" dialog nothing can answer under --noUI.
    """
    return projects.open(project_path, encryption_password=password)


def _get_or_create_local_gateway(new_gateway_name="Gateway-1"):
    """
    Returns the gateway pointing at this machine (localhost:1217), creating
    it if missing - a fresh CI runner has no gateways configured at all,
    while a developer machine may have several (other ports/hosts), so an
    existing one is only reused when its host/port match.
    """
    gws = online.gateways
    for existing in gws:
        try:
            params = existing.config_params
            host = ("%s" % params[0]).lower()
            port = int(params[1])
        except Exception:  # noqa: BLE001 - not a TCP/IP gateway
            continue
        if host in ("localhost", "127.0.0.1") and port == 1217:
            return existing

    taken = set("%s" % g.name for g in gws)
    i = 1
    while new_gateway_name in taken:
        i += 1
        new_gateway_name = "Gateway-Local-%d" % i

    tcp_driver = online.gateway_drivers["TCP/IP"]
    tcp_params = tcp_driver.gateway_parameters

    host_param = tcp_params[0]
    host_param.validate("localhost")
    host_value = gws.convert_gateway_parameter("localhost", host_param.parameter_type)

    port_param = tcp_params[1]
    port_param.validate(1217)
    port_value = gws.convert_gateway_parameter(1217, port_param.parameter_type)

    return gws.add_new_gateway(new_gateway_name, {0: host_value, 1: port_value}, tcp_driver)


def _describe(result):
    parts = []
    for attr in ("device_name", "type_name", "vendor_name", "device_version", "type_id", "device_id", "address"):
        try:
            parts.append("%s=%s" % (attr, getattr(result, attr)))
        except Exception:  # noqa: BLE001
            pass
    return ", ".join(parts)


def configure_device_gateway(project):
    """
    Points the project's Device at the SoftMotion runtime on THIS machine.

    A project opened on another machine has no usable gateway/address for
    it, and the local runtime is addressed by a device-address code the
    gateway hands out during a network scan (not by IP) - so: scan, then
    pick the local SoftMotion runtime.

    The scan also sees real PLCs on the LAN (on a developer machine), so
    results are filtered to this computer's node name and the SoftMotion
    device type - never "just take the first one", which could download
    the test application to a real machine.
    """
    device = project.find("Device", True)[0]
    gw = _get_or_create_local_gateway()
    results = list(gw.perform_network_scan())
    for r in results:
        print("Scan result: %s" % _describe(r))

    hostname = socket.gethostname().upper()
    local = []
    for r in results:
        try:
            name = ("%s" % r.device_name).upper()
        except Exception:  # noqa: BLE001
            name = ""
        try:
            type_ok = int(r.type_id) == SOFTMOTION_DEVICE_TYPE
        except Exception:  # noqa: BLE001
            type_ok = True
        if name == hostname and type_ok:
            local.append(r)

    if not local:
        raise RuntimeError(
            "Network scan found no local CODESYS Control Win V3 x64 SoftMotion runtime named '%s' "
            "(scan results: %s) - is the runtime running?" % (hostname, [_describe(r) for r in results])
        )
    print("Using local runtime: %s" % _describe(local[0]))
    device.set_gateway_and_address(gw, local[0].address)


def runtime_state(onlineapp):
    """(application_state, operation_state, has_exception) of the online app."""
    app_state = onlineapp.application_state
    try:
        op_state = onlineapp.operation_state
        has_exception = (op_state & OperatingState.exception) == OperatingState.exception
    except Exception:  # noqa: BLE001 - property not available
        op_state = None
        has_exception = False
    return app_state, op_state, has_exception
