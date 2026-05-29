#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated Apache Cassandra Installation Script for Windows

.DESCRIPTION
    This script automates the COMPLETE Apache Cassandra installation on Windows, including:
    1. Pre-flight checks (Java 8 validation, Python detection for cqlsh)
    2. Cassandra 3.11.16 download and extraction (with SHA-512 verification)
    3. Environment variables configuration (CASSANDRA_HOME, JAVA_HOME, PATH)
    4. cassandra-env.ps1 configuration (JAVA_HOME, heap, Windows fixes)
    5. cassandra.yaml configuration (data dirs, listen address, ports)
    6. Windows .cmd launcher shim generation (cassandra.cmd, cqlsh.cmd)
    7. Windows Firewall rules for Cassandra ports (9042, 7000, 7199)
    8. Python detection for cqlsh (installs via winget if missing)

.NOTES
    Author:  VANSH RANA
    Date:    2026-05-22
    Version: 1.0

    REQUIREMENTS:
    - Run as Administrator (right-click PowerShell > Run as Administrator)
    - Internet connection for downloads
    - Windows 10/11
    - Java 8 (Eclipse Temurin) already installed  [install-hadoop.ps1 does this]
      NOTE: Cassandra 3.11.x is the last release that supports Windows, and it
            requires Java 8. Cassandra 4.x dropped Windows support entirely.

    USAGE:
    1. Right-click PowerShell and "Run as Administrator"
    2. Run:  Set-ExecutionPolicy Bypass -Scope Process -Force
    3. Run:  .\install-cassandra.ps1
#>

# ============================================================================
#  CONFIGURATION - Modify these as needed before running
# ============================================================================

$CASSANDRA_VERSION = "3.11.16"   # Last Cassandra line that supports Windows (4.x dropped it)
$INSTALL_DIR       = "C:\cassandra"                              # Where Cassandra will be installed

# Guard against missing env vars (rare: locked-down service accounts, broken profile setup).
if (-not $env:USERPROFILE) {
    Write-Host "  [ERROR] %USERPROFILE% env var not set. Cannot derive data directory." -ForegroundColor Red
    exit 1
}
if (-not $env:TEMP) {
    Write-Host "  [ERROR] %TEMP% env var not set. Cannot create install temp directory." -ForegroundColor Red
    exit 1
}

$CASSANDRA_DATA    = ($env:USERPROFILE.TrimEnd('\') + "\cassandra-data")  # Normalize: strip any trailing backslash

# Relocate the data dir to a known-safe location if USERPROFILE contains:
#   - non-printable / non-ASCII chars (Java NIO + Windows codepage mismatch)
#   - cmd metacharacters that break our shim: " ' & | < > ^ ! %
# Without this, e.g. username "AT&T" or "O'Brien" or "Yahoo!" produces a path that
# survives PowerShell quoting but breaks the .cmd shim at runtime expansion time.
if ($CASSANDRA_DATA -match '[^ -~]' -or $CASSANDRA_DATA -match "[`"'&|<>^!%]") {
    Write-Host "  [!!] USERPROFILE contains shell-unsafe characters - relocating data dir to C:\cassandra-data" -ForegroundColor DarkYellow
    $CASSANDRA_DATA = "C:\cassandra-data"
}

$TEMP_DIR = (Join-Path $env:TEMP 'cassandra-install')
# 7-Zip's NSIS installer mis-parses /D= paths containing spaces. If TEMP has a space, use
# a guaranteed no-spaces directory for the 7-Zip extraction (we have admin rights).
$SAFE_INSTALL_TEMP = if ($TEMP_DIR -match '\s') { "$env:SystemRoot\Temp\cassandra-7z" } else { "$TEMP_DIR\7z-extract" }

# ============================================================================
#  LOGGING - transcript started immediately so nothing is missed
# ============================================================================
$_logDir  = $TEMP_DIR
$_logFile = "$_logDir\install-cassandra-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
if (-not (Test-Path $_logDir)) { New-Item -ItemType Directory -Path $_logDir -Force | Out-Null }
Start-Transcript -Path $_logFile -Append | Out-Null
Write-Host "  [LOG] Transcript started -> $_logFile" -ForegroundColor DarkGray
Write-Host ""

# Exit helper - always flushes transcript before quitting
function Exit-Script {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "  [LOG] Install log saved to: $_logFile" -ForegroundColor DarkGray
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    exit $Code
}

# Cassandra download mirrors
$CASSANDRA_URLS = @(
    "https://dlcdn.apache.org/cassandra/$CASSANDRA_VERSION/apache-cassandra-$CASSANDRA_VERSION-bin.tar.gz",
    "https://downloads.apache.org/cassandra/$CASSANDRA_VERSION/apache-cassandra-$CASSANDRA_VERSION-bin.tar.gz",
    "https://archive.apache.org/dist/cassandra/$CASSANDRA_VERSION/apache-cassandra-$CASSANDRA_VERSION-bin.tar.gz"
)

$7ZIP_URLS = @(
    "https://www.7-zip.org/a/7z2409-x64.exe",
    "https://www.7-zip.org/a/7z2408-x64.exe",
    "https://www.7-zip.org/a/7z2407-x64.exe"
)

# ============================================================================
#  HELPER FUNCTIONS
# ============================================================================

function Write-Banner {
    param([string]$Text)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    # "  " prefix (2) + Text + padding + "  by VANSH RANA" (16) = 70
    Write-Host "  $Text" -NoNewline -ForegroundColor Cyan
    $padding = 70 - 2 - $Text.Length - 16
    if ($padding -gt 0) { Write-Host (" " * $padding) -NoNewline }
    Write-Host "  by VANSH RANA" -ForegroundColor Magenta
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$StepNum, [string]$Text)
    Write-Host "  [$StepNum] " -ForegroundColor Yellow -NoNewline
    Write-Host $Text -ForegroundColor White
}

function Write-Success {
    param([string]$Text)
    Write-Host "  [OK] " -ForegroundColor Green -NoNewline
    Write-Host $Text
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [!!] " -ForegroundColor DarkYellow -NoNewline
    Write-Host $Text -ForegroundColor DarkYellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [ERROR] " -ForegroundColor Red -NoNewline
    Write-Host $Text -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Message)
    Write-Host ""
    $r = Read-Host "  $Message (Y/N)"
    if ($r -ne 'Y' -and $r -ne 'y') { Write-Host "  Skipped." -ForegroundColor DarkGray; return $false }
    return $true
}

function Get-ShortPath {
    param([string]$LongPath)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path $LongPath -PathType Container) { return $fso.GetFolder($LongPath).ShortPath }
        elseif (Test-Path $LongPath -PathType Leaf)  { return $fso.GetFile($LongPath).ShortPath }
    }
    catch {}
    return $LongPath
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Download-WithProgress {
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$DisplayName = "",
        [int]$TimeoutSec = 300
    )
    if (-not $DisplayName) { $DisplayName = [System.IO.Path]::GetFileName($OutFile) }
    $uri     = New-Object System.Uri($Url)
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Timeout         = $TimeoutSec * 1000
    $request.UserAgent       = "CassandraInstaller/1.0"
    $request.AllowAutoRedirect = $true
    try { $response = $request.GetResponse() }
    catch { throw "Download failed for ${Url}: $_" }

    $totalBytes     = $response.ContentLength
    $responseStream = $response.GetResponseStream()
    $fileStream     = $null
    try { $fileStream = [System.IO.File]::Create($OutFile) }
    catch { $response.Close(); $responseStream.Close(); throw "Cannot create '${OutFile}': $_" }

    $buffer          = New-Object byte[] 65536
    $downloadedBytes = [long]0
    $startTime       = Get-Date
    $lastUpdate      = [DateTime]::MinValue
    try {
        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead
            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                $lastUpdate = $now
                $elapsed    = ($now - $startTime).TotalSeconds
                $speedBps   = if ($elapsed -gt 0) { $downloadedBytes / $elapsed } else { 0 }
                $speedText  = "$(Format-FileSize ([long]$speedBps))/s"
                $dlText     = Format-FileSize $downloadedBytes
                if ($totalBytes -gt 0) {
                    $pct    = [Math]::Round(($downloadedBytes / $totalBytes) * 100, 1)
                    $totTxt = Format-FileSize $totalBytes
                    $bw     = 30
                    $filled = [int][Math]::Floor($bw * $pct / 100)
                    $bar    = ("$([char]0x2588)" * $filled) + ("$([char]0x2591)" * ($bw - $filled))
                    $line   = "`r    [$bar] $pct%  $dlText / $totTxt  ($speedText)   "
                }
                else {
                    $line = "`r    Downloading...  $dlText  ($speedText)   "
                }
                Write-Host $line -NoNewline -ForegroundColor DarkCyan
            }
        }
        $elapsed  = ((Get-Date) - $startTime).TotalSeconds
        $avgSpeed = if ($elapsed -gt 0) { Format-FileSize ([long]($downloadedBytes / $elapsed)) } else { "?" }
        Write-Host "`r    Downloaded $(Format-FileSize $downloadedBytes) in $([Math]::Round($elapsed,1))s ($avgSpeed/s)                    " -ForegroundColor Green
    }
    finally {
        if ($fileStream) { $fileStream.Close() }
        $responseStream.Close()
        $response.Close()
    }
}

