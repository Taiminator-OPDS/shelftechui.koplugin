"""Small helpers to cut Lua source: whole top-level functions, or an
indented block from its opening line to the closing line at the same indent."""
import re, sys

def cut_function(text, name):
    """Remove `function Owner:name(` / `function Owner.name(` / `local function name(`
    at column 0, up to its closing `end` at column 0, plus the comment block
    directly above it. Returns (text, removed?)."""
    lines = text.split('\n')
    pat = re.compile(r'^(local\s+)?function\s+(\w+[.:])?%s\s*\(' % re.escape(name))
    for i, l in enumerate(lines):
        if pat.match(l):
            j = i + 1
            while j < len(lines) and lines[j] != 'end':
                j += 1
            if j >= len(lines):
                return text, False
            s = i
            while s > 0 and lines[s - 1].startswith('--'):
                s -= 1
            del lines[s:j + 1]
            # collapse a doubled blank line
            if s < len(lines) and s > 0 and lines[s] == '' and lines[s - 1] == '':
                del lines[s]
            return '\n'.join(lines), True
    return text, False

def cut_block(text, first_line_startswith):
    """Remove the block whose first line starts with the given text (with its
    indentation) through the line that closes it at the same indentation
    ("}" / "})" / "}," / "end" / "end)"), plus comments directly above."""
    lines = text.split('\n')
    for i, l in enumerate(lines):
        if l.startswith(first_line_startswith):
            ind = len(l) - len(l.lstrip())
            j = i + 1
            while j < len(lines):
                lj = lines[j]
                if lj.strip() and (len(lj) - len(lj.lstrip())) == ind and re.match(r'^\s*(\}|end)[),]*\s*$', lj):
                    break
                j += 1
            if j >= len(lines):
                return text, False
            s = i
            while s > 0 and lines[s - 1].strip().startswith('--') and (len(lines[s-1]) - len(lines[s-1].lstrip())) == ind:
                s -= 1
            del lines[s:j + 1]
            return '\n'.join(lines), True
    return text, False
