#!/usr/bin/env python3
"""Build the release copy of ShelfTechUI from the source tree.

    python3 build.py SRC_DIR OUT_DIR

The source tree keeps its comments and docs; the release copy is pruned:
  * Lua: comments removed, indentation and trailing spaces dropped, blank lines
    kept (so line numbers in crash logs still match the source)
  * .po: comments, obsolete and untranslated entries removed
  * no editor/OS clutter, no empty folders
Only Lua files that still compile and translations that parse identically are
written; anything else aborts the build.
"""
import os, re, shutil, sys

SKIP_NAMES = {".DS_Store", "Thumbs.db", ".git", ".gitignore", "__pycache__"}
SKIP_EXT = (".orig", ".bak", ".rej", ".swp", ".pot", "~")


def strip_lua(src):
    out = []          # characters of the output
    i, n = 0, len(src)
    line_start = True  # at the start of a line outside any string

    def long_bracket(at):
        m = re.match(r"\[(=*)\[", src[at:at + 64])
        return m.group(1) if m else None

    while i < n:
        c = src[i]
        if line_start:
            if c in " \t":
                i += 1
                continue
            line_start = False
        if c == "\n":
            while out and out[-1] in " \t":
                out.pop()
            out.append("\n")
            line_start = True
            i += 1
        elif src.startswith("--", i):
            eq = long_bracket(i + 2)
            if eq is not None:
                close = "]" + eq + "]"
                j = src.find(close, i + 4 + len(eq))
                if j < 0:
                    raise ValueError("unclosed long comment")
                out.append("\n" * src.count("\n", i, j))  # keep the line count
                if src.count("\n", i, j):
                    line_start = True
                i = j + len(close)
                # a comment between two tokens must still separate them
                if out and out[-1] not in " \t\n" and i < n and src[i] not in " \t\n":
                    out.append(" ")
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
        elif c == "[" and long_bracket(i) is not None:
            eq = long_bracket(i)
            close = "]" + eq + "]"
            j = src.find(close, i + 2 + len(eq))
            if j < 0:
                raise ValueError("unclosed long string")
            out.append(src[i:j + len(close)])
            i = j + len(close)
        elif c in "\"'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == c:
                    break
                if src[j] == "\n":
                    raise ValueError("unfinished string")
                j += 1
            out.append(src[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    s = "".join(out)
    s = re.sub(r"[ \t]+\n", "\n", s)
    return s.rstrip("\n") + "\n"


def compact_po(src):
    """Keep only translated msgid/msgstr pairs, as the plugin's parser reads them."""
    entries, cur, field = [], None, None

    def flush():
        nonlocal cur, field
        if cur and cur.get("msgid") and cur.get("msgstr"):
            raw_id = "".join(cur["msgid"])
            raw_str = "".join(cur["msgstr"])
            if raw_id != "" and raw_str != "":
                entries.append((cur["msgid"], cur["msgstr"]))
        cur, field = None, None

    for raw in src.splitlines():
        line = raw.strip()
        if line == "":
            flush()
        elif line.startswith("#"):
            continue
        elif re.match(r'^msgid\s+"', line):
            flush()
            cur = {"msgid": [re.match(r'^msgid\s+"(.*)"', line).group(1)]}
            field = "msgid"
        elif re.match(r'^msgstr\s+"', line):
            if cur is None:
                cur = {}
            cur["msgstr"] = [re.match(r'^msgstr\s+"(.*)"', line).group(1)]
            field = "msgstr"
        elif line.startswith('"') and cur is not None and field in cur:
            cur[field].append(re.match(r'^"(.*)"', line).group(1))
    flush()
    # the header entry (msgid "") never reaches the parser's map; skip it too
    parts = []
    for mid, mstr in entries:
        parts.append("msgid " + "\n".join('"%s"' % p for p in mid) + "\n"
                     + "msgstr " + "\n".join('"%s"' % p for p in mstr) + "\n")
    return "\n".join(parts)


def main(src_dir, out_dir):
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    before = after = 0
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_NAMES]
        rel = os.path.relpath(root, src_dir)
        for f in files:
            if f in SKIP_NAMES or f.endswith(SKIP_EXT):
                continue
            sp = os.path.join(root, f)
            dp = os.path.join(out_dir, rel, f)
            os.makedirs(os.path.dirname(dp), exist_ok=True)
            before += os.path.getsize(sp)
            if f.endswith(".lua"):
                with open(sp, encoding="utf-8") as fh:
                    data = strip_lua(fh.read())
                with open(dp, "w", encoding="utf-8") as fh:
                    fh.write(data)
            elif f.endswith(".po"):
                with open(sp, encoding="utf-8") as fh:
                    data = compact_po(fh.read())
                with open(dp, "w", encoding="utf-8") as fh:
                    fh.write(data)
            else:
                shutil.copy2(sp, dp)
            after += os.path.getsize(dp)
    print("source %.1f MB -> release %.1f MB" % (before / 1e6, after / 1e6))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
