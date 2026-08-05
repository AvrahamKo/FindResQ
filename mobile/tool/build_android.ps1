<#
.SYNOPSIS
    Builds / runs the LifeSearch app on Android from Windows.

.DESCRIPTION
    Exists for exactly one reason: the `sodium` package cross-compiles
    libsodium for Android with Autotools, which needs a working `bash` AND a
    working `make` on Windows. Getting that combination right by hand is
    error-prone in a way that produces confusing failures far from the cause,
    so this script assembles a deterministic PATH for the build process only.

    NOTHING PERMANENT IS CHANGED. The PATH edit lives in this process and dies
    with it; no system or user environment variable is touched.

    ---------------------------------------------------------------------
    WHICH bash GETS PICKED DECIDES EVERYTHING. Two properties are required.
    ---------------------------------------------------------------------
    sodium's hook runs `bash ./configure` and `bash -c "make ..."`, passing
    MSYS-style paths like `--prefix=/c/Users/...`. The shell it picks must
    therefore satisfy BOTH:

      (1) `make` must resolve to a WORKING make, and
      (2) `/c/...` must mean `C:\...`.

    Measured on this machine:

        Git\bin\bash.exe       (1) NO  -- a wrapper that rebuilds its own PATH,
                                          so it ALWAYS lands on
                                          Git\usr\bin\make.exe, which is broken
                                          here (exit 127, cannot load
                                          msys-2.0.dll). Un-overridable from
                                          outside.
                               (2) yes
        cygwin64\bin\bash.exe  (1) yes -- Cygwin ships a working make
                               (2) NO  -- Cygwin maps drives at /cygdrive/c,
                                          so `/c/...` becomes a folder INSIDE
                                          the Cygwin root. libsodium compiles
                                          perfectly and then installs to
                                          C:\cygwin64\c\Users\... , and the
                                          hook fails with "Code asset ...
                                          does not exist as a file".
        Git\usr\bin\bash.exe   (1) yes -- the RAW MSYS bash: it INHERITS PATH
                                          instead of rebuilding it, so a good
                                          make placed ahead of Git\usr\bin
                                          actually wins.
                               (2) yes

    So `Git\usr\bin` IS on the PATH below, deliberately -- but only AFTER a
    directory holding a working make. That ordering is the entire fix: it is
    what stops Git's broken make from being found first.

    Symptoms if this regresses: "Something went wrong bootstrapping makefile
    fragments" (broken make), or "Code asset ... does not exist as a file"
    (wrong path semantics). Note the `ld.lld: undefined symbol: memset_s`
    lines in config.log are NORMAL configure probes -- do not chase them.

    Second reason this script exists: it pins --target-platform android-arm64.
    Building every ABI compiles libsodium three times, which is what makes the
    build appear to hang. Restricting to the device's actual ABI is roughly a
    3x saving and the difference between finishing and timing out.

.PARAMETER Target
    apk     - build a debug APK only (default)
    install - build, then adb install -r onto the device
    run     - flutter run (attached, hot reload)

.PARAMETER DeviceId
    ADB device id. Defaults to the only connected device.

