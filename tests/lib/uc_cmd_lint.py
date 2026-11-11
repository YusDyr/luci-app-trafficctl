#!/usr/bin/env python3
"""Lint for the ucode backend's shell command lines.

  uc_cmd_lint.py <lib.uc> <file>...

Prints one line per finding, nothing when clean:
- popen or system named anywhere but lib.uc (import aliases included);
- a run()/lines()/sh() command built from anything but string literals and
  q(...) calls (a ternary is fine when both branches are).
"""
import re
import sys


def skip_regex(s, i):
    """End of the regex literal starting at s[i] == '/'."""
    j, cls = i + 1, False
    while j < len(s) and s[j] != '\n':
        c = s[j]
        if c == '\\':
            j += 2
            continue
        if c == '[':
            cls = True
        elif c == ']':
            cls = False
        elif c == '/' and not cls:
            j += 1
            while j < len(s) and s[j].isalpha():
                j += 1
            return j
        j += 1
    return j


def regex_here(s, i):
    """A '/' that starts a regex literal, not a division."""
    k = i - 1
    while k >= 0 and s[k] in ' \t':
        k -= 1
    return k < 0 or s[k] in '(,=:[!&|?{};\n'


def strip(src):
    """Comments out; strings and regex literals kept whole."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and not src.startswith('//', i) and not src.startswith('/*', i) \
                and regex_here(src, i):
            j = skip_regex(src, i)
            out.append('/' + 'r' * (j - i - 2) + '/')
            i = j
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            out.append(' ' * ((n if j < 0 else j + 2) - i))
            i = n if j < 0 else j + 2
        elif c in '\'"`':
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(src[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def skip_string(s, i):
    q = s[i]
    j = i + 1
    while j < len(s) and s[j] != q:
        j += 2 if s[j] == '\\' else 1
    return j + 1


def split_top(expr, seps):
    """Split on top-level separators (outside brackets and strings)."""
    parts, depth, cur, i = [], 0, [], 0
    while i < len(expr):
        c = expr[i]
        if c in '\'"`':
            j = skip_string(expr, i)
            cur.append(expr[i:j])
            i = j
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        if depth == 0 and c in seps:
            parts.append(''.join(cur))
            parts.append(c)
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append(''.join(cur))
    return parts


def wrapped(e):
    """True when e is one (...) group."""
    if not (e.startswith('(') and e.endswith(')')):
        return False
    depth = 0
    for i, c in enumerate(e):
        depth += c == '('
        depth -= c == ')'
        if depth == 0 and i < len(e) - 1:
            return False
    return True


STRING = re.compile(r'''^('([^'\\]|\\.)*'|"([^"\\]|\\.)*")$''', re.S)
QCALL = re.compile(r'^(lib\.)?q\(')


# lib.uc's lines() hands its own parameter on to run().
forwarded = None


def safe(e):
    e = e.strip()
    if wrapped(e):
        return safe(e[1:-1])
    p = split_top(e, '?')
    if len(p) > 1:
        rest = ''.join(p[2:])
        branches = [x for x in split_top(rest, ':') if x != ':']
        return len(branches) == 2 and all(safe(b) for b in branches)
    ops = [x for x in split_top(e, '+') if x != '+']
    if len(ops) > 1:
        return all(safe(o) for o in ops)
    if STRING.match(e):
        return True
    if QCALL.match(e) and wrapped(e[e.index('('):]):
        return True
    return e == forwarded


def first_arg(code, i):
    """The first argument of the call whose '(' is at i."""
    depth, j = 0, i
    while j < len(code):
        c = code[j]
        if c in '\'"`':
            j = skip_string(code, j)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return code[i + 1:j]
        elif c == ',' and depth == 1:
            return code[i + 1:j]
        j += 1
    return code[i + 1:]


CALL = re.compile(r'(?<![\w.])(lib\.)?(run|lines|sh)\s*\(')
DEF = re.compile(r'function\s+$')
EXEC = re.compile(r'\b(popen|system)\b')


def lint(path, is_lib):
    global forwarded
    forwarded = 'cmd' if is_lib else None
    src = open(path, encoding='utf-8').read()
    code = strip(src)
    found = []
    # Names outside string literals only.
    bare = re.sub(r'''('([^'\\\n]|\\.)*'|"([^"\\\n]|\\.)*")''', '""', code)
    if not is_lib:
        for m in EXEC.finditer(bare):
            line = bare.count('\n', 0, m.start()) + 1
            found.append(f'{path}:{line}: {m.group(1)} outside lib.uc')
    for m in CALL.finditer(code):
        if not is_lib and not m.group(1):
            continue
        if DEF.search(code[max(0, m.start() - 20):m.start()]):
            continue
        arg = first_arg(code, m.end() - 1)
        if not safe(arg):
            line = code.count('\n', 0, m.start()) + 1
            found.append(f'{path}:{line}: unquoted value in {m.group(0)}{arg.strip()}')
    return found


def main(argv):
    lib = argv[1]
    out = []
    for f in argv[1:]:
        out += lint(f, f == lib)
    for line in out:
        print(line)


if __name__ == '__main__':
    main(sys.argv)
