param([string]$BuildRoot, [switch]$Install, [string]$SmoothLoadingSource)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $BuildRoot) { $BuildRoot = Join-Path 'E:\Codex' ((Split-Path $projectRoot -Leaf) + '\native-build') }
New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
$env:TEMP = $BuildRoot
$env:TMP = $BuildRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$configure = @('-S', $PSScriptRoot, '-B', $BuildRoot, '-G', 'Visual Studio 17 2022', '-A', 'x64')
if ($SmoothLoadingSource) {
    $sourcePath = (Resolve-Path -LiteralPath $SmoothLoadingSource).Path
    $configure += "-DSMOOTH_LOADING_SOURCE=$sourcePath"
} else {
    $configure += '-DSMOOTH_LOADING_SOURCE='
}
& $cmake @configure
if ($LASTEXITCODE) { throw 'CMake 配置失败' }
& $cmake --build $BuildRoot --config Release --parallel 4
if ($LASTEXITCODE) { throw '原生构建失败' }
& (Join-Path (Split-Path $cmake -Parent) 'ctest.exe') --test-dir $BuildRoot -C Release --output-on-failure
if ($LASTEXITCODE) { throw '原生测试失败' }
if ($Install) {
    $destination = Join-Path $projectRoot 'native'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $BuildRoot 'Release\dst_fastloading_native.dll') -Destination (Join-Path $destination 'dst_fastloading_native.dll.pkg') -Force
    Write-Host '已更新发布包；运行副本在下次启动时生成。请完整退出游戏后测试。'
}