function Download-WithFallback {
    param([string[]]$Urls, [string]$OutFile, [string]$DisplayName, [int]$TimeoutSec = 300)
    foreach ($url in $Urls) {
        try {
            Write-Host "    Trying: $url" -ForegroundColor Gray
            Download-WithProgress -Url $url -OutFile $OutFile -DisplayName $DisplayName -TimeoutSec $TimeoutSec
            if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
                Write-Warn "    File is 0 bytes (quarantined?) - trying next..."
                Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                continue
            }
            Write-Success "$DisplayName downloaded"
            return $true
        }
        catch {
            Write-Warn "    Failed ($($_.Exception.Message.Split([char]10)[0])) - trying next..."
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        }
    }
    return $false
}

function Test-CassandraArchive {
    param([string]$ArchivePath, [string[]]$MirrorUrls)
    Write-Step "1.1b" "Verifying SHA-512 checksum..."
    foreach ($url in $MirrorUrls) {
        $sha512Url = $url + ".sha512"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $shaRaw = (Invoke-WebRequest -Uri $sha512Url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
            # Content may be a byte array (binary HTTP response) - convert to string
            if ($shaRaw -is [byte[]]) {
                $shaRaw = [System.Text.Encoding]::UTF8.GetString($shaRaw)
            }
            $expectedHash = (($shaRaw -split '[\s]+')[0]).ToUpper().Trim()
            if ($expectedHash.Length -ne 128) { continue }   # not a valid SHA-512
            $actualHash   = (Get-FileHash $ArchivePath -Algorithm SHA512).Hash.ToUpper()
            if ($actualHash -eq $expectedHash) {
                Write-Success "SHA-512 verified ($($expectedHash.Substring(0,16))...)"
                return $true
            }
            else {
                Write-Err "SHA-512 MISMATCH - archive is corrupt or tampered. Deleting and aborting."
                Write-Host "  Expected : $expectedHash" -ForegroundColor Red
                Write-Host "  Actual   : $actualHash"   -ForegroundColor Red
                Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
                Exit-Script 1
            }
        }
        catch {
            Write-Warn "Could not fetch .sha512 from $sha512Url"
        }
    }
    Write-Warn "SHA-512 verification skipped (no .sha512 reachable). Proceeding on size check only."
    return $false
}

# ============================================================================
#  PRE-FLIGHT CHECKS
# ============================================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Banner "CASSANDRA AUTOMATED INSTALLER FOR WINDOWS"
Write-Host "  Cassandra Version : $CASSANDRA_VERSION"
Write-Host "  Install Path      : $INSTALL_DIR"
Write-Host "  Data Dir          : $CASSANDRA_DATA"
Write-Host "  Created by        : VANSH RANA" -ForegroundColor Magenta
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "  Right-click PowerShell > 'Run as Administrator', then re-run this script."
    Exit-Script 1
}
Write-Success "Running as Administrator"

# Java check (Cassandra 3.11.x supports Java 8 ONLY)
$existingJava = Get-Command java.exe -ErrorAction SilentlyContinue
if (-not $existingJava) {
    Write-Err "java.exe not found on PATH!"
    Write-Host "  Cassandra $CASSANDRA_VERSION requires Java 8. Run install-hadoop.ps1 first to get Java 8."
    Exit-Script 1
}
$javaVerRaw  = & "$($existingJava.Source)" -version 2>&1
$javaVerText = ($javaVerRaw | ForEach-Object { $_.ToString() }) -join " "
if ($javaVerText -match '1\.8\.0') {
    Write-Success "Java 8 detected - fully compatible with Cassandra $CASSANDRA_VERSION"
}
elseif ($javaVerText -match '"11\.') {
    Write-Warn "Java 11 detected. Cassandra 3.11.x officially supports Java 8 ONLY."
    Write-Warn "Cassandra will likely fail to start on Java 11. Install Java 8 (Eclipse Temurin)."
    if (-not (Confirm-Continue "Continue anyway with Java 11?")) { Exit-Script 1 }
}
else {
    Write-Warn "Detected Java: $javaVerText"
    Write-Warn "Cassandra 3.11.x requires Java 8. Other versions are unsupported and may not start."
    if (-not (Confirm-Continue "Continue with this JVM?")) { Exit-Script 1 }
}

# Resolve JAVA_HOME — try Machine scope, then User scope, then derive from java.exe location.
# The derived path is validated; if java.exe is a shim (scoop/chocolatey/jenv) the derived
# JAVA_HOME won't contain bin\java.exe and we must bail with a clear error.
$javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if (-not $javaHome -or -not (Test-Path "$javaHome\bin\java.exe")) {
    $javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "User")
}
if (-not $javaHome -or -not (Test-Path "$javaHome\bin\java.exe")) {
    $javaHome = Split-Path (Split-Path $existingJava.Source -Parent) -Parent
}
if (-not (Test-Path "$javaHome\bin\java.exe")) {
    Write-Err "Could not resolve a valid JAVA_HOME containing bin\java.exe"
    Write-Host "  Detected java.exe : $($existingJava.Source)" -ForegroundColor Yellow
    Write-Host "  Derived JAVA_HOME : $javaHome" -ForegroundColor Yellow
    Write-Host "  This usually means java.exe is a shim (scoop/chocolatey/jenv)." -ForegroundColor Yellow
    Write-Host "  Set JAVA_HOME to your JDK root, then re-run:" -ForegroundColor Yellow
    Write-Host "    [Environment]::SetEnvironmentVariable('JAVA_HOME','C:\path\to\jdk','Machine')" -ForegroundColor DarkCyan
    Exit-Script 1
}
Write-Success "JAVA_HOME resolved: $javaHome"

# Short path for JAVA_HOME (critical when path contains spaces)
$javaHomeShort = $javaHome
if ($javaHome -match '\s') {
    $javaHomeShort = Get-ShortPath $javaHome
    if ($javaHomeShort -ne $javaHome) {
        Write-Success "JAVA_HOME short path: $javaHomeShort"
    }
    else {
        Write-Warn "Could not shorten JAVA_HOME. Consider moving Java to a path without spaces."
    }
}

# Python check for cqlsh. The Cassandra SERVER needs no Python; cqlsh (the interactive
# CQL client) does. Two viable clients exist, and we auto-pick the best available:
#   - Python 2.7 + the bundled 3.11 cqlsh.py  -> FULL features incl. DESCRIBE
#       (3.11's cqlsh.py guard is: 2.7.0 <= version < 3.0; it will not run on Python 3)
#   - Python 3   + the PyPI 'cqlsh' package (in a private venv) -> runs on any modern
#       machine, but DESCRIBE is unavailable on a 3.11 server (that PyPI client targets
#       Cassandra 4.0+, which moved DESCRIBE server-side; 3.11 has none). On Python 3.12+
#       it also needs the 'pyasyncore' backport (3.12 removed the stdlib asyncore module).
# "Auto: best of both" -> prefer Python 2.7 when present, otherwise fall back to Python 3.
Write-Host ""
Write-Host "  Detecting Python for cqlsh (the Cassandra server itself needs no Python)..." -ForegroundColor Gray

function Resolve-Python {
    # $Want = '2' or '3'. Returns @{ Cmd=<invocation string>; Ver=<version text> } or $null.
    param([string]$Want)
    $candidates = if ($Want -eq '2') { @('py -2', 'python2', 'python') }
                  else                { @('py -3', 'python', 'python3') }
    foreach ($c in $candidates) {
        $exe, $rest = $c -split ' ', 2
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $verOut = if ($rest) { & $exe $rest --version 2>&1 } else { & $exe --version 2>&1 }
            $ver = ($verOut | Select-Object -First 1).ToString()
        } catch { continue }
        if ($ver -match "Python $Want\.") { return @{ Cmd = $c; Ver = $ver.Trim() } }
    }
    return $null
}

