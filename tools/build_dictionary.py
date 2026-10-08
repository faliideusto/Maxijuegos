#!/usr/bin/env python3
"""Genera data/es_words.txt y data/es_syllables.txt a partir del diccionario hunspell es_ES de LibreOffice
(github.com/LibreOffice/dictionaries, carpeta es/; triple licencia GPLv3+/LGPLv3+/MPL 1.1+; se usa bajo MPL 1.1).

  python tools/build_dictionary.py <carpeta con es_ES.dic y es_ES.aff> [carpeta de salida (por defecto data)]

- es_words.txt: todas las formas (afijos expandidos), en minúsculas, sin tildes (se conserva la ñ), solo
  letras a-zñ, una por línea y sin repetir. Las entradas con mayúscula inicial (nombres propios, siglas)
  se descartan: solo palabras comunes.
- es_tiers.txt: las combinaciones de cada nivel (TIERS): "nivel|combinación|nº de palabras|ejemplos"
  (los ejemplos son palabras corrientes, no formas verbales raras).
"""
import random
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

SAMPLES = 24           # palabras de ejemplo por combinación (las usan los bots y el aviso final)
MAX_LEN = 24

# Niveles de Bomba de Palabras (de muy fácil a experto): combinaciones de letras que hay que contener.
TIERS = [
    "ar er ir en es la de ra re ro ta te co an or".split(),
    "cas con est ent ado ada era ero par por res men tra ter sol".split(),
    "bra bre cri gre ple clo nte ndo rta rto mbr str fra dra tro".split(),
    "xpr xtr gni cni pti nqu squ cti lqu dmi mpl ngr rqu rni bst".split(),
    "psic xcep zqui xpri gnit ptim bstr nstr lqui yect umbr scen cept ctua ctiv".split(),
]


def normalize(word: str) -> str:
    """Minúsculas y sin tildes/diéresis, conservando la ñ."""
    out = []
    for ch in unicodedata.normalize("NFC", word.lower()):
        if ch == "ñ":
            out.append("ñ")
            continue
        d = unicodedata.normalize("NFD", ch)
        out.append("".join(c for c in d if unicodedata.category(c) != "Mn"))
    return "".join(out)


def parse_aff(path: Path):
    """Devuelve {flag: (es_prefijo, cruzable, [(quitar, añadir, condicion_regex, flags_continuacion)])}."""
    rules = {}
    cur = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip() if not raw.startswith("PFX") and not raw.startswith("SFX") else raw.rstrip()
        parts = line.split()
        if len(parts) >= 4 and parts[0] in ("PFX", "SFX") and parts[2] in ("Y", "N") and parts[3].isdigit():
            cur = (parts[0] == "PFX", parts[2] == "Y", [])
            rules[parts[1]] = cur
        elif len(parts) >= 4 and parts[0] in ("PFX", "SFX") and cur is not None:
            strip = "" if parts[2] == "0" else parts[2]
            add = parts[3]
            cont = ""
            if "/" in add:
                add, cont = add.split("/", 1)
            if add == "0":
                add = ""
            cond = parts[4] if len(parts) > 4 else "."
            is_pfx = parts[0] == "PFX"
            pattern = ("^" + cond) if is_pfx else (cond + "$")
            cur[2].append((strip, add, re.compile(pattern), cont))
    return rules


def apply_rule(word: str, is_pfx: bool, rule):
    strip, add, cond, cont = rule
    if not cond.search(word):
        return None
    if is_pfx:
        if strip and not word.startswith(strip):
            return None
        return add + word[len(strip):], cont
    if strip and not word.endswith(strip):
        return None
    return (word[: len(word) - len(strip)] if strip else word) + add, cont


def expand(word: str, flags: str, rules):
    forms = {word}
    pfx_forms = []   # (forma, cruzable)
    sfx_forms = []
    for f in flags:
        r = rules.get(f)
        if r is None:
            continue
        is_pfx, cross, lst = r
        for rule in lst:
            res = apply_rule(word, is_pfx, rule)
            if res is None:
                continue
            form, cont = res
            forms.add(form)
            (pfx_forms if is_pfx else sfx_forms).append((form, cross))
            # Segundo nivel: flags de continuación (p. ej. "ción/S" → plural).
            for cf in cont:
                r2 = rules.get(cf)
                if r2 is None:
                    continue
                for rule2 in r2[2]:
                    res2 = apply_rule(form, r2[0], rule2)
                    if res2:
                        forms.add(res2[0])
    # Prefijo + sufijo (solo si ambos son cruzables).
    for pf, pc in pfx_forms:
        if not pc:
            continue
        for f in flags:
            r = rules.get(f)
            if r is None or r[0] or not r[1]:
                continue
            for rule in r[2]:
                res = apply_rule(pf, False, rule)
                if res:
                    forms.add(res[0])
    return forms


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("data")
    out.mkdir(parents=True, exist_ok=True)
    rules = parse_aff(src / "es_ES.aff")
    words = set()
    lemmas = set()
    lines = (src / "es_ES.dic").read_text(encoding="utf-8").splitlines()[1:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        base, _, flags = line.partition("/")
        if not base or not base[0].islower():
            continue          # nombres propios, siglas...
        nb = normalize(base)
        if re.fullmatch(r"[a-zñ]+", nb) and 3 <= len(nb) <= 9:
            lemmas.add(nb)
        for form in expand(base, flags, rules):
            w = normalize(form)
            if 2 <= len(w) <= MAX_LEN and re.fullmatch(r"[a-zñ]+", w):
                words.add(w)
    sorted_words = sorted(words)
    # Se escribe en binario con LF: en Windows write_text() metería CRLF.
    (out / "es_words.txt").write_bytes(("\n".join(sorted_words) + "\n").encode("utf-8"))
    print(f"{len(sorted_words)} palabras")

    # Niveles de dificultad de Bomba de Palabras: cada combinación con su nº de palabras y ejemplos.
    # Los ejemplos son palabras corrientes (lemas) que la contienen; si hay pocos, se completan con formas.
    rnd = random.Random(7)
    rows = []
    for tier, combos in enumerate(TIERS, start=1):
        for syl in combos:
            n_all = sum(1 for w in sorted_words if syl in w)
            lem = sorted(w for w in lemmas if syl in w)
            pool = lem if len(lem) >= 8 else lem + [w for w in sorted_words if syl in w and len(w) <= 10 and w not in lem]
            picks = rnd.sample(pool, min(SAMPLES, len(pool)))
            if n_all < 12 or len(picks) < 8:
                print(f"AVISO: «{syl}» (nivel {tier}) tiene pocas palabras: {n_all}")
            rows.append(f"{tier}|{syl}|{n_all}|{','.join(picks)}")
    (out / "es_tiers.txt").write_bytes(("\n".join(rows) + "\n").encode("utf-8"))
    print(f"{len(rows)} combinaciones en {len(TIERS)} niveles")


if __name__ == "__main__":
    main()
