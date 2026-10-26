"""plt.py <nso> <addr> [count]: disassemble from addr, naming PLT calls (bl to an import stub) by their symbol."""
import sys

import capstone

from nso import Nso


def plt_name(n, img, md, t):
    ins = list(md.disasm(img[t:t + 8], t))
    if len(ins) < 2 or ins[0].mnemonic != 'adrp' or ins[1].mnemonic != 'ldr':
        return None
    page = int(ins[0].op_str.split('#')[1], 16)
    off = int(ins[1].op_str.split('#')[1].rstrip(']'), 16) if '#' in ins[1].op_str else 0
    for o, typ, sym, add in n.relocs:
        if o == page + off and isinstance(sym, int):
            return n.syms[sym][0]
    return None


def main():
    n = Nso(sys.argv[1])
    a, count = int(sys.argv[2], 16), int(sys.argv[3]) if len(sys.argv) > 3 else 80
    img = bytes(n.image[:n.text[0] + n.text[1]])
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    for i in md.disasm(img[a:a + 4 * count], a):
        note = ''
        if i.mnemonic in ('bl', 'b'):
            t = int(i.op_str.lstrip('#'), 16)
            note = plt_name(n, img, md, t) or ''
        print(f'{i.address:#x}  {i.mnemonic:6} {i.op_str}  {note}')
        if i.mnemonic == 'ret':
            break


if __name__ == '__main__':
    main()
