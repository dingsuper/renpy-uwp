# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds the media dependencies of Ren'Py for UWP x64 (static, MSVC) into $Prefix:
# libpng, libjpeg-turbo, libwebp, freetype (+harfbuzz), harfbuzz, fribidi, SDL2_image, FFmpeg (LGPL).
# Needs: MSVC environment (cl/link in PATH), CMake, NASM in PATH, MSYS2 at C:\msys64 (make, diffutils).
# zlib comes from the CPython build ($ZlibPrefix: include/zlib, lib/zlibstatic.lib).

param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$ZlibPrefix,
    [Parameter(Mandatory = $true)][string]$SdlPrefix,
    [string]$WorkDir = (Join-Path $env:RUNNER_TEMP 'media-deps')
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'version.ps1')

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE" }
}

$tars = New-Item -ItemType Directory -Force (Join-Path $WorkDir 'tars')
$srcRoot = New-Item -ItemType Directory -Force (Join-Path $WorkDir 'src')
$buildRoot = New-Item -ItemType Directory -Force (Join-Path $WorkDir 'build')
New-Item -ItemType Directory -Force (Join-Path $Prefix 'licenses') | Out-Null
$Prefix = (Resolve-Path $Prefix).Path

function Get-Source([string]$key, [string]$into = '') {
    $d = $MediaDeps[$key]
    $tar = Join-Path $tars $d.file
    if (-not (Test-Path $tar)) {
        Write-Host "Downloading $($d.url)"
        # curl with retries and a hard time limit: an Invoke-WebRequest download from GitHub hung for
        # 58 minutes in CI and the whole job timed out.
        $t0 = Get-Date
        Invoke-Checked "download $($d.file)" {
            curl.exe -fsSL --retry 4 --retry-delay 5 --retry-all-errors --connect-timeout 30 --max-time 900 -A 'renpy-uwp-ci' -o $tar $d.url
        }
        Write-Host "Downloaded $($d.file) in $([int]((Get-Date) - $t0).TotalSeconds) s"
    }
    $h = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLowerInvariant()
    if ($d.sha) {
        if ($h -ne $d.sha) { throw "SHA-256 mismatch for $($d.file): $h" }
    } else {
        # No pinned hash yet (candidate dependency): print it so it can be pinned in version.ps1.
        Write-Host "WARNING: no pinned SHA-256 for $($d.file); computed $h"
    }
    # Archives with a top-level directory are unpacked next to each other in $srcRoot (several builds
    # reuse the same tree, e.g. freetype twice), so only that archive's own directory is removed.
    # Archives without one (googlesource) are unpacked into the dedicated $into directory instead.
    if ($into) {
        $target = Join-Path $srcRoot $into
        if (Test-Path $target) { Remove-Item -Recurse -Force $target }
        New-Item -ItemType Directory -Force $target | Out-Null
        $extractTo = $target
    } else {
        $extractTo = $srcRoot
        $own = Join-Path $srcRoot ($d.file -replace '\.tar\.(gz|xz|bz2)$', '')
        if (Test-Path $own) { Remove-Item -Recurse -Force $own }
        $archiveDir = $own
    }
    $t0 = Get-Date
    Invoke-Checked "extract $($d.file)" {
        python -I -c "import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2], filter='data')" $tar $extractTo
    }
    Write-Host "Extracted $($d.file) in $([int]((Get-Date) - $t0).TotalSeconds) s"
    if ($into) { return $extractTo }
    return $archiveDir
}

function Copy-License([string]$src, [string]$name, [string[]]$candidates) {
    foreach ($c in $candidates) {
        $f = Join-Path $src $c
        if (Test-Path $f) { Copy-Item $f (Join-Path $Prefix "licenses\$name-$((Split-Path $c -Leaf))"); }
    }
}

