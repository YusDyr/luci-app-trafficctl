#!/bin/bash
# Translations have to reach the RELEASE artifacts, not just feed builds (#74).
#
# The OpenWrt feed build compiles po/ into .lmo with luci-base's po2lmo and
# ships one package per language. build-ipk.sh and build-apk.sh run outside any
# SDK, had no idea po/ existed, and would have published a "complete Simplified
# Chinese translation" release in which every string was English.
#
# Two things are being defended here.
#
# The FORMAT. tools/po2lmo.py is a reimplementation of a C tool whose output is
# consumed by a hash lookup: a single wrong bit does not raise an error, it just
# fails to find the entry and the UI silently falls back to English. So the test
# is byte-exactness against a golden .lmo produced by the real po2lmo, not a
# round-trip through the reimplementation itself, which would agree with its own
# mistakes. tests/fixtures/i18n/sample.po is deliberately adversarial on the
# parts most likely to diverge: multi-line continuations, \" and \\ escapes, a
# literal \n, msgctxt, plural forms, non-ASCII, an empty msgstr, and a
# translation identical to its source (which po2lmo drops entirely).
#
# The LAYOUT. Package name, install paths and the uci-defaults line must match
# what luci.mk produces, or a router with both the feed package and a release
# artifact ends up with one file owned by two packages.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures/i18n"

TMP=$(mktemp -d)
LANG_TABLE="$REPO_ROOT/tools/luci-languages.tsv"
cp "$LANG_TABLE" "$TMP/luci-languages.tsv.orig"
# The end-to-end case stages a language into the source tree; restore both the
# tree and the table whatever happens, including an assertion aborting the run.
cleanup() {
    cp "$TMP/luci-languages.tsv.orig" "$LANG_TABLE"
    rm -rf "$REPO_ROOT/luci-app-trafficctl/po/xx_Test" "$TMP"
}
trap cleanup EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n" "$desc"
    fi
}

# --- the format ------------------------------------------------------------

python3 "$REPO_ROOT/tools/po2lmo.py" "$FIXTURES/sample.po" "$TMP/out.lmo"
if cmp -s "$FIXTURES/sample.lmo" "$TMP/out.lmo"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: po2lmo.py output differs from the golden lmo built by luci-base's po2lmo\n"
    cmp -l "$FIXTURES/sample.lmo" "$TMP/out.lmo" 2>/dev/null | head -5
fi

