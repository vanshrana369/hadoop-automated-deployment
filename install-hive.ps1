#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated Apache Hive Installation Script for Windows

.DESCRIPTION
    This script automates the COMPLETE Apache Hive installation on Windows, including:
    1. Pre-flight checks (Java 8, Hadoop, HADOOP_HOME validation)
    2. Hive 3.1.3 download and extraction
    3. Environment variables configuration (HIVE_HOME, PATH)
    4. Hive configuration files (hive-site.xml, hive-env.cmd)
    5. Derby metastore initialization (schematool -initSchema)
    6. HDFS user directories creation (/user/hive/warehouse)
    7. Permissions fix on warehouse and scratch directories
    8. Guava JAR conflict fix (Hive ships an older guava than Hadoop)

.NOTES
    Author:  VANSH RANA
    Date:    2026-04-21
    Version: 1.0

    REQUIREMENTS:
    - Run as Administrator (right-click PowerShell > Run as Administrator)
    - Internet connection for downloads
    - Windows 10/11
    - Java 8 (Eclipse Temurin) already installed
    - Hadoop 3.x already installed and configured

    USAGE:
    1. Right-click PowerShell and "Run as Administrator"
    2. Run:  Set-ExecutionPolicy Bypass -Scope Process -Force
    3. Run:  .\install-hive.ps1

    You can customize the variables below before running.
#>

# ============================================================================
#  CONFIGURATION - Modify these as needed before running
# ============================================================================

$HIVE_VERSION  = "3.1.3"
$INSTALL_DIR   = "C:\hive"                          # Where Hive will be installed
$HADOOP_HOME   = "C:\hadoop"                         # Existing Hadoop install directory
$HIVE_DB_DIR   = "$env:USERPROFILE\hive-data"       # Derby metastore + scratch dir (user-owned)
$LOG_DIR       = "$HIVE_DB_DIR\logs"                 # Hive log directory

$TEMP_DIR      = "$env:TEMP\hive-install"           # Temporary download directory
$HIVE_PORT     = "10000"                             # HiveServer2 port
$HIVE_WEB_PORT = "10002"                             # HiveServer2 Web UI port

# Apache mirrors - dlcdn can sometimes return 404, so we list several
$HIVE_URLS = @(
    "https://dlcdn.apache.org/hive/hive-$HIVE_VERSION/apache-hive-$HIVE_VERSION-bin.tar.gz",
    "https://downloads.apache.org/hive/hive-$HIVE_VERSION/apache-hive-$HIVE_VERSION-bin.tar.gz",
    "https://archive.apache.org/dist/hive/hive-$HIVE_VERSION/apache-hive-$HIVE_VERSION-bin.tar.gz",
    "https://mirrors.gigenet.com/apache/hive/hive-$HIVE_VERSION/apache-hive-$HIVE_VERSION-bin.tar.gz"
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
    Write-Host "  $Text" -NoNewline -ForegroundColor Cyan
    $padding = 70 - $Text.Length - 19
    # Clamp padding to 0 so we never pass a negative number to string multiply
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
    $response = Read-Host "  $Message (Y/N)"
    if ($response -ne 'Y' -and $response -ne 'y') {
        Write-Host "  Skipped." -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Download-WithProgress {
    <#
    .SYNOPSIS
        Downloads a file with a real-time progress bar showing %, speed, and size.
    #>
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$DisplayName = "",
        [int]$TimeoutSec = 300
    )

    if (-not $DisplayName) { $DisplayName = [System.IO.Path]::GetFileName($OutFile) }

    $uri = New-Object System.Uri($Url)
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Timeout = $TimeoutSec * 1000
    $request.UserAgent = "HiveInstaller/1.0"
    $request.AllowAutoRedirect = $true

    try {
        $response = $request.GetResponse()
    }
    catch {
        throw "Download failed for ${Url}: $_"
    }

    $totalBytes = $response.ContentLength
    $responseStream = $response.GetResponseStream()
    $fileStream = $null
    try {
        $fileStream = [System.IO.File]::Create($OutFile)
    }
    catch {
        $response.Close()
        $responseStream.Close()
        throw "Cannot create output file '${OutFile}': $_"
    }
    $buffer = New-Object byte[] 65536
    $downloadedBytes = [long]0
    $startTime = Get-Date
    $lastUpdate = [DateTime]::MinValue

    try {
        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                $lastUpdate = $now
                $elapsed = ($now - $startTime).TotalSeconds
                $speedBps = if ($elapsed -gt 0) { $downloadedBytes / $elapsed } else { 0 }
                $speedText = "$(Format-FileSize ([long]$speedBps))/s"
                $downloadedText = Format-FileSize $downloadedBytes

                if ($totalBytes -gt 0) {
                    $pct = [Math]::Round(($downloadedBytes / $totalBytes) * 100, 1)
                    $totalText = Format-FileSize $totalBytes
                    $barWidth = 30
                    $filled = [int][Math]::Floor($barWidth * $pct / 100)
                    $empty  = $barWidth - $filled
                    $bar = ("$([char]0x2588)" * $filled) + ("$([char]0x2591)" * $empty)
                    $line = "`r    [$bar] $pct%  $downloadedText / $totalText  ($speedText)   "
                }
                else {
                    $line = "`r    Downloading...  $downloadedText  ($speedText)   "
                }
                Write-Host $line -NoNewline -ForegroundColor DarkCyan
            }
        }

        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $avgSpeed = if ($elapsed -gt 0) { Format-FileSize ([long]($downloadedBytes / $elapsed)) } else { "?" }
        Write-Host "`r    Downloaded $(Format-FileSize $downloadedBytes) in $([Math]::Round($elapsed, 1))s ($avgSpeed/s)                    " -ForegroundColor Green
    }
    finally {
        if ($fileStream) { $fileStream.Close() }
        $responseStream.Close()
        $response.Close()
    }
}

