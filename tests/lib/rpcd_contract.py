#!/usr/bin/env python3
"""The views' rpc.declare() calls against the rpcd plugin's `list`.

Usage: rpcd_contract.py <list.json> <file.js>...

Per declare on object luci.trafficctl, each a FAIL, because rpcd-mod-ucode
validates every call against the declared policy and refuses the whole call
with INVALID_ARGUMENT (the method never runs):
  - the method is not in the plugin's list (METHOD_NOT_FOUND)
  - a param the method does not declare
  - a call site whose literal argument has another type than the declared one
    (a heuristic: only literals and a few obvious conversions are typed,
    everything else is unknown)
  - a call site that can pass null or NaN (JSON null, a blobmsg UNSPEC that no
    policy type takes): a literal null/NaN, or a ternary with a null branch.
    Pass undefined to leave a param out.
Prints one line per finding and exits 1 on any.
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
        yield m.start(), split_args(src[m.end():i - 1])


def literal_type(a):
    if a in ('true', 'false') or a.startswith('!'):
        return 'bool'
    if re.fullmatch(r'-?\d+', a) or re.match(r'(parseInt|Number|Math\.\w+)\(', a):
        return 'int'
    if re.fullmatch(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"", a) or re.match(r'String\(', a):
        return 'str'
    return None


def may_be_null(a):
    if a in ('null', 'NaN'):
        return True
    return bool(re.search(r'\?\s*null\s*:|:\s*null\s*$|\?\s*NaN\s*:|:\s*NaN\s*$', a))


def main():
    sigs = json.load(open(sys.argv[1]))
    fails = declares = 0
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
                    fails += 1
                    print('FAIL: %s sends %s.%s, which the plugin does not declare' % (where, method, p))
            for pos, args in call_args(src, var):
                line = src.count('\n', 0, pos) + 1
                for p, a in zip(params, args):
                    if may_be_null(a):
                        fails += 1
                        print('FAIL: %s:%d %s can pass null for %s (rpcd refuses the call; pass undefined)'
                              % (path, line, method, p))
                        continue
                    t = literal_type(a)
                    if t and p in sig and t != sig[p] and a != 'undefined':
                        fails += 1
                        print('FAIL: %s:%d %s passes %s as %s, declared %s' % (path, line, method, p, t, sig[p]))
    print('%d declares checked, %d failed' % (declares, fails))
    return 1 if fails or not declares else 0


if __name__ == '__main__':
    sys.exit(main())
