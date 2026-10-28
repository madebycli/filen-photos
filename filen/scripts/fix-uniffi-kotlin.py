#!/usr/bin/env python3
"""Make uniffi's generated Kotlin compile with Kotlin 2.x (K2).

uniffi emits sealed classes whose variants wrap payload types, e.g.

    sealed class AnyFile {
        data class File(val v1: File) : AnyFile()          // variant named like its payload
        data class Linked(val v1: LinkedFile) : AnyFile()
    }
    sealed class ParentUuid {
        data class Uuid(val v1: Uuid) : ParentUuid()        // also shadows the payload of Trash(val v1: Uuid)
        data class Trash(val v1: Uuid) : ParentUuid()
    }

K1 resolved such a payload type to the top-level type; K2 resolves it to the sibling variant, which breaks
the generated converters. Qualifying every payload type that is shadowed by a sibling variant with the
package that really defines it removes the ambiguity and changes nothing else. Idempotent.
"""
import pathlib
import re
import sys

TOP_LEVEL = re.compile(
    r"^(?:public |internal )?(?:data |sealed |enum |open |abstract |annotation )*"
    r"(?:class|interface|object|typealias) (\w+)",
    re.M,
)
SEALED = re.compile(r"^sealed class (\w+) \{\n(.*?)^\}", re.M | re.S)
VARIANT = re.compile(r"^\s+(?:data class|object|class) (\w+)\b", re.M)
PAYLOAD = re.compile(r"(val v\d+: )([^,)\n]+)")


def main(root: pathlib.Path) -> int:
    files = sorted(root.rglob("*.kt"))
    texts = {f: f.read_text() for f in files}
    packages = {f: re.search(r"^package (\S+)", t, re.M).group(1) for f, t in texts.items()}
    defined = {}  # simple name -> packages that define it at top level
    for f, t in texts.items():
        for name in TOP_LEVEL.findall(t):
            defined.setdefault(name, []).append(packages[f])

    total = 0
    for f, text in texts.items():
        current = packages[f]

        def fix_block(block: re.Match) -> str:
            nonlocal total
            siblings = set(VARIANT.findall(block.group(2)))

            def fix_payload(m: re.Match) -> str:
                nonlocal total
                type_expr = m.group(2)

                def qualify(ident: re.Match) -> str:
                    nonlocal total
                    written = ident.group(0)
                    name = written.rsplit(".", 1)[-1]
                    if name not in siblings or (written != name and not written.startswith("uniffi.")):
                        return written
                    owners = defined.get(name, [])
                    if not owners:
                        return written
                    wanted = f"{current if current in owners else owners[0]}.{name}"
                    if wanted != written:
                        total += 1
                    return wanted

                return m.group(1) + re.sub(r"(?<![\w.])(?:uniffi\.\w+\.)?\w+(?![\w.])", qualify, type_expr)

            body = PAYLOAD.sub(fix_payload, block.group(2))
            return f"sealed class {block.group(1)} {{\n{body}}}"

        fixed = SEALED.sub(fix_block, text)
        if fixed != text:
            f.write_text(fixed)
    print(f"fix-uniffi-kotlin: qualified {total} shadowed variant payloads")
    return 0


if __name__ == "__main__":
    sys.exit(main(pathlib.Path(sys.argv[1])))
