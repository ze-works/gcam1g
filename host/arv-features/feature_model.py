# -----------------------------------------------------------------------------
# File:        feature_model.py
# Description: Reads and writes the GenICam features of a camera through
#              Aravis. Does not depend on GTK.
# -----------------------------------------------------------------------------

from __future__ import annotations

from dataclasses import dataclass, field

import gi

gi.require_version("Aravis", "0.8")
from gi.repository import Aravis, GLib

class FeatureError(Exception):
    """A feature could not be read, written or executed."""

@dataclass
class DeviceInfo:
    device_id: str
    vendor: str
    model: str
    address: str

@dataclass
class Feature:
    name: str
    display_name: str
    kind: str
    readable: bool
    writable: bool
    value: str | None
    choices: list[str] = field(default_factory=list)
    minimum: int | None = None
    maximum: int | None = None
    increment: int | None = None
    error: str | None = None

@dataclass
class Category:
    name: str
    display_name: str
    features: list[Feature] = field(default_factory=list)
    children: list["Category"] = field(default_factory=list)

def list_devices() -> list[DeviceInfo]:
    """Return the cameras Aravis can see right now."""
    Aravis.update_device_list()
    out = []
    for i in range(Aravis.get_n_devices()):
        out.append(
            DeviceInfo(
                Aravis.get_device_id(i),
                Aravis.get_device_vendor(i) or "",
                Aravis.get_device_model(i) or "",
                Aravis.get_device_address(i) or "",
            )
        )
    return out

def build_tree(lookup, root: str = "Root") -> Category:
    """Build the category tree from lookup(name) -> NodeView | None.

    A NodeView has name, is_category(), children_names (for categories) and feature().
    Unknown names are skipped and each category is visited once, so a broken or
    cyclic description cannot hang the tree.
    """
    visited: set[str] = set()

    def category(name: str) -> Category | None:
        node = lookup(name)
        if node is None or not node.is_category() or name in visited:
            return None
        visited.add(name)
        cat = Category(name, getattr(node, "display_name", None) or name)
        for child in node.children_names or []:
            sub = lookup(child)
            if sub is None:
                continue
            if sub.is_category():
                c = category(child)
                if c is not None:
                    cat.children.append(c)
            else:
                f = sub.feature()
                if f is not None:
                    cat.features.append(f)
        return cat

    top = category(root)
    return top if top is not None else Category(root, root)

_KINDS = (
    ("GcEnumeration", "enum"),
    ("GcBoolean", "bool"),
    ("GcCommand", "command"),
    ("GcInteger", "int"),
    ("GcFloat", "float"),
    ("GcString", "string"),
)

def kind_of(node) -> str:
    for cls, kind in _KINDS:
        if isinstance(node, getattr(Aravis, cls)):
            return kind
    return "other"

class _AravisNode:
    """NodeView over an Aravis GenICam node, for build_tree()."""

    def __init__(self, model: "FeatureModel", name: str, node):
        self._model, self.name, self._node = model, name, node
        self.display_name = node.get_display_name() if hasattr(node, "get_display_name") else None
        self.children_names = list(node.get_features() or []) if isinstance(node, Aravis.GcCategory) else None

    def is_category(self) -> bool:
        return self.children_names is not None

    def feature(self) -> Feature | None:
        if not isinstance(self._node, Aravis.GcFeatureNode):
            return None
        try:
            if not self._node.is_implemented():
                return None
        except GLib.Error:
            pass
        return self._model.describe(self.name)

class FeatureModel:
    """An open camera and its GenICam description."""

    def __init__(self, camera):
        self._camera = camera
        self._device = camera.get_device()
        self._gc = self._device.get_genicam()

    @classmethod
    def open(cls, device_id: str) -> "FeatureModel":
        """Open a camera by Aravis device id or IP address."""
        try:
            return cls(Aravis.Camera.new(device_id))
        except GLib.Error as e:
            raise FeatureError(e.message) from None

    def _node(self, name: str):
        node = self._gc.get_node(name)
        if node is None:
            raise FeatureError(f"no feature named {name}")
        return node

    def tree(self, root: str = "Root") -> Category:
        """Return the category tree under root."""

        def lookup(name):
            node = self._gc.get_node(name)
            return None if node is None else _AravisNode(self, name, node)

        return build_tree(lookup, root)

    def describe(self, name: str) -> Feature:
        """Read one feature: kind, access, value and, for enum / int, its choices or bounds."""
        node = self._node(name)
        kind = kind_of(node)
        try:
            mode = node.get_actual_access_mode()
        except GLib.Error:
            mode = Aravis.GcAccessMode.UNDEFINED
        readable = mode in (Aravis.GcAccessMode.RO, Aravis.GcAccessMode.RW)
        writable = mode in (Aravis.GcAccessMode.WO, Aravis.GcAccessMode.RW)
        display = node.get_display_name() or name
        f = Feature(name, display, kind, readable, writable, None)
        if kind == "command":
            return f
        if readable:
            try:
                if kind == "bool":
                    f.value = "true" if node.get_value() else "false"
                else:
                    f.value = node.get_value_as_string()
            except GLib.Error as e:
                f.error = e.message
        try:
            if kind == "enum":
                f.choices = list(node.dup_available_string_values() or [])
            elif kind == "int":
                f.minimum, f.maximum = self._device.get_integer_feature_bounds(name)
                f.increment = self._device.get_integer_feature_increment(name)
        except GLib.Error as e:
            f.error = f.error or e.message
        return f

    def write(self, name: str, value: str) -> Feature:
        """Write value (as text) to an enum, int or bool feature and return it read back.

        Values are checked against the choices or bounds first, so an invalid value
        never reaches the camera.
        """
        node = self._node(name)
        current = self.describe(name)
        if not current.writable:
            raise FeatureError(f"{name} is not writable")
        try:
            if current.kind == "enum":
                if value not in current.choices:
                    raise FeatureError(f"{value} is not one of {', '.join(current.choices)}")
                node.set_string_value(value)
            elif current.kind == "int":
                try:
                    v = int(value, 0)
                except ValueError:
                    raise FeatureError(f"{value} is not an integer") from None
                if current.minimum is not None and not (current.minimum <= v <= current.maximum):
                    raise FeatureError(f"{v} is outside {current.minimum}..{current.maximum}")
                inc = current.increment or 1
                if current.minimum is not None and (v - current.minimum) % inc:
                    raise FeatureError(f"{v} is not a multiple of {inc} from {current.minimum}")
                node.set_value(v)
            elif current.kind == "bool":
                if value.lower() not in ("true", "false", "1", "0"):
                    raise FeatureError(f"{value} is not true or false")
                node.set_value(value.lower() in ("true", "1"))
            else:
                raise FeatureError(f"{name} is a {current.kind} feature; this version cannot write it")
        except GLib.Error as e:
            raise FeatureError(e.message) from None
        after = self.describe(name)
        wanted = {"enum": value, "bool": "true" if value.lower() in ("true", "1") else "false"}.get(
            current.kind, str(int(value, 0)) if current.kind == "int" else value
        )
        if after.value is not None and after.value != wanted:
            raise FeatureError(f"the camera kept {after.value} (it did not take {value})")
        return after

    def execute(self, name: str) -> None:
        """Execute a command feature."""
        node = self._node(name)
        if kind_of(node) != "command":
            raise FeatureError(f"{name} is not a command")
        try:
            node.execute()
        except GLib.Error as e:
            raise FeatureError(e.message) from None
