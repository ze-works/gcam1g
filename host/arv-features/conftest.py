# -----------------------------------------------------------------------------
# File:        conftest.py
# Description: Test fixture that starts Aravis's fake camera on the loopback.
# -----------------------------------------------------------------------------

import shutil
import subprocess
import time

import pytest

try:
    import gi

    gi.require_version("Aravis", "0.8")
    from gi.repository import Aravis, GLib
except (ImportError, ValueError):
    pytest.skip("Aravis GObject introspection is not installed", allow_module_level=True)

FAKE = shutil.which("arv-fake-gv-camera-0.8")
ADDR = "127.0.0.1"

@pytest.fixture
def fake_camera():
    """Start Aravis's fake camera on the loopback and yield its address."""
    if FAKE is None:
        pytest.skip("arv-fake-gv-camera-0.8 not found")
    proc = subprocess.Popen([FAKE, "-i", ADDR], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    while True:
        try:
            Aravis.Camera.new(ADDR)
            break
        except GLib.Error:
            if time.time() > deadline:
                proc.kill()
                pytest.fail("fake camera did not answer within 10 s")
            time.sleep(0.2)
    yield {"address": ADDR, "process": proc}
    proc.kill()
    proc.wait()