$py27 = Resolve-Python '2'   # full-feature cqlsh (bundled)
$py3  = Resolve-Python '3'   # portable fallback (PyPI cqlsh in a venv)
$py27Cmd = if ($py27) { $py27.Cmd } else { $null }
$py3Cmd  = if ($py3)  { $py3.Cmd }  else { $null }

if ($py27Cmd) {
    $cqlshMode = "py2"
    Write-Success "Python 2.7 found ($($py27.Ver)) - cqlsh will use the bundled client (full features incl. DESCRIBE)"
}
elseif ($py3Cmd) {
    $cqlshMode = "py3"
    Write-Success "Python 3 found ($($py3.Ver)) - cqlsh will use the PyPI client in a private venv"
    Write-Warn "With the Python 3 client, DESCRIBE is unavailable on a 3.11 server (use system_schema.* queries instead)."
}
else {
    $cqlshMode = "none"
    Write-Warn "No Python found. The Cassandra SERVER will still install and run fine."
    Write-Warn "cqlsh needs Python: install Python 3 (https://www.python.org/downloads/) and re-run this script,"
    Write-Warn "or install Python 2.7.18 for the full-feature bundled cqlsh."
}

# Create temp and data directories
$cassandraSubDirs = @(
    $TEMP_DIR,
    $CASSANDRA_DATA,
    "$CASSANDRA_DATA\data",
    "$CASSANDRA_DATA\commitlog",
    "$CASSANDRA_DATA\saved_caches",
    "$CASSANDRA_DATA\hints",
    "$CASSANDRA_DATA\cdc_raw",
    "$CASSANDRA_DATA\logs"
)
foreach ($d in $cassandraSubDirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ============================================================================
#  STEP 1: DOWNLOAD AND EXTRACT CASSANDRA
# ============================================================================

Write-Banner "STEP 1: Apache Cassandra $CASSANDRA_VERSION Download & Extraction"

$doDownload = $false
if ((Test-Path "$INSTALL_DIR\bin\cassandra.bat") -or (Test-Path "$INSTALL_DIR\bin\cassandra")) {
    Write-Warn "Cassandra already exists at $INSTALL_DIR"
    if (-not (Confirm-Continue "Existing Cassandra found. OVERWRITE with Cassandra $CASSANDRA_VERSION?")) {
        Write-Success "Keeping existing Cassandra installation"
        $doDownload = $false
    }
    else {
        $backupDir = "$TEMP_DIR\cassandra-conf-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (Test-Path "$INSTALL_DIR\conf") {
            Copy-Item "$INSTALL_DIR\conf" $backupDir -Recurse -Force
            Write-Success "Conf backed up to: $backupDir"
        }
        # Remove and recreate install dir cleanly (safer than Remove-Item *)
        # Double-quote the path inside cmd to handle spaces
        cmd /c "rmdir /s /q `"$INSTALL_DIR`"" 2>$null
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        $doDownload = $true
    }
}
else {
    $doDownload = $true
}

if ($doDownload) {
    Write-Step "1.1" "Downloading Apache Cassandra $CASSANDRA_VERSION (~40 MB)..."
    $cassandraTarGz = "$TEMP_DIR\apache-cassandra-$CASSANDRA_VERSION-bin.tar.gz"
    $minCassandraBytes = 30MB
    $archiveVerified   = $false

    if (Test-Path $cassandraTarGz) {
        $archiveSize = (Get-Item $cassandraTarGz).Length
        if ($archiveSize -ge $minCassandraBytes) {
            Write-Warn "Archive already downloaded ($(Format-FileSize $archiveSize)), reusing."
            $archiveVerified = Test-CassandraArchive -ArchivePath $cassandraTarGz -MirrorUrls $CASSANDRA_URLS
        }
        else {
            Write-Warn "Cached archive is $(Format-FileSize $archiveSize) - likely corrupt. Re-downloading..."
            Remove-Item $cassandraTarGz -Force
        }
    }

    if (-not (Test-Path $cassandraTarGz)) {
        $downloaded = Download-WithFallback -Urls $CASSANDRA_URLS -OutFile $cassandraTarGz -DisplayName "Apache Cassandra $CASSANDRA_VERSION" -TimeoutSec 600
        if (-not $downloaded) {
            Write-Err "All mirrors failed. Please download manually:"
            $CASSANDRA_URLS | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Host "  Save to: $cassandraTarGz" -ForegroundColor Yellow
            Read-Host "  Press Enter after downloading manually"
        }
    }

    if (-not (Test-Path $cassandraTarGz)) { Write-Err "Archive not found. Cannot continue."; Exit-Script 1 }
    if (-not $archiveVerified) { Test-CassandraArchive -ArchivePath $cassandraTarGz -MirrorUrls $CASSANDRA_URLS | Out-Null }

    Write-Step "1.2" "Extracting Cassandra (this may take a minute)..."
    if (-not (Test-Path $INSTALL_DIR)) { New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null }

    $extractTemp = "$TEMP_DIR\cassandra-extract"
    if (Test-Path $extractTemp) { cmd /c "rmdir /s /q `"$extractTemp`"" }
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
    $extracted = $false

    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Write-Host "    Using built-in tar.exe..." -ForegroundColor Gray
        & tar.exe -xzf "$cassandraTarGz" -C "$extractTemp" 2>$null
        $tarExit   = $LASTEXITCODE
        $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-cassandra-*" } | Select-Object -First 1
        if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($tarExit -eq 0 -and $chkFolder -and ((Test-Path "$($chkFolder.FullName)\bin\cassandra.bat") -or (Test-Path "$($chkFolder.FullName)\bin\cassandra"))) {
            $extracted = $true; Write-Success "Extracted using tar.exe"
        }
        else {
            Write-Warn "tar.exe incomplete (exit $tarExit). Trying 7-Zip..."
            cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null
            New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
        }
    }

    if (-not $extracted) {
        $7zInstaller = "$TEMP_DIR\7z_installer.exe"
        $7zDir       = $SAFE_INSTALL_TEMP   # Avoids NSIS /D= space-handling bug on TEMP paths with spaces
        $7zDownloaded = $false
        foreach ($zUrl in $7ZIP_URLS) {
            try {
                Download-WithProgress -Url $zUrl -OutFile $7zInstaller -DisplayName "7-Zip Installer"
                if ((Test-Path $7zInstaller) -and (Get-Item $7zInstaller).Length -gt 0) { $7zDownloaded = $true; break }
                Remove-Item $7zInstaller -Force -ErrorAction SilentlyContinue
            }
            catch { Write-Warn "7-Zip mirror failed, trying next..." }
        }
        if ($7zDownloaded) {
            # NSIS-based 7-Zip installer: /D= must NOT have quotes around the path
            # (NSIS parses /D= specially and quotes break the silent install)
            Start-Process -FilePath $7zInstaller -ArgumentList "/S", "/D=$7zDir" -Wait -NoNewWindow
            $7zExe = "$7zDir\7z.exe"
            if (Test-Path $7zExe) {
                & $7zExe x "$cassandraTarGz" -o"$extractTemp" -y | Out-Null
                # The .tar may be at root of extractTemp OR inside a subfolder - search recursively
                $tarFile = Get-ChildItem $extractTemp -Filter "*.tar" -File -Recurse | Select-Object -First 1
                if ($tarFile) {
                    & $7zExe x "$($tarFile.FullName)" -o"$extractTemp" -y | Out-Null
                    Remove-Item $tarFile.FullName -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-Warn "    No .tar file found after gzip extraction. Archive may be corrupt."
                }
                $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-cassandra-*" } | Select-Object -First 1
                if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
                if ($chkFolder -and ((Test-Path "$($chkFolder.FullName)\bin\cassandra.bat") -or (Test-Path "$($chkFolder.FullName)\bin\cassandra"))) {
                    $extracted = $true; Write-Success "Extracted using 7-Zip fallback"
                }
            }
        }
    }

    if ($extracted) {
        $ef = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-cassandra-*" } | Select-Object -First 1
        if (-not $ef) { $ef = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if (-not $ef) {
            Write-Err "Cannot find extracted Cassandra directory inside $extractTemp"
            Exit-Script 1
        }
        robocopy "$($ef.FullName)" "$INSTALL_DIR" /E /MOVE /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1 | Out-Null
        $rcExit = $LASTEXITCODE
        cmd /c "rmdir /s /q `"$extractTemp`"" 2>$null
        # Robocopy exit codes: 0-7 = success/warnings, >=8 = real failure.
        # Also require the launcher binary to exist after copy (defends against partial copies).
        $launcherPresent = (Test-Path "$INSTALL_DIR\bin\cassandra.bat") -or (Test-Path "$INSTALL_DIR\bin\cassandra")
        if ($rcExit -le 7 -and $launcherPresent) {
            if ($rcExit -le 1) { Write-Success "Cassandra extracted to $INSTALL_DIR" }
            else               { Write-Success "Cassandra extracted to $INSTALL_DIR (robocopy info code $rcExit, files OK)" }
        }
        elseif ($rcExit -ge 8) {
            Write-Err "robocopy failed with exit code $rcExit. Cassandra files may be incomplete."
            Exit-Script 1
        }
        else {
            Write-Err "robocopy completed (exit $rcExit) but Cassandra launcher is missing under $INSTALL_DIR\bin"
            Exit-Script 1
        }
    }
    else {
        Write-Err "Extraction failed. Please extract $cassandraTarGz to $INSTALL_DIR manually."
        Read-Host "Press Enter after extracting manually"
        if (-not ((Test-Path "$INSTALL_DIR\bin\cassandra.bat") -or (Test-Path "$INSTALL_DIR\bin\cassandra"))) { Write-Err "Cassandra not found. Cannot continue."; Exit-Script 1 }
    }

    # $7zDir is only assigned if the 7-Zip fallback ran; guard against unbound variable warning.
    if ($7zDir -and (Test-Path $7zDir)) { Remove-Item $7zDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Success "Cassandra binaries ready at: $INSTALL_DIR"

# Neutralize SIGAR. The bundled SIGAR native (lib\sigar-bin\sigar-amd64-winnt.dll, ~2010)
# hard-crashes the JVM (EXCEPTION_ACCESS_VIOLATION) on modern Windows when the shipped
# cassandra.bat/cassandra.ps1 loads it via -Djava.library.path. SIGAR only provides
# advisory startup checks (swap/ulimits/disk), so removing the native libs is safe:
# Cassandra logs "Could not initialize SIGAR library" and continues. This makes EVERY
# launcher safe (our cassandra.cmd already avoids it; the shipped .bat/.ps1 need this).
$sigarBin = "$INSTALL_DIR\lib\sigar-bin"
if (Test-Path $sigarBin) {
    Remove-Item $sigarBin -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $sigarBin) {
        Write-Warn "Could not remove $sigarBin - use .\cassandra.cmd (it does not load SIGAR) to avoid a JVM crash."
    } else {
        Write-Success "Removed bundled SIGAR natives (prevents a JVM crash on the shipped launcher)"
    }
}

# ============================================================================
#  STEP 2: ENVIRONMENT VARIABLES
# ============================================================================

Write-Banner "STEP 2: Environment Variables (CASSANDRA_HOME, PATH)"

Write-Step "2.1" "Setting CASSANDRA_HOME system environment variable..."
[System.Environment]::SetEnvironmentVariable("CASSANDRA_HOME", $INSTALL_DIR, "Machine")
$env:CASSANDRA_HOME = $INSTALL_DIR
Write-Success "CASSANDRA_HOME = $INSTALL_DIR"

Write-Step "2.2" "Checking JAVA_HOME system environment variable..."
$existingJavaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if ($existingJavaHome -eq $javaHome) {
    Write-Success "JAVA_HOME already set correctly, skipping: $javaHome"
} else {
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
    $env:JAVA_HOME = $javaHome
    Write-Success "JAVA_HOME set to: $javaHome"
}

Write-Step "2.3" "Adding $INSTALL_DIR\bin to system PATH..."
$machinePath    = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$cassandraBin   = "$INSTALL_DIR\bin"
$machineEntries = if ($machinePath) { ($machinePath -split ';') | ForEach-Object { $_.Trim() } } else { @() }
if ($machineEntries -notcontains $cassandraBin) {
    $newMachinePath = if ($machinePath) { "$machinePath;$cassandraBin" } else { $cassandraBin }
    [System.Environment]::SetEnvironmentVariable("Path", $newMachinePath, "Machine")
    $env:Path = "$env:Path;$cassandraBin"
    Write-Success "Added $cassandraBin to system PATH"
}
else {
    Write-Success "$cassandraBin is already in system PATH"
}

Write-Step "2.4" "Updating user-level PATH (for non-admin terminals)..."
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$userEntries = ($userPath -split ';') | ForEach-Object { $_.Trim() }
if ($userEntries -notcontains $cassandraBin) {
    if ($userPath) { $userPath = "$userPath;$cassandraBin" } else { $userPath = $cassandraBin }
    [System.Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    Write-Success "Added $cassandraBin to user PATH"
}
else {
    Write-Success "$cassandraBin is already in user PATH"
}

# Refresh session PATH
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path    = if ($userPath) { "$machinePath;$userPath" } else { $machinePath }

# ============================================================================
#  STEP 3: cassandra-env.ps1 CONFIGURATION
# ============================================================================

Write-Banner "STEP 3: cassandra-env.ps1 Configuration"

$cassandraEnvFile = "$INSTALL_DIR\conf\cassandra-env.ps1"
if (-not (Test-Path "$INSTALL_DIR\conf")) {
    New-Item -ItemType Directory -Path "$INSTALL_DIR\conf" -Force | Out-Null
}

Write-Step "3.1" "Patching cassandra-env.ps1 with JAVA_HOME and Windows settings..."

if (Test-Path $cassandraEnvFile) {
    # Read the existing file and patch JAVA_HOME at the top
    $envContent = [System.IO.File]::ReadAllText($cassandraEnvFile)

    # If a previous run of this script already inserted a patch block, strip it before
    # prepending the new one — otherwise re-runs would stack duplicate patches indefinitely.
    $envContent = $envContent -replace '(?s)# ---- Patched by install-cassandra\.ps1 \(VANSH RANA\) ----.*?# ---- End of patch ----\s*\r?\n', ''

    # Escape apostrophes in baked-in paths so single-quoted PS strings stay valid even if a
    # path contains a "'" (rare: usernames like O'Brien, or unusual install locations).
    $jhEsc = $javaHomeShort -replace "'", "''"
    $idEsc = $INSTALL_DIR   -replace "'", "''"
    $cdEsc = $CASSANDRA_DATA -replace "'", "''"

    # Inject JAVA_HOME override at the very top (after any existing shebang-style comment lines)
    # IMPORTANT: heap sizes go to env vars; Apache's cassandra-env.ps1 checks $env:MAX_HEAP_SIZE,
    # not the script-scoped $MAX_HEAP_SIZE. Setting the script var has no effect.
    $javaHomeBlock = @"
# ---- Patched by install-cassandra.ps1 (VANSH RANA) ----
`$env:JAVA_HOME = '$jhEsc'
`$env:CASSANDRA_HOME = '$idEsc'
`$env:CASSANDRA_LOG_DIR = '$cdEsc\logs'

# Heap settings - 512M for dev, increase for production.
# Must be set as ENV vars so Apache cassandra-env.ps1's CalculateHeapSizes() skips its auto-calc.
`$env:MAX_HEAP_SIZE = "512M"
`$env:HEAP_NEWSIZE  = "100M"

# Windows: initialise JVM_OPTS cleanly then append flags
if (-not `$JVM_OPTS) { `$JVM_OPTS = '' }

# Windows: prefer IPv4 stack (avoids dual-stack bind issues)
`$JVM_OPTS = (`$JVM_OPTS + ' -Djava.net.preferIPv4Stack=true').Trim()

# Windows: disable DNS caching
`$JVM_OPTS = (`$JVM_OPTS + ' -Dsun.net.inetaddr.ttl=0').Trim()

# ---- End of patch ----

"@
    # Prepend patch block
    $patchedContent = $javaHomeBlock + $envContent
    $noBomUtf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($cassandraEnvFile, $patchedContent, $noBomUtf8)
    Write-Success "cassandra-env.ps1 patched at: $cassandraEnvFile"
}
else {
    # Same apostrophe-escaping as the patch branch (defensive)
    $jhEsc = $javaHomeShort -replace "'", "''"
    $idEsc = $INSTALL_DIR   -replace "'", "''"
    $cdEsc = $CASSANDRA_DATA -replace "'", "''"
    # Write a fresh cassandra-env.ps1
    $freshEnvContent = @"
# cassandra-env.ps1 - Cassandra environment for Windows
# Generated by install-cassandra.ps1 (VANSH RANA)

`$env:JAVA_HOME = '$jhEsc'
`$env:CASSANDRA_HOME = '$idEsc'
`$env:CASSANDRA_LOG_DIR = '$cdEsc\logs'

# Heap settings (env vars so Apache cassandra-env's CalculateHeapSizes() skips auto-calc)
`$env:MAX_HEAP_SIZE = "512M"
`$env:HEAP_NEWSIZE  = "100M"

# Windows: initialise JVM_OPTS cleanly then append flags
if (-not `$JVM_OPTS) { `$JVM_OPTS = '' }

# Windows: prefer IPv4 stack
`$JVM_OPTS = (`$JVM_OPTS + ' -Djava.net.preferIPv4Stack=true').Trim()

# Windows: disable DNS caching
`$JVM_OPTS = (`$JVM_OPTS + ' -Dsun.net.inetaddr.ttl=0').Trim()
"@
    $noBomUtf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($cassandraEnvFile, $freshEnvContent, $noBomUtf8)
    Write-Success "cassandra-env.ps1 written to: $cassandraEnvFile"
}

# ============================================================================
#  STEP 4: cassandra.yaml CONFIGURATION
# ============================================================================

Write-Banner "STEP 4: cassandra.yaml Configuration"

$cassandraYamlFile = "$INSTALL_DIR\conf\cassandra.yaml"

# Convert backslash paths to forward-slash for YAML (Cassandra requires this on Windows)
$dataDir        = ($CASSANDRA_DATA + "\data").Replace('\', '/')
$commitlogDir   = ($CASSANDRA_DATA + "\commitlog").Replace('\', '/')
$savedCachesDir = ($CASSANDRA_DATA + "\saved_caches").Replace('\', '/')
$hintsDir       = ($CASSANDRA_DATA + "\hints").Replace('\', '/')

if (Test-Path $cassandraYamlFile) {
    Write-Step "4.1" "Patching existing cassandra.yaml (data dirs, listen address, Windows fixes)..."
    $yaml = [System.IO.File]::ReadAllText($cassandraYamlFile)

    # Patch data_file_directories
    # Replace the entire data_file_directories block (key + its list items) with the new value
    $yaml = $yaml -replace '(?m)^data_file_directories:[^\S\r\n]*\r?\n([ \t]+-[^\r\n]*\r?\n)*', "data_file_directories:`n    - $dataDir`n"

    # Patch commitlog_directory
    $yaml = $yaml -replace '(?m)^commitlog_directory:.*', "commitlog_directory: $commitlogDir"

    # Patch saved_caches_directory
    $yaml = $yaml -replace '(?m)^saved_caches_directory:.*', "saved_caches_directory: $savedCachesDir"

    # Patch hints_directory
    $yaml = $yaml -replace '(?m)^hints_directory:.*', "hints_directory: $hintsDir"

    # Set listen_address to localhost (single-node dev setup)
    $yaml = $yaml -replace '(?m)^listen_address:.*', "listen_address: localhost"

    # Set rpc_address to localhost
    $yaml = $yaml -replace '(?m)^rpc_address:.*', "rpc_address: localhost"

    # Set seeds to localhost
    $yaml = $yaml -replace '(?m)(- seeds: )"[^"]*"', '$1"localhost"'

    $noBomUtf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($cassandraYamlFile, $yaml, $noBomUtf8)
    Write-Success "cassandra.yaml patched: $cassandraYamlFile"
}
else {
    Write-Step "4.1" "Writing fresh minimal cassandra.yaml (standalone single-node)..."
    $cassandraYamlContent = @"
# cassandra.yaml - Apache Cassandra $CASSANDRA_VERSION (Windows single-node)
# Generated by install-cassandra.ps1 | Author: VANSH RANA
# NOTE: Cassandra 3.11 uses *_in_ms / *_in_mb / *_in_kb suffixes and enable_*
#       flags. Do NOT mix in 4.x-style keys (e.g. commitlog_sync_period: 10000ms,
#       user_defined_functions_enabled) - 3.11's yaml loader rejects unknown keys.

cluster_name: 'VanshCassandraCluster'
num_tokens: 256

hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000
hinted_handoff_throttle_in_kb: 1024
max_hints_delivery_threads: 2
hints_directory: $hintsDir
hints_flush_period_in_ms: 10000
max_hints_file_size_in_mb: 128

batchlog_replay_throttle_in_kb: 1024

authenticator: AllowAllAuthenticator
authorizer: AllowAllAuthorizer
role_manager: CassandraRoleManager
roles_validity_in_ms: 2000
permissions_validity_in_ms: 2000
credentials_validity_in_ms: 2000

partitioner: org.apache.cassandra.dht.Murmur3Partitioner

data_file_directories:
    - $dataDir

commitlog_directory: $commitlogDir

cdc_enabled: false

saved_caches_directory: $savedCachesDir

commitlog_sync: periodic
commitlog_sync_period_in_ms: 10000
commitlog_segment_size_in_mb: 32

seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          - seeds: "127.0.0.1"

concurrent_reads: 32
concurrent_writes: 32
concurrent_counter_writes: 32
concurrent_materialized_view_writes: 32

memtable_allocation_type: heap_buffers

index_summary_capacity_in_mb:
index_summary_resize_interval_in_minutes: 60

trickle_fsync: false
trickle_fsync_interval_in_kb: 10240

disk_failure_policy: stop
commit_failure_policy: stop

prepared_statements_cache_size_mb:
key_cache_size_in_mb:
key_cache_save_period: 14400
row_cache_size_in_mb: 0
row_cache_save_period: 0
counter_cache_size_in_mb:
counter_cache_save_period: 7200

file_cache_size_in_mb: 512

memtable_heap_space_in_mb: 256
memtable_offheap_space_in_mb: 256

listen_address: localhost

start_native_transport: true
native_transport_port: 9042

start_rpc: false
rpc_address: localhost
rpc_port: 9160
rpc_keepalive: true
rpc_server_type: sync
thrift_framed_transport_size_in_mb: 15

storage_port: 7000
ssl_storage_port: 7001

incremental_backups: false
snapshot_before_compaction: false
auto_snapshot: true

column_index_size_in_kb: 64
column_index_cache_size_in_kb: 2

compaction_throughput_mb_per_sec: 16
sstable_preemptive_open_interval_in_mb: 50

read_request_timeout_in_ms: 5000
range_request_timeout_in_ms: 10000
write_request_timeout_in_ms: 2000
counter_write_request_timeout_in_ms: 5000
cas_contention_timeout_in_ms: 1000
truncate_request_timeout_in_ms: 60000
request_timeout_in_ms: 10000
slow_query_log_timeout_in_ms: 500

cross_node_timeout: false

phi_convict_threshold: 8

endpoint_snitch: SimpleSnitch
dynamic_snitch: true
dynamic_snitch_update_interval_in_ms: 100
dynamic_snitch_reset_interval_in_ms: 600000
dynamic_snitch_badness_threshold: 0.1

request_scheduler: org.apache.cassandra.scheduler.NoScheduler

server_encryption_options:
    internode_encryption: none
    keystore: conf/.keystore
    keystore_password: cassandra
    truststore: conf/.truststore
    truststore_password: cassandra

client_encryption_options:
    enabled: false
    optional: false
    keystore: conf/.keystore
    keystore_password: cassandra

internode_compression: dc
inter_dc_tcp_nodelay: false

tracetype_query_ttl: 86400
tracetype_repair_ttl: 604800

enable_user_defined_functions: false
enable_scripted_user_defined_functions: false

# Windows-only: sets the OS timer resolution (1ms). Valid in 3.11, removed in 4.x.
windows_timer_interval: 1

transparent_data_encryption_options:
    enabled: false
    chunk_length_kb: 64
    cipher: AES/CBC/PKCS5Padding
    key_alias: testing:1

tombstone_warn_threshold: 1000
tombstone_failure_threshold: 100000

batch_size_warn_threshold_in_kb: 5
batch_size_fail_threshold_in_kb: 50
unlogged_batch_across_partitions_warn_threshold: 10

compaction_large_partition_warning_threshold_mb: 100

gc_warn_threshold_in_ms: 1000

back_pressure_enabled: false

cdc_raw_directory: $($CASSANDRA_DATA.Replace('\','/'))/cdc_raw
"@
    $noBomUtf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($cassandraYamlFile, $cassandraYamlContent, $noBomUtf8)
    Write-Success "cassandra.yaml written to: $cassandraYamlFile"
}

# ============================================================================
#  STEP 5: WINDOWS LAUNCHER SHIMS
#  Cassandra ships cassandra.bat but we add a PowerShell-friendly cassandra.cmd
#  and a Windows cqlsh.cmd wrapper.
# ============================================================================

Write-Banner "STEP 5: Windows Launcher Shims (.cmd wrappers)"

# cassandra.cmd - start Cassandra in the foreground (great for dev)
# NOTE: This shim uses Java's wildcard classpath (lib\*) and calls CassandraDaemon
# directly. It does NOT delegate to cassandra.bat, so it works even on machines
# where cassandra.bat has Windows line-ending or encoding issues. All -D values
# are quoted so paths with spaces (e.g. "C:\Users\John Doe\...") work correctly.
$cassandraCmdContent = @"
@echo off
@rem Cassandra Windows launcher shim
@rem Generated by install-cassandra.ps1  |  Author: VANSH RANA
setlocal EnableDelayedExpansion

if not defined CASSANDRA_HOME set "CASSANDRA_HOME=$INSTALL_DIR"
if not defined JAVA_HOME      set "JAVA_HOME=$javaHomeShort"

set "CASSANDRA_CONF=%CASSANDRA_HOME%\conf"
@rem Data dir baked in at install time so this shim agrees with cassandra.yaml and
@rem cassandra-env.ps1 - including the non-ASCII / quoted-username relocation to C:\cassandra-data.
set "CASSANDRA_DATA=$CASSANDRA_DATA"
set "CASSANDRA_LOG_DIR=%CASSANDRA_DATA%\logs"

if not exist "!CASSANDRA_LOG_DIR!" mkdir "!CASSANDRA_LOG_DIR!"

@rem Java's wildcard classpath: lib\* expands to all .jar files at runtime.
@rem Robust to spaces in paths and to long classpaths (no cmd-line length blowup).
set "CASSANDRA_CP=%CASSANDRA_CONF%;%CASSANDRA_HOME%\lib\*"

@rem JVM options. Each -D path is quoted with embedded "" so paths containing
@rem spaces (USERPROFILE with a space, etc.) reach Java as one argument.
set "JVM_OPTS=-Xms512M -Xmx512M -Xss256k"
set "JVM_OPTS=!JVM_OPTS! -XX:+UseG1GC -XX:+AlwaysPreTouch -XX:+UseNUMA"
set "JVM_OPTS=!JVM_OPTS! -XX:+HeapDumpOnOutOfMemoryError"
set "JVM_OPTS=!JVM_OPTS! -Djava.net.preferIPv4Stack=true"
set "JVM_OPTS=!JVM_OPTS! -Dsun.net.inetaddr.ttl=0"
set "JVM_OPTS=!JVM_OPTS! -Dcassandra-foreground=yes"
@rem Local JMX on 7199 so nodetool works (3.11's launcher sets this; our shim must too).
set "JVM_OPTS=!JVM_OPTS! -Dcassandra.jmx.local.port=7199"
set JVM_OPTS=!JVM_OPTS! -Dcassandra.logdir="!CASSANDRA_LOG_DIR!"
set JVM_OPTS=!JVM_OPTS! -Dcassandra.storagedir="!CASSANDRA_DATA!"
set JVM_OPTS=!JVM_OPTS! -Dlogback.configurationFile="!CASSANDRA_CONF!\logback.xml"
set JVM_OPTS=!JVM_OPTS! -XX:HeapDumpPath="!CASSANDRA_LOG_DIR!\cassandra-heap.hprof"

echo Starting Apache Cassandra $CASSANDRA_VERSION...
echo Native transport port : 9042  ^(CQL clients connect here^)
echo Logs                  : !CASSANDRA_LOG_DIR!
echo Press Ctrl+C to stop.
echo.

"%JAVA_HOME%\bin\java" !JVM_OPTS! -cp "!CASSANDRA_CP!" org.apache.cassandra.service.CassandraDaemon
"@

# cqlsh.cmd - built per Python mode ($cqlshMode, decided in the pre-flight check).
# "Auto: best of both": py2-bundled when Python 2.7 is present (full features incl.
# DESCRIBE), else a Python-3 PyPI cqlsh in a private venv (portable; no DESCRIBE).
if ($cqlshMode -eq "py3") {
    Write-Step "5.0" "Setting up the Python 3 cqlsh client in a private venv (one-time, downloads from PyPI)..."
    $cqlshVenv  = "$INSTALL_DIR\cqlsh-venv"
    $cqlshReady = $false
    try {
        if (Test-Path $cqlshVenv) { Remove-Item $cqlshVenv -Recurse -Force -ErrorAction SilentlyContinue }
        $pyExe, $pyRest = $py3Cmd -split ' ', 2
        if ($pyRest) { & $pyExe $pyRest -m venv $cqlshVenv } else { & $pyExe -m venv $cqlshVenv }
        $venvPy = "$cqlshVenv\Scripts\python.exe"
        if (Test-Path $venvPy) {
            # 'cqlsh' = the CQL client; 'pyasyncore' = the asyncore backport that the
            # cassandra driver needs on Python 3.12+ (3.12 removed stdlib asyncore).
            & $venvPy -m pip install --quiet --disable-pip-version-check --upgrade pip 2>&1 | Out-Null
            & $venvPy -m pip install --quiet --disable-pip-version-check cqlsh pyasyncore 2>&1 | Out-Null
            if (Test-Path "$cqlshVenv\Scripts\cqlsh.exe") {
                $cqlshReady = $true
                Write-Success "Python 3 cqlsh installed: $cqlshVenv\Scripts\cqlsh.exe"
            }
        }
    }
    catch { Write-Warn "cqlsh venv setup failed: $($_.Exception.Message.Split([char]10)[0])" }
    if (-not $cqlshReady) {
        Write-Warn "Could not set up the Python 3 cqlsh client (no internet, or pip failed)."
        Write-Warn "The server is unaffected. Retry later: '$py3Cmd -m venv `"$cqlshVenv`"' then pip install cqlsh pyasyncore."
    }
    $cqlshCmdContent = @"
@echo off
@rem cqlsh Windows wrapper (Python 3 client in a private venv)
@rem Generated by install-cassandra.ps1  |  Author: VANSH RANA
setlocal
if not defined CASSANDRA_HOME set "CASSANDRA_HOME=$INSTALL_DIR"
set "CQLSH_EXE=%CASSANDRA_HOME%\cqlsh-venv\Scripts\cqlsh.exe"
if not exist "%CQLSH_EXE%" (
    echo [ERROR] Python 3 cqlsh client not found at %CQLSH_EXE%
    echo         Re-run install-cassandra.ps1 ^(needs internet^) to set it up.
    exit /b 1
)
echo Connecting to Cassandra at localhost:9042 ...
echo NOTE: DESCRIBE is unavailable with the Python 3 client on a 3.11 server.
echo       Use system_schema instead, e.g.:
echo         SELECT keyspace_name FROM system_schema.keyspaces;
echo         SELECT table_name FROM system_schema.tables WHERE keyspace_name='your_ks';
echo Use QUIT or EXIT to leave the shell.
echo.
"%CQLSH_EXE%" %*
"@
}
elseif ($cqlshMode -eq "py2") {
    $cqlshCmdContent = @"
@echo off
@rem cqlsh Windows wrapper (Python 2.7 + bundled 3.11 cqlsh = full features incl. DESCRIBE)
@rem Generated by install-cassandra.ps1  |  Author: VANSH RANA
setlocal EnableDelayedExpansion
if not defined CASSANDRA_HOME set "CASSANDRA_HOME=$INSTALL_DIR"
set "CQLSH=!CASSANDRA_HOME!\bin\cqlsh.py"
if not exist "!CQLSH!" set "CQLSH=!CASSANDRA_HOME!\bin\cqlsh"
if not exist "!CQLSH!" (
    echo [ERROR] bundled cqlsh not found under !CASSANDRA_HOME!\bin
    exit /b 1
)
echo Connecting to Cassandra at localhost:9042 ...
echo Use QUIT or EXIT to leave the shell.
echo.
$py27Cmd "!CQLSH!" %*
"@
}
else {
    $cqlshCmdContent = @"
@echo off
@rem cqlsh Windows wrapper (no Python client was available at install time)
@rem Generated by install-cassandra.ps1  |  Author: VANSH RANA
echo [ERROR] No Python client is configured for cqlsh.
echo         Install Python 3 from https://www.python.org/downloads/ and re-run
echo         install-cassandra.ps1, or install Python 2.7.18 for full DESCRIBE support.
echo         ^(The Cassandra server itself runs fine without cqlsh.^)
exit /b 1
"@
}

# stop-cassandra.cmd - kills cassandra java processes
$stopCassandraCmdContent = @"
@echo off
@rem Stop Cassandra (kills Java processes running CassandraDaemon)
@rem Generated by install-cassandra.ps1  |  Author: VANSH RANA
echo Stopping Cassandra...
set _KILLED=0

@rem Try jps first (JDK tool - most reliable)
jps >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=1" %%p in ('jps 2^>nul ^| findstr /i "CassandraDaemon"') do (
        echo   Killing PID %%p ^(jps^)
        taskkill /PID %%p /F >nul 2>&1
        set _KILLED=1
    )
) else (
    @rem jps not available (JRE-only) - write a temp PS script then run it to avoid quoting hell
    powershell -NoProfile -Command "$f='%TEMP%\find_cassandra.ps1'; Set-Content $f 'Get-Process java -EA SilentlyContinue | Where-Object { try { (Get-WmiObject Win32_Process -Filter (\"ProcessId=\"+$_.Id)).CommandLine -like \"*CassandraDaemon*\" } catch { $false } } | Select-Object -Expand Id'" >nul 2>&1
    for /f "delims=" %%p in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\find_cassandra.ps1" 2^>nul') do (
        echo   Killing PID %%p ^(WMI fallback^)
        taskkill /PID %%p /F >nul 2>&1
        set _KILLED=1
    )
    del "%TEMP%\find_cassandra.ps1" >nul 2>&1
)

