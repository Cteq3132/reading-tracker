#!/usr/bin/env python3
"""Assemble un document Icon Composer (.icon) à partir des calques SVG d'un concept,
puis le rend avec ictool (le moteur d'Icon Composer, livré avec Xcode).

Usage : python3 build.py <dossier-concept> [<dossier-sortie>]

Le dossier du concept contient :
  - des calques SVG numérotés de l'arrière vers l'avant (1-*.svg, 2-*.svg…),
    un calque par groupe Liquid Glass ;
  - optionnellement spec.json pour surcharger couleurs et réglages.
"""
import json
import pathlib
import shutil
import subprocess
import sys

ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# Accent de l'app (Assets.xcassets/AccentColor) : #D96B3C en clair, #F58F61 en sombre.
DEFAULTS = {
    "background": "srgb:0.85098,0.41961,0.23529,1.00000",
    "background_dark": "srgb:0.13725,0.10588,0.09412,1.00000",
    "foreground_dark": "srgb:0.96078,0.56078,0.38039,1.00000",
    "translucency": 0.4,
    "shadow_opacity": 0.5,
    "layers": {},
}

RENDITIONS = ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"]


def build_icon(concept: pathlib.Path, out_icon: pathlib.Path) -> None:
    spec = dict(DEFAULTS)
    spec_file = concept / "spec.json"
    if spec_file.exists():
        spec.update(json.loads(spec_file.read_text()))

    layers = sorted(concept.glob("[0-9]-*.svg"))
    if out_icon.exists():
        shutil.rmtree(out_icon)
    (out_icon / "Assets").mkdir(parents=True)

    groups = []
    # icon.json liste les groupes de l'avant vers l'arrière.
    for svg in reversed(layers):
        shutil.copy(svg, out_icon / "Assets" / svg.name)
        override = spec["layers"].get(svg.stem, {})
        layer = {
            "name": svg.stem,
            "image-name": svg.name,
            "glass": override.get("glass", True),
            "fill-specializations": [
                {"appearance": "dark", "value": {"solid": override.get("dark", spec["foreground_dark"])}}
            ],
        }
        if "fill" in override:
            layer["fill"] = {"solid": override["fill"]}
        if "opacity" in override:
            layer["opacity"] = override["opacity"]
        groups.append({
            "name": svg.stem,
            "layers": [layer],
            "shadow": {"kind": "neutral", "opacity": spec["shadow_opacity"]},
            "translucency": {"enabled": True, "value": override.get("translucency", spec["translucency"])},
            "specular": True,
        })

    doc = {
        "fill": {"automatic-gradient": spec["background"]},
        "fill-specializations": [
            {"appearance": "dark", "value": {"automatic-gradient": spec["background_dark"]}}
        ],
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    (out_icon / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def render(icon: pathlib.Path, out_dir: pathlib.Path, size: int = 1024) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for rendition in RENDITIONS:
        out = out_dir / f"{rendition}-{size}.png"
        cmd = [ICTOOL, str(icon), "--export-image", "--output-file", str(out),
               "--platform", "iOS", "--rendition", rendition,
               "--width", str(size), "--height", str(size), "--scale", "1"]
        if rendition.startswith("Tinted"):
            cmd += ["--tint-color", "0.08", "--tint-strength", "0.8"]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    concept = pathlib.Path(sys.argv[1]).resolve()
    out = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else concept.parent.parent / "out" / concept.name
    icon = out / "AppIcon.icon"
    build_icon(concept, icon)
    render(icon, out)
    for small in (60, 180):
        for rendition in ("Default", "Dark"):
            subprocess.run([ICTOOL, str(icon), "--export-image", "--output-file", str(out / f"{rendition}-{small}.png"),
                            "--platform", "iOS", "--rendition", rendition,
                            "--width", str(small), "--height", str(small), "--scale", "1"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(out)
