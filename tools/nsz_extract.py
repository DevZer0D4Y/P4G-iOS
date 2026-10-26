#!/usr/bin/env python3
"""Extract a game's ExeFS and RomFS straight out of an NSZ (or an NSP whose program content is an NCZ).

Usage: nsz_extract.py <game.nsz> <prod.keys> <outdir> [--list] [--exefs-only]

An NCZ stores the NCA's sections already decrypted, compressed as one zstd stream after the NCA's first 0x4000 bytes,
so the files are read off that stream in order and nothing the size of the NCA is ever written. Only the NCA header
is decrypted (header_key, AES-XTS) to find the sections. Writes <outdir>/exefs/ and <outdir>/romfs/.
Key values are never printed.
"""
import argparse
import os
import struct
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from zstandard import ZstdDecompressor

NCZ_HEADER = 0x4000


def load_key(path, name):
    for line in open(path, encoding='utf-8', errors='replace'):
        k, _, v = line.partition('=')
        if k.strip() == name:
            return bytes.fromhex(v.strip())
    sys.exit(f'{name} not in {path}')


def xts_decrypt(key, data, sector_size=0x200):
    # Nintendo's tweak is the sector number as a 16-byte big-endian integer
    out = bytearray()
    for i in range(len(data) // sector_size):
        d = Cipher(algorithms.AES(key), modes.XTS(i.to_bytes(16, 'big'))).decryptor()
        out += d.update(data[i * sector_size:(i + 1) * sector_size]) + d.finalize()
    return bytes(out)


def pfs0_entries(f, base=0):
    f.seek(base)
    hdr = f.read(16)
    if hdr[:4] != b'PFS0':
        sys.exit(f'no PFS0 at {base:#x}')
    n, st = struct.unpack('<II', hdr[4:12])
    ents = [struct.unpack('<QQII', f.read(24)) for _ in range(n)]
    strs = f.read(st)
    data = base + 16 + 24 * n + st
    return [(strs[so:strs.index(b'\0', so)].decode(), data + off, size) for off, size, so, _ in ents]


class Stream:
    """Sequential reader over the NCA's plaintext, positioned in NCA offsets (starting at 0x4000)."""

    def __init__(self, f, start):
        f.seek(start)
        self.r = ZstdDecompressor().stream_reader(f, read_size=1 << 20, read_across_frames=True)
        self.pos = NCZ_HEADER

    def skip_to(self, off):
        if off < self.pos:
            raise ValueError(f'stream already past {off:#x} (at {self.pos:#x})')
        while self.pos < off:
            n = len(self.r.read(min(off - self.pos, 1 << 22)))
            if not n:
                raise EOFError
            self.pos += n

    def read(self, size):
        out = bytearray()
        while len(out) < size:
            b = self.r.read(min(size - len(out), 1 << 22))
            if not b:
                raise EOFError
            out += b
        self.pos += len(out)
        return bytes(out)

    def copy(self, size, w):
        left = size
        while left:
            b = self.r.read(min(left, 1 << 22))
            if not b:
                raise EOFError
            w.write(b)
            left -= len(b)
        self.pos += size


def romfs_files(meta):
    """meta: the RomFS bytes up to the end of its file table. Yields (path, data offset, size)."""
    (hsz, dh_off, dh_sz, dt_off, dt_sz, fh_off, fh_sz, ft_off, ft_sz, data_off) = struct.unpack_from('<10Q', meta, 0)
    dirs = meta[dt_off:dt_off + dt_sz]
    files = meta[ft_off:ft_off + ft_sz]

    def name(tbl, o, hdr):
        ln = struct.unpack_from('<I', tbl, o + hdr - 4)[0]
        return tbl[o + hdr:o + hdr + ln].decode('utf-8')

    out = []

    def walk(d, path):
        parent, sib, child, first_file, nxt = struct.unpack_from('<5I', dirs, d)
        f = first_file
        while f != 0xFFFFFFFF:
            fparent, fsib, foff, fsize, fnext = struct.unpack_from('<IIQQI', files, f)
            out.append((path + name(files, f, 0x20), data_off + foff, fsize))
            f = fsib
        c = child
        while c != 0xFFFFFFFF:
            walk(c, path + name(dirs, c, 0x18) + '/')
            c = struct.unpack_from('<I', dirs, c + 4)[0]

    walk(0, '')
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('nsz')
    ap.add_argument('keys')
    ap.add_argument('outdir')
    ap.add_argument('--list', action='store_true', help='list the RomFS without writing it')
    ap.add_argument('--exefs-only', action='store_true')
    a = ap.parse_args()

    f = open(a.nsz, 'rb')
    ncz = [e for e in pfs0_entries(f) if e[0].endswith('.ncz')]
    if len(ncz) != 1:
        sys.exit(f'expected one .ncz in the container, found {len(ncz)}')
    _, nca, nca_size = ncz[0]

    f.seek(nca)
    hdr = xts_decrypt(load_key(a.keys, 'header_key'), f.read(0xC00))
    if hdr[0x200:0x204] not in (b'NCA3', b'NCA2'):
        sys.exit('NCA header did not decrypt (wrong header_key?)')
    tid = struct.unpack_from('<Q', hdr, 0x210)[0]
    print(f'title {tid:016X}, content type {hdr[0x205]}, sdk {".".join(str(b) for b in hdr[0x21C:0x220][::-1])}')

    sections = []
    for i in range(4):
        start, end = struct.unpack_from('<II', hdr, 0x240 + i * 0x10)
        if not end:
            continue
        fsh = hdr[0x400 + i * 0x200:0x600 + i * 0x200]
        fs_type, hash_type, enc = fsh[2], fsh[3], fsh[4]
        base = start * 0x200
        if hash_type == 2:  # hierarchical SHA-256: the PFS0 is layer 2
            data = base + struct.unpack_from('<Q', fsh, 0x40)[0]  # hash data +0x38: layer regions (hash table, PFS0)
        elif hash_type == 3:  # IVFC: the RomFS is level 6
            data = base + struct.unpack_from('<Q', fsh, 0x8 + 0x10 + 5 * 0x18)[0]
        else:
            sys.exit(f'section {i}: hash type {hash_type} not handled')
        sections.append((data, i, 'pfs0' if fs_type == 1 else 'romfs', end * 0x200))
        print(f'section {i}: {"PFS0" if fs_type == 1 else "RomFS"} data at {data:#x}, encryption {enc}')
    sections.sort()

    s = Stream(f, ncz_stream_start(f, nca))
    for data, i, kind, end in sections:
        if kind == 'pfs0':
            s.skip_to(data)
            head = s.read(16)
            n, st = struct.unpack('<II', head[4:12])
            rest = s.read(24 * n + st)
            ents = [struct.unpack_from('<QQII', rest, k * 24) for k in range(n)]
            strs = rest[24 * n:]
            dbase = data + 16 + 24 * n + st
            out = os.path.join(a.outdir, 'exefs' if i == 0 else 'logo')
            os.makedirs(out, exist_ok=True)
            for off, size, so, _ in sorted(ents):
                nm = strs[so:strs.index(b'\0', so)].decode()
                s.skip_to(dbase + off)
                with open(os.path.join(out, nm), 'wb') as w:
                    s.copy(size, w)
                print(f'  exefs/{nm} {size:,}')
            if a.exefs_only and i == 0:
                return
        else:
            if a.exefs_only:
                continue
            s.skip_to(data)
            head = s.read(0x50)
            hsz, _, _, dt_off, dt_sz, _, _, ft_off, ft_sz, data_off = struct.unpack_from('<10Q', head, 0)
            lo, hi = min(dt_off, ft_off), max(dt_off + dt_sz, ft_off + ft_sz)
            if lo >= data_off:
                # the tables follow the file data: read them with a second pass over the stream, then come back
                g = open(a.nsz, 'rb')  # (its own handle: the main stream reads on from f)
                t = Stream(g, ncz_stream_start(g, nca))
                t.skip_to(data + lo)
                meta = bytearray(hi)
                meta[:0x50] = head
                meta[lo:hi] = t.read(hi - lo)
                meta = bytes(meta)
            else:
                meta = head + s.read(hi - 0x50)
            files = sorted(romfs_files(meta), key=lambda e: e[1])
            total = sum(e[2] for e in files)
            print(f'  romfs: {len(files):,} files, {total / 2**30:.2f} GiB')
            if a.list:
                for p, _, sz in files:
                    print(f'    {sz:>14,}  {p}')
                continue
            root = os.path.join(a.outdir, 'romfs')
            done = 0
            for p, off, sz in files:
                dst = os.path.join(root, p)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                s.skip_to(data + off)
                with open(dst, 'wb') as w:
                    s.copy(sz, w)
                done += sz
                print(f'\r  romfs {done / 2**30:6.2f} / {total / 2**30:.2f} GiB', end='', flush=True)
            print()


def ncz_stream_start(f, nca):
    f.seek(nca + NCZ_HEADER)
    if f.read(8) != b'NCZSECTN':
        sys.exit('no NCZSECTN header: not an NCZ')
    count = struct.unpack('<Q', f.read(8))[0]
    start = nca + NCZ_HEADER + 16 + 64 * count
    f.seek(start)
    if f.read(8) == b'NCZBLOCK':
        sys.exit('block-compressed NCZ not handled yet')
    return start


if __name__ == '__main__':
    main()