if "%_KILLED%"=="0" (
    echo   No running Cassandra process found.
) else (
    echo Cassandra stopped.
)
"@

# Write a .cmd shim that cmd.exe can actually parse. Two hard requirements:
#   1. CRLF line endings - a .cmd with LF-only endings makes cmd.exe mis-seek and
#      execute line fragments (you get errors like "'em' is not recognized" from a
#      truncated @rem). This script's source is saved with LF, and here-strings
#      inherit those LF newlines, so we MUST re-expand them to CRLF before writing.
#   2. 7-bit ASCII, no BOM - cmd.exe reads bytes in the console's OEM codepage. A
#      multi-byte char (e.g. a UTF-8 em-dash) or a UTF-8 BOM corrupts parsing.
#      ASCII encoding guarantees single-byte, codepage-safe output. All baked-in
#      paths are ASCII (INSTALL_DIR=C:\cassandra; data dir is relocated off any
#      non-ASCII USERPROFILE; JAVA_HOME uses an 8.3 short path).
function Write-CmdShim {
    param([string]$Path, [string]$Content)
    $crlf = ($Content -replace "`r`n", "`n") -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $crlf, [System.Text.Encoding]::ASCII)
}

Write-Step "5.1" "Writing cassandra.cmd launcher..."
Write-CmdShim "$INSTALL_DIR\bin\cassandra.cmd" $cassandraCmdContent
Write-Success "cassandra.cmd -> $INSTALL_DIR\bin\cassandra.cmd"

