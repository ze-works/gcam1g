# -----------------------------------------------------------------------------
# File:        feature_view.py
# Description: GTK 3 window over the feature model: categories on the left,
#              an editor for each feature on the right.
# -----------------------------------------------------------------------------

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

import feature_model as fm

class FeatureWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="arv-features")
        self.set_default_size(900, 600)
        self.model = None
        self.categories = {}
        self.current = None

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, border_width=6)
        self.add(outer)
        top = Gtk.Box(spacing=6)
        outer.pack_start(top, False, False, 0)
        self.devices = Gtk.ComboBoxText()
        top.pack_start(self.devices, True, True, 0)
        for label, handler in (("Rescan", self.on_rescan), ("Connect", self.on_connect), ("Reload", self.on_reload)):
            button = Gtk.Button(label=label)
            button.connect("clicked", handler)
            top.pack_start(button, False, False, 0)

        paned = Gtk.Paned()
        outer.pack_start(paned, True, True, 0)
        self.store = Gtk.TreeStore(str, str)
        self.tree_view = Gtk.TreeView(model=self.store)
        self.tree_view.append_column(Gtk.TreeViewColumn("Category", Gtk.CellRendererText(), text=0))
        self.tree_view.get_selection().connect("changed", self.on_category)
        left = Gtk.ScrolledWindow()
        left.set_size_request(240, -1)
        left.add(self.tree_view)
        paned.pack1(left, False, False)
        self.grid = Gtk.Grid(column_spacing=12, row_spacing=4, border_width=6)
        right = Gtk.ScrolledWindow()
        right.add(self.grid)
        paned.pack2(right, True, False)

        self.status = Gtk.Label(xalign=0)
        outer.pack_start(self.status, False, False, 0)
        self.on_rescan(None)

    def say(self, text):
        self.status.set_text(text)

    def on_rescan(self, _button):
        self.devices.remove_all()
        devices = fm.list_devices()
        for d in devices:
            self.devices.append(d.device_id, f"{d.device_id}  ({d.address})")
        if devices:
            self.devices.set_active(0)
        self.say(f"{len(devices)} camera(s) found")

    def on_connect(self, _button):
        device = self.devices.get_active_id()
        if device is None:
            self.say("no camera selected")
            return
        try:
            self.model = fm.FeatureModel.open(device)
        except fm.FeatureError as e:
            self.say(f"cannot open {device}: {e}")
            return
        self.on_reload(None)
        self.say(f"connected to {device}")

    def on_reload(self, _button):
        if self.model is None:
            return
        self.store.clear()
        self.categories = {}

        def add(parent, cat):
            self.categories[cat.name] = cat
            it = self.store.append(parent, [cat.display_name, cat.name])
            for child in cat.children:
                add(it, child)

        add(None, self.model.tree())
        self.tree_view.expand_all()
        if self.current in self.categories:
            self.show_category(self.current)

    def on_category(self, selection):
        store, it = selection.get_selected()
        if it is not None:
            self.show_category(store[it][1])

    def show_category(self, name):
        self.current = name
        for child in self.grid.get_children():
            self.grid.remove(child)
        cat = self.categories[name]
        for row, f in enumerate(cat.features):
            label = Gtk.Label(label=f.display_name, xalign=0, tooltip_text=f.name)
            self.grid.attach(label, 0, row, 1, 1)
            self.grid.attach(self.editor(f), 1, row, 1, 1)
        self.grid.show_all()

    def editor(self, f):
        if f.kind == "command" and f.writable:
            button = Gtk.Button(label="Execute")
            button.connect("clicked", lambda _b: self.run(lambda: self.model.execute(f.name), f"executed {f.name}"))
            return button
        if f.kind == "enum" and f.writable and f.choices:
            combo = Gtk.ComboBoxText()
            for c in f.choices:
                combo.append(c, c)
            if f.value in f.choices:
                combo.set_active_id(f.value)
            combo.connect("changed", lambda c: self.write(f.name, c.get_active_id()))
            return combo
        if f.kind == "int" and f.writable and f.minimum is not None and f.value is not None:
            spin = Gtk.SpinButton.new_with_range(f.minimum, f.maximum, f.increment or 1)
            spin.set_value(int(f.value, 0))
            spin.connect("value-changed", lambda s: self.write(f.name, str(s.get_value_as_int())))
            return spin
        if f.kind == "bool" and f.writable and f.value is not None:
            switch = Gtk.Switch(active=f.value == "true", halign=Gtk.Align.START)
            switch.connect("notify::active", lambda s, _p: self.write(f.name, "true" if s.get_active() else "false"))
            return switch
        text = f.value if f.value is not None else f"<{f.error or 'no value'}>"
        return Gtk.Label(label=text, xalign=0, selectable=True)

    def write(self, name, value):
        if value is None:
            return
        self.run(lambda: self.model.write(name, value), f"{name} = {value}")

    def run(self, action, done):
        try:
            action()
        except fm.FeatureError as e:
            self.say(f"refused: {e}")
            return
        self.say(done)
        self.on_reload(None)

def run() -> int:
    window = FeatureWindow()
    window.connect("destroy", Gtk.main_quit)
    window.show_all()
    Gtk.main()
    return 0