# The trailer is the size of the data section; the index that precedes it is a
# whole number of 16-byte records. Checking this separately means a corrupted
# golden file cannot make the comparison above vacuous.
size=$(wc -c < "$TMP/out.lmo" | tr -d ' ')
blob=$(python3 -c "
import struct, sys
data = open('$TMP/out.lmo','rb').read()
print(struct.unpack('>I', data[-4:])[0])
")
assert_eq "index section is a whole number of 16-byte records" "0" \
    "$(( (size - blob - 4) % 16 ))"

# A .po with nothing to translate must leave no file behind rather than an
# empty container that the runtime would mmap and find no entries in.
printf 'msgid "only"\nmsgstr ""\n' > "$TMP/empty.po"
python3 "$REPO_ROOT/tools/po2lmo.py" "$TMP/empty.po" "$TMP/empty.lmo"
assert_eq "an untranslated .po produces no .lmo at all" "absent" \
    "$([ -f "$TMP/empty.lmo" ] && echo present || echo absent)"

# --- the layout ------------------------------------------------------------

TCTL_ROOT="$REPO_ROOT"
export TCTL_ROOT
# shellcheck source=../tools/i18n.sh
. "$REPO_ROOT/tools/i18n.sh"

assert_eq "zh_Hans maps to LuCI's own language code" "zh-cn" "$(i18n_code zh_Hans)"
assert_eq "pt_BR maps to LuCI's own language code" "pt-br" "$(i18n_code pt_BR)"
assert_eq "a language with no alias keeps its directory name" "ru" "$(i18n_code ru)"
assert_eq "package name matches the feed's" "luci-i18n-trafficctl-zh-cn" "$(i18n_pkgname zh_Hans)"

# An unknown language must stop the build. Emitting a package whose
# uci-defaults line registers a language under an empty name would put a blank
# entry in the LuCI language menu.
if i18n_code xx_Nonexistent >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf "FAIL: an unknown language is accepted instead of failing the build\n"
else
    PASS=$((PASS + 1))
fi

# --- end to end through build-ipk.sh ---------------------------------------
#
# Staged under a language the repository does not ship, so this passes both
# before and after a real translation lands and never collides with one.

mkdir -p "$REPO_ROOT/luci-app-trafficctl/po/xx_Test"
cp "$FIXTURES/sample.po" "$REPO_ROOT/luci-app-trafficctl/po/xx_Test/luci-app-trafficctl.po"
printf 'xx_Test\txx-test\tTestish (Test Language)\n' >> "$LANG_TABLE"

DIST="$TMP/dist"
OUT=$(cd "$REPO_ROOT" && OUTDIR="$DIST" sh build-ipk.sh 0.0.1-test 1 2>/dev/null)

assert_eq "the main package is still the LAST line of stdout" \
    "$DIST/luci-app-trafficctl_0.0.1-test-1_all.ipk" "$(printf '%s\n' "$OUT" | tail -1)"
assert_eq "a translation package is emitted too" \
    "$DIST/luci-i18n-trafficctl-xx-test_0.0.1-test-1_all.ipk" "$(printf '%s\n' "$OUT" | head -1)"

I18N_IPK="$DIST/luci-i18n-trafficctl-xx-test_0.0.1-test-1_all.ipk"
MAIN_IPK="$DIST/luci-app-trafficctl_0.0.1-test-1_all.ipk"
assert_ok "the translation ipk exists on disk" test -f "$I18N_IPK"

mkdir -p "$TMP/x" && tar -xzf "$I18N_IPK" -C "$TMP/x" 2>/dev/null
mkdir -p "$TMP/x/data" && tar -xzf "$TMP/x/data.tar.gz" -C "$TMP/x/data" 2>/dev/null
mkdir -p "$TMP/x/ctrl" && tar -xzf "$TMP/x/control.tar.gz" -C "$TMP/x/ctrl" 2>/dev/null

# luci.mk installs to $(LUCI_LIBRARYDIR)/i18n/$(basename $(po)).$(code).lmo
assert_ok "lmo lands where LuCI looks for it" \
    test -f "$TMP/x/data/usr/lib/lua/luci/i18n/luci-app-trafficctl.xx-test.lmo"
assert_ok "the shipped lmo is the compiled container, not the .po" \
    cmp -s "$FIXTURES/sample.lmo" "$TMP/x/data/usr/lib/lua/luci/i18n/luci-app-trafficctl.xx-test.lmo"

# Verbatim from luci.mk, dashes turned into underscores because a uci option
# name cannot contain a dash.
assert_eq "uci-defaults registers the language exactly as the feed does" \
    "uci set luci.languages.xx_test='Testish (Test Language)'; uci commit luci" \
    "$(cat "$TMP/x/data/etc/uci-defaults/luci-i18n-trafficctl-xx-test" 2>/dev/null)"

assert_eq "the translation package depends on the main one" \
    "Depends: luci-app-trafficctl" \
    "$(grep '^Depends:' "$TMP/x/ctrl/control" 2>/dev/null)"
assert_eq "the translation package is architecture independent" \
    "Architecture: all" \
    "$(grep '^Architecture:' "$TMP/x/ctrl/control" 2>/dev/null)"

# Nothing may be bundled into the main package: a router running the feed
# package plus a release artifact would otherwise have the same path twice.
mkdir -p "$TMP/m" && tar -xzf "$MAIN_IPK" -C "$TMP/m" 2>/dev/null
assert_eq "the main package ships no translations of its own" "0" \
    "$(tar -tzf "$TMP/m/data.tar.gz" 2>/dev/null | grep -c '\.lmo$')"

rm -rf "$REPO_ROOT/luci-app-trafficctl/po/xx_Test"

# --- the two standalone builders must not drift apart ----------------------

for f in build-ipk.sh build-apk.sh; do
    assert_eq "$f sources the shared i18n helper" "1" \
        "$(grep -c '^\. "\$TCTL_ROOT/tools/i18n.sh"' "$REPO_ROOT/$f")"
    assert_eq "$f names translation packages through i18n_pkgname" "1" \
        "$(grep -c 'i18n_pkgname' "$REPO_ROOT/$f")"
done

# --- the language table must agree with luci.mk ----------------------------
#
# Only checkable where a LuCI source tree is present; skipped in CI rather than
# vendored, because the table is upstream's to change.

LUCI_MK="${LUCI_SRC:-$HOME/xiaomi-token/luci}/luci.mk"
if [ -r "$LUCI_MK" ]; then
    mismatch=$(awk -F'\t' '$0 !~ /^#/ { want[$1] = $2 "\t" $3 }
        END { while ((getline line < MK) > 0) {
                if (line ~ /^LUCI_LANG\./) {
                    split(line, p, "=");
                    lang = substr(p[1], 11);
                    name = line; sub(/^[^=]*=/, "", name);
                    lname[lang] = name;
                } else if (line ~ /^LUCI_LC_ALIAS\./) {
                    split(line, p, "=");
                    alias[substr(p[1], 15)] = p[2];
                }
              }
              for (l in lname) {
                  code = (l in alias) ? alias[l] : l;
                  if (want[l] != code "\t" lname[l]) print l;
              } }' MK="$LUCI_MK" "$REPO_ROOT/tools/luci-languages.tsv" | tr '\n' ' ')
    assert_eq "tools/luci-languages.tsv matches luci.mk" "" "$(echo "$mismatch" | sed 's/ *$//')"
else
    printf 'skip: no LuCI checkout, not cross-checking the language table\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