function Download-WithFallback {
    <#
    .SYNOPSIS
        Downloads a file trying each URL in the list until one succeeds.
        Checks the file is non-zero after each download (Defender stub guard).
    #>
    param(
        [string[]]$Urls,
        [string]$OutFile,
        [string]$DisplayName,
        [int]$TimeoutSec = 300
    )
    foreach ($url in $Urls) {
        try {
            Write-Host "    Trying: $url" -ForegroundColor Gray
            Download-WithProgress -Url $url -OutFile $OutFile -DisplayName $DisplayName -TimeoutSec $TimeoutSec

            # Guard: Defender/antivirus sometimes replaces the file with a 0-byte stub
            if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -eq 0) {
                Write-Warn "    Downloaded file is 0 bytes or missing (likely quarantined by Defender) - trying next mirror..."
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

# ============================================================================
#  PRE-FLIGHT CHECKS
# ============================================================================

# Force TLS 1.2 - required by GitHub / Apache CDN
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Banner "HIVE AUTOMATED INSTALLER FOR WINDOWS"
Write-Host "  Hive Version   : $HIVE_VERSION"
Write-Host "  Install Path   : $INSTALL_DIR"
Write-Host "  Hadoop Home    : $HADOOP_HOME"
Write-Host "  Metastore Dir  : $HIVE_DB_DIR"
Write-Host "  Created by     : VANSH RANA" -ForegroundColor Magenta
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "  Right-click PowerShell > 'Run as Administrator', then re-run this script."
    exit 1
}
Write-Success "Running as Administrator"

# ---- Java 8 check ----
$existingJava = Get-Command java.exe -ErrorAction SilentlyContinue
if (-not $existingJava) {
    Write-Err "java.exe not found on PATH!"
    Write-Host "  Hive requires Java 8. Run install-hadoop.ps1 first (it installs Java 8)."
    exit 1
}
$javaVerRaw   = & "$($existingJava.Source)" -version 2>&1
$javaVerText  = ($javaVerRaw | ForEach-Object { $_.ToString() }) -join " "
if ($javaVerText -notmatch '1\.8\.0') {
    Write-Warn "Detected Java version: $javaVerText"
    Write-Warn "Hive 3.1.x officially supports Java 8. Other versions may work but are untested."
    if (-not (Confirm-Continue "Continue with non-Java-8 JVM?")) { exit 1 }
}
else {
    Write-Success "Java 8 detected - compatible with Hive $HIVE_VERSION"
}

# ---- Hadoop check ----
if (-not (Test-Path "$HADOOP_HOME\bin\hadoop.cmd")) {
    Write-Err "Hadoop not found at: $HADOOP_HOME\bin\hadoop.cmd"
    Write-Host "  Run install-hadoop.ps1 first, then re-run this script."
    exit 1
}
Write-Success "Hadoop found at: $HADOOP_HOME"

# ---- Resolve JAVA_HOME ----
$javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if (-not $javaHome -or -not (Test-Path "$javaHome\bin\java.exe")) {
    $javaHome = Split-Path (Split-Path $existingJava.Source -Parent) -Parent
}
Write-Success "JAVA_HOME resolved: $javaHome"

# Create temp directory
if (-not (Test-Path $TEMP_DIR)) {
    New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null
}

# ============================================================================
#  STEP 1: DOWNLOAD AND EXTRACT HIVE
# ============================================================================

Write-Banner "STEP 1: Apache Hive $HIVE_VERSION Download & Extraction"

$doDownload = $false
if (Test-Path "$INSTALL_DIR\bin\hive.cmd") {
    Write-Warn "Hive already exists at $INSTALL_DIR"
    if (-not (Confirm-Continue "Existing Hive found. OVERWRITE with Hive $HIVE_VERSION?")) {
        Write-Success "Keeping existing Hive installation"
    }
    else {
        Write-Step "1.0" "Backing up existing Hive conf..."
        $backupDir = "$TEMP_DIR\hive-conf-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (Test-Path "$INSTALL_DIR\conf") {
            Copy-Item "$INSTALL_DIR\conf" $backupDir -Recurse -Force
            Write-Success "Conf backed up to: $backupDir"
        }
        Write-Step "1.0b" "Removing old Hive binaries..."
        Remove-Item "$INSTALL_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        $doDownload = $true
    }
}
else {
    $doDownload = $true
}

if ($doDownload) {
    Write-Step "1.1" "Downloading Apache Hive $HIVE_VERSION (this is ~230MB, please wait)..."
    $hiveTarGz = "$TEMP_DIR\apache-hive-$HIVE_VERSION-bin.tar.gz"

    $minHiveBytes = 100MB
    if (Test-Path $hiveTarGz) {
        $archiveSize = (Get-Item $hiveTarGz).Length
        if ($archiveSize -ge $minHiveBytes) {
            Write-Warn "Archive already downloaded ($(Format-FileSize $archiveSize)), reusing: $hiveTarGz"
        }
        else {
            Write-Warn "Cached archive is only $(Format-FileSize $archiveSize) -- likely corrupt. Re-downloading..."
            Remove-Item $hiveTarGz -Force
        }
    }

    if (-not (Test-Path $hiveTarGz)) {
        $downloaded = Download-WithFallback -Urls $HIVE_URLS -OutFile $hiveTarGz -DisplayName "Apache Hive $HIVE_VERSION" -TimeoutSec 300
        if (-not $downloaded) {
            Write-Err "All mirrors failed."
            Write-Host ""
            Write-Host "  Manual download from any of these:" -ForegroundColor Yellow
            $HIVE_URLS | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Host "  Save to: $hiveTarGz" -ForegroundColor Yellow
            Read-Host "  Press Enter after downloading manually"
        }
    }

    if (-not (Test-Path $hiveTarGz)) {
        Write-Err "Hive archive not found at $hiveTarGz. Cannot continue."
        exit 1
    }

    Write-Step "1.2" "Extracting Hive (this may take a minute)..."

    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    }

    $extractTemp = "$TEMP_DIR\hive-extract"
    if (Test-Path $extractTemp) { cmd /c rmdir /s /q "$extractTemp" }
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null

    $extracted = $false

    # Try built-in tar.exe first
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Write-Host "    Using built-in tar.exe for extraction..." -ForegroundColor Gray
        # Call tar.exe directly via &; PowerShell quotes each argument individually,
        # correctly handling spaces in paths without needing cmd /c.
        & tar.exe -xzf "$hiveTarGz" -C "$extractTemp" 2>$null

        $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-hive-*" } | Select-Object -First 1
        if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hive")) {
            $extracted = $true
            Write-Success "Extracted successfully using tar.exe"
        }
        else {
            Write-Warn "    tar.exe extraction failed or was incomplete. Trying 7-Zip fallback..."
            cmd /c rmdir /s /q "$extractTemp" 2>$null
            New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
        }
    }

    # Fallback to 7-Zip
    if (-not $extracted) {
        Write-Host "    Downloading standalone 7-Zip for reliable extraction..." -ForegroundColor Gray
        $7zInstaller = "$TEMP_DIR\7z_installer.exe"
        $7zDir = "$INSTALL_DIR\7zip-temp"

        $7zDownloaded = $false
        foreach ($zUrl in $7ZIP_URLS) {
            try {
                Download-WithProgress -Url $zUrl -OutFile $7zInstaller -DisplayName "7-Zip Installer"
                # Guard against Defender quarantine (0-byte stub)
                if (-not (Test-Path $7zInstaller) -or (Get-Item $7zInstaller).Length -eq 0) {
                    Remove-Item $7zInstaller -Force -ErrorAction SilentlyContinue
                    Write-Warn "    7-Zip installer is 0 bytes (quarantined?) - trying next mirror..."
                    continue
                }
                $7zDownloaded = $true
                break
            }
            catch {
                Write-Warn "    Failed to download 7-Zip from mirror, trying next..."
            }
        }

        if ($7zDownloaded) {
            Start-Process -FilePath $7zInstaller -ArgumentList "/S /D=$7zDir" -Wait -NoNewWindow
            $7zExe = "$7zDir\7z.exe"

            if (Test-Path $7zExe) {
                Write-Host "    Extracting gzip wrapper..." -ForegroundColor Gray
                & $7zExe x "$hiveTarGz" -o"$extractTemp" -y | Out-Null

                $tarFile = Get-ChildItem $extractTemp -Filter "*.tar" -File | Select-Object -First 1
                if ($tarFile) {
                    Write-Host "    Extracting tar archive..." -ForegroundColor Gray
                    & $7zExe x "$($tarFile.FullName)" -o"$extractTemp" -y | Out-Null
                    Remove-Item $tarFile.FullName -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-Warn "    No .tar file found after gzip extraction. Archive may be corrupt."
                }

                $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-hive-*" } | Select-Object -First 1
                if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
                if ($chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hive")) {
                    $extracted = $true
                    Write-Success "Extracted successfully using 7-Zip fallback"
                }
                else {
                    Write-Warn "    7-Zip fallback extraction failed."
                }
            }
        }
        else {
            Write-Warn "    Failed to download 7-Zip installer from all mirrors."
        }
    }

    if ($extracted) {
        $extractedFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "apache-hive-*" } | Select-Object -First 1
        if (-not $extractedFolder) { $extractedFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($extractedFolder -and (Test-Path "$($extractedFolder.FullName)\bin\hive")) {
            $roboSrc = $extractedFolder.FullName
            $roboDst = $INSTALL_DIR
            # robocopy sets $LASTEXITCODE 0-7 = success; capture BEFORE any other command resets it
            robocopy "$roboSrc" "$roboDst" /E /MOVE /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1 | Out-Null
            $roboCopyExit = $LASTEXITCODE
            cmd /c rmdir /s /q "$extractTemp" 2>$null
            if ($roboCopyExit -le 7) {
                Write-Success "Hive extracted to $INSTALL_DIR"
            }
            else {
                Write-Warn "robocopy reported issues (exit code $roboCopyExit), but files may still be usable."
                Write-Success "Hive extracted to $INSTALL_DIR (with warnings)"
            }
        }
        else {
            Write-Err "Extraction failed or archive structure unexpected (bin\hive not found)."
            Write-Err "Check $extractTemp manually."
            exit 1
        }
    }
    else {
        Write-Err "'tar.exe' and '7-Zip' both failed. Please extract manually."
        Write-Host "  Extract $hiveTarGz to $INSTALL_DIR"
        Read-Host "  Press Enter after extracting manually"
        if (-not (Test-Path "$INSTALL_DIR\bin\hive")) {
            Write-Err "Hive binaries not found at $INSTALL_DIR\bin\hive after manual extraction. Cannot continue."
            exit 1
        }
    }

    # Clean up 7-Zip temp dir if present
    if (Test-Path "$INSTALL_DIR\7zip-temp") {
        Remove-Item "$INSTALL_DIR\7zip-temp" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Ensure Windows .cmd binaries are present (Official Hive 3.x doesn't include them)
if (Test-Path "$INSTALL_DIR\bin\hive") {
    if (-not (Test-Path "$INSTALL_DIR\bin\hive.cmd")) {
        Write-Step "1.3" "Downloading missing Windows .cmd binaries (not included in Hive 3.x)..."
        $winBinZip = "$TEMP_DIR\hive-cmd-master.zip"
        $winBinDir = "$TEMP_DIR\hive-cmd"
        try {
            Download-WithProgress -Url "https://github.com/HadiFadl/Hive-cmd/archive/master.zip" -OutFile $winBinZip -DisplayName "Hive Windows Binaries"
            if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
                Expand-Archive -Path $winBinZip -DestinationPath $winBinDir -Force
                Copy-Item -Path "$winBinDir\Hive-cmd-master\bin\*" -Destination "$INSTALL_DIR\bin" -Recurse -Force | Out-Null
                Write-Success "Windows .cmd binaries installed successfully"
            } else {
                Write-Warn "Expand-Archive not found (old PS version?). Try manually adding them."
            }
        }
        catch {
            Write-Warn "Failed to download/install Windows binaries: $_"
        }
    }
}

# Ensure commons-collections 3.x is present (Hive 3.x removed it but still needs it for HMS)
$commonsJar = "$INSTALL_DIR\lib\commons-collections-3.2.2.jar"
if (-not (Test-Path $commonsJar)) {
    Write-Step "1.4" "Fixing missing Apache commons-collections jar (Hive 3.x oversight)..."
    try {
        Download-WithProgress -Url "https://repo1.maven.org/maven2/commons-collections/commons-collections/3.2.2/commons-collections-3.2.2.jar" -OutFile $commonsJar -DisplayName "commons-collections-3.2.2.jar"
        Write-Success "Added missing commons-collections dependency successfully"
    } catch {
        Write-Warn "Could not download commons-collections, Hive might fail to start if it isn't in Hadoop classpath."
    }
}

# Verify conf dir exists
$hiveConf = "$INSTALL_DIR\conf"
if (-not (Test-Path $hiveConf)) {
    Write-Warn "conf directory missing - creating it now..."
    New-Item -ItemType Directory -Path $hiveConf -Force | Out-Null
    Write-Success "Created: $hiveConf"
}

# ============================================================================
#  STEP 2: FIX GUAVA JAR CONFLICT
# ============================================================================
# Hive 3.1.x ships guava-19.0.jar but Hadoop 3.x requires guava-27.0.jar.
# Having both on the classpath at the same time causes:
#   java.lang.NoSuchMethodError: com.google.common.base.Preconditions.checkArgument
# The fix: replace Hive's guava with Hadoop's guava.

Write-Banner "STEP 2: Fix Guava JAR Conflict (Hive vs Hadoop)"

$hiveLib      = "$INSTALL_DIR\lib"
$hadoopGuava  = Get-ChildItem "$HADOOP_HOME\share\hadoop\common\lib" -Filter "guava-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
$hiveGuavaOld = Get-ChildItem "$hiveLib" -Filter "guava-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1

if ($hadoopGuava -and $hiveGuavaOld) {
    Write-Step "2.1" "Hive guava: $($hiveGuavaOld.Name)   Hadoop guava: $($hadoopGuava.Name)"
    if ($hiveGuavaOld.Name -ne $hadoopGuava.Name) {
        Write-Step "2.2" "Replacing Hive's guava with Hadoop's version..."
        Remove-Item $hiveGuavaOld.FullName -Force
        Copy-Item $hadoopGuava.FullName "$hiveLib\" -Force
        Write-Success "Guava conflict resolved: now using $($hadoopGuava.Name)"
    }
    else {
        Write-Success "Guava versions already match ($($hiveGuavaOld.Name)) - no fix needed"
    }
}
elseif (-not $hadoopGuava) {
    Write-Warn "Could not find guava JAR in $HADOOP_HOME\share\hadoop\common\lib - skipping fix"
}
else {
    Write-Success "No Hive guava JAR found to replace - likely already fixed"
}

# ============================================================================
#  STEP 3: SET ENVIRONMENT VARIABLES
# ============================================================================

Write-Banner "STEP 3: Environment Variables"

# HIVE_HOME
Write-Step "3.1" "Setting HIVE_HOME = $INSTALL_DIR"
$currentHiveHome = [System.Environment]::GetEnvironmentVariable("HIVE_HOME", "Machine")
if ($currentHiveHome -ne $INSTALL_DIR) {
    [System.Environment]::SetEnvironmentVariable("HIVE_HOME", $INSTALL_DIR, "Machine")
    $env:HIVE_HOME = $INSTALL_DIR
    Write-Success "HIVE_HOME set to: $INSTALL_DIR"
}
else {
    Write-Success "HIVE_HOME already correct: $INSTALL_DIR"
}

# PATH - add Hive bin
Write-Step "3.2" "Updating system PATH..."
$systemPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if (-not $systemPath) { $systemPath = "" }
$pathsToAdd = @(
    "%HIVE_HOME%\bin"
)

$resolvedPathEntries = $systemPath -split ';' | ForEach-Object {
    [System.Environment]::ExpandEnvironmentVariables($_.Trim())
} | Where-Object { $_ -ne '' }

$pathModified = $false
foreach ($p in $pathsToAdd) {
    $pResolved = [System.Environment]::ExpandEnvironmentVariables($p)
    $alreadyExists = ($systemPath -split ';' | ForEach-Object { $_.Trim() }) -contains $p
    $resolvedExists = $resolvedPathEntries -contains $pResolved
    if (-not $alreadyExists -and -not $resolvedExists) {
        if ($systemPath) { $systemPath = "$systemPath;$p" } else { $systemPath = $p }
        $pathModified = $true
        Write-Host "    Added to PATH: $p" -ForegroundColor Gray
    }
    else {
        Write-Host "    Already in PATH: $p" -ForegroundColor DarkGray
    }
}

if ($pathModified) {
    [System.Environment]::SetEnvironmentVariable("Path", $systemPath, "Machine")
    Write-Success "System PATH updated"
}
else {
    Write-Success "System PATH already has all required entries"
}

# User-level PATH for non-admin terminals
Write-Step "3.3" "Ensuring Hive is accessible in non-admin terminals..."
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$userPathsToAdd = @("$INSTALL_DIR\bin")
$userPathModified = $false
foreach ($up in $userPathsToAdd) {
    $userEntries = ($userPath -split ';') | ForEach-Object { $_.Trim() }
    if ($userEntries -notcontains $up) {
        if ($userPath) { $userPath = "$userPath;$up" } else { $userPath = $up }
        $userPathModified = $true
        Write-Host "    Added to User PATH: $up" -ForegroundColor Gray
    }
    else {
        Write-Host "    Already in User PATH: $up" -ForegroundColor DarkGray
    }
}
if ($userPathModified) {
    [System.Environment]::SetEnvironmentVariable("Path", $userPath, "User")
    Write-Success "User PATH updated"
}
else {
    Write-Success "User PATH already has Hive entries"
}

# Refresh session PATH
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath) { $env:Path = "$machinePath;$userPath" } else { $env:Path = $machinePath }
$env:HIVE_HOME  = $INSTALL_DIR
$env:HADOOP_HOME = $HADOOP_HOME

