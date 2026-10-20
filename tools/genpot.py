import re, sys, glob

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
uniq=sorted(set(ids))

bad=[i for i in uniq if i != i.strip()]
if bad:
    sys.exit("msgid with edge whitespace (can never match its .lmo entry): %r" % bad[:3])

out=['msgid ""','msgstr "Content-Type: text/plain; charset=UTF-8"']
for i in uniq:
    out += ['', 'msgid "%s"' % po_escape(i), 'msgstr ""']
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print("entries:", len(uniq))
