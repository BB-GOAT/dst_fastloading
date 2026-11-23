"""用 x64 指令模拟器比较两个循环的内存及寄存器结果。依赖 unicorn。"""
from pathlib import Path
import random
import re
from unicorn import Uc, UC_ARCH_X86, UC_MODE_64
from unicorn import x86_const as reg

source = (Path(__file__).parents[1] / 'src/plugin.cpp').read_text(encoding='utf-8')
def code(name):
    match = re.search(r'unsigned char ' + name + r'\[\] = \{(.*?)\};', source, re.S)
    return bytes(int(v.strip(), 0) for v in match.group(1).split(',') if v.strip())

registers = [getattr(reg, 'UC_X86_REG_' + name) for name in
             ['RAX', 'RBX', 'RCX', 'RDX', 'RSI', 'RDI', 'RBP', 'RSP', 'R8', 'R9', 'R10', 'R11', 'R12', 'R13', 'R14', 'R15', 'EFLAGS']]
def execute(binary, variant, count, value, alias):
    uc = Uc(UC_ARCH_X86, UC_MODE_64)
    for address in [0x100000, 0x200000, 0x300000, 0x400000]:
        uc.mem_map(address, 0x20000)
    uc.mem_write(0x100000, binary)
    uc.mem_write(0x300000, bytes([0xA7]) * 0x20000)
    for i, register in enumerate(registers[:-1]):
        uc.reg_write(register, 0x12340000 + i * 0x100)
    uc.reg_write(reg.UC_X86_REG_RSP, 0x210000)
    uc.reg_write(reg.UC_X86_REG_EFLAGS, 0x202)
    if variant == 'a':
        uc.reg_write(reg.UC_X86_REG_RBX, count)
        uc.reg_write(reg.UC_X86_REG_RSI, 0x300100)
        pointer = 0x300100 + max(0, count // 2) if alias else 0x400000
        uc.mem_write(pointer, bytes([value]))
        uc.reg_write(reg.UC_X86_REG_R13, pointer)
    else:
        uc.reg_write(reg.UC_X86_REG_RAX, count)
        uc.reg_write(reg.UC_X86_REG_RCX, 0x300100)
        uc.reg_write(reg.UC_X86_REG_R12, value | 0x7ABC0000)
    uc.emu_start(0x100000, 0x100000 + len(binary))
    return ([uc.reg_read(r) for r in registers], bytes(uc.mem_read(0x300000, 0x20000)), bytes(uc.mem_read(0x210000, 0x80)))

rng = random.Random(143)
cases = 0
for variant in ['a', 'b']:
    for count in [0, 1, 2, 15, 16, 257, 16384, 65537] + [rng.randrange(0, 2048) for _ in range(20)]:
        for value in [0, 1, 127, 255]:
            for alias in [False, True]:
                original = execute(code('signature_' + variant), variant, count, value, alias)
                replacement = execute(code('code_' + variant), variant, count, value, alias)
                assert original == replacement, (variant, count, value, alias)
                cases += 1
print(f'Fill equivalence: {cases} cases passed (GPR, RFLAGS, stack outputs, memory).')
