#!/usr/bin/env python3
"""Convert a gettext .po file into LuCI's .lmo container.

LuCI does not read .mo files. Its translation lookup (lmo.c) mmaps a custom
format — a data blob of 4-byte-aligned strings followed by a sorted index of
16-byte records — and finds an entry by hashing the source string. GNU msgfmt
cannot produce it, so the OpenWrt build uses a C tool, po2lmo, that ships in
luci-base and is only available inside a configured SDK.

This repository's release artifacts are assembled by build-ipk.sh and
build-apk.sh, which run outside any SDK. Rather than vendor and compile ~1000
lines of C at package time, this reimplements po2lmo in Python, which the
release workflow already depends on.

It is a *bit-exact* reimplementation, not an approximation: the output is
compared byte-for-byte against the real po2lmo in tests/test_i18n_packaging.sh
whenever a LuCI checkout is available to build the reference from. Anything
subtler than that would be a silent mistranslation at runtime, since a hash
that differs by one bit simply fails to find its entry and the UI falls back
to English with no error anywhere.

Derived from po2lmo.c and lib/lmo.c in luci-base:
  Copyright (C) 2009-2012 Jo-Philipp Wich <jow@openwrt.org>
  Licensed under the Apache License, Version 2.0
The hash is SuperFastHash by Paul Hsieh (Copyright 2004-2008).

Usage: po2lmo.py input.po output.lmo
"""

import os
import struct
import sys

M32 = 0xFFFFFFFF


def _u16(data, pos):
    """The sfh_get16 macro: little-endian 16-bit load."""
    return data[pos] | (data[pos + 1] << 8)


def _i8(byte):
    """C's (signed char) cast, which the tail cases rely on."""
    return byte - 256 if byte > 127 else byte


def sfh_hash(data, init):
    """SuperFastHash, as lmo.c computes it.

    Every step is masked back to 32 bits. Python integers do not overflow, so
    without the masks the hash diverges from the C version on the first carry
    and every lookup misses.
    """
    if not data:
        return 0

    hash_ = init & M32
    length = len(data)
    rem = length & 3
    pos = 0

    for _ in range(length >> 2):
        hash_ = (hash_ + _u16(data, pos)) & M32
        tmp = ((_u16(data, pos + 2) << 11) & M32) ^ hash_
        hash_ = ((hash_ << 16) & M32) ^ tmp
        pos += 4
        hash_ = (hash_ + (hash_ >> 11)) & M32

    if rem == 3:
        hash_ = (hash_ + _u16(data, pos)) & M32
        hash_ ^= (hash_ << 16) & M32
        hash_ ^= (_i8(data[pos + 2]) << 18) & M32
        hash_ = (hash_ + (hash_ >> 11)) & M32
    elif rem == 2:
        hash_ = (hash_ + _u16(data, pos)) & M32
        hash_ ^= (hash_ << 11) & M32
        hash_ = (hash_ + (hash_ >> 17)) & M32
    elif rem == 1:
        hash_ = (hash_ + _i8(data[pos])) & M32
        hash_ ^= (hash_ << 10) & M32
        hash_ = (hash_ + (hash_ >> 1)) & M32

    hash_ ^= (hash_ << 3) & M32
    hash_ = (hash_ + (hash_ >> 5)) & M32
    hash_ ^= (hash_ << 4) & M32
    hash_ = (hash_ + (hash_ >> 17)) & M32
    hash_ ^= (hash_ << 25) & M32
    hash_ = (hash_ + (hash_ >> 6)) & M32

    return hash_


def extract_string(line):
    """Pull the quoted payload out of one .po line.

    Deliberately narrow, matching extract_string() in po2lmo.c: only \\" and
    \\\\ are unescaped. A \\n stays as the two characters backslash and n,
    because that is what the JavaScript source literal contained and therefore
    what the runtime will hash. Interpreting it here would break every msgid
    holding a newline escape.

    Returns None for comment lines and lines with no quoted section.
    """
    if line.startswith('#'):
        return None

    out = []
    inside = False
    esc = False

    for ch in line:
        if not inside:
            if ch == '"':
                inside = True
            continue
        if esc:
            # A backslash was emitted already; these two cases replace it.
            if ch in ('"', '\\'):
                out[-1] = ch
            else:
                out.append(ch)
            esc = False
        elif ch == '\\':
            out.append(ch)
            esc = True
        elif ch != '"':
            out.append(ch)
        else:
            break

    return ''.join(out) if inside else None


