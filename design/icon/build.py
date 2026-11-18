#!/usr/bin/env python3
"""Assemble un document Icon Composer (.icon) à partir des calques SVG d'une piste,
puis le rend avec ictool (le moteur d'Icon Composer, livré avec Xcode).

Usage : python3 build.py <dossier-piste> [--install]

Le dossier de la piste contient des calques SVG numérotés de l'arrière vers l'avant
(1-*.svg, 2-*.svg…) ; chaque calque devient un groupe Liquid Glass. Les rendus vont dans
out/<piste>/ ; --install copie aussi le .icon dans l'app (ios/ReadingTracker/AppIcon.icon).
"""
import json
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
APP_ICON = HERE.parent.parent / "ios" / "ReadingTracker" / "AppIcon.icon"

# Accent de l'app (Assets.xcassets/AccentColor) : #D96B3C en clair, #F58F61 en sombre.
BACKGROUND = "srgb:0.85098,0.41961,0.23529,1.00000"
BACKGROUND_DARK = "srgb:0.13725,0.10588,0.09412,1.00000"
FOREGROUND_DARK = "srgb:0.96078,0.56078,0.38039,1.00000"

ALL_RENDITIONS = ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"]


def ictool() -> str:
    developer = subprocess.run(["xcode-select", "-p"], check=True, capture_output=True, text=True).stdout.strip()
    return str(pathlib.Path(developer).parent / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool")


def build_icon(piste: pathlib.Path, out_icon: pathlib.Path) -> None:
    layers = sorted(piste.glob("*-*.svg"), key=lambda p: int(p.name.split("-", 1)[0]))
    if not layers:
        sys.exit(f"Aucun calque numéroté (1-*.svg…) dans {piste}")
    if out_icon.exists():
        shutil.rmtree(out_icon)
    (out_icon / "Assets").mkdir(parents=True)

    groups = []
    # icon.json liste les groupes de l'avant vers l'arrière.
    for svg in reversed(layers):
        shutil.copy(svg, out_icon / "Assets" / svg.name)
        groups.append({
            "name": svg.stem,
            "layers": [{
                "name": svg.stem,
                "image-name": svg.name,
                "glass": True,
                "fill-specializations": [{"appearance": "dark", "value": {"solid": FOREGROUND_DARK}}],
            }],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
            "specular": True,
        })

    doc = {
        "fill": {"automatic-gradient": BACKGROUND},
        "fill-specializations": [{"appearance": "dark", "value": {"automatic-gradient": BACKGROUND_DARK}}],
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    (out_icon / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def render(icon: pathlib.Path, out_dir: pathlib.Path, size: int, renditions: list[str]) -> None:
    """Rend l'icône ; le teinté utilise la teinte par défaut d'ictool."""
    tool = ictool()
    for rendition in renditions:
        result = subprocess.run(
            [tool, str(icon), "--export-image", "--output-file", str(out_dir / f"{rendition}-{size}.png"),
             "--platform", "iOS", "--rendition", rendition,
             "--width", str(size), "--height", str(size), "--scale", "1"],
            capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"ictool a échoué ({rendition}, {size} px) :\n{result.stderr}")


def main(argv: list[str]) -> None:
    args = [a for a in argv if a != "--install"]
    if len(args) != 1:
        sys.exit(__doc__)
    piste = pathlib.Path(args[0]).resolve()
    out = HERE / "out" / piste.name
    icon = out / "AppIcon.icon"
    build_icon(piste, icon)
    render(icon, out, 1024, ALL_RENDITIONS)
    for size in (180, 60):
        render(icon, out, size, ["Default", "Dark"])
    if "--install" in argv:
        if APP_ICON.exists():
            shutil.rmtree(APP_ICON)
        shutil.copytree(icon, APP_ICON)
        print(f"Installée : {APP_ICON}")
    print(out)


if __name__ == "__main__":
    main(sys.argv[1:])