# --- tools: NASM must be on PATH (libjpeg-turbo and dav1d assemble with it) -----------------------
# Run #4 (2026-11-17) failed in libjpeg with "'NASM-NOTFOUND' is not recognized": the choco step was a
# no-op because the image already ships NASM somewhere that is not on PATH for pwsh steps. Discover it.
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    $candidates = @("$env:ProgramFiles\NASM", "${env:ProgramFiles(x86)}\NASM",
        "$env:ProgramData\chocolatey\bin", "$env:ChocolateyInstall\bin",
        "$env:SystemDrive\ProgramData\chocolatey\lib\nasm\tools\nasm")
    foreach ($dir in $candidates) {
        if ($dir -and (Test-Path (Join-Path $dir 'nasm.exe'))) {
            $env:PATH = "$dir;$env:PATH"
            Write-Host "NASM found at $dir (added to PATH)"
            break
        }
    }
}
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) { throw 'NASM not found (install it or add it to PATH)' }
& nasm -v

$zinc = Join-Path $ZlibPrefix 'include\zlib'
$zlib = Join-Path $ZlibPrefix 'lib\zlibstatic.lib'
$cflags = '/DWIN32 /D_WINDOWS /W3 /sdl- /D_CRT_SECURE_NO_WARNINGS'
$common = @(
    '-G', 'Visual Studio 17 2022', '-A', 'x64',
    '-DCMAKE_SYSTEM_NAME=WindowsStore', '-DCMAKE_SYSTEM_VERSION=10.0.22621.0',
    "-DCMAKE_INSTALL_PREFIX=$Prefix", "-DCMAKE_PREFIX_PATH=$Prefix",
    '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
    "-DCMAKE_C_FLAGS=$cflags", "-DCMAKE_CXX_FLAGS=$cflags /EHsc /GR"
)

function Find-InstalledLib([string]$pattern) {
    # Meson/MSVC naming and layout vary (dav1d.lib vs libdav1d.lib, lib\ vs lib\x64\): search.
    Get-ChildItem -Recurse -File (Join-Path $Prefix 'lib') -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1
}

function Build-CMake([string]$name, [string]$src, [string[]]$extra, [string]$target = '') {
    $b = Join-Path $buildRoot $name
    if (Test-Path $b) { Remove-Item -Recurse -Force $b }
    Write-Host "=== $name"
    # Tool output goes to the host: only the build directory is returned.
    Invoke-Checked "$name configure" { cmake -S $src -B $b @common @extra | Out-Host }
    if ($target) {
        Invoke-Checked "$name build" { cmake --build $b --config Release --parallel --target $target -- /nologo /v:minimal | Out-Host }
    } else {
        Invoke-Checked "$name build" { cmake --build $b --config Release --parallel -- /nologo /v:minimal | Out-Host }
        Invoke-Checked "$name install" { cmake --install $b --config Release | Out-Host }
    }
    return $b
}

