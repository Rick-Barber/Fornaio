param([switch]$Package, [ValidateRange(1, 256)][int]$Jobs = 8)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
$buildDirectory = Join-Path $projectRoot '.build'
$appDirectory = Join-Path $projectRoot 'dist\Fornaio'
$testDirectory = Join-Path $buildDirectory 'Release'
New-Item -ItemType Directory -Force -Path $buildDirectory | Out-Null
$buildFolder = Get-Item -LiteralPath $buildDirectory -Force
$buildFolder.Attributes = $buildFolder.Attributes -bor [IO.FileAttributes]::Hidden
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'Visual Studio C++ build tools are required.' }
$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
$envLines = & cmd.exe /d /c "call `"$vcvars`" >nul && set"
if ($LASTEXITCODE) { throw 'Could not initialize the Visual Studio environment.' }
foreach ($line in $envLines) { if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') } }
$cmake = Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$qt = Join-Path $projectRoot '.deps\Qt\6.8.3\msvc2022_64'
if (-not (Test-Path "$qt\lib\cmake\Qt6")) { throw 'Install Qt as described in README.md first.' }
& $cmake -S . -B $buildDirectory -G 'Visual Studio 17 2022' -A x64 "-DCMAKE_PREFIX_PATH=$qt"
if ($LASTEXITCODE) { throw 'CMake configure failed.' }
# Fornaio doesn't use vcpkg; opt out of the machine-wide MSBuild integration.
& $cmake --build $buildDirectory --config Release --parallel $Jobs -- /p:VCPkgLocalAppDataDisabled=true /nodeReuse:false
if ($LASTEXITCODE) { throw 'Build failed.' }
# Qt can emit non-fatal diagnostics on stderr. On Windows PowerShell those must
# not bypass the actual process exit-code check under ErrorActionPreference=Stop.
$deployPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $deployMessages = & "$qt\bin\windeployqt.exe" --release --no-translations --no-system-d3d-compiler --no-system-dxc-compiler --no-opengl-sw --no-compiler-runtime "$appDirectory\Fornaio.exe" 2>&1
    $deployExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $deployPreference
}
$deployMessages | ForEach-Object { Write-Host $_ }
if ($deployExit) { throw 'Qt deployment failed.' }
# The optional private Python engine also needs the app-local MSVC runtime on clean Windows.
$redist = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory | Where-Object Name -Match '^14\.' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$crt = Join-Path $redist.FullName 'x64\Microsoft.VC143.CRT'
Get-ChildItem -LiteralPath $crt -Filter '*.dll' | Copy-Item -Destination $appDirectory -Force
# Every build refreshes the runnable portable folder; archives are optional.
if ($Package) { & "$PSScriptRoot\package.ps1" }
else { & "$PSScriptRoot\package.ps1" -StageOnly }
# Development tests stay with CMake's intermediate files, without another app/CLI copy.
Get-ChildItem -LiteralPath $appDirectory -Filter '*.dll' | Copy-Item -Destination $testDirectory -Force
Copy-Item -LiteralPath "$qt\bin\Qt6Test.dll" -Destination $testDirectory -Force
foreach ($name in @('platforms','imageformats','styles','generic','networkinformation','tls','ai')) {
    if (Test-Path "$appDirectory\$name") { Copy-Item -LiteralPath "$appDirectory\$name" -Destination $testDirectory -Recurse -Force }
}
Write-Host "Application ready: $appDirectory\Fornaio.exe"
