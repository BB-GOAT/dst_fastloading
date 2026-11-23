"""在独立 LuaJIT VM 中验证 Win32 加载器，不向游戏进程安装补丁。依赖 lupa.luajit21。"""
from pathlib import Path
import ctypes
import gc
import shutil
import subprocess
import sys
import lupa.luajit21 as luajit

project = Path(__file__).parents[2]
base = Path(sys.argv[1]).resolve()
def vm(root, workshop=None):
    runtime = luajit.LuaRuntime()
    runtime.execute('_G = _G')
    if workshop:
        runtime.globals().workshop_path = workshop.as_posix()
        runtime.execute('GameInjector = { DS_LUAJIT_get_workshop_dir = function() return workshop_path end }')
    disk_factory = runtime.execute((project / 'main/loading_index_disk.lua').read_text(encoding='utf-8'))
    disk = disk_factory(runtime.table_from({'game_root': base.as_posix()}))
    loader = runtime.execute((project / 'main/native_loading.lua').read_text(encoding='utf-8'))
    opts = runtime.table_from({'ffi': runtime.eval('require("ffi")'), 'disk': disk,
        'root': root.as_posix(), 'name': 'workshop-1234' if workshop else 'test_mod', 'flags': 3})
    return runtime, loader, opts

def fixture(root):
    (root / 'native').mkdir(parents=True)
    (root / 'modinfo.lua').write_text('name="loader test"', encoding='utf-8')
    shutil.copy2(project / 'native/dst_fastloading_native.dll.pkg', root / 'native/dst_fastloading_native.dll.pkg')
    return root / 'native'

if len(sys.argv) == 2:
    for case in ['local', 'chinese', 'vm_reload', 'missing', 'corrupt', 'conflict', 'workshop']:
        subprocess.run([sys.executable, __file__, str(base), case], check=True)
    print('Loader: 7 isolated scenarios passed.')
else:
    case = sys.argv[2]
    root = base / case / ('中文 模组' if case == 'chinese' else 'mod')
    workshop = base / case / 'workshop' if case == 'workshop' else None
    if workshop:
        root = workshop / '1234'
    native = fixture(root)
    package = native / 'dst_fastloading_native.dll.pkg'
    running = native / 'dst_fastloading_native.dll'
    if case == 'missing':
        package.unlink()
        running.write_bytes(b'old file')
    if case == 'corrupt':
        package.write_bytes(b'broken package')
        running.write_bytes(b'old file')
    if case == 'conflict':
        other = fixture(base / case / 'other')
        shutil.copy2(other / package.name, other / running.name)
        held = ctypes.WinDLL(str(other / running.name))
    runtime, loader, opts = vm(base / 'nonexistent' if workshop else root, workshop)
    try:
        status = loader(opts)
        assert case not in ['missing', 'corrupt', 'conflict']
        assert status == 0
        assert running.read_bytes() == package.read_bytes()
        assert 'Unsupported executable' in (native / 'fastloading_native.log').read_text()
        if case in ['local', 'vm_reload']:
            first = running.stat().st_mtime_ns
            # 发布源可被更新，当前进程复用原模块，不覆盖在用 DLL。
            with package.open('ab') as f:
                f.write(b'update marker')
            if case == 'vm_reload':
                del loader, opts, runtime
                gc.collect()
                runtime, loader, opts = vm(root)
            assert loader(opts) == 0
            assert running.stat().st_mtime_ns == first
            log = (native / 'fastloading_native.log').read_text()
            assert 'Configuration changed' not in log
            # 功能未安装不等于用户修改配置；真正改变请求才提示完整退出。
            opts.flags = 2
            assert loader(opts) == 0
            assert 'Configuration changed since initialization' in (native / 'fastloading_native.log').read_text()
    except luajit.LuaError:
        assert case in ['missing', 'corrupt', 'conflict']
        if case in ['missing', 'corrupt']:
            assert running.read_bytes() == b'old file'
    assert not list(native.glob('*.tmp'))
    print('Loader passed:', case)