# --- zlib for consumers that expect z.lib / zlib.h in the prefix (FFmpeg -lz, FindZLIB) -------
New-Item -ItemType Directory -Force (Join-Path $Prefix 'lib'), (Join-Path $Prefix 'include') | Out-Null
Copy-Item $zlib (Join-Path $Prefix 'lib\z.lib')
# FFmpeg's msvc toolchain maps -lz to zlib.lib (configure, msvc_flags).
Copy-Item $zlib (Join-Path $Prefix 'lib\zlib.lib')
Copy-Item (Join-Path $zinc '*.h') (Join-Path $Prefix 'include')
# zconf.h tests HAVE_UNISTD_H / HAVE_STDARG_H with #ifdef, but FFmpeg's config.h defines them to 0,
# which pulls in <unistd.h> (absent in MSVC). Make the prefix copy honour the value.
$zconf = Join-Path $Prefix 'include\zconf.h'
$zc = (Get-Content -Raw $zconf) -replace '#ifdef HAVE_UNISTD_H', '#if defined(HAVE_UNISTD_H) && (HAVE_UNISTD_H + 0)' `
                                 -replace '#ifdef HAVE_STDARG_H', '#if defined(HAVE_STDARG_H) && (HAVE_STDARG_H + 0)'
if ($zc -notmatch [regex]::Escape('(HAVE_UNISTD_H + 0)')) { throw 'zconf.h patch did not apply' }
Set-Content -NoNewline -Path $zconf -Value $zc
$zlibArgs = @("-DZLIB_INCLUDE_DIR=$(Join-Path $Prefix 'include')", "-DZLIB_LIBRARY=$(Join-Path $Prefix 'lib\z.lib')")

# --- libpng -----------------------------------------------------------------------------------
$s = Get-Source 'libpng'
Build-CMake 'libpng' $s (@('-DPNG_SHARED=OFF', '-DPNG_STATIC=ON', '-DPNG_TESTS=OFF', '-DPNG_EXECUTABLES=OFF',
    '-DPNG_TOOLS=OFF', "-DCMAKE_C_FLAGS=$cflags /DPNG_NO_CONSOLE_IO") + $zlibArgs) | Out-Null
Copy-License $s 'libpng' @('LICENSE')
$pngLib = Get-ChildItem (Join-Path $Prefix 'lib') -Filter 'libpng16*.lib' | Select-Object -First 1
Copy-Item $pngLib.FullName (Join-Path $Prefix 'lib\png.lib')

# --- libjpeg-turbo 1.5.3 (old CMake: build only the static library, install by hand) ------------
$s = Get-Source 'libjpeg'
$b = Build-CMake 'libjpeg' $s @('-DENABLE_SHARED=OFF', '-DENABLE_STATIC=ON', '-DWITH_SIMD=ON', '-DWITH_TURBOJPEG=OFF',
    '-DWITH_JAVA=OFF', '-DWITH_CRT_DLL=ON') 'jpeg-static'
$jlib = Get-ChildItem -Recurse $b -Filter 'jpeg-static.lib' | Select-Object -First 1
Copy-Item $jlib.FullName (Join-Path $Prefix 'lib\jpeg.lib')
foreach ($h in 'jpeglib.h', 'jmorecfg.h', 'jerror.h') { Copy-Item (Join-Path $s $h) (Join-Path $Prefix 'include') }
Copy-Item (Get-ChildItem -Recurse $b -Filter 'jconfig.h' | Select-Object -First 1).FullName (Join-Path $Prefix 'include')
Copy-License $s 'libjpeg-turbo' @('LICENSE.md', 'README.ijg')

# --- libwebp (not used by KS:RE; generic runtime) --------------------------------------------
$s = Get-Source 'libwebp'
Build-CMake 'libwebp' $s @('-DWEBP_BUILD_ANIM_UTILS=OFF', '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF',
    '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF', '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF',
    '-DWEBP_BUILD_WEBPMUX=OFF', '-DWEBP_BUILD_EXTRAS=OFF') | Out-Null
Copy-License $s 'libwebp' @('COPYING', 'PATENTS')

# --- freetype (without harfbuzz), harfbuzz (with freetype), freetype again (with harfbuzz) ----
$ftSrc = Get-Source 'freetype'
$pngArgs = @("-DPNG_LIBRARY=$(Join-Path $Prefix 'lib\png.lib')", "-DPNG_PNG_INCLUDE_DIR=$(Join-Path $Prefix 'include')")
$ftCommon = @('-DFT_DISABLE_BROTLI=ON', '-DFT_DISABLE_BZIP2=ON', '-DFT_REQUIRE_ZLIB=ON', '-DFT_REQUIRE_PNG=ON') + $zlibArgs + $pngArgs
Build-CMake 'freetype' $ftSrc (@('-DFT_DISABLE_HARFBUZZ=ON') + $ftCommon) | Out-Null

$s = Get-Source 'harfbuzz'
Build-CMake 'harfbuzz' $s @('-DHB_HAVE_FREETYPE=ON', '-DHB_BUILD_SUBSET=OFF', '-DHB_BUILD_UTILS=OFF',
    "-DFREETYPE_LIBRARY=$(Join-Path $Prefix 'lib\freetype.lib')",
    "-DFREETYPE_INCLUDE_DIRS=$(Join-Path $Prefix 'include\freetype2')",
    "-DFREETYPE_INCLUDE_DIR_freetype2=$(Join-Path $Prefix 'include\freetype2')",
    "-DFREETYPE_INCLUDE_DIR_ft2build=$(Join-Path $Prefix 'include\freetype2')") | Out-Null
Copy-License $s 'harfbuzz' @('COPYING')

Build-CMake 'freetypehb' $ftSrc (@('-DFT_REQUIRE_HARFBUZZ=ON',
    "-DHarfBuzz_INCLUDE_DIR=$(Join-Path $Prefix 'include\harfbuzz')",
    "-DHarfBuzz_LIBRARY=$(Join-Path $Prefix 'lib\harfbuzz.lib')") + $ftCommon) | Out-Null
Copy-License $ftSrc 'freetype' @('LICENSE.TXT', 'docs\FTL.TXT')

# --- fribidi (our CMake) ------------------------------------------------------------------------
$s = Get-Source 'fribidi'
Build-CMake 'fribidi' (Join-Path $here 'fribidi') @("-DFRIBIDI_SRC=$s") | Out-Null
Copy-License $s 'fribidi' @('COPYING')

# --- dav1d (AV1 decoder used by libavif; meson + ninja + NASM) -----------------------------------
# Why dav1d and not aom: we only need to *decode* AVIF, dav1d decodes ~2x faster than libaom on the
# same files and has no encoder to build (aom + its runtime tables would add minutes to every run).
#
# CI gotcha (run #1, 2026-11-17): the whole job runs inside the UWP dev shell, so the CRT is the App
# variant. meson's compiler sanity check links a console exe with /MD and dies with
#   MSVCRT.lib(utility_app.obj) : unresolved external symbol __imp_RoInitialize ...
# => "Compiler cl cannot compile programs". Fix: teach the sanity check to link WindowsApp.lib (which
# exports RoInitialize and every other kernel32 entry point a UWP app container gets) and compile with
# WINAPI_FAMILY=WINAPI_FAMILY_APP so the headers match the App CRT.
$avifBackend = 'dav1d'
$s = $null
$b = $null
try {
    $s = Get-Source 'dav1d'
    foreach ($tool in 'meson', 'ninja') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool is not in PATH (needed by dav1d): python -m pip install --quiet meson ninja"
        }
    }
    $b = Join-Path $buildRoot 'dav1d'
    if (Test-Path $b) { Remove-Item -Recurse -Force $b }
    # meson runs a compiled sanity exe. A UWP/App-container exe cannot be launched from a normal
    # process, so declare a cross build with needs_exe_wrapper: meson then only compiles it.
    $crossFile = Join-Path $buildRoot 'msvc-uwp-cross.txt'
    @'
[binaries]
c = 'cl'
cpp = 'cl'
ar = 'lib'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
'@ | Set-Content -Path $crossFile -Encoding ascii
    Write-Host '=== dav1d (meson, cross file: do not run sanity exe; link WindowsApp.lib)'
    Invoke-Checked 'dav1d setup' {
        meson setup $b $s "--cross-file=$crossFile" --buildtype=release --default-library=static `
            "--prefix=$Prefix" `
            -Denable_tests=false -Denable_tools=false -Denable_examples=false -Denable_docs=false `
            -Denable_asm=true `
            '-Dc_args=/DWINAPI_FAMILY=WINAPI_FAMILY_APP' `
            '-Dc_link_args=WindowsApp.lib' | Out-Host
    }
    Invoke-Checked 'dav1d compile' { meson compile -C $b --jobs $env:NUMBER_OF_PROCESSORS | Out-Host }
    Invoke-Checked 'dav1d install' { meson install -C $b | Out-Host }
    $found = Find-InstalledLib '*dav1d*.lib'
    if (-not $found) {
        Write-Host 'installed files under lib:'
        Get-ChildItem -Recurse (Join-Path $Prefix 'lib') | Select-Object -ExpandProperty FullName | Out-Host
        throw 'no dav1d .lib was installed'
    }
    if ($found.Name -ne 'dav1d.lib') {
        Copy-Item $found.FullName (Join-Path $Prefix 'lib\dav1d.lib') -Force
        $found = Get-Item (Join-Path $Prefix 'lib\dav1d.lib')
    }
    $script:dav1dLibPath = $found.FullName
    Write-Host "dav1d library: $($script:dav1dLibPath)"
    Copy-License $s 'dav1d' @('COPYING')
} catch {
    # Fallback 1: build dav1d with the *desktop* MSVC environment (vcvars64), where a compiled exe can
    # actually run. The resulting static lib is plain C with no OS calls, so it links into the UWP host
    # like zlib/libpng do.
    Write-Host "WARNING: dav1d (UWP cross) failed: $($_.Exception.Message)"
    Write-Host '--- retrying dav1d with the desktop MSVC environment'
    try {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (-not $vsPath) { throw 'vswhere found no VC toolset' }
        $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
        if (-not (Test-Path $vcvars)) { throw "missing $vcvars" }
        if (Test-Path $b) { Remove-Item -Recurse -Force $b }
        $line = 'set "CL=" && set "WINAPI_FAMILY=" && call "' + $vcvars + '" >nul && ' +
            'meson setup "' + $b + '" "' + $s + '" --buildtype=release --default-library=static "--prefix=' + $Prefix + '" ' +
            '-Denable_tests=false -Denable_tools=false -Denable_examples=false -Denable_docs=false -Denable_asm=true && ' +
            'meson compile -C "' + $b + '" && meson install -C "' + $b + '"'
        Invoke-Checked 'dav1d (desktop MSVC)' { cmd /c $line | Out-Host }
        $found = Find-InstalledLib '*dav1d*.lib'
        if (-not $found) { throw 'no dav1d .lib after the desktop build' }
        if ($found.Name -ne 'dav1d.lib') {
            Copy-Item $found.FullName (Join-Path $Prefix 'lib\dav1d.lib') -Force
            $found = Get-Item (Join-Path $Prefix 'lib\dav1d.lib')
        }
        $script:dav1dLibPath = $found.FullName
        Write-Host "dav1d library: $($script:dav1dLibPath)"
        Copy-License $s 'dav1d' @('COPYING')
    } catch {
        # Fallback 2: libaom (CMake project, already builds under the UWP CMake settings used above).
        Write-Host "WARNING: dav1d (desktop MSVC) failed: $($_.Exception.Message)"
        Write-Host '--- falling back to libaom'
        $avifBackend = 'aom'
        $aom = Get-Source 'aom' 'aom'
        Build-CMake 'aom' $aom @('-DAOM_TARGET_CPU=x64', '-DENABLE_DOCS=OFF', '-DENABLE_TESTS=OFF',
            '-DENABLE_TOOLS=OFF', '-DENABLE_EXAMPLES=OFF', '-DENABLE_TESTDATA=OFF', '-DENABLE_NASM=ON',
            '-DCONFIG_AV1_ENCODER=0', '-DCONFIG_AV1_DECODER=1', '-DCONFIG_PIC=0', '-DENABLE_WERROR=OFF') | Out-Null
        Copy-License $aom 'aom' @('LICENSE', 'PATENTS')
        $aomLib = Find-InstalledLib '*aom*.lib'
        if (-not $aomLib) { throw 'libaom did not install a .lib' }
        Write-Host "aom library: $($aomLib.FullName)"
        if ($aomLib.Name -ne 'aom.lib') { Copy-Item $aomLib.FullName (Join-Path $Prefix 'lib\aom.lib') }
    }
}
Write-Host "AVIF decoder backend: $avifBackend"

