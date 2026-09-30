#!/bin/sh
# Translation packaging, shared by build-ipk.sh and build-apk.sh.
#
# The OpenWrt feed build ships translations as SEPARATE packages, one per
# language (luci.mk's LuciTranslation): luci-i18n-<basename>-<code>, arch all,
# depending on the main package, carrying a compiled .lmo plus a uci-defaults
# snippet that registers the language with LuCI. The standalone builders have
# to produce the same shape, not a bundle — a router that has the feed package
# installed and then takes a release artifact must not end up with the same
# file owned by two packages.
#
# Both builders source this so the layout is defined once. test_postinst_parity
# exists because these two scripts drifted apart before and broke every
# released install; the same reasoning applies here.
#
# Callers must set TCTL_ROOT to the repository root before sourcing.

: "${TCTL_ROOT:=.}"

I18N_BASENAME="trafficctl"
I18N_PO_ROOT="$TCTL_ROOT/luci-app-trafficctl/po"
I18N_LANG_TABLE="$TCTL_ROOT/tools/luci-languages.tsv"
I18N_PO2LMO="$TCTL_ROOT/tools/po2lmo.py"

# Directory under which LuCI looks translations up (LUCI_LIBRARYDIR/i18n).
I18N_INSTALL_DIR="usr/lib/lua/luci/i18n"

# Language directories that actually hold a .po. po/templates is the .pot
# source and is not a language.
i18n_langs() {
    [ -d "$I18N_PO_ROOT" ] || return 0
    for dir in "$I18N_PO_ROOT"/*/; do
        [ -d "$dir" ] || continue
        lang=$(basename "$dir")
        [ "$lang" = "templates" ] && continue
        set -- "$dir"*.po
        [ -f "$1" ] || continue
        printf '%s\n' "$lang"
    done
}

_i18n_field() {
    awk -F'\t' -v want="$1" -v col="$2" \
        '$0 !~ /^#/ && $1 == want { print $col; found = 1; exit }
         END { exit found ? 0 : 1 }' "$I18N_LANG_TABLE"
}

# zh_Hans -> zh-cn. LuCI's own alias table decides this; guessing would give a
# package name the feed build does not use.
i18n_code() {
    _i18n_field "$1" 2
}

# zh_Hans -> 简体中文 (Simplified Chinese), as it appears in the LuCI language
# menu once the uci-defaults snippet has run.
i18n_name() {
    _i18n_field "$1" 3
}

i18n_pkgname() {
    printf 'luci-i18n-%s-%s' "$I18N_BASENAME" "$(i18n_code "$1")"
}

# Populate a package root with one language's payload.
#   $1 language directory name (zh_Hans)
#   $2 destination root
i18n_stage() {
    _lang="$1"
    _dest="$2"
    _code=$(i18n_code "$_lang") || return 1
    _name=$(i18n_name "$_lang") || return 1

    mkdir -p "$_dest/$I18N_INSTALL_DIR" "$_dest/etc/uci-defaults"

    for _po in "$I18N_PO_ROOT/$_lang"/*.po; do
        [ -f "$_po" ] || continue
        _base=$(basename "$_po" .po)
        python3 "$I18N_PO2LMO" "$_po" "$_dest/$I18N_INSTALL_DIR/$_base.$_code.lmo" || return 1
    done

    # po2lmo deletes its output for a .po with nothing translatable in it.
    # Shipping a package whose only payload is a uci-defaults line that adds a
    # language with no strings behind it is worse than shipping nothing.
    if [ -z "$(ls -A "$_dest/$I18N_INSTALL_DIR" 2>/dev/null)" ]; then
        rm -rf "$_dest"
        return 1
    fi

    # Verbatim from luci.mk: the key is the language code with dashes turned
    # into underscores, because uci option names cannot contain a dash.
    printf "uci set luci.languages.%s='%s'; uci commit luci\n" \
        "$(printf '%s' "$_code" | tr '-' '_')" "$_name" \
        > "$_dest/etc/uci-defaults/$(i18n_pkgname "$_lang")"
}
