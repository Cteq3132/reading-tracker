#!/usr/bin/env python3
"""Génère les calques SVG des concepts d'icône (canevas 1024 × 1024, blanc sur transparent).

Les livres sont des rectangles arrondis percés de bandes (règle evenodd) : les bandes
de dos font lire « livre » là où un rectangle nu se lirait « barre de graphique ».
"""
import pathlib

HERE = pathlib.Path(__file__).parent


def rrect(x, y, w, h, r):
    """Chemin d'un rectangle arrondi."""
    r = min(r, w / 2, h / 2)
    if r == 0:
        return f"M{x} {y} H{x + w} V{y + h} H{x} Z"
    return (f"M{x + r} {y} H{x + w - r} A{r} {r} 0 0 1 {x + w} {y + r} "
            f"V{y + h - r} A{r} {r} 0 0 1 {x + w - r} {y + h} "
            f"H{x + r} A{r} {r} 0 0 1 {x} {y + h - r} V{y + r} A{r} {r} 0 0 1 {x + r} {y} Z")


def spine(x, y, w, h, r=22, band=18, inset=0.16):
    """Livre debout : dos vertical avec deux bandes horizontales."""
    b1 = y + h * inset
    b2 = y + h * (1 - inset) - band
    return " ".join([rrect(x, y, w, h, r), rrect(x, b1, w, band, 0), rrect(x, b2, w, band, 0)])


def lying(x, y, w, h, r=24, band=18, inset=0.1):
    """Livre couché : tranche horizontale avec deux bandes verticales."""
    b1 = x + w * inset
    b2 = x + w * (1 - inset) - band
    return " ".join([rrect(x, y, w, h, r), rrect(b1, y, band, h, 0), rrect(b2, y, band, h, 0)])


def write_svg(name, body):
    path = HERE / name
    path.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
        f"{body}\n</svg>\n")


def white_path(d, transform=None):
    """Élément <path> blanc, règle evenodd (les bandes percent le livre)."""
    t = f' transform="{transform}"' if transform else ""
    return f'  <path fill="#FFFFFF" fill-rule="evenodd" d="{d}"{t}/>'


# A. L'étagère : trois livres, celui du milieu sort de son rang.
SHELF_Y = 760
write_svg("a-etagere/1-etagere.svg", "\n".join([
    white_path(rrect(196, SHELF_Y, 632, 44, 22)),
    white_path(spine(236, 372, 124, SHELF_Y - 372 - 16)),
    white_path(spine(664, 412, 124, SHELF_Y - 412 - 16)),
]))
write_svg("a-etagere/2-livre.svg", white_path(spine(450, 196, 124, 420), "rotate(-6 512 406)"))

# B. Le U serre-livres : un U à fond plat qui ne tient plus qu'un livre.
write_svg("b-serre-livres/1-u.svg",
    '  <path d="M300 250 V676 Q300 760 384 760 H640 Q724 760 724 676 V250" fill="none" '
    'stroke="#FFFFFF" stroke-width="112" stroke-linecap="round" stroke-linejoin="round"/>')
# Appuyé contre le bras droit : pivote sur son coin bas-droit (fond intérieur à y = 704).
write_svg("b-serre-livres/2-livre.svg", white_path(spine(453, 344, 112, 360, r=20, band=16), "rotate(16 565 704)"))

# C. La pile : deux livres restent, le troisième s'envole.
write_svg("c-pile/1-pile.svg", "\n".join([
    white_path(lying(216, 652, 592, 124)),
    white_path(lying(262, 512, 520, 120)),
]))
write_svg("c-pile/2-livre.svg", white_path(lying(300, 300, 470, 116), "rotate(-12 535 358) translate(40 -30)"))