# The host project (RenpyUWP.vcxproj) links dav1d.lib unconditionally; when the aom fallback is in
# use there is no dav1d at all, so provide an empty stand-in library instead of touching the vcxproj.
if ($avifBackend -eq 'aom') {
    $eb = Join-Path $buildRoot 'emptylib'
    New-Item -ItemType Directory -Force $eb | Out-Null
    Set-Content -Path (Join-Path $eb 'empty.c') -Value '/* stand-in: libavif was built with libaom */' -Encoding ascii
    Invoke-Checked 'empty dav1d obj' { cl /c /nologo "/Fo$eb\empty.obj" "$eb\empty.c" | Out-Host }
    Invoke-Checked 'empty dav1d lib' { lib /nologo "/out:$(Join-Path $Prefix 'lib\dav1d.lib')" "$eb\empty.obj" | Out-Host }
}

# --- libavif (decode only) -----------------------------------------------------------------------
$s = Get-Source 'libavif'
$avifArgs = @('-DBUILD_SHARED_LIBS=OFF', '-DAVIF_ENABLE_WERROR=OFF',
    '-DAVIF_BUILD_APPS=OFF', '-DAVIF_BUILD_EXAMPLES=OFF', '-DAVIF_BUILD_TESTS=OFF',
    '-DAVIF_BUILD_MAN_PAGES=OFF', '-DAVIF_ENABLE_GTEST=OFF')