.PARAMETER BaseUrl
    Backend URL baked in via --dart-define=API_BASE_URL.
    Omit for USB use: the app already defaults to 127.0.0.1:8000, which works
    with `adb reverse tcp:8000 tcp:8000`. Supply a LAN IP
    (http://192.168.x.x:8000) for untethered Wi-Fi testing.

.EXAMPLE
    .\tool\build_android.ps1 -Target install
.EXAMPLE
    .\tool\build_android.ps1 -Target install -BaseUrl http://192.168.1.143:8000
#>
[CmdletBinding()]
param(
    [ValidateSet('apk', 'install', 'run')]
    [string]$Target = 'apk',

    [string]$DeviceId = '',

    [string]$BaseUrl = '',

    # Forces libsodium to rebuild from scratch (~10 minutes). Only needed if
    # the native cache is suspected corrupt -- normally it is reused and the
    # build takes well under a minute.
    [switch]$CleanNative
)

$ErrorActionPreference = 'Stop'

$mobileRoot = Split-Path -Parent $PSScriptRoot
$savedPath = $env:PATH
Push-Location $mobileRoot
try {
    # --- put a WORKING make ahead of everything ---------------------------
    # The Android NDK ships GNU Make 4.3 (native Windows, no MSYS runtime to
    # go missing), so it is always present whenever an Android build is even
    # possible. WinGet's ezwinports.make is used if the NDK one is absent.
    $makeDir = $null
    $ndkRoot = Join-Path $env:LOCALAPPDATA 'Android\sdk\ndk'
    if (Test-Path $ndkRoot) {
        $makeDir = Get-ChildItem $ndkRoot -Directory |
            Sort-Object Name |
            ForEach-Object { Join-Path $_.FullName 'prebuilt\windows-x86_64\bin' } |
            Where-Object { Test-Path (Join-Path $_ 'make.exe') } |
            Select-Object -Last 1
    }
    if (-not $makeDir) {
        $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
        if (Test-Path (Join-Path $winget 'make.exe')) { $makeDir = $winget }
    }
    if (-not $makeDir) {
        throw ("No working 'make' found (looked in the Android NDK and WinGet). " +
               "Install one with:  winget install ezwinports.make")
    }
    $env:PATH = "$makeDir;$env:PATH"

    # --- pick a bash that satisfies BOTH requirements ---------------------
    # Preference order reflects the measurements in the header; the probe is
    # what actually decides, so a machine with MSYS2 instead of Git works too.
    $bashCandidates = @(
        'C:\Program Files\Git\usr\bin\bash.exe',
        'C:\msys64\usr\bin\bash.exe',
        'C:\Program Files\Git\bin\bash.exe',
        'C:\cygwin64\bin\bash.exe'
    ) | Where-Object { Test-Path $_ }

    Write-Host '--- preflight ---'
    Write-Host "  make dir : $makeDir"
    if (-not $bashCandidates) {
        throw ("No bash.exe found. sodium's Android build cross-compiles " +
               "libsodium with Autotools and needs one. Install Git for " +
               "Windows or MSYS2.")
    }

    $chosenBash = $null
    foreach ($candidate in $bashCandidates) {
        $dir = Split-Path -Parent $candidate
        # Probe with -c, NOT -lc: the hook runs `bash ./configure` and
        # `bash -c "make ..."`, both non-login. A login shell re-sources
        # /etc/profile and rebuilds PATH, so -lc would measure a different
        # shell than the build actually gets.
        $env:PATH = "$makeDir;$dir;$savedPath"

        $makeProbe = (& $candidate -c 'make --version 2>&1 | head -1') 2>&1
        if ($LASTEXITCODE -ne 0 -or "$makeProbe" -notmatch 'GNU Make') {
            Write-Host "  skip : $candidate -- make unusable ($makeProbe)"
            continue
        }
        # Second requirement: MSYS-style drive paths. Cygwin passes the make
        # probe and then silently installs into C:\cygwin64\c\... instead.
        $pathProbe = (& $candidate -c 'test -d /c/Windows && echo msys || echo other') 2>&1
        if ("$pathProbe" -notmatch 'msys') {
            Write-Host "  skip : $candidate -- /c/ is not the C: drive (Cygwin-style)"
            continue
        }

        $chosenBash = $candidate
        Write-Host "  bash     : $candidate"
        Write-Host "  make     : $makeProbe  (resolved INSIDE that bash)"
        Write-Host "  /c/ maps : C:\  (MSYS-style, as the hook expects)"
        break
    }
    if (-not $chosenBash) {
        throw ("No bash satisfies both requirements (working make AND " +
               "MSYS-style /c/ paths). Checked:`n  " +
               ($bashCandidates -join "`n  ") + "`n" +
               "Installing MSYS2 is the usual fix.")
    }

    # sodium's hook takes the first usable `where bash` hit, so the chosen
    # shell's directory goes on PATH -- but AFTER $makeDir, which is what
    # keeps Git's broken make from winning.
    $env:PATH = "$makeDir;$(Split-Path -Parent $chosenBash);$savedPath"

    if ($CleanNative) {
        $nativeCache = '.dart_tool\hooks_runner\shared\sodium\build'
        if (Test-Path $nativeCache) {
            Write-Host '  clearing native sodium cache (rebuild takes ~10 min)...'
            Remove-Item $nativeCache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # --- resolve the device ----------------------------------------------
    if (-not $DeviceId) {
        $devices = @(& adb devices |
            Select-Object -Skip 1 |
            Where-Object { $_ -match '\sdevice$' } |
            ForEach-Object { ($_ -split '\s+')[0] })
        if ($devices.Count -eq 1) {
            $DeviceId = $devices[0]
        } elseif ($devices.Count -gt 1) {
            throw "Multiple devices attached; pass -DeviceId. Found: $($devices -join ', ')"
        }
    }
    if ($DeviceId) { Write-Host "  device: $DeviceId" }

    # --- build -----------------------------------------------------------
    # arm64 only: see the header. Every extra ABI is another full libsodium
    # cross-compile.
    $flutterArgs = @('--debug', '--target-platform', 'android-arm64')
    if ($BaseUrl) { $flutterArgs += "--dart-define=API_BASE_URL=$BaseUrl" }

    Write-Host "--- flutter build apk $($flutterArgs -join ' ') ---"
    $started = Get-Date
    & flutter build apk @flutterArgs
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed (exit $LASTEXITCODE)" }
    Write-Host ("--- build finished in {0:n0}s ---" -f ((Get-Date) - $started).TotalSeconds)

    # --- verify the native library actually made it in --------------------
    # A missing/wrong-arch libsodium.so does not fail the build; it crashes the
    # app at startup, far from the cause. Cheaper to catch here.
    $apk = 'build\app\outputs\flutter-apk\app-debug.apk'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'lib/arm64-v8a/libsodium.so' }
        if (-not $entry) {
            throw ("APK is missing lib/arm64-v8a/libsodium.so -- the native build " +
                   "silently produced nothing usable. Re-run with -CleanNative.")
        }
        Write-Host ("  libsodium.so present ({0:n0} bytes)" -f $entry.Length)
    } finally {
        $zip.Dispose()
    }

    # --- install / run ----------------------------------------------------
    if ($Target -eq 'install' -or $Target -eq 'run') {
        if (-not $DeviceId) { throw 'No device connected.' }

        # The app defaults to 127.0.0.1:8000, which only reaches the host
        # through this tunnel. Harmless to re-apply; it does not survive
        # unplugging the cable.
        if (-not $BaseUrl) {
            & adb -s $DeviceId reverse tcp:8000 tcp:8000 | Out-Null
            Write-Host '  adb reverse tcp:8000 -> host:8000'
        }
    }

    if ($Target -eq 'install') {
        Write-Host '--- installing ---'
        & adb -s $DeviceId install -r $apk
        if ($LASTEXITCODE -ne 0) {
            throw ("adb install failed. On Xiaomi/MIUI this is usually " +
                   "'INSTALL_FAILED_USER_RESTRICTED' -- enable Developer " +
                   "options -> Install via USB on the handset.")
        }
    } elseif ($Target -eq 'run') {
        $runArgs = @('-d', $DeviceId, '--target-platform', 'android-arm64')
        if ($BaseUrl) { $runArgs += "--dart-define=API_BASE_URL=$BaseUrl" }
        & flutter run @runArgs
    }

    Write-Host 'Done.'
} finally {
    Pop-Location
}
