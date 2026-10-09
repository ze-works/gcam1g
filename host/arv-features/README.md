# arv-features

A small window that lists the GenICam features of a camera and lets you change them. It
works with any camera Aravis can open. Aravis Viewer has a fixed set of controls, so use it
for the video and this tool for the rest, such as `TestPattern`.

## Install

- Ubuntu / Debian: `sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-aravis-0.8`
- Windows, MSYS2 UCRT64 (with Aravis Viewer already set up):
  `pacman -S mingw-w64-ucrt-x86_64-python-gobject`

## Use

This is a separate program. Aravis Viewer does not start it, so run it yourself next to the
viewer, in either order.

```sh
python3 arv_features.py                    # window: pick the camera, Connect
python3 arv_features.py --dump 192.0.2.10  # print the feature tree and exit
```

You can change enumerations, integers and booleans, and run commands. Floats and strings
are read-only in this version. If the camera refuses a change (for example `PixelFormat`
while streaming), the window shows the reason at the bottom.

Some features can only change while the camera is not streaming. In Aravis Viewer,
the back arrow ("Return to camera list") stops streaming; change the feature, then open
the camera again.

## Tests

```sh
python3 -m pytest
```

The tests start Aravis's fake camera (`arv-fake-gv-camera-0.8`) on 127.0.0.1. They skip
themselves when the fake camera or the Aravis introspection data is not installed.