if ($avifBackend -eq 'dav1d') {
    $avifArgs += @('-DAVIF_CODEC_DAV1D=ON', '-DAVIF_CODEC_AOM=OFF', '-DAVIF_CODEC_LIBGAV1=OFF',
        '-DAVIF_CODEC_RAV1E=OFF', '-DAVIF_CODEC_SVT=OFF',
        "-DDAV1D_INCLUDE_DIR=$(Join-Path $Prefix 'include')",
        "-DDAV1D_LIBRARY=$($script:dav1dLibPath)")
} else {
    $avifArgs += @('-DAVIF_CODEC_AOM=ON', '-DAVIF_CODEC_DAV1D=OFF', '-DAVIF_CODEC_LIBGAV1=OFF',
        '-DAVIF_CODEC_RAV1E=OFF', '-DAVIF_CODEC_SVT=OFF', '-DAVIF_CODEC_AOM_DECODE=ON',
        '-DAVIF_CODEC_AOM_ENCODE=OFF',
        "-DAOM_INCLUDE_DIR=$(Join-Path $Prefix 'include')",
        "-DAOM_LIBRARY=$(Join-Path $Prefix 'lib\aom.lib')")
}
Build-CMake 'libavif' $s $avifArgs | Out-Null
Copy-License $s 'libavif' @('LICENSE')
if (-not (Test-Path (Join-Path $Prefix 'lib\avif.lib'))) { throw 'libavif.lib was not installed' }