Write-Step "5.2" "Writing cqlsh.cmd wrapper..."
Write-CmdShim "$INSTALL_DIR\bin\cqlsh.cmd" $cqlshCmdContent
Write-Success "cqlsh.cmd -> $INSTALL_DIR\bin\cqlsh.cmd"

Write-Step "5.3" "Writing stop-cassandra.cmd..."
Write-CmdShim "$INSTALL_DIR\bin\stop-cassandra.cmd" $stopCassandraCmdContent
Write-Success "stop-cassandra.cmd -> $INSTALL_DIR\bin\stop-cassandra.cmd"

# Make the shipped .bat launchers delegate to our working .cmd shims. Reason: when a user
# types bare "cqlsh" or "cassandra", Windows resolves .BAT before .CMD (PATHEXT order), so
# the shipped cqlsh.bat (which runs the Python-2 cqlsh.py under Python 3 -> SyntaxError) and
# cassandra.bat would shadow our shims. Delegating makes the bare command "just work".
Write-Step "5.4" "Redirecting shipped launchers (cqlsh.bat, cassandra.bat, cassandra.ps1) to the working shims..."
# .bat: CMD resolves .BAT before .CMD, so the shipped .bat would shadow our .cmd.
Write-CmdShim "$INSTALL_DIR\bin\cqlsh.bat"     "@echo off`r`ncall `"%~dp0cqlsh.cmd`" %*`r`n"
Write-CmdShim "$INSTALL_DIR\bin\cassandra.bat" "@echo off`r`ncall `"%~dp0cassandra.cmd`" %*`r`n"
# .ps1: PowerShell resolves a .ps1 on PATH before .bat/.cmd, so the shipped cassandra.ps1
# would shadow our shim when a user types bare "cassandra" in a PowerShell window.
Write-CmdShim "$INSTALL_DIR\bin\cassandra.ps1" "& `"`$PSScriptRoot\cassandra.cmd`" @args`r`n"
Write-Success "cqlsh / cassandra now route to cqlsh.cmd / cassandra.cmd in both CMD and PowerShell"

