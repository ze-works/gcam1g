# -----------------------------------------------------------------------------
# File:        test_feature_model.py
# Description: Tests of the feature model against Aravis's fake camera.
# -----------------------------------------------------------------------------

import feature_model as fm

def _find(cat, name):
    for f in cat.features:
        if f.name == name:
            return f
    for c in cat.children:
        hit = _find(c, name)
        if hit:
            return hit
    return None

def test_tree_contains_typed_features(fake_camera):
    m = fm.FeatureModel.open(fake_camera["address"])
    root = m.tree()
    assert root.name == "Root" and root.children, "Root has child categories"
    width = _find(root, "Width")
    assert width.kind == "int" and width.writable and int(width.value) > 0
    assert width.minimum is not None and width.maximum >= int(width.value)
    pf = _find(root, "PixelFormat")
    assert pf.kind == "enum" and pf.value in pf.choices
    assert m.describe("TestBoolean").kind == "bool"
    start = _find(root, "AcquisitionStart")
    assert start.kind == "command" and start.value is None

class _Stub:
    """Minimal NodeView for build_tree tests (no Aravis)."""

    def __init__(self, name, children=None, kind="int"):
        self.name, self.children_names, self.kind = name, children, kind

    def is_category(self):
        return self.children_names is not None

    def feature(self):
        return fm.Feature(self.name, self.name, self.kind, True, True, "1")

def test_build_tree_survives_missing_and_cyclic_categories():
    nodes = {
        "Root": _Stub("Root", ["A", "Missing", "B"]),
        "A": _Stub("A", ["X", "B"]),
        "B": _Stub("B", ["A", "Y"]),
        "X": _Stub("X"),
        "Y": _Stub("Y"),
    }
    root = fm.build_tree(nodes.get)
    names = []

    def walk(c):
        names.append(c.name)
        for f in c.features:
            names.append(f.name)
        for k in c.children:
            walk(k)

    walk(root)
    assert names.count("A") == 1 and names.count("B") == 1
    assert "Missing" not in names and "X" in names and "Y" in names

def test_list_devices_returns_device_info():
    for d in fm.list_devices():
        assert isinstance(d.device_id, str) and d.device_id

import pytest

def test_write_enum_int_bool_and_execute(fake_camera):
    m = fm.FeatureModel.open(fake_camera["address"])
    pf = m.describe("PixelFormat")
    other = next(c for c in pf.choices if c != pf.value)
    assert m.write("PixelFormat", other).value == other
    w = m.describe("Width")
    target = w.minimum + (w.increment or 1)
    assert m.write("Width", str(target)).value == str(target)
    b = m.describe("TestBoolean")
    flipped = "false" if b.value == "true" else "true"
    assert m.write("TestBoolean", flipped).value == flipped
    m.execute("AcquisitionStart")
    m.execute("AcquisitionStop")

def test_invalid_values_are_refused_before_sending(fake_camera):
    m = fm.FeatureModel.open(fake_camera["address"])
    w = m.describe("Width")
    with pytest.raises(fm.FeatureError):
        m.write("Width", str(w.maximum + 1))
    with pytest.raises(fm.FeatureError):
        m.write("Width", "abc")
    if (w.increment or 1) > 1:
        with pytest.raises(fm.FeatureError):
            m.write("Width", str(w.minimum + 1))
    with pytest.raises(fm.FeatureError):
        m.write("PixelFormat", "NoSuchFormat")
    with pytest.raises(fm.FeatureError):
        m.write("AcquisitionFrameRate", "10")
    with pytest.raises(fm.FeatureError):
        m.write("NoSuchFeature", "1")

def test_reload_sees_change_made_elsewhere(fake_camera):
    a = fm.FeatureModel.open(fake_camera["address"])
    w = a.describe("Width")
    target = w.minimum + 2 * (w.increment or 1)
    a._device.set_integer_feature_value("Width", target)
    assert a.describe("Width").value == str(target)

def test_write_fails_cleanly_when_camera_is_gone(fake_camera):
    m = fm.FeatureModel.open(fake_camera["address"])
    w = m.describe("Width")
    fake_camera["process"].kill()
    fake_camera["process"].wait()
    with pytest.raises(fm.FeatureError):
        m.write("Width", str(w.minimum))

import subprocess
import sys
from pathlib import Path

def test_dump_prints_the_tree(fake_camera):
    out = subprocess.run(
        [sys.executable, str(Path(__file__).with_name("arv_features.py")), "--dump", fake_camera["address"]],
        capture_output=True, text=True, timeout=30,
    )
    assert out.returncode == 0, out.stderr
    assert "ImageFormatControl" in out.stdout
    assert "Width" in out.stdout and "PixelFormat" in out.stdout

def test_write_reports_when_the_camera_keeps_the_old_value(fake_camera, monkeypatch):
    m = fm.FeatureModel.open(fake_camera["address"])
    before = m.describe("PixelFormat")
    other = next(c for c in before.choices if c != before.value)
    real = m.describe
    calls = {"n": 0}

    def stale_describe(name):
        calls["n"] += 1
        f = real(name)
        if name == "PixelFormat" and calls["n"] > 1:
            f.value = before.value
        return f

    monkeypatch.setattr(m, "describe", stale_describe)
    with pytest.raises(fm.FeatureError, match="kept"):
        m.write("PixelFormat", other)

def test_dump_works_without_docstrings(fake_camera):
    out = subprocess.run(
        [sys.executable, "-OO", str(Path(__file__).with_name("arv_features.py")), "--dump", fake_camera["address"]],
        capture_output=True, text=True, timeout=30,
    )
    assert out.returncode == 0, out.stderr
    assert "Width" in out.stdout

def test_window_does_not_reload_after_a_failed_write(monkeypatch):
    import os

    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        pytest.skip("no display for GTK")
    import feature_view

    monkeypatch.setattr(fm, "list_devices", lambda: [])
    w = feature_view.FeatureWindow()
    reloads = []
    monkeypatch.setattr(w, "on_reload", lambda _b: reloads.append(1))

    def fail():
        raise fm.FeatureError("camera gone")

    w.run(fail, "never")
    assert reloads == [] and "camera gone" in w.status.get_text()
    w.run(lambda: None, "done")
    assert reloads == [1]
    w.destroy()
