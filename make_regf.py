#!/usr/bin/env python3
"""
Generate minimal but valid Windows Registry REGF hive files for chntpw testing.

Produces SAM with one Administrator account (blank password), plus stub
SYSTEM, SOFTWARE, and SECURITY hives.

Structures match chntpw 0.99.6 / ntreg.h (2014 version).
"""

import struct, time, os, sys

# ---------------------------------------------------------------------------
# Struct format strings (shared between size helpers and cell builders)
# ---------------------------------------------------------------------------

_NK_FMT = '<2sHQIIIIIIIIIIIIIIIHH'   # 76 bytes  (15 × I between Q and HH)
_VK_FMT = '<2sHIIIHH'                  # 20 bytes
_SK_FMT = '<2sHIIII'                   # 20 bytes
_LF_FMT = '<2sH'                       # 4 bytes (entries follow)
_VL_FMT = '<I'                         # 4 bytes per entry

# Sanity-check at import time
assert struct.calcsize(_NK_FMT) == 76,  f"NK size mismatch: {struct.calcsize(_NK_FMT)}"
assert struct.calcsize(_VK_FMT) == 20,  f"VK size mismatch: {struct.calcsize(_VK_FMT)}"
assert struct.calcsize(_SK_FMT) == 20,  f"SK size mismatch: {struct.calcsize(_SK_FMT)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _pad8(n: int) -> int:
    return ((n + 7) // 8) * 8

def _filetime() -> int:
    return int((time.time() + 11644473600) * 10_000_000)

def _utf16(s: str) -> bytes:
    return s.encode('utf-16-le')

# ---------------------------------------------------------------------------
# Cell builders  (each returns a bytes object whose length = total cell bytes,
# including the 4-byte size field; negative size = allocated)
# ---------------------------------------------------------------------------

def _cell(payload: bytes) -> bytes:
    total = _pad8(4 + len(payload))
    body  = payload + b'\x00' * (total - 4 - len(payload))
    return struct.pack('<i', -total) + body


def _sk_cell(prev_off: int, next_off: int) -> bytes:
    """SK cell with a minimal self-relative security descriptor."""
    # SECURITY_DESCRIPTOR (self-relative, no owner/group/DACL/SACL)
    sd = struct.pack('<BBHIIII', 1, 0, 0x8004, 0, 0, 0, 0)  # 20 bytes
    payload = struct.pack(_SK_FMT,
        b'sk',
        0,           # dummy1
        prev_off,    # ofs_prevsk
        next_off,    # ofs_nextsk
        1,           # no_usage (reference count)
        len(sd),     # len_sk
    ) + sd
    return _cell(payload)


def _nk_cell(name: str, flags: int, ts: int,
             parent: int, sk_off: int,
             subkeys_lf: int = 0xFFFF_FFFF, num_subkeys: int = 0,
             values_lv: int  = 0xFFFF_FFFF, num_values:  int = 0) -> bytes:
    """NK cell.  flags: 0x2C = hive root, 0x20 = ordinary subkey (ASCII name)."""
    name_b = name.encode('ascii')
    payload = struct.pack(_NK_FMT,
        b'nk',
        flags,
        ts,
        0,              # access bits
        parent,         # ofs_parent
        num_subkeys,    # no_subkeys
        0,              # no_volatile_subkeys
        subkeys_lf,     # ofs_lf (subkey list)
        0xFFFF_FFFF,    # ofs_volatile_lf
        num_values,     # no_values
        values_lv,      # ofs_vallist
        sk_off,         # ofs_sk
        0xFFFF_FFFF,    # ofs_classname
        0, 0, 0, 0,     # max_subkey_name, max_subkey_class, max_value_name, max_value_data
        0,              # work variable
        len(name_b),    # len_name
        0,              # len_classname
    ) + name_b
    return _cell(payload)


def _lf_cell(entries: list) -> bytes:
    """LF cell: list of (nk_off, name_hint_bytes) tuples."""
    body = struct.pack(_LF_FMT, b'lf', len(entries))
    for nk_off, hint in entries:
        body += struct.pack('<I', nk_off) + hint[:4].ljust(4, b'\x00')
    return _cell(body)


def _vl_cell(vk_offsets: list) -> bytes:
    """Value-list cell: array of uint32 offsets to VK cells."""
    return _cell(struct.pack(f'<{len(vk_offsets)}I', *vk_offsets))


def _vk_cell(name: str, dtype: int, data: bytes, data_off: int) -> bytes:
    """
    VK cell.
    dtype  : REG type (e.g. 3 = REG_BINARY)
    data   : raw value bytes (used only for its length here)
    data_off: hbins-relative offset of the separate data cell
              (or 0x8000_0000 | value for inline ≤ 4-byte data)
    """
    name_b = name.encode('ascii')
    payload = struct.pack(_VK_FMT,
        b'vk',
        len(name_b),  # len_name
        len(data),    # len_data
        data_off,     # ofs_data
        dtype,        # val_type
        1,            # flag: 1 = ASCII name
        0,            # dummy1
    ) + name_b
    return _cell(payload)

# ---------------------------------------------------------------------------
# HBIN block
# ---------------------------------------------------------------------------

class HBin:
    HEADER = 32   # bytes

    def __init__(self, index: int = 0):
        self.file_off = index * 0x1000  # this hbin's offset in the hive-bins area
        self._cells: list[bytes] = []
        self._pos   = self.HEADER

    def place(self, cell: bytes) -> int:
        """Append cell; return its hbins-relative offset."""
        off = self._pos
        self._cells.append(cell)
        self._pos += len(cell)
        return off

    def used(self) -> int:
        return self._pos

    def build(self, ts: int) -> bytes:
        total = 0x1000
        if self._pos > total:
            raise RuntimeError(f"HBIN overflow: used {self._pos} of {total} bytes")
        header = struct.pack('<4sIIQQI',
            b'hbin',
            self.file_off,  # offset from start of hive-bins area
            total,          # size of this hbin
            0,              # reserved (8 bytes)
            ts,             # timestamp (FILETIME, 8 bytes)
            0,              # spare
        )
        assert len(header) == 32
        body = b''.join(self._cells)
        free = total - self.HEADER - len(body)
        if free > 0:
            body += struct.pack('<i', free) + b'\x00' * (free - 4)
        return header + body

# ---------------------------------------------------------------------------
# Precompute all cell sizes without placing them
# ---------------------------------------------------------------------------

def _sz_nk(name: str) -> int:
    return _pad8(4 + struct.calcsize(_NK_FMT) + len(name))

def _sz_lf(n: int) -> int:
    return _pad8(4 + struct.calcsize(_LF_FMT) + n * 8)

def _sz_vl(n: int) -> int:
    return _pad8(4 + n * 4)

def _sz_vk(name: str) -> int:
    return _pad8(4 + struct.calcsize(_VK_FMT) + len(name))

def _sz_data(data: bytes) -> int:
    return _pad8(4 + len(data))

def _sz_sk() -> int:
    sd = 20  # 7-field SECURITY_DESCRIPTOR
    return _pad8(4 + struct.calcsize(_SK_FMT) + sd)

# ---------------------------------------------------------------------------
# REGF base-block (header)
# ---------------------------------------------------------------------------

def _regf_header(root_off: int, hive_size: int, hive_name: str, ts: int) -> bytes:
    name_utf16 = _utf16(hive_name)[:128].ljust(128, b'\x00')

    hdr = struct.pack('<4sIIQIIIII',
        b'regf',
        1,          # primary_seq
        1,          # secondary_seq
        ts,
        1,          # major version
        3,          # minor version (1.3 = Windows XP era)
        0,          # type: primary
        1,          # format
        root_off,   # root cell offset (relative to hive-bins start)
    )
    hdr += struct.pack('<I', hive_size)   # hive_bins_data_size
    hdr += struct.pack('<I', 1)           # unknown
    hdr += name_utf16                     # 128 bytes
    hdr  = hdr.ljust(508, b'\x00')       # pad to 508

    cksum = 0
    for i in range(0, 508, 4):
        cksum ^= struct.unpack_from('<I', hdr, i)[0]
    hdr += struct.pack('<I', cksum)       # checksum at offset 508
    hdr  = hdr.ljust(0x1000, b'\x00')   # pad to 4096
    return hdr

# ---------------------------------------------------------------------------
# V blob: SAM user data for Administrator (blank password)
# ---------------------------------------------------------------------------

def _v_blob() -> bytes:
    """
    SAM 'V' value for Administrator.

    Fixed header: 0xCC bytes.
    Data section follows immediately after.
    All offsets in header are relative to the DATA SECTION start (offset 0xCC).

    Hash structs:
        type   H  = 1
        unk    H  = 0
        flags  B  = 0 (no hash present → blank password)
        pad  3×B  = 0
        hash 16×B = 0
    """
    USERNAME  = _utf16("Administrator")  # 26 bytes
    UN_OFF, UN_LEN = 0, len(USERNAME)

    # Hash structs at standard SAM data-section offsets
    LM_OFF, NT_OFF = 0xAC, 0xC0
    DATA_LEN = NT_OFF + 0x14            # = 0xD4 bytes

    def _hash_struct():
        # 20 bytes: type=1, unk=0, flags=0 (no hash), pad=0, hash=zeros
        return struct.pack('<HHBBBB', 1, 0, 0, 0, 0, 0) + b'\x00' * 14

    hdr = bytearray(0xCC)
    hdr[0] = 0x03   # format version seen in real Windows SAM

    def _triplet(buf, off, o, l):
        struct.pack_into('<III', buf, off, o, l, 1)

    _triplet(hdr, 0x0C, UN_OFF, UN_LEN)              # username
    _triplet(hdr, 0x18, UN_OFF + UN_LEN, 0)          # full name (empty)
    _triplet(hdr, 0x24, UN_OFF + UN_LEN, 0)          # comment  (empty)
    _triplet(hdr, 0x84, LM_OFF, 0x14)                # LM hash struct
    _triplet(hdr, 0x90, NT_OFF, 0x14)                # NT hash struct

    data = bytearray(DATA_LEN)
    data[0:UN_LEN]              = USERNAME
    data[LM_OFF:LM_OFF + 0x14] = _hash_struct()
    data[NT_OFF:NT_OFF + 0x14] = _hash_struct()

    return bytes(hdr) + bytes(data)

# ---------------------------------------------------------------------------
# F blob: account flags for Administrator
# ---------------------------------------------------------------------------

def _f_blob() -> bytes:
    f = bytearray(0x50)
    f[0x00] = 0x02  # format version
    f[0x02] = 0x01
    struct.pack_into('<H', f, 0x38, 0x0214)  # ACB = normal account, don't expire passwd
    return bytes(f)

# ---------------------------------------------------------------------------
# SAM hive: ROOT → SAM → Domains → Account → Users → 000001F4 (Administrator)
# ---------------------------------------------------------------------------

def build_sam_hive() -> bytes:
    ts    = _filetime()
    hbin  = HBin(0)

    # -- SK cell (placed first, self-referential ring) ----------------------
    sk_off = hbin.place(_sk_cell(0, 0))   # placeholder offsets
    hbin._cells.clear()
    hbin._pos = HBin.HEADER
    sk_off = hbin.place(_sk_cell(sk_off, sk_off))

    # -- Pre-compute all offsets before placing any NK cell -----------------
    pos = hbin._pos   # position after SK cell

    # Key names and sizes
    keys = ["ROOT", "SAM", "Domains", "Account", "Users", "000001F4"]
    szNK   = {k: _sz_nk(k) for k in keys}
    szLF1  = _sz_lf(1)    # 1-entry LF cell

    v_data = _v_blob()
    f_data = _f_blob()

    szV    = _sz_data(v_data)
    szF    = _sz_data(f_data)
    szVKV  = _sz_vk("V")
    szVKF  = _sz_vk("F")
    szVL2  = _sz_vl(2)   # 2-value list for 000001F4

    # Lay out in top-down order
    off = {}
    off["ROOT"]     = pos
    off["LF_ROOT"]  = off["ROOT"]    + szNK["ROOT"]
    off["SAM"]      = off["LF_ROOT"] + szLF1
    off["LF_SAM"]   = off["SAM"]     + szNK["SAM"]
    off["Domains"]  = off["LF_SAM"]  + szLF1
    off["LF_DOM"]   = off["Domains"] + szNK["Domains"]
    off["Account"]  = off["LF_DOM"]  + szLF1
    off["LF_ACC"]   = off["Account"] + szNK["Account"]
    off["Users"]    = off["LF_ACC"]  + szLF1
    off["LF_USR"]   = off["Users"]   + szNK["Users"]
    off["000001F4"] = off["LF_USR"]  + szLF1
    off["VL"]       = off["000001F4"]+ szNK["000001F4"]
    off["VKV"]      = off["VL"]      + szVL2
    off["VKF"]      = off["VKV"]     + szVKV
    off["VDATA"]    = off["VKF"]     + szVKF
    off["FDATA"]    = off["VDATA"]   + szV

    total_used = off["FDATA"] + szF
    if total_used + HBin.HEADER > 0x1000:
        raise RuntimeError(f"HBIN too small: need {total_used + HBin.HEADER} bytes")

    # -- Place cells in layout order ----------------------------------------
    def place_nk(name, flags, parent_key, sk, lf_key=None, num_sk=0,
                 vl_key=None, num_v=0):
        lf_off = off[lf_key] if lf_key else 0xFFFF_FFFF
        vl_off = off[vl_key] if vl_key else 0xFFFF_FFFF
        cell = _nk_cell(name, flags, ts, off[parent_key], sk,
                        subkeys_lf=lf_off, num_subkeys=num_sk,
                        values_lv=vl_off,  num_values=num_v)
        hbin.place(cell)

    place_nk("ROOT",     0x2C, "ROOT",     sk_off, "LF_ROOT", 1)
    hbin.place(_lf_cell([(off["SAM"], b"SAM\x00")]))

    place_nk("SAM",      0x20, "ROOT",     sk_off, "LF_SAM", 1)
    hbin.place(_lf_cell([(off["Domains"], b"Doma")]))

    place_nk("Domains",  0x20, "SAM",      sk_off, "LF_DOM", 1)
    hbin.place(_lf_cell([(off["Account"], b"Acco")]))

    place_nk("Account",  0x20, "Domains",  sk_off, "LF_ACC", 1)
    hbin.place(_lf_cell([(off["Users"],   b"User")]))

    place_nk("Users",    0x20, "Account",  sk_off, "LF_USR", 1)
    hbin.place(_lf_cell([(off["000001F4"], b"0000")]))

    # 000001F4 = Administrator (RID 500 = 0x1F4, padded to 8 hex digits)
    place_nk("000001F4", 0x20, "Users",    sk_off, vl_key="VL", num_v=2)

    # Value list for 000001F4
    hbin.place(_vl_cell([off["VKV"], off["VKF"]]))

    # VK cells
    hbin.place(_vk_cell("V", 3, v_data, off["VDATA"]))
    hbin.place(_vk_cell("F", 3, f_data, off["FDATA"]))

    # Data cells
    hbin.place(_cell(v_data))
    hbin.place(_cell(f_data))

    hive_bins = hbin.build(ts)
    header    = _regf_header(off["ROOT"], len(hive_bins), "SAM", ts)
    return header + hive_bins

# ---------------------------------------------------------------------------
# Stub hive: single root key, no subkeys or values
# ---------------------------------------------------------------------------

def build_stub_hive(name: str) -> bytes:
    ts   = _filetime()
    hbin = HBin(0)

    sk_off = hbin.place(_sk_cell(0, 0))
    hbin._cells.clear()
    hbin._pos = HBin.HEADER
    sk_off = hbin.place(_sk_cell(sk_off, sk_off))

    root_off = hbin._pos
    hbin.place(_nk_cell(name, 0x2C, ts, parent=root_off, sk_off=sk_off))

    hive_bins = hbin.build(ts)
    header    = _regf_header(root_off, len(hive_bins), name, ts)
    return header + hive_bins

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_dir>")
        sys.exit(1)

    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)

    hives = {
        "SAM":      build_sam_hive(),
        "SYSTEM":   build_stub_hive("SYSTEM"),
        "SOFTWARE": build_stub_hive("SOFTWARE"),
        "SECURITY": build_stub_hive("SECURITY"),
    }
    for fname, data in hives.items():
        path = os.path.join(out, fname)
        with open(path, 'wb') as f:
            f.write(data)
        print(f"  wrote {path}  ({len(data)} bytes)")