# --- SDL2_image (our CMake) ---------------------------------------------------------------------
$s = Get-Source 'sdl2_image'
Build-CMake 'sdl2_image' (Join-Path $here 'sdl2_image') @("-DSDL2_IMAGE_SRC=$s", "-DSDL2_DIR_PREFIX=$SdlPrefix",
    "-DDEPS_PREFIX=$Prefix") | Out-Null
Copy-License $s 'SDL2_image' @('LICENSE.txt')

# --- FFmpeg (MSYS2 bash, MSVC toolchain) --------------------------------------------------------
$s = Get-Source 'ffmpeg'
$bash = 'C:\msys64\usr\bin\bash.exe'
$env:MSYS2_PATH_TYPE = 'inherit'
$env:CHERE_INVOKING = '1'
Invoke-Checked 'msys2 packages' { & $bash -lc 'pacman -S --noconfirm --needed make diffutils patch' }
# MSYS2's /usr/bin/link would shadow MSVC's link.exe.
Invoke-Checked 'hide msys link' { & $bash -lc 'test ! -e /usr/bin/link.exe || mv -f /usr/bin/link.exe /usr/bin/link.exe.msys' }
$sh = (Join-Path $here 'ffmpeg\build.sh')
# FFmpeg links zlib as -lz (zlib.lib with msvc): use the prefix copies, not the CPython zlibstatic.lib.
Invoke-Checked 'ffmpeg' { & $bash -lc "'$($sh -replace '\\','/')' '$($s -replace '\\','/')' '$($Prefix -replace '\\','/')' '$((Join-Path $Prefix 'include') -replace '\\','/')' '$((Join-Path $Prefix 'lib') -replace '\\','/')'" }
Copy-License $s 'FFmpeg' @('COPYING.LGPLv2.1', 'LICENSE.md')

@{ deps = $MediaDeps } | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $Prefix 'media-deps-build.json')
Get-ChildItem (Join-Path $Prefix 'lib') -File | Select-Object Name, Length | Format-Table -AutoSize | Out-String -Width 200
