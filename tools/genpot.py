import re, sys, glob

# Usage: python3 tools/genpot.py [output]   (run from the repository root)
#
# The template is named after the i18n domain, trafficctl, as every
# openwrt/luci application names its own (po/templates/<domain>.pot, with
# po/<lang>/<domain>.po beside it). luci.mk compiles each .po into
# <basename>.<lang>.lmo, so the .po basename is what lands on the router.
DEFAULT_OUT = 'luci-app-trafficctl/po/templates/trafficctl.pot'

# Extract the msgids a LuCI view exposes, and write them in .po syntax.
#
# Two escaping layers meet here and getting them confused produced a template
# msgfmt rejected on the first attempt. The JS literal 'style=\"x\"' has a
# RUNTIME VALUE of style="x" — the backslashes are JS escaping. The .po file
# then needs its own escaping of that value. Passing the literal source text
# through unchanged yields \\" in the template, which terminates the string
# early and makes msgfmt read the rest as keywords.
JS_ESCAPES = {'n':'\n','t':'\t','r':'\r','\\':'\\',"'":"'",'"':'"','0':'\0'}

def js_unescape(lit):
    out=[]; i=0
    while i < len(lit):
        c=lit[i]
        if c=='\\' and i+1 < len(lit):
            nxt=lit[i+1]
            if nxt=='u' and i+5 < len(lit):
                try:
                    out.append(chr(int(lit[i+2:i+6],16))); i+=6; continue
                except ValueError:
                    pass
            if nxt=='x' and i+3 < len(lit):
                try:
                    out.append(chr(int(lit[i+2:i+4],16))); i+=4; continue
                except ValueError:
                    pass
            out.append(JS_ESCAPES.get(nxt, nxt)); i+=2; continue
        out.append(c); i+=1
    return ''.join(out)

def po_escape(s):
    s=s.replace('\\','\\\\').replace('"','\\"')
    return s.replace('\n','\\n').replace('\t','\\t').replace('\r','\\r')

LIT = r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\""
CALL = re.compile(r"_\(\s*((?:%s)(?:\s*\+\s*(?:%s))*)\s*[,)]" % (LIT, LIT))

def extract(path):
    src=open(path).read()
    ids=[]
    for m in CALL.finditer(src):
        parts=re.findall(LIT, m.group(1))
        joined=''.join(js_unescape(p[1:-1]) for p in parts)
        if joined.strip():
            ids.append(joined)
    return ids

ids=[]
for f in sorted(glob.glob('luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/*.js')):
    ids += extract(f)
# Menu titles and ACL descriptions are translated too: LuCI looks them up at
# runtime, and luci's own build/i18n-scan.pl collects them, so a .pot without
# them is what an upstream review regenerates and finds four strings short.
import json
for f in sorted(glob.glob('luci-app-trafficctl/root/usr/share/luci/menu.d/*.json')):
    ids += [n['title'] for n in json.load(open(f)).values() if n.get('title')]
for f in sorted(glob.glob('luci-app-trafficctl/root/usr/share/rpcd/acl.d/*.json')):
    ids += [n['description'] for n in json.load(open(f)).values() if n.get('description')]
uniq=sorted(set(ids))

bad=[i for i in uniq if i != i.strip()]
if bad:
    sys.exit("msgid with edge whitespace (can never match its .lmo entry): %r" % bad[:3])

out=['msgid ""','msgstr "Content-Type: text/plain; charset=UTF-8"']
for i in uniq:
    out += ['', 'msgid "%s"' % po_escape(i), 'msgstr ""']
open(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT,'w').write('\n'.join(out)+'\n')
print("entries:", len(uniq))
