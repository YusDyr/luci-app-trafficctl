#!/bin/bash
# The contract between the views and the rpcd plugin: every rpc.declare() on
# luci.trafficctl in htdocs/ names a method the plugin lists, with params it
# declares, with values of the declared types. Every mismatch fails: rpcd-mod-ucode
# checks each call against the declared policy and refuses it whole
# (tests/lib/rpcd_contract.py has the heuristic).

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PLUGIN="$UC_REPO/luci-app-trafficctl/root/usr/share/rpcd/ucode/luci.trafficctl.uc"
mkdir -p "$UC_TMP/root"
if ! TCTL_ROOT="$UC_TMP/root" rpcd_uc "$PLUGIN" list > "$UC_TMP/list.json" ||
        ! jq -e 'type == "object" and length > 0' "$UC_TMP/list.json" >/dev/null; then
    echo "FAIL: the plugin's list is not a JSON object"
    exit 1
fi

mapfile -t JS < <(find "$UC_REPO/luci-app-trafficctl/htdocs" -name '*.js' | sort)
python3 "$UC_TESTLIB/rpcd_contract.py" "$UC_TMP/list.json" "${JS[@]}"