class Message(object):
    def __init__(self):
        self.ctxt = None
        self.id = None
        self.id_plural = None
        self.val = {}
        self.plural_num = 0


class Writer(object):
    def __init__(self):
        self.blob = bytearray()
        self.entries = []

    def _append(self, payload):
        """Write one string into the data section, 4-byte aligned."""
        offset = len(self.blob)
        self.blob += payload
        pad = (4 - (len(payload) % 4)) % 4
        self.blob += b'\0' * pad
        return offset

    def add_message(self, msg):
        if msg.id is not None and msg.val.get(0) is not None:
            for i in range(msg.plural_num + 1):
                value = msg.val.get(i)
                if value is None:
                    continue

                if msg.ctxt is not None and msg.id_plural is not None:
                    key = '%s\1%s\2%d' % (msg.ctxt, msg.id, i)
                elif msg.ctxt is not None:
                    key = '%s\1%s' % (msg.ctxt, msg.id)
                elif msg.id_plural is not None:
                    key = '%s\2%d' % (msg.id, i)
                else:
                    key = msg.id

                key_b = key.encode('utf-8')
                val_b = value.encode('utf-8')

                key_id = sfh_hash(key_b, len(key_b))
                val_id = sfh_hash(val_b, len(val_b))

                # An untranslated string — msgstr identical to msgid — is not
                # stored at all. The runtime falls back to the source string,
                # so the entry would be dead weight.
                if key_id == val_id:
                    continue

                offset = self._append(val_b)
                # Not the value's hash: the reader uses this slot for the
                # plural count.
                self.entries.append((key_id, msg.plural_num + 1, offset, len(val_b)))

        elif msg.val.get(0) is not None:
            # The header entry. Only its Plural-Forms line is kept, stored
            # under the reserved key 0.
            for field in msg.val[0].split('\\n'):
                if field[:14].lower() == 'plural-forms: ':
                    payload = field[14:].encode('utf-8')
                    offset = self._append(payload)
                    self.entries.append((0, 0, offset, len(payload)))
                    break

    def dump(self):
        if not self.blob:
            return None
        out = bytearray(self.blob)
        for entry in sorted(self.entries, key=lambda e: e[0]):
            out += struct.pack('>IIII', *entry)
        out += struct.pack('>I', len(self.blob))
        return bytes(out)


def convert(po_path, lmo_path):
    writer = Writer()
    msg = Message()
    cur = None

    with open(po_path, 'r', encoding='utf-8', errors='surrogateescape') as fh:
        lines = fh.readlines()

    # The trailing None stands in for po2lmo's eof pass, which flushes the
    # message still being accumulated when the file ends.
    for line in lines + [None]:
        started = line is None or line.startswith(('msgctxt "', 'msgid "'))

        if started and (msg.id is not None or msg.val.get(0) is not None):
            writer.add_message(msg)
            msg = Message()

        if line is None:
            break

        if line.startswith('msgctxt "'):
            msg.ctxt = None
            cur = 'ctxt'
        elif line.startswith('msgid "'):
            msg.id = None
            cur = 'id'
        elif line.startswith('msgid_plural "'):
            msg.id_plural = None
            cur = 'id_plural'
        elif line.startswith('msgstr "') or line.startswith('msgstr['):
            msg.plural_num = int(line[7:].split(']')[0]) if line[6] == '[' else 0
            if msg.plural_num >= 10:
                sys.exit('Error: Too many plural forms')
            msg.val[msg.plural_num] = None
            cur = 'val'

        if cur is None:
            continue

        text = extract_string(line)
        if not text:
            continue

        if cur == 'val':
            prev = msg.val.get(msg.plural_num)
            msg.val[msg.plural_num] = (prev or '') + text
        else:
            prev = getattr(msg, cur)
            setattr(msg, cur, (prev or '') + text)

    data = writer.dump()
    if data is None:
        # po2lmo removes the output rather than leaving an empty container.
        if os.path.exists(lmo_path):
            os.unlink(lmo_path)
        return

    with open(lmo_path, 'wb') as fh:
        fh.write(data)


def main(argv):
    if len(argv) != 3:
        sys.exit('Usage: %s input.po output.lmo' % os.path.basename(argv[0]))
    convert(argv[1], argv[2])


if __name__ == '__main__':
    main(sys.argv)
