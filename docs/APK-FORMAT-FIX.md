# APK Package Format Fix — Research & Implementation Brief

## Problem

`apk add luci-app-trafficctl_1.5.0-r1_noarch.apk --allow-untrusted` fails:
```
ERROR: file format is invalid or inconsistent
```

## Investigation Results

Inspected the locally-built APK with Python (multi-stream gzip analysis):

```
Segment 0 (control): ['._.', '.', './._.pre-upgrade', './.pre-upgrade', ...]
Segment 1 (data):    ['._.', '.', './._usr', './usr', './._etc', ...]
```

Three fatal bugs in `build-apk.sh` fallback path (used when `apk mkpkg` unavailable — i.e., always on Ubuntu CI):

### Bug 1: `./` prefix on all tar entries

**Current code** (line 127-130):
```sh
tar -czf "$WORKDIR/control.tar.gz" -C "$CTRL" .
tar -czf "$WORKDIR/data.tar.gz" -C "$DATA" .
```

**Problem**: `tar -C dir .` creates entries prefixed with `./` (e.g., `./.PKGINFO`, `./usr/local/bin/...`). 

apk-tools v3 parser (`src/apk_extract_v2.c`):
- Control tar: the `.` directory entry immediately sets `data_started=true`, so `./.PKGINFO` is never parsed as metadata
- Data tar: entries where `name[0]=='.'` are silently skipped during extraction

**Fix**: Use `find * -print` to generate paths without `./` prefix, pipe to `tar -T -`.

### Bug 2: macOS AppleDouble `._` resource fork files

macOS tar automatically includes `._` files. Suppressed via `COPYFILE_DISABLE=1` env var.

### Bug 3: Missing `datahash` field in .PKGINFO

apk-tools v3 requires a `datahash` field containing the SHA256 hex digest of the raw `data.tar.gz` bytes. Without it, integrity check fails and the package is rejected even with `--allow-untrusted`.

**Current .PKGINFO** has no `datahash` line.

## Correct APKv2 Structure

An unsigned APKv2 package is exactly: `control.tar.gz` + `data.tar.gz` (binary concatenation of two gzip streams).

### Control tar requirements:
- Entries must NOT have `./` prefix or directory entries
- Must contain `.PKGINFO` (literal filename starting with dot, no slash)
- May contain `.post-install`, `.pre-upgrade`, `.post-upgrade`, `.pre-deinstall`
- Format: posix/ustar (has "ustar" magic at offset 257)

### Data tar requirements:
- Paths like `usr/local/bin/foo`, `etc/config/bar` (no leading `./` or `/`)
- Format: posix/ustar

### .PKGINFO required fields:
```
pkgname = luci-app-trafficctl
pkgver = 1.5.0-r1
pkgdesc = ...
arch = noarch
license = Apache-2.0
origin = ...
url = ...
maintainer = ...
depend = conntrack
depend = luci-base
depend = rpcd
datahash = <sha256 hex of data.tar.gz file>
```

## Implementation

Replace `build-apk.sh` lines 102-134 (the `else` fallback branch) with:

```sh
else
    # Fallback: build APKv2 manually (two concatenated gzipped tars)
    CTRL="$WORKDIR/control"
    mkdir -p "$CTRL"

    # 1. Build data tar first (need its hash for .PKGINFO)
    DATATAR="$WORKDIR/data.tar.gz"
    (cd "$DATA" && find * -print | LC_ALL=C sort | \
        COPYFILE_DISABLE=1 tar --format=posix --numeric-owner --owner=0 --group=0 \
        --no-recursion -cf - -T -) | gzip -n > "$DATATAR"

    # 2. Compute datahash (SHA256 of compressed data.tar.gz)
    DATAHASH=$(sha256sum "$DATATAR" | cut -d' ' -f1)

    # 3. Write .PKGINFO with datahash
    cat > "$CTRL/.PKGINFO" <<PKGINFO
pkgname = ${PKG_NAME}
pkgver = ${PKG_VERSION}-r${PKG_RELEASE}
pkgdesc = Per-device traffic monitoring, rate limiting (nft/iptables), traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, and Telegram bot control.
arch = noarch
license = Apache-2.0
origin = https://github.com/YusDyr/luci-app-trafficctl
url = https://github.com/YusDyr/luci-app-trafficctl
maintainer = Denis Iusupov <yusdyr@gmail.com>
depend = conntrack
depend = luci-base
depend = rpcd
datahash = ${DATAHASH}
PKGINFO

    # 4. Copy lifecycle scripts
    cp "$SCRIPTS/post-install" "$CTRL/.post-install"
    cp "$SCRIPTS/pre-upgrade" "$CTRL/.pre-upgrade"
    cp "$SCRIPTS/post-upgrade" "$CTRL/.post-upgrade"
    cp "$SCRIPTS/pre-deinstall" "$CTRL/.pre-deinstall"

    # 5. Build control tar (explicit file list, no directory entries)
    CTRLS=".PKGINFO"
    for f in .post-install .pre-upgrade .post-upgrade .pre-deinstall; do
        [ -f "$CTRL/$f" ] && CTRLS="$CTRLS $f"
    done
    (cd "$CTRL" && COPYFILE_DISABLE=1 tar --format=posix --numeric-owner --owner=0 --group=0 \
        -cf - $CTRLS) | gzip -n > "$WORKDIR/control.tar.gz"

    # 6. Concatenate: control + data = APKv2
    cat "$WORKDIR/control.tar.gz" "$DATATAR" > "$APK_FILE"
fi
```

## Key portability notes

| Flag | Purpose | macOS | GNU/Linux |
|------|---------|-------|-----------|
| `COPYFILE_DISABLE=1` | Suppress `._` files | Works | Ignored |
| `--format=posix` | ustar tar format | bsdtar OK | GNU tar OK |
| `gzip -n` | No timestamp in header | Yes | Yes |
| `find *` vs `find .` | Avoids `./` prefix | Yes | Yes |
| `sha256sum` | Hash utility | Not on macOS! Use `shasum -a 256` | Yes |

**Important**: macOS doesn't have `sha256sum`. Use portable fallback:
```sh
if command -v sha256sum >/dev/null 2>&1; then
    DATAHASH=$(sha256sum "$DATATAR" | cut -d' ' -f1)
else
    DATAHASH=$(shasum -a 256 "$DATATAR" | cut -d' ' -f1)
fi
```

## Verification steps

1. `./build-apk.sh 1.5.1 1`
2. `tar tzf dist/luci-app-trafficctl_1.5.1-r1_noarch.apk | head` — should show `.PKGINFO` (no `./`)
3. Extract and check .PKGINFO has `datahash` line
4. On router: `apk add /tmp/luci-app-trafficctl_1.5.1-r1_noarch.apk --allow-untrusted` — should succeed
5. Commit as `fix(ci): correct APKv2 format in build-apk.sh fallback`

## File to modify

- `build-apk.sh` — only the `else` branch (lines 102-134), replace entirely with the code above
