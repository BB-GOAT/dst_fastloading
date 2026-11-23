"""只读验证特征唯一性，以及地址重定位与私有布局变化的处理边界。"""
from pathlib import Path
import re
import sys

header = (Path(__file__).parents[1] / 'src/zip_patterns.h').read_text(encoding='utf-8')
image = Path(sys.argv[1]).read_bytes()
for name in ['read', 'close']:
    definition = re.search(r'zip_' + name + r'_pattern =(.*?);', header, re.S).group(1)
    tokens = ''.join(re.findall(r'"(.*?)"', definition)).split()
    regex = b''.join(b'.' if token == '??' else re.escape(bytes.fromhex(token)) for token in tokens)
    matches = list(re.finditer(regex, image, re.S))
    assert len(matches) == 1, (name, len(matches))
    raw = bytearray(matches[0].group())
    for i, token in enumerate(tokens):
        if token == '??':
            raw[i] ^= 0xA5
    assert re.fullmatch(regex, raw, re.S)
    # 读/关闭均从 file+0xC8 取得读取状态；变化后必须拒绝该实现。
    field = raw.find(bytes.fromhex('C8 00 00 00'))
    assert field >= 0
    raw[field] = 0xD0
    assert not re.fullmatch(regex, raw, re.S)
    print(f'{name}: unique match at file offset {matches[0].start():#x}; relocation accepted; changed layout rejected')