# Strip BOM from any cmd/bat files Cassandra itself shipped
$shimFiles = @(
    "$INSTALL_DIR\bin\cassandra.cmd",
    "$INSTALL_DIR\bin\cqlsh.cmd",
    "$INSTALL_DIR\bin\stop-cassandra.cmd",
    "$INSTALL_DIR\bin\cassandra.bat",
    "$INSTALL_DIR\conf\cassandra-env.ps1"
)
foreach ($f in $shimFiles) {
    if (Test-Path $f) {
        $raw = [System.IO.File]::ReadAllBytes($f)
        if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
            # Cast slice to byte[] explicitly - PS array slicing returns object[] otherwise
            [byte[]]$stripped = $raw[3..($raw.Length - 1)]
            [System.IO.File]::WriteAllBytes($f, $stripped)
            Write-Success "BOM stripped from: $(Split-Path $f -Leaf)"
        }
    }
}

# ============================================================================
#  STEP 6: WINDOWS DEFENDER EXCLUSION
# ============================================================================

Write-Banner "STEP 6: Windows Defender Exclusions"

Write-Step "6.1" "Adding Windows Defender exclusion for Cassandra directories..."
try {
    Add-MpPreference -ExclusionPath $INSTALL_DIR    -ErrorAction Stop
    Write-Success "Defender exclusion added: $INSTALL_DIR"
}
catch {
    Write-Warn "Could not add Defender exclusion for $INSTALL_DIR : $($_.Exception.Message.Split([char]10)[0])"
    Write-Warn "If Cassandra JARs get quarantined, add exclusion manually via Windows Security."
}

