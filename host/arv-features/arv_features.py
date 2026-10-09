#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# File:        arv_features.py
# Description: Entry point. Opens the window, or prints the feature tree of a
#              camera with --dump.
# -----------------------------------------------------------------------------

import argparse
import sys

import feature_model as fm

DESCRIPTION = "List and change the GenICam features of a camera through Aravis."

def dump(device: str) -> int:
    try:
        model = fm.FeatureModel.open(device)
    except fm.FeatureError as e:
        print(f"cannot open {device}: {e}", file=sys.stderr)
        return 1

    def walk(cat: fm.Category, depth: int) -> None:
        print("  " * depth + f"[{cat.name}]")
        for f in cat.features:
            access = ("r" if f.readable else "-") + ("w" if f.writable else "-")
            extra = f" ({' | '.join(f.choices)})" if f.choices else ""
            if f.minimum is not None:
                extra = f" ({f.minimum}..{f.maximum} step {f.increment or 1})"
            value = f.value if f.value is not None else f"<{f.error or 'no value'}>"
            print("  " * (depth + 1) + f"{f.name} {f.kind} {access} = {value}{extra}")
        for c in cat.children:
            walk(c, depth + 1)

    walk(model.tree(), 0)
    return 0

def main() -> int:
    ap = argparse.ArgumentParser(description=DESCRIPTION)
    ap.add_argument("--dump", metavar="DEVICE", help="print the feature tree of DEVICE (id or IP address) and exit")
    args = ap.parse_args()
    if args.dump:
        return dump(args.dump)
    import feature_view

    return feature_view.run()

if __name__ == "__main__":
    sys.exit(main())