# ============================================================================
#  STEP 4: HIVE CONFIGURATION FILES
# ============================================================================

Write-Banner "STEP 4: Hive Configuration Files"

$metastoreDb     = "$HIVE_DB_DIR\metastore_db".Replace('\', '/')
$hiveLocalScratch = "$HIVE_DB_DIR\scratch".Replace('\', '/')
$warehouseDir    = "/user/hive/warehouse"    # HDFS path

# ---- hive-site.xml ----
Write-Step "4.1" "Writing hive-site.xml..."
$hiveSiteContent = @"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- hive-site.xml - Generated by Hive Installer Script -->
<configuration>

  <!-- ===== Metastore (embedded Derby) ===== -->
  <property>
    <name>javax.jdo.option.ConnectionURL</name>
    <value>jdbc:derby:;databaseName=$metastoreDb;create=true</value>
    <description>Derby JDBC URL for the embedded metastore</description>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionDriverName</name>
    <value>org.apache.derby.jdbc.EmbeddedDriver</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionUserName</name>
    <value>APP</value>
  </property>
  <property>
    <name>javax.jdo.option.ConnectionPassword</name>
    <value>mine</value>
  </property>

  <!-- ===== Warehouse & Scratch directories ===== -->
  <property>
    <name>hive.metastore.warehouse.dir</name>
    <value>$warehouseDir</value>
    <description>Default HDFS path for Hive-managed tables</description>
  </property>
  <property>
    <name>hive.exec.scratchdir</name>
    <value>/tmp/hive</value>
    <description>HDFS scratch directory for Hive query execution (must exist on HDFS)</description>
  </property>

  <!-- ===== HiveServer2 ===== -->
  <property>
    <name>hive.server2.thrift.port</name>
    <value>$HIVE_PORT</value>
  </property>
  <property>
    <name>hive.server2.webui.port</name>
    <value>$HIVE_WEB_PORT</value>
  </property>

  <!-- ===== Misc fixes for Windows ===== -->
  <property>
    <name>hive.exec.local.scratchdir</name>
    <value>$hiveLocalScratch</value>
  </property>
  <property>
    <name>hive.downloaded.resources.dir</name>
    <value>$hiveLocalScratch/resources</value>
  </property>
  <property>
    <name>hive.querylog.location</name>
    <value>$($LOG_DIR.Replace('\', '/'))</value>
  </property>

</configuration>
"@
if (-not (Test-Path $hiveConf)) { New-Item -ItemType Directory -Path $hiveConf -Force | Out-Null }
[System.IO.File]::WriteAllText("$hiveConf\hive-site.xml", $hiveSiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "hive-site.xml configured (Derby metastore, warehouse=$warehouseDir)"

# ---- hive-env.cmd ----
Write-Step "4.2" "Writing hive-env.cmd..."
$hiveEnvCmdContent = @"
@rem hive-env.cmd - Generated by Hive Installer Script
@rem Set HADOOP_HOME so Hive can locate Hadoop libraries
set HADOOP_HOME=$HADOOP_HOME
@rem Set JAVA_HOME
set JAVA_HOME=$javaHome
@rem Hive log directory
set HIVE_LOG_DIR=$LOG_DIR
"@
[System.IO.File]::WriteAllText("$hiveConf\hive-env.cmd", $hiveEnvCmdContent, [System.Text.Encoding]::ASCII)
Write-Success "hive-env.cmd configured"

# ---- hive-log4j2.properties (silence excessive logging) ----
Write-Step "4.3" "Checking hive-log4j2.properties..."
$log4jTemplate = "$hiveConf\hive-log4j2.properties.template"
$log4jDest     = "$hiveConf\hive-log4j2.properties"
if (-not (Test-Path $log4jDest)) {
    if (Test-Path $log4jTemplate) {
        Copy-Item $log4jTemplate $log4jDest -Force
        Write-Success "Copied hive-log4j2.properties from template"
    }
    else {
        Write-Warn "hive-log4j2.properties template not found - logging will use defaults"
    }
}
else {
    Write-Success "hive-log4j2.properties already exists"
}

# ============================================================================
#  STEP 5: CREATE LOCAL DATA DIRECTORIES
# ============================================================================

Write-Banner "STEP 5: Local Data Directories"

$localDirs = @(
    $HIVE_DB_DIR,
    "$HIVE_DB_DIR\scratch",
    "$HIVE_DB_DIR\scratch\resources",
    $LOG_DIR
)

foreach ($dir in $localDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Success "Created: $dir"
    }
    else {
        Write-Success "Already exists: $dir"
    }
}

# Grant BUILTIN\Users full control on the data dir (same pattern as Hadoop installer)
Write-Step "5.1" "Granting user permissions on $HIVE_DB_DIR..."
cmd /c "icacls `"$HIVE_DB_DIR`" /grant `"BUILTIN\Users:(OI)(CI)F`" /T /Q" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "BUILTIN\Users granted full control on $HIVE_DB_DIR (recursive)"
}
else {
    Write-Warn "icacls failed (exit $LASTEXITCODE). You may need to fix permissions manually."
}

# Also fix Hive install dir permissions (Read+Execute so non-admin users can run hive.cmd)
Write-Step "5.2" "Granting Read+Execute on $INSTALL_DIR for non-admin users..."
cmd /c "icacls `"$INSTALL_DIR`" /grant `"BUILTIN\Users:(OI)(CI)RX`" /T /Q" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "BUILTIN\Users granted Read+Execute on $INSTALL_DIR (recursive)"
}
else {
    Write-Warn "icacls on $INSTALL_DIR failed (exit $LASTEXITCODE) - hive.cmd may require admin to run"
}

# Create and fix $INSTALL_DIR\logs
Write-Step "5.3" "Creating $INSTALL_DIR\logs and granting write access..."
$hiveInstallLogs = "$INSTALL_DIR\logs"
if (-not (Test-Path $hiveInstallLogs)) {
    New-Item -ItemType Directory -Path $hiveInstallLogs -Force | Out-Null
}
cmd /c "icacls `"$hiveInstallLogs`" /grant `"BUILTIN\Users:(OI)(CI)F`" /T /Q" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "Created and granted user permissions on $hiveInstallLogs"
}
else {
    Write-Warn "icacls on $hiveInstallLogs failed (exit $LASTEXITCODE) - log writes may fail at runtime"
}

# ============================================================================
#  STEP 6: HDFS DIRECTORIES
# ============================================================================

Write-Banner "STEP 6: HDFS Directories for Hive"

Write-Host "  Checking that HDFS is reachable before creating directories..." -ForegroundColor Gray

$hdfsReady = $false
try {
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -ls / 2>&1 | Out-Null
    $hdfsCheckExit = $LASTEXITCODE
    if ($hdfsCheckExit -eq 0) {
        $hdfsReady = $true
        Write-Success "HDFS is running"
    }
    else {
        Write-Warn "HDFS ls returned exit code $hdfsCheckExit - HDFS may not be running."
    }
}
catch {
    Write-Warn "Could not connect to HDFS: $_"
}

if ($hdfsReady) {
    Write-Step "6.1" "Creating /tmp and /tmp/hive on HDFS..."
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p /tmp 2>&1 | Out-Null
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -chmod 1777 /tmp 2>&1 | Out-Null
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p /tmp/hive 2>&1 | Out-Null
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -chmod 1777 /tmp/hive 2>&1 | Out-Null
    Write-Success "HDFS /tmp and /tmp/hive ready (chmod 1777)"

    Write-Step "6.2" "Creating /user/hive/warehouse on HDFS..."
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p /user/hive/warehouse 2>&1 | Out-Null
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -chmod g+w /user/hive/warehouse 2>&1 | Out-Null
    Write-Success "HDFS /user/hive/warehouse ready"

    Write-Step "6.3" "Creating /user/$env:USERNAME on HDFS..."
    & "$HADOOP_HOME\bin\hdfs.cmd" dfs -mkdir -p "/user/$env:USERNAME" 2>&1 | Out-Null
    Write-Success "HDFS /user/$env:USERNAME ready"
}
else {
    Write-Warn "HDFS is not running. Skipping HDFS directory creation."
    Write-Warn "After starting HDFS (start-dfs.cmd), run these commands manually:"
    Write-Host "    hdfs dfs -mkdir -p /tmp" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -chmod 1777 /tmp" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -mkdir -p /tmp/hive" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -chmod 1777 /tmp/hive" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -mkdir -p /user/hive/warehouse" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -chmod g+w /user/hive/warehouse" -ForegroundColor Cyan
    Write-Host "    hdfs dfs -mkdir -p /user/$env:USERNAME" -ForegroundColor Cyan
}

# ============================================================================
#  STEP 7: INITIALIZE DERBY METASTORE (schematool)
# ============================================================================

Write-Banner "STEP 7: Initialize Hive Metastore (Derby)"

$metaDbPath  = "$HIVE_DB_DIR\metastore_db"

if (Test-Path "$metaDbPath\seg0") {
    Write-Warn "Metastore DB already initialized at $metaDbPath"
    if (-not (Confirm-Continue "Re-initialize metastore? (This will erase all Hive metadata)")) {
        Write-Success "Keeping existing metastore"
    }
    else {
        Remove-Item $metaDbPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step "7.1" "Running schematool -initSchema -dbType derby..."
        try {
            # hadoop classpath writes to stdout; take only the last non-empty line
            # (skips any WARNING: lines that precede the actual classpath)
            $env:HADOOP_CLASSPATH = (& "$HADOOP_HOME\bin\hadoop.cmd" classpath 2>$null) |
                Where-Object { $_ } | Select-Object -Last 1
            $schemaOut = & "$INSTALL_DIR\bin\hive.cmd" --service schematool -dbType derby -initSchema 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Metastore schema initialized"
            }
            else {
                Write-Warn "schematool exited with code $LASTEXITCODE. Output:"
                $schemaOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
        catch {
            Write-Err "hive.cmd --service schematool could not be launched: $_"
        }
    }
}
else {
    Write-Step "7.1" "Running schematool -initSchema -dbType derby..."
    try {
        # hadoop classpath writes to stdout; take only the last non-empty line
        # (skips any WARNING: lines that precede the actual classpath)
        $env:HADOOP_CLASSPATH = (& "$HADOOP_HOME\bin\hadoop.cmd" classpath 2>$null) |
            Where-Object { $_ } | Select-Object -Last 1
        $schemaOut = & "$INSTALL_DIR\bin\hive.cmd" --service schematool -dbType derby -initSchema 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Metastore schema initialized successfully"
        }
        else {
            Write-Warn "schematool exited with code $LASTEXITCODE. Output:"
            $schemaOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Write-Warn "You may need to run schematool manually after verifying hive-site.xml."
        }
    }
    catch {
        Write-Err "hive.cmd --service schematool could not be launched: $_"
        Write-Warn "Try running manually after setting HIVE_HOME:"
        Write-Host "    `$env:HIVE_HOME = '$INSTALL_DIR'" -ForegroundColor Cyan
        Write-Host "    `$env:HADOOP_HOME = '$HADOOP_HOME'" -ForegroundColor Cyan
        Write-Host "    `$env:HADOOP_CLASSPATH = (& '$HADOOP_HOME\bin\hadoop.cmd' classpath)" -ForegroundColor Cyan
        Write-Host "    & '$INSTALL_DIR\bin\hive.cmd' --service schematool -dbType derby -initSchema" -ForegroundColor Cyan
    }
}

# ============================================================================
#  STEP 8: ADD WINDOWS FIREWALL RULES
# ============================================================================

Write-Banner "STEP 8: Windows Firewall Rules"

try {
    $existingHS2 = Get-NetFirewallRule -DisplayName "Hive HiveServer2" -ErrorAction SilentlyContinue
    if (-not $existingHS2) {
        New-NetFirewallRule -DisplayName "Hive HiveServer2" -Direction Inbound -LocalPort $HIVE_PORT -Protocol TCP -Action Allow -ErrorAction Stop | Out-Null
        Write-Success "Firewall rule added: port $HIVE_PORT (HiveServer2 Thrift)"
    }
    else {
        Write-Success "Firewall rule already exists: port $HIVE_PORT"
    }

    $existingHS2Web = Get-NetFirewallRule -DisplayName "Hive HiveServer2 Web UI" -ErrorAction SilentlyContinue
    if (-not $existingHS2Web) {
        New-NetFirewallRule -DisplayName "Hive HiveServer2 Web UI" -Direction Inbound -LocalPort $HIVE_WEB_PORT -Protocol TCP -Action Allow -ErrorAction Stop | Out-Null
        Write-Success "Firewall rule added: port $HIVE_WEB_PORT (HiveServer2 Web UI)"
    }
    else {
        Write-Success "Firewall rule already exists: port $HIVE_WEB_PORT"
    }
}
catch {
    Write-Warn "Could not add firewall rules: $_"
    Write-Warn "Localhost access still works. Add rules manually if remote access is needed."
}

# ============================================================================
#  STEP 9: VERIFICATION
# ============================================================================

Write-Banner "STEP 9: Verification"

Write-Step "VERIFY" "Running 'hive --help' to confirm installation..."
try {
    $hiveVer = & "$INSTALL_DIR\bin\hive.cmd" --help 2>&1
    $hiveVerText = @($hiveVer | ForEach-Object { $_.ToString() })
    $outputOk = ($hiveVerText -join " ") -match "Usage" -or ($hiveVerText -join " ") -match "help"
    if ($outputOk) {
        Write-Success "Hive is installed and working:"
        $hiveVerText | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    else {
        Write-Warn "hive --help output was unexpected. Check installation."
        $hiveVerText | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}
catch {
    Write-Warn "Could not run hive --help: $_"
    Write-Warn "Open a NEW Command Prompt and run: hive --help"
}

# Cleanup prompt
if (Test-Path $TEMP_DIR) {
    if (Confirm-Continue "Delete temporary download files ($TEMP_DIR)?") {
        Remove-Item $TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Temp files cleaned up"
    }
}

# ============================================================================
#  STEP 10: SUMMARY & NEXT STEPS
# ============================================================================

Write-Banner "INSTALLATION COMPLETE!"

Write-Host "  Installation Summary:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  JAVA_HOME      : $javaHome" -ForegroundColor Gray
Write-Host "  HADOOP_HOME    : $HADOOP_HOME" -ForegroundColor Gray
Write-Host "  HIVE_HOME      : $INSTALL_DIR" -ForegroundColor Gray
Write-Host "  Metastore DB   : $HIVE_DB_DIR\metastore_db" -ForegroundColor Gray
Write-Host "  Warehouse (HDFS): $warehouseDir" -ForegroundColor Gray
Write-Host "  HiveServer2    : localhost:$HIVE_PORT" -ForegroundColor Gray
Write-Host ""

Write-Host "  IMPORTANT: Open a NEW Command Prompt to pick up environment variables!" -ForegroundColor Yellow
Write-Host ""

Write-Host "  Quick Start Commands (run in a NEW cmd.exe window):" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Start HDFS     :  " -NoNewline -ForegroundColor Gray
Write-Host "$HADOOP_HOME\sbin\start-dfs.cmd" -ForegroundColor Green
Write-Host "  Start YARN     :  " -NoNewline -ForegroundColor Gray
Write-Host "$HADOOP_HOME\sbin\start-yarn.cmd" -ForegroundColor Green
Write-Host "  Start HiveShell:  " -NoNewline -ForegroundColor Gray
Write-Host "hive" -ForegroundColor Green
Write-Host "  Start HiveServer2:" -NoNewline -ForegroundColor Gray
Write-Host "  hiveserver2" -ForegroundColor Green
Write-Host ""

Write-Host "  Connect via Beeline:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  beeline -u jdbc:hive2://localhost:$HIVE_PORT" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Web UIs:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  HiveServer2 UI :  " -NoNewline -ForegroundColor Gray
Write-Host "http://localhost:$HIVE_WEB_PORT" -ForegroundColor Cyan
Write-Host "  NameNode UI    :  " -NoNewline -ForegroundColor Gray
Write-Host "http://localhost:9870" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Quick HiveQL Test (inside hive shell):" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  CREATE DATABASE test_db;" -ForegroundColor Gray
Write-Host "  USE test_db;" -ForegroundColor Gray
Write-Host "  CREATE TABLE hello (id INT, name STRING);" -ForegroundColor Gray
Write-Host "  SHOW TABLES;" -ForegroundColor Gray
Write-Host ""

# ============================================================================
#  STAR ON GITHUB
# ============================================================================

Write-Host ""
Write-Host "  ======================================================================" -ForegroundColor DarkGray
Write-Host "  If this installer saved you time, please star the repo on GitHub!" -ForegroundColor Yellow
Write-Host ""
Write-Host "    https://github.com/vanshrana369/hadoop-automated-deployment" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Press S to open the repo in your browser, or any other key to skip." -ForegroundColor Gray
Write-Host "  ======================================================================" -ForegroundColor DarkGray
Write-Host ""
$key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
if ($key.Character -eq 's' -or $key.Character -eq 'S') {
    Start-Process "https://github.com/vanshrana369/hadoop-automated-deployment"
}
Write-Host ""
