#!/usr/bin/env python3
"""The views' rpc.declare() calls against the rpcd plugin's `list`.

Usage: rpcd_contract.py <list.json> <file.js>...

Per declare on object luci.trafficctl:
  FAIL  the method is not in the plugin's list (the call fails at runtime)
  WARN  a param the method does not declare (rpcd drops it before the
        plugin sees it), or a call site whose literal argument has another
        type than the declared one (a heuristic: only literals and a few
        obvious conversions are typed, everything else is unknown)
Prints one line per finding and exits 1 only on a FAIL.
"""
import json
import re
import sys

DECLARE = re.compile(r'var\s+(\w+)\s*=\s*rpc\.declare\(\s*\{(.*?)\}\s*\)', re.S)
FIELD = re.compile(r"(\w+)\s*:\s*('(?:[^'\\]|\\.)*'|\[[^\]]*\])", re.S)


def strings(s):
    return re.findall(r"'((?:[^'\\]|\\.)*)'", s)


def split_args(s):
    """Top-level comma split of a call's argument text."""
    out, depth, cur, quote = [], 0, '', None
    for ch in s:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in '\'"':
            quote = ch
        elif ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif ch == ',' and depth == 0:
            out.append(cur.strip())
            cur = ''
            continue
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def call_args(src, name):
    """Argument lists of every call to name(...)."""
    for m in re.finditer(r'\b' + re.escape(name) + r'\(', src):
        i, depth = m.end(), 1
        while i < len(src) and depth:
            depth += {'(': 1, ')': -1}.get(src[i], 0)
            i += 1
        yield src[m.start():i], split_args(src[m.end():i - 1])


def literal_type(a):
    if a in ('true', 'false') or a.startswith('!'):
        return 'bool'
    if re.fullmatch(r'-?\d+', a) or re.match(r'(parseInt|Number|Math\.\w+)\(', a):
        return 'int'
    if re.fullmatch(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"", a) or re.match(r'String\(', a):
        return 'str'
    return None


def main():
    sigs = json.load(open(sys.argv[1]))
    fails = warns = declares = 0
    for path in sys.argv[2:]:
        src = open(path).read()
        for m in DECLARE.finditer(src):
            var, body = m.group(1), m.group(2)
            fields = dict(FIELD.findall(body))
            if strings(fields.get('object', ''))[:1] != ['luci.trafficctl']:
                continue
            declares += 1
            method = strings(fields.get('method', ''))[0]
            params = strings(fields.get('params', '[]'))
            where = '%s:%d %s' % (path, src.count('\n', 0, m.start()) + 1, var)
            if method not in sigs:
                fails += 1
                print('FAIL: %s calls %s, which the plugin does not list' % (where, method))
                continue
            sig = sigs[method]
            for p in params:
                if p not in sig:
                    warns += 1
                    print('WARN: %s sends %s.%s, which the plugin does not declare' % (where, method, p))
            for text, args in call_args(src, var):
                for p, a in zip(params, args):
                    t = literal_type(a)
                    if t and p in sig and t != sig[p] and not (a == 'null' or a == 'undefined'):
                        warns += 1
                        line = src.count('\n', 0, src.find(text)) + 1
                        print('WARN: %s:%d %s passes %s as %s, declared %s' % (path, line, method, p, t, sig[p]))
    print('%d declares checked, %d failed, %d warnings' % (declares, fails, warns))
    return 1 if fails or not declares else 0


if __name__ == '__main__':
    sys.exit(main())