try {
    Add-MpPreference -ExclusionPath $CASSANDRA_DATA -ErrorAction Stop
    Write-Success "Defender exclusion added: $CASSANDRA_DATA"
}
catch {
    Write-Warn "Could not add Defender exclusion for $CASSANDRA_DATA"
}

# ============================================================================
#  STEP 7: WINDOWS FIREWALL RULES
# ============================================================================

Write-Banner "STEP 7: Windows Firewall Rules"

$firewallPorts = @(
    @{ Port = 9042; Name = "Cassandra-CQL-Native"; Description = "Cassandra CQL native transport (client connections)" },
    @{ Port = 7000; Name = "Cassandra-Internode"; Description = "Cassandra inter-node communication" },
    @{ Port = 7001; Name = "Cassandra-Internode-SSL"; Description = "Cassandra inter-node SSL" },
    @{ Port = 7199; Name = "Cassandra-JMX"; Description = "Cassandra JMX monitoring port" },
    @{ Port = 9160; Name = "Cassandra-Thrift"; Description = "Cassandra Thrift (legacy, disabled by default)" }
)

foreach ($fw in $firewallPorts) {
    try {
        $existing = Get-NetFirewallRule -DisplayName $fw.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $fw.Name -Direction Inbound -Protocol TCP `
                -LocalPort $fw.Port -Action Allow -ErrorAction Stop | Out-Null
            Write-Success "Firewall rule added: $($fw.Name) (port $($fw.Port))"
        }
        else {
            Write-Success "Firewall rule already exists: $($fw.Name)"
        }
    }
    catch {
        Write-Warn "Could not add firewall rule for $($fw.Name): $($_.Exception.Message.Split([char]10)[0])"
    }
}

# ============================================================================
#  STEP 8: VERIFICATION
# ============================================================================

Write-Banner "STEP 8: Installation Verification"

$allGood = $true

# Check key binaries and config files
# cassandra.bat presence is version-dependent; check either cassandra.bat or cassandra (no ext)
$cassandraMainBin = if (Test-Path "$INSTALL_DIR\bin\cassandra.bat") { "$INSTALL_DIR\bin\cassandra.bat" } else { "$INSTALL_DIR\bin\cassandra" }
$checks = @(
    @{ Path = $cassandraMainBin; Label = "cassandra launcher (bat/script)" },
    @{ Path = "$INSTALL_DIR\bin\cassandra.cmd"; Label = "cassandra.cmd (Windows shim)" },
    @{ Path = "$INSTALL_DIR\bin\cqlsh.cmd"; Label = "cqlsh.cmd (CQL shell shim)" },
    @{ Path = "$INSTALL_DIR\bin\stop-cassandra.cmd"; Label = "stop-cassandra.cmd" },
    @{ Path = "$INSTALL_DIR\conf\cassandra.yaml"; Label = "cassandra.yaml" },
    @{ Path = "$INSTALL_DIR\conf\cassandra-env.ps1"; Label = "cassandra-env.ps1" },
    @{ Path = "$INSTALL_DIR\lib"; Label = "lib directory" }
)

foreach ($chk in $checks) {
    if (Test-Path $chk.Path) {
        Write-Success "$($chk.Label): OK"
    }
    else {
        Write-Err "$($chk.Label): MISSING - $($chk.Path)"
        $allGood = $false
    }
}

# Check env vars
$cassandraHomeEnv = [System.Environment]::GetEnvironmentVariable("CASSANDRA_HOME", "Machine")
if ($cassandraHomeEnv -eq $INSTALL_DIR) {
    Write-Success "CASSANDRA_HOME env var: OK ($cassandraHomeEnv)"
}
else {
    Write-Warn "CASSANDRA_HOME env var not confirmed. Current value: $cassandraHomeEnv"
}

$javaHomeEnv = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if ($javaHomeEnv -and (Test-Path "$javaHomeEnv\bin\java.exe")) {
    Write-Success "JAVA_HOME env var: OK ($javaHomeEnv)"
}
else {
    Write-Warn "JAVA_HOME env var missing or invalid. Current value: $javaHomeEnv"
}

$systemPath  = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$pathEntries = ($systemPath -split ';') | ForEach-Object { $_.Trim() }
if ($pathEntries -contains "$INSTALL_DIR\bin") {
    Write-Success "PATH contains Cassandra bin: OK"
}
else {
    Write-Warn "PATH may not contain Cassandra bin. Check manually."
}

# Check data directories
foreach ($d in @($CASSANDRA_DATA, "$CASSANDRA_DATA\data", "$CASSANDRA_DATA\commitlog", "$CASSANDRA_DATA\saved_caches", "$CASSANDRA_DATA\hints", "$CASSANDRA_DATA\cdc_raw", "$CASSANDRA_DATA\logs")) {
    if (Test-Path $d) { Write-Success "Data dir: $d" }
    else { Write-Warn "Data dir missing: $d" }
}

# Check cqlsh client (mode decided in pre-flight: py2-bundled / py3-venv / none)
switch ($cqlshMode) {
    "py2" {
        Write-Success "cqlsh: bundled client via Python 2.7 ($py27Cmd) - full features incl. DESCRIBE"
    }
    "py3" {
        if (Test-Path "$INSTALL_DIR\cqlsh-venv\Scripts\cqlsh.exe") {
            Write-Success "cqlsh: Python 3 client in venv ($INSTALL_DIR\cqlsh-venv) - DESCRIBE unavailable on 3.11"
        }
        else {
            Write-Warn "cqlsh: Python 3 venv not ready (pip/internet failed). Re-run to set it up; server is unaffected."
        }
    }
    default {
        Write-Warn "cqlsh: no Python client configured. Install Python 3 and re-run; the server runs fine without cqlsh."
    }
}

# ============================================================================
#  FINAL SUMMARY
# ============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  CASSANDRA INSTALLATION COMPLETE" -NoNewline -ForegroundColor Green
Write-Host "                   by VANSH RANA" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""
Write-Host "  Cassandra Version : $CASSANDRA_VERSION"              -ForegroundColor White
Write-Host "  Install Dir       : $INSTALL_DIR"                    -ForegroundColor White
Write-Host "  Data Dir          : $CASSANDRA_DATA"                 -ForegroundColor White
Write-Host "  CQL Port          : 9042"                            -ForegroundColor White
Write-Host "  Log Dir           : $CASSANDRA_DATA\logs"            -ForegroundColor White
Write-Host ""
Write-Host "  IMPORTANT: Open a NEW PowerShell/CMD window for env vars to take effect!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Start Cassandra:" -ForegroundColor White
Write-Host "       cd $INSTALL_DIR\bin" -ForegroundColor DarkCyan
Write-Host "       .\cassandra.cmd" -ForegroundColor DarkCyan
Write-Host "     (Wait for 'Starting listening for CQL clients' in the output)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. Open CQL Shell (in a NEW terminal window):" -ForegroundColor White
Write-Host "       cd $INSTALL_DIR\bin" -ForegroundColor DarkCyan
Write-Host "       .\cqlsh.cmd" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  3. Quick test in cqlsh:" -ForegroundColor White
if ($cqlshMode -eq "py3") {
    Write-Host "       cqlsh> SELECT keyspace_name FROM system_schema.keyspaces;  -- (DESCRIBE n/a on Py3 client)" -ForegroundColor DarkCyan
} else {
    Write-Host "       cqlsh> DESCRIBE KEYSPACES;" -ForegroundColor DarkCyan
}
Write-Host "       cqlsh> CREATE KEYSPACE test WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};" -ForegroundColor DarkCyan
Write-Host "       cqlsh> USE test;" -ForegroundColor DarkCyan
Write-Host "       cqlsh:test> CREATE TABLE users (id UUID PRIMARY KEY, name TEXT, age INT);" -ForegroundColor DarkCyan
Write-Host "       cqlsh:test> INSERT INTO users (id, name, age) VALUES (uuid(), 'Vansh', 21);" -ForegroundColor DarkCyan
Write-Host "       cqlsh:test> SELECT * FROM users;" -ForegroundColor DarkCyan
Write-Host "       cqlsh:test> EXIT;" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  4. Web / Monitoring (JMX):" -ForegroundColor White
Write-Host "       nodetool status   -- cluster health" -ForegroundColor DarkCyan
Write-Host "       nodetool info     -- node details" -ForegroundColor DarkCyan
Write-Host "       nodetool tpstats  -- thread pool stats" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  5. Stop Cassandra:" -ForegroundColor White
Write-Host "       cd $INSTALL_DIR\bin" -ForegroundColor DarkCyan
Write-Host "       .\stop-cassandra.cmd" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  KEY PORTS:" -ForegroundColor Cyan
Write-Host "       9042  - CQL native transport (client connections)" -ForegroundColor DarkCyan
Write-Host "       7000  - Inter-node communication (gossip)" -ForegroundColor DarkCyan
Write-Host "       7199  - JMX (nodetool connects here)" -ForegroundColor DarkCyan
Write-Host ""

if (-not $allGood) {
    Write-Warn "Some checks above failed. Review errors before starting Cassandra."
}
else {
    Write-Success "All checks passed. Cassandra is ready to use!"
}

Write-Host ""
Write-Host "  TROUBLESHOOTING:" -ForegroundColor Cyan
Write-Host "    - Logs are in: $CASSANDRA_DATA\logs" -ForegroundColor DarkGray
Write-Host "    - If port 9042 fails, check another Cassandra is not already running:" -ForegroundColor DarkGray
Write-Host "        jps  (should show CassandraDaemon)" -ForegroundColor DarkGray
Write-Host "    - cqlsh client: Python 2.7 -> bundled (full features); Python 3 -> venv at $INSTALL_DIR\cqlsh-venv (no DESCRIBE)" -ForegroundColor DarkGray
Write-Host "    - If cqlsh fails: re-run this script with internet so the Python 3 client can be installed, or install Python 2.7.18" -ForegroundColor DarkGray
Write-Host "    - cassandra.yaml is at: $INSTALL_DIR\conf\cassandra.yaml" -ForegroundColor DarkGray
Write-Host ""

# Cleanup prompt
if (Confirm-Continue "Delete temporary download files (archive, 7-Zip installer)?") {
    $filesToClean = @(
        "$TEMP_DIR\apache-cassandra-$CASSANDRA_VERSION-bin.tar.gz",
        "$TEMP_DIR\7z_installer.exe"
    )
    foreach ($f in $filesToClean) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path "$TEMP_DIR\cassandra-extract") { Remove-Item "$TEMP_DIR\cassandra-extract" -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $SAFE_INSTALL_TEMP)             { Remove-Item $SAFE_INSTALL_TEMP            -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Success "Temp download files cleaned up (log file kept)"
}

Write-Host ""
Write-Host "  [LOG] Full transcript saved to: $_logFile" -ForegroundColor DarkGray

Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
