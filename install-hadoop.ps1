#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated Hadoop Installation Script for Windows
    
.DESCRIPTION
    This script automates the COMPLETE Hadoop installation on Windows, including:
    1. Java 8 (Eclipse Temurin) installation
    2. Hadoop 3.4.3 download and extraction
    3. winutils.exe setup (required for Hadoop on Windows)
    4. Environment variables configuration (JAVA_HOME, HADOOP_HOME, PATH)
    5. Hadoop XML configuration files (core-site, hdfs-site, mapred-site, yarn-site)
    6. hadoop-env.cmd fix for JAVA_HOME (handles "Program Files" spaces)
    7. Data directories creation (namenode, datanode)
    8. NameNode formatting
    
.NOTES
    Author:  VANSH RANA
    Date:    2026-03-12
    Version: 2.0
    
    REQUIREMENTS:
    - Run as Administrator (right-click PowerShell > Run as Administrator)
    - Internet connection for downloads
    - Windows 10/11

    USAGE:
    1. Right-click PowerShell and "Run as Administrator"
    2. Run:  Set-ExecutionPolicy Bypass -Scope Process -Force
    3. Run:  .\install-hadoop.ps1
    
    You can customize the variables below before running.
#>

# ============================================================================
#  CONFIGURATION - Modify these as needed before running
# ============================================================================

$HADOOP_VERSION = "3.4.3"
$JAVA_VERSION = "8"                                     # Major version (Hadoop 3.4.x requires Java 8)
$INSTALL_DIR = "C:\hadoop"                             # Where Hadoop will be installed
$JAVA_INSTALL_DIR = "C:\Program Files\Eclipse Adoptium"     # Temurin default location
$DATA_DIR = "$env:USERPROFILE\hadoop-data"          # User-owned directory to avoid Admin locks
$LOG_DIR = "$DATA_DIR\logs"                         # User-owned log directory

$TEMP_DIR = "$env:TEMP\hadoop-install"              # Temporary download directory
$NAMENODE_PORT = "9000"                                  # HDFS NameNode RPC port
$REPLICATION = "1"                                     # HDFS replication factor (1 for single-node)

# Multiple Apache mirrors as fallback (dlcdn can sometimes return 404)
$HADOOP_URLS = @(
    "https://dlcdn.apache.org/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz",
    "https://downloads.apache.org/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz",
    "https://archive.apache.org/dist/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz",
    "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-main/$HADOOP_VERSION/hadoop-main-$HADOOP_VERSION.tar.gz",
    "https://mirrors.gigenet.com/apache/hadoop/common/hadoop-$HADOOP_VERSION/hadoop-$HADOOP_VERSION.tar.gz"
)
# NOTE: winutils 3.4.0 is the closest available build for the 3.4.x line
$WINUTILS_URLS = @(
    # cdarlint/winutils - most reliable, has every 3.x minor version (all cross-compatible with 3.4.x)
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.6/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.5/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.4/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.3/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.2/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.1/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.3.0/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.2.3/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.2.2/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.2.1/bin",
    "https://raw.githubusercontent.com/cdarlint/winutils/master/hadoop-3.1.3/bin",
    # steveloughran/winutils - original repo by a Hadoop committer
    "https://raw.githubusercontent.com/steveloughran/winutils/master/hadoop-3.0.0/bin",
    # kontext-tech/winutils - try last, 3.4.0 path sometimes 404
    "https://raw.githubusercontent.com/kontext-tech/winutils/master/hadoop-3.4.0/bin",
    "https://github.com/kontext-tech/winutils/raw/master/hadoop-3.4.0/bin"
)
$JAVA_URLS = @(
    "https://api.adoptium.net/v3/installer/latest/$JAVA_VERSION/ga/windows/x64/jdk/hotspot/normal/eclipse",
    "https://corretto.aws/downloads/latest/amazon-corretto-$JAVA_VERSION-x64-windows-jdk.msi",
    "https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u402-b06/OpenJDK8U-jdk_x64_windows_hotspot_8u402b06.msi"
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

function Get-ShortPath {
    # Convert a long path to 8.3 short path to avoid spaces issues
    param([string]$LongPath)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        if (Test-Path $LongPath -PathType Container) {
            return $fso.GetFolder($LongPath).ShortPath
        }
        elseif (Test-Path $LongPath -PathType Leaf) {
            return $fso.GetFile($LongPath).ShortPath
        }
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
    $request.UserAgent = "HadoopInstaller/2.0"
    $request.AllowAutoRedirect = $true

    try {
        $response = $request.GetResponse()
    }
    catch {
        throw "Download failed for ${Url}: $_"
    }

    $totalBytes = $response.ContentLength
    $responseStream = $response.GetResponseStream()
    $fileStream = [System.IO.File]::Create($OutFile)
    $buffer = New-Object byte[] 65536
    $downloadedBytes = [long]0
    $startTime = Get-Date
    $lastUpdate = [DateTime]::MinValue

    try {
        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            $now = Get-Date
            # Update the progress display every 250ms to avoid console flicker
            if (($now - $lastUpdate).TotalMilliseconds -ge 250) {
                $lastUpdate = $now
                $elapsed = ($now - $startTime).TotalSeconds
                $speedBps = if ($elapsed -gt 0) { $downloadedBytes / $elapsed } else { 0 }
                $speedText = "$(Format-FileSize ([long]$speedBps))/s"
                $downloadedText = Format-FileSize $downloadedBytes

                if ($totalBytes -gt 0) {
                    $pct = [Math]::Round(($downloadedBytes / $totalBytes) * 100, 1)
                    $totalText = Format-FileSize $totalBytes
                    # Build a visual bar: [########............] 42.3%
                    $barWidth = 30
                    $filled = [Math]::Floor($barWidth * $pct / 100)
                    $empty = $barWidth - $filled
                    $bar = ("$([char]0x2588)" * $filled) + ("$([char]0x2591)" * $empty)
                    $line = "`r    [$bar] $pct%  $downloadedText / $totalText  ($speedText)   "
                }
                else {
                    # Unknown total size - just show downloaded amount and speed
                    $line = "`r    Downloading...  $downloadedText  ($speedText)   "
                }
                Write-Host $line -NoNewline -ForegroundColor DarkCyan
            }
        }

        # Final progress line
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $avgSpeed = if ($elapsed -gt 0) { Format-FileSize ([long]($downloadedBytes / $elapsed)) } else { "?" }
        Write-Host "`r    Downloaded $(Format-FileSize $downloadedBytes) in $([Math]::Round($elapsed, 1))s ($avgSpeed/s)                    " -ForegroundColor Green
    }
    finally {
        $fileStream.Close()
        $responseStream.Close()
        $response.Close()
    }
}

# ============================================================================
#  PRE-FLIGHT CHECKS
# ============================================================================

# Force TLS 1.2 for all web requests - older Windows 10 builds default to TLS 1.0
# which GitHub and Apache CDN reject, causing all downloads to fail silently.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Banner "HADOOP AUTOMATED INSTALLER FOR WINDOWS"
Write-Host "  Hadoop Version : $HADOOP_VERSION"
Write-Host "  Java Version   : Temurin JDK $JAVA_VERSION"
Write-Host "  Install Path   : $INSTALL_DIR"
Write-Host "  Data Path      : $DATA_DIR"
Write-Host "  Created by     : VANSH RANA" -ForegroundColor Magenta
Write-Host ""

# Stop any running Java/Hadoop processes to avoid "Port in use" errors during reinstall
$javaProcs = Get-Process -Name "java" -ErrorAction SilentlyContinue
if ($javaProcs) {
    Write-Host ""
    Write-Warn "The following Java processes are currently running:"
    $javaProcs | ForEach-Object {
        $cpuSec = if ($_.CPU) { [Math]::Round($_.CPU, 1) } else { 0 }
        Write-Host "    PID $($_.Id)  $($_.MainWindowTitle -or $_.ProcessName)  (CPU: ${cpuSec}s)" -ForegroundColor DarkYellow
    }
    Write-Warn "These will be killed to prevent port conflicts during installation."
    Write-Warn "If IntelliJ, Eclipse, or another Java app is open, save your work first!"
    if (Confirm-Continue "Kill all Java processes and continue?") {
        $javaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Success "Java processes stopped"
    }
    else {
        Write-Err "Cannot continue with Java processes running (port conflicts likely)."
        Write-Host "  Please close all Java applications and re-run this script."
        exit 1
    }
}
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator!"
    Write-Host "  Right-click PowerShell > 'Run as Administrator', then re-run this script."
    exit 1
}
Write-Success "Running as Administrator"

# Create temp directory
if (-not (Test-Path $TEMP_DIR)) {
    New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null
}

# ============================================================================
#  STEP 1: INSTALL JAVA 8 (ECLIPSE TEMURIN)
# ============================================================================

Write-Banner "STEP 1: Java 8 (Eclipse Temurin) Installation"

$javaExists = $false
$javaHome = $null

# Check if Java is already installed
$existingJava = Get-Command java.exe -ErrorAction SilentlyContinue
if ($existingJava) {
    # Capture ALL output lines from java -version (outputs to stderr)
    $javaVerRaw = & "$($existingJava.Source)" -version 2>&1
    # Convert ErrorRecord objects to plain strings explicitly
    $javaVerLines = @($javaVerRaw | ForEach-Object { $_.ToString() })
    $javaVerFirst = ""
    if ($javaVerLines.Count -gt 0) { $javaVerFirst = $javaVerLines[0] }
    
    Write-Warn "Java already detected: $javaVerFirst"
    Write-Warn "Location: $($existingJava.Source)"
    Write-Host "    Full version output:" -ForegroundColor Gray
    foreach ($vline in $javaVerLines) {
        Write-Host "      $vline" -ForegroundColor Gray
    }
    
    # Parse the major version number from ALL output lines
    $majorVersion = $null
    $allVerText = $javaVerLines -join " "
    Write-Host "    Parsing version from: $allVerText" -ForegroundColor DarkGray
    
    # Pattern 1: Explicit "1.8" pattern (Java 8 old-style versioning)
    # This is the MOST RELIABLE check for Java 8 - check first!
    if ($allVerText -match '1\.8\.0') {
        $majorVersion = 8
        Write-Host "    Matched pattern: 1.8.0 (Java 8 old-style)" -ForegroundColor DarkGray
    }
    # Pattern 2: Quoted version like: version "11.0.21+9" or version "17.0.1"
    elseif ($allVerText -match 'version\s*"(\d+)\.(\d+)') {
        if ($Matches[1] -eq "1") {
            $majorVersion = [int]$Matches[2]
        }
        else {
            $majorVersion = [int]$Matches[1]
        }
        Write-Host "    Matched pattern: version X.Y -> major=$majorVersion" -ForegroundColor DarkGray
    }
    # Pattern 3: Unquoted like: openjdk 17 2023-09-19
    elseif ($allVerText -match '(?:openjdk|java)\s+(\d+)[\s\.]') {
        $majorVersion = [int]$Matches[1]
        Write-Host "    Matched pattern: unquoted version -> major=$majorVersion" -ForegroundColor DarkGray
    }
    # Pattern 4: Last resort - find any version-like number after "version"
    elseif ($allVerText -match 'version.*?(\d+)') {
        $majorVersion = [int]$Matches[1]
        if ($majorVersion -eq 1) {
            if ($allVerText -match 'version.*?1\.(\d+)') {
                $majorVersion = [int]$Matches[1]
            }
        }
        Write-Host "    Matched pattern: last-resort -> major=$majorVersion" -ForegroundColor DarkGray
    }
    
    if ($majorVersion) {
        Write-Host "    ==> Detected Java major version: $majorVersion" -ForegroundColor Yellow
    }
    else {
        Write-Warn "Could not parse Java version from output"
    }
    
    if ($majorVersion -eq 8) {
        Write-Success "Java 8 detected - compatible with Hadoop $HADOOP_VERSION"
        $envJavaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
        if ($envJavaHome -and (Test-Path $envJavaHome)) {
            $javaHome = $envJavaHome
            $javaExists = $true
            Write-Success "JAVA_HOME is set to: $javaHome"
        }
        else {
            # JAVA_HOME not set in registry - derive it from java.exe location
            # java.exe is at <JAVA_HOME>\bin\java.exe, so go up two levels
            $javaExePath = $existingJava.Source
            $derivedHome = Split-Path (Split-Path $javaExePath -Parent) -Parent
            if (Test-Path "$derivedHome\bin\java.exe") {
                $javaHome = $derivedHome
                $javaExists = $true
                Write-Warn "JAVA_HOME was not set. Auto-detected from java.exe path: $javaHome"
            }
        }
    }
    elseif ($majorVersion -and $majorVersion -ne 8) {
        # We positively know the version is NOT 8 - safe to uninstall
        Write-Err "Java $majorVersion is NOT compatible with Hadoop! Only Java 8 is supported."
        Write-Warn "The incompatible Java will be removed and Java 8 will be installed."
        Write-Host ""
        
        # --- Uninstall all existing Java installations ---
        Write-Step "1.0" "Removing incompatible Java installations..."
        
        # Find all Java-related products in the registry
        $uninstallPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        
        $javaProducts = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue | 
        Where-Object { 
            $_.DisplayName -and (
                $_.DisplayName -match "Java \d" -or 
                $_.DisplayName -match 'Java\(TM\)' -or
                $_.DisplayName -match "OpenJDK" -or
                $_.DisplayName -match "Temurin" -or
                $_.DisplayName -match "AdoptOpenJDK" -or
                $_.DisplayName -match "Eclipse Adoptium" -or
                $_.DisplayName -match "JDK" -or
                $_.DisplayName -match "Java SE"
            ) 
        } | Where-Object {
            # Exclude Java 8 entries - we want to KEEP Java 8
            $_.DisplayName -notmatch "1\.8" -and
            $_.DisplayName -notmatch "jdk-?8" -and
            $_.DisplayName -notmatch "jre-?8" -and
            $_.DisplayName -notmatch '8u\d' -and
            $_.DisplayName -notmatch "Java 8" -and
            $_.DisplayName -notmatch 'Java\(TM\) 8'
        }
        
        $removedCount = 0
        foreach ($product in $javaProducts) {
            Write-Host "    Removing: $($product.DisplayName)..." -ForegroundColor DarkYellow
            try {
                if ($product.UninstallString -match 'msiexec' -or $product.PSChildName -match '^\{.*\}$') {
                    $productCode = $product.PSChildName
                    Start-Process msiexec.exe -ArgumentList "/x $productCode /quiet /norestart" -Wait -NoNewWindow
                }
                elseif ($product.UninstallString) {
                    $uninstallCmd = $product.UninstallString -replace '"', ''
                    if ($uninstallCmd -notmatch '/s|/silent|/quiet') {
                        $uninstallCmd = "$uninstallCmd /s"
                    }
                    Start-Process cmd.exe -ArgumentList "/c `"$uninstallCmd`"" -Wait -NoNewWindow
                }
                $removedCount++
            }
            catch {
                Write-Warn "    Could not remove $($product.DisplayName): $_"
            }
        }
        
        if ($removedCount -gt 0) {
            Write-Success "Removed $removedCount Java installation(s)"
        }
        else {
            Write-Warn "No Java installations found in registry to remove"
            Write-Warn "You may need to manually remove Java from: $($existingJava.Source)"
        }
        
        # Clean stale JAVA_HOME
        $oldJavaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
        if ($oldJavaHome) {
            [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $null, "Machine")
            $env:JAVA_HOME = $null
            Write-Host "    Cleared old JAVA_HOME: $oldJavaHome" -ForegroundColor Gray
        }
        
        # Refresh PATH for current session
        $machinePath463 = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath463    = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = if ($userPath463) { "$machinePath463;$userPath463" } else { $machinePath463 }
    }
}

if (-not $javaExists) {
    Write-Step "1.1" "Downloading Temurin JDK $JAVA_VERSION installer..."
    $javaMsi = "$TEMP_DIR\temurin-jdk$JAVA_VERSION.msi"
    
    try {
        # Download the MSI installer with progress
        $downloaded = $false
        foreach ($jUrl in $JAVA_URLS) {
            try {
                Write-Host "    Trying: $jUrl" -ForegroundColor Gray
                Download-WithProgress -Url $jUrl -OutFile $javaMsi -DisplayName "Java JDK $JAVA_VERSION"
                Write-Success "Downloaded Java JDK installer"
                $downloaded = $true
                break
            }
            catch {
                Write-Warn "    Failed from this source, trying next..."
            }
        }
        
        if (-not $downloaded) {
            throw "Failed to download Java from all mirrors."
        }
        
        Write-Step "1.2" "Installing Java JDK $JAVA_VERSION (this may take a minute)..."
        $msiArgs = "/i `"$javaMsi`" ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome,FeatureOracleJavaSoft /quiet /norestart"
        $msiProc = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow -PassThru
        # msiexec exit codes: 0 = success, 3010 = success (reboot required), anything else = failure
        if ($msiProc.ExitCode -eq 0 -or $msiProc.ExitCode -eq 3010) {
            if ($msiProc.ExitCode -eq 3010) {
                Write-Warn "Java JDK $JAVA_VERSION installed - a reboot is recommended but not required now"
            } else {
                Write-Success "Java JDK $JAVA_VERSION installed"
            }
        } else {
            throw "msiexec failed with exit code $($msiProc.ExitCode). Common causes: Group Policy blocking MSI installs, another MSI already running, or corrupt installer. Try running the MSI manually: $javaMsi"
        }
        
        # Find the installed JAVA_HOME
        Start-Sleep -Seconds 2
        $javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
        if (-not $javaHome) {
            # Try to find it manually
            $temurinDirs = Get-ChildItem "$JAVA_INSTALL_DIR" -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match "jdk-8" } | 
            Sort-Object LastWriteTime -Descending
            if ($temurinDirs) {
                $javaHome = $temurinDirs[0].FullName
            }
        }
        
        if ($javaHome) {
            Write-Success "JAVA_HOME detected at: $javaHome"
        }
        else {
            Write-Err "Could not auto-detect JAVA_HOME. You may need to set it manually."
            Write-Host "  Check $JAVA_INSTALL_DIR for the JDK folder name."
            $javaHome = Read-Host "  Enter the full path to your JDK installation"
        }
    }
    catch {
        Write-Err "Failed to download/install Java: $_"
        Write-Host "  Please install Java 8 manually from: https://adoptium.net/"
        $javaHome = Read-Host "  Enter the full path to your JDK 8 installation"
    }
}
else {
    Write-Success "Using existing Java 8 installation"
}

# Validate JAVA_HOME
if (-not $javaHome -or -not (Test-Path "$javaHome\bin\java.exe")) {
    Write-Err "Invalid JAVA_HOME: $javaHome"
    Write-Host "  Cannot continue without a valid Java installation."
    exit 1
}
Write-Success "Java validated at: $javaHome"

# --- Convert JAVA_HOME to 8.3 short path if it contains spaces ---
# This is CRITICAL: Hadoop's .cmd scripts break on paths with spaces like "Program Files"
$javaHomeShort = $javaHome
if ($javaHome -match '\s') {
    Write-Step "1.3" "Converting JAVA_HOME to short path (spaces detected)..."
    $javaHomeShort = Get-ShortPath $javaHome
    Write-Host "    Long path : $javaHome" -ForegroundColor Gray
    Write-Host "    Short path: $javaHomeShort" -ForegroundColor Gray
    if ($javaHomeShort -ne $javaHome) {
        Write-Success "Will use short path for Hadoop compatibility: $javaHomeShort"
    }
    else {
        Write-Warn "Could not get short path. Hadoop may have issues with spaces in JAVA_HOME."
        Write-Warn "Consider installing Java to a path without spaces (e.g., C:\Java\jdk8)"
    }
}

# ============================================================================
#  STEP 2: DOWNLOAD AND EXTRACT HADOOP
# ============================================================================

Write-Banner "STEP 2: Hadoop $HADOOP_VERSION Download & Extraction"

$doDownload = $false
if (Test-Path "$INSTALL_DIR\bin\hadoop.cmd") {
    Write-Warn "Hadoop already exists at $INSTALL_DIR"
    $existingVer = "unknown"
    try {
        $verFile = Get-Content "$INSTALL_DIR\share\doc\hadoop\hadoop-project-dist\hadoop-common\version.txt" -ErrorAction SilentlyContinue
        if ($verFile) { $existingVer = $verFile.Trim() }
    }
    catch {}
    
    if (-not (Confirm-Continue "Existing Hadoop ($existingVer) found. OVERWRITE with Hadoop $HADOOP_VERSION?")) {
        Write-Success "Keeping existing Hadoop installation"
    }
    else {
        # Backup existing config
        Write-Step "2.0" "Backing up existing configuration..."
        $backupDir = "$TEMP_DIR\hadoop-config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        if (Test-Path "$INSTALL_DIR\etc\hadoop") {
            Copy-Item "$INSTALL_DIR\etc\hadoop" $backupDir -Recurse -Force
            Write-Success "Config backed up to: $backupDir"
        }
        
        # Remove old installation but keep data
        Write-Step "2.0b" "Removing old Hadoop binaries (keeping data directory)..."
        Get-ChildItem "$INSTALL_DIR\*" -Exclude "data" | Remove-Item -Recurse -Force
        
        $doDownload = $true
    }
}
else {
    $doDownload = $true
}

if ($doDownload) {
    Write-Step "2.1" "Downloading Hadoop $HADOOP_VERSION (this is ~380MB, please wait)..."
    $hadoopTarGz = "$TEMP_DIR\hadoop-$HADOOP_VERSION.tar.gz"
    
    $minHadoopBytes = 300MB   # A valid Hadoop 3.x tar.gz is always > 300 MB
    if (Test-Path $hadoopTarGz) {
        $archiveSize = (Get-Item $hadoopTarGz).Length
        if ($archiveSize -ge $minHadoopBytes) {
            Write-Warn "Archive already downloaded ($(Format-FileSize $archiveSize)), reusing: $hadoopTarGz"
        } else {
            Write-Warn "Cached archive is only $(Format-FileSize $archiveSize) -- likely a partial/corrupt download. Deleting and re-downloading..."
            Remove-Item $hadoopTarGz -Force
        }
    }
    if (-not (Test-Path $hadoopTarGz)) {
        $downloaded = $false
        foreach ($mirrorUrl in $HADOOP_URLS) {
            try {
                Write-Host "    Trying mirror: $mirrorUrl" -ForegroundColor Gray
                Download-WithProgress -Url $mirrorUrl -OutFile $hadoopTarGz -DisplayName "Hadoop $HADOOP_VERSION" -TimeoutSec 120
                Write-Success "Downloaded Hadoop $HADOOP_VERSION"
                $downloaded = $true
                break
            }
            catch {
                Write-Warn "    Mirror failed, trying next..."
                if (Test-Path $hadoopTarGz) { Remove-Item $hadoopTarGz -Force -ErrorAction SilentlyContinue }
            }
        }
        if (-not $downloaded) {
            Write-Err "All mirrors failed."
            Write-Host ""
            Write-Host "  Manual download from any of these:" -ForegroundColor Yellow
            $HADOOP_URLS | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            Write-Host "  Save to: $hadoopTarGz" -ForegroundColor Yellow
            Read-Host "  Press Enter after downloading manually"
        }
    }

    # Verify the archive exists before trying to extract
    if (-not (Test-Path $hadoopTarGz)) {
        Write-Err "Hadoop archive not found at $hadoopTarGz. Cannot continue."
        exit 1
    }
    
    Write-Step "2.2" "Extracting Hadoop (this may take a few minutes)..."
    
    if (-not (Test-Path $INSTALL_DIR)) {
        New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
    }
    
    $extractTemp = "$TEMP_DIR\hadoop-extract"
    if (Test-Path $extractTemp) { Remove-Item $extractTemp -Recurse -Force }
    New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
    
    $extracted = $false
    
    # Try built-in tar.exe first
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Write-Host "    Using built-in tar.exe for extraction..." -ForegroundColor Gray
        tar.exe -xzf "$hadoopTarGz" -C "$extractTemp" 2>$null
        
        $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hadoop-*" } | Select-Object -First 1
        if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hadoop.cmd")) {
            $extracted = $true
            Write-Success "Extracted successfully using tar.exe"
        }
        else {
            Write-Warn "    tar.exe extraction failed or was incomplete. Trying 7-Zip fallback..."
            # Clean up partial extraction
            Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $extractTemp -Force | Out-Null
        }
    }
    
    # Fallback to 7-Zip if tar failed or is missing
    if (-not $extracted) {
        Write-Host "    Downloading standalone 7-Zip for reliable extraction..." -ForegroundColor Gray
        $7zInstaller = "$TEMP_DIR\7z_installer.exe"
        # NSIS /D= flag does NOT support spaces or quotes - must use a space-free path.
        # $TEMP_DIR can have spaces if the username does, so use $INSTALL_DIR which is C:\hadoop.
        $7zDir = "$INSTALL_DIR\7zip-temp"
        
        $7zDownloaded = $false
        foreach ($zUrl in $7ZIP_URLS) {
            try {
                Download-WithProgress -Url $zUrl -OutFile $7zInstaller -DisplayName "7-Zip Installer"
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
                & $7zExe x "$hadoopTarGz" -o"$extractTemp" -y | Out-Null
                
                $tarFile = Get-ChildItem "$extractTemp\*.tar" | Select-Object -First 1
                if ($tarFile) {
                    Write-Host "    Extracting tar archive..." -ForegroundColor Gray
                    & $7zExe x "$($tarFile.FullName)" -o"$extractTemp" -y | Out-Null
                    Remove-Item $tarFile.FullName -Force -ErrorAction SilentlyContinue
                }
                
                $chkFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hadoop-*" } | Select-Object -First 1
                if (-not $chkFolder) { $chkFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
                if ($chkFolder -and (Test-Path "$($chkFolder.FullName)\bin\hadoop.cmd")) {
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
        $extractedFolder = Get-ChildItem $extractTemp -Directory | Where-Object { $_.Name -like "hadoop-*" } | Select-Object -First 1
        if (-not $extractedFolder) { $extractedFolder = Get-ChildItem $extractTemp -Directory | Select-Object -First 1 }
        if ($extractedFolder -and (Test-Path "$($extractedFolder.FullName)\bin\hadoop.cmd")) {
            # Use robocopy instead of Copy-Item to handle long paths (>260 chars)
            # Hadoop docs contain deeply nested paths that exceed Windows MAX_PATH limit
            $roboSrc = $extractedFolder.FullName
            $roboDst = $INSTALL_DIR
            $roboResult = robocopy "$roboSrc" "$roboDst" /E /MOVE /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1
            # robocopy exit codes: 0-7 = success, 8+ = error
            if ($LASTEXITCODE -le 7) {
                # Clean up the (now mostly empty) temp extraction folder
                Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Hadoop extracted to $INSTALL_DIR"
            }
            else {
                Write-Warn "robocopy reported issues (exit code $LASTEXITCODE), but files may still be usable."
                Remove-Item $extractTemp -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Hadoop extracted to $INSTALL_DIR (with warnings)"
            }
        }
        else {
            Write-Err "Extraction failed or archive structure unexpected (bin\hadoop.cmd not found)."
            Write-Err "Check $extractTemp manually."
            exit 1
        }
    }
    else {
        Write-Err "'tar.exe' and '7-Zip' failed. Please extract manually."
        Write-Host "  Extract $hadoopTarGz to $INSTALL_DIR"
        Read-Host "  Press Enter after extracting manually"
        if (-not (Test-Path "$INSTALL_DIR\bin\hadoop.cmd")) {
            Write-Err "Hadoop binaries not found at $INSTALL_DIR\bin\hadoop.cmd after manual extraction. Cannot continue."
            exit 1
        }
    }
}

# --- Verify etc\hadoop exists (can be missing from incomplete extractions) ---
$hadoopEtc = "$INSTALL_DIR\etc\hadoop"
if (-not (Test-Path $hadoopEtc)) {
    Write-Warn "etc\hadoop directory missing - creating it now..."
    New-Item -ItemType Directory -Path $hadoopEtc -Force | Out-Null
    Write-Success "Created: $hadoopEtc"
}

# ============================================================================
#  STEP 3: DOWNLOAD WINUTILS.EXE
# ============================================================================

Write-Banner "STEP 3: winutils.exe (Windows Hadoop Utilities)"

$winutilsPath = "$INSTALL_DIR\bin\winutils.exe"
$hadoopDll    = "$INSTALL_DIR\bin\hadoop.dll"

# --- Step 3.0: Add Windows Defender exclusions BEFORE downloading ---
# winutils.exe is a legitimate Windows-native Hadoop utility but Defender flags it as
# a PUA (potentially unwanted app) or HackTool because it manipulates file permissions.
# Adding an exclusion BEFORE the download prevents Defender from quarantining the file
# the instant it hits disk. Without this, the download "succeeds" but leaves a 0-byte
# stub file, making Hadoop fail at runtime with no clear error.
Write-Step "3.0" "Adding Windows Defender exclusion for Hadoop bin directory..."
try {
    $existingExclusions = (Get-MpPreference -ErrorAction Stop).ExclusionPath
    foreach ($excPath in @("$INSTALL_DIR\bin", $TEMP_DIR)) {
        if ($existingExclusions -contains $excPath) {
            Write-Success "Defender exclusion already exists: $excPath"
        } else {
            Add-MpPreference -ExclusionPath $excPath -ErrorAction Stop
            Write-Success "Defender exclusion added: $excPath"
        }
    }
}
catch {
    Write-Warn "Could not add Defender exclusion: $_"
    Write-Warn "Windows Defender may still quarantine winutils.exe after download."
    Write-Warn "If winutils is missing after this step, temporarily disable Real-time Protection."
}

function Download-WithFallback {
    <#
    .SYNOPSIS
        Downloads a file trying each URL in the list until one succeeds.
        After each successful download it checks the file is non-zero (not a Defender stub).
    #>
    param(
        [string[]]$Urls,
        [string]$OutFile,
        [string]$DisplayName,
        [int]$TimeoutSec = 120
    )
    foreach ($url in $Urls) {
        try {
            Write-Host "    Trying: $url" -ForegroundColor Gray
            Download-WithProgress -Url $url -OutFile $OutFile -DisplayName $DisplayName -TimeoutSec $TimeoutSec

            # Defender quarantine creates a 0-byte stub - treat as failed download
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -eq 0) {
                Write-Warn "    Downloaded file is 0 bytes (likely quarantined by Defender) - trying next mirror..."
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

if (Test-Path $winutilsPath) {
    Write-Success "winutils.exe already exists"
}
else {
    Write-Step "3.1" "Downloading winutils.exe..."
    $winutilsUrls = $WINUTILS_URLS | ForEach-Object { "$_/winutils.exe" }
    $downloaded = Download-WithFallback -Urls $winutilsUrls -OutFile $winutilsPath -DisplayName "winutils.exe"

    if (-not $downloaded) {
        Write-Warn "All mirrors failed. Attempting Windows Defender quarantine restore..."
        # MpCmdRun can restore a quarantined file back to its original location
        $mpCmd = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
        if (Test-Path $mpCmd) {
            & $mpCmd -Restore -Name "winutils.exe" 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
    }
}

# Validate winutils.exe exists and is not a 0-byte stub
$winutilsOk = (Test-Path $winutilsPath) -and ((Get-Item $winutilsPath -ErrorAction SilentlyContinue).Length -gt 0)
if (-not $winutilsOk) {
    Write-Err "winutils.exe is missing or empty at $winutilsPath. Hadoop will fail on Windows."
    Write-Host ""
    Write-Host "  Most likely cause: Windows Defender quarantined it." -ForegroundColor Yellow
    Write-Host "  Fix options (choose one):" -ForegroundColor Yellow
    Write-Host '    1. Open Windows Security > Virus & threat protection > Protection history' -ForegroundColor Gray
    Write-Host "       Find 'winutils.exe' entry > click 'Allow on device'" -ForegroundColor Gray
    Write-Host "    2. Run PowerShell as Admin and run:" -ForegroundColor Gray
    Write-Host "         Add-MpPreference -ExclusionPath '$INSTALL_DIR\bin'" -ForegroundColor Cyan
    Write-Host "         Then re-run this installer." -ForegroundColor Gray
    Write-Host "    3. Temporarily disable Real-time Protection, re-run installer, re-enable it." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Manual download URL:" -ForegroundColor Yellow
    Write-Host "    $($WINUTILS_URLS[0])/winutils.exe" -ForegroundColor Cyan
    Write-Host "  Place it in: $INSTALL_DIR\bin\" -ForegroundColor Yellow
    exit 1
}
Write-Success "winutils.exe validated ($(Format-FileSize (Get-Item $winutilsPath).Length))"

if (-not (Test-Path $hadoopDll)) {
    Write-Step "3.2" "Downloading hadoop.dll..."
    $hadoopDllUrls = $WINUTILS_URLS | ForEach-Object { "$_/hadoop.dll" }
    $downloaded = Download-WithFallback -Urls $hadoopDllUrls -OutFile $hadoopDll -DisplayName "hadoop.dll"
    if (-not $downloaded) {
        Write-Warn "Failed to download hadoop.dll from all sources (non-critical, continuing...)"
    }
}
else {
    Write-Success "hadoop.dll already exists"
}

# ============================================================================
#  STEP 4: SET ENVIRONMENT VARIABLES
# ============================================================================

Write-Banner "STEP 4: Environment Variables"

# JAVA_HOME - use short path if spaces detected
$javaHomeForEnv = $javaHomeShort
Write-Step "4.1" "Setting JAVA_HOME = $javaHomeForEnv"
$currentJavaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if ($currentJavaHome -ne $javaHomeForEnv) {
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHomeForEnv, "Machine")
    $env:JAVA_HOME = $javaHomeForEnv
    Write-Success "JAVA_HOME set to: $javaHomeForEnv"
}
else {
    Write-Success "JAVA_HOME already correct: $javaHomeForEnv"
}

# HADOOP_HOME
$currentHadoopHome = [System.Environment]::GetEnvironmentVariable("HADOOP_HOME", "Machine")
if ($currentHadoopHome -ne $INSTALL_DIR) {
    Write-Step "4.2" "Setting HADOOP_HOME = $INSTALL_DIR"
    [System.Environment]::SetEnvironmentVariable("HADOOP_HOME", $INSTALL_DIR, "Machine")
    $env:HADOOP_HOME = $INSTALL_DIR
    Write-Success "HADOOP_HOME set"
}
else {
    Write-Success "HADOOP_HOME already correct: $INSTALL_DIR"
}

# PATH - add Java bin, Hadoop bin, and Hadoop sbin
Write-Step "4.3" "Updating system PATH..."
$systemPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
if (-not $systemPath) { $systemPath = "" }
$pathsToAdd = @(
    "%JAVA_HOME%\bin",
    "%HADOOP_HOME%\bin",
    "%HADOOP_HOME%\sbin"
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

# Also add RESOLVED (absolute) paths to USER-level PATH
# This ensures 'java -version' and 'hadoop version' work in non-admin CMD sessions too,
# since %JAVA_HOME%/%HADOOP_HOME% variable expansion can be unreliable for newly-set variables.
Write-Step "4.4" 'Ensuring Java & Hadoop are accessible in non-admin terminals...'
$userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$userPathsToAdd = @(
    "$javaHomeShort\bin",
    "$INSTALL_DIR\bin",
    "$INSTALL_DIR\sbin"
)
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
    Write-Success "User PATH updated (Hadoop will work in non-admin terminals)"
}
else {
    Write-Success "User PATH already has Hadoop entries"
}

# Refresh current session PATH
$machinePath984 = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath984    = [System.Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath984) { $env:Path = "$machinePath984;$userPath984" } else { $env:Path = $machinePath984 }

# ============================================================================
#  STEP 5: CONFIGURE HADOOP XML FILES
# ============================================================================

Write-Banner "STEP 5: Hadoop Configuration Files"

# --- core-site.xml ---
Write-Step "5.1" "Writing core-site.xml..."
$coreSiteContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- core-site.xml - Generated by Hadoop Installer Script -->
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:$NAMENODE_PORT</value>
        <description>The name of the default file system</description>
    </property>
    <property>
        <name>hadoop.tmp.dir</name>
        <value>$($DATA_DIR.Replace('\','/'))/tmp</value>
        <description>Temporary directory for Hadoop</description>
    </property>
</configuration>
"@
[System.IO.File]::WriteAllText("$hadoopEtc\core-site.xml", $coreSiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "core-site.xml configured (fs.defaultFS = hdfs://localhost:$NAMENODE_PORT)"

# --- hdfs-site.xml ---
Write-Step "5.2" "Writing hdfs-site.xml..."
$namenodeDir = "$DATA_DIR\namenode".Replace('\', '/')
$datanodeDir = "$DATA_DIR\datanode".Replace('\', '/')
$hdfsSiteContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- hdfs-site.xml - Generated by Hadoop Installer Script -->
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>$REPLICATION</value>
        <description>Number of data replicas</description>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>file:///$namenodeDir</value>
        <description>Path where NameNode stores metadata</description>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>file:///$datanodeDir</value>
        <description>Path where DataNode stores blocks</description>
    </property>
</configuration>
"@
[System.IO.File]::WriteAllText("$hadoopEtc\hdfs-site.xml", $hdfsSiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "hdfs-site.xml configured (replication=$REPLICATION)"

# --- mapred-site.xml ---
Write-Step "5.3" "Writing mapred-site.xml..."
$mapredSiteContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- mapred-site.xml - Generated by Hadoop Installer Script -->
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
        <description>Execution framework</description>
    </property>
    <property>
        <name>mapreduce.application.classpath</name>
        <value>%HADOOP_HOME%\share\hadoop\mapreduce\*,%HADOOP_HOME%\share\hadoop\mapreduce\lib\*</value>
    </property>
</configuration>
"@
[System.IO.File]::WriteAllText("$hadoopEtc\mapred-site.xml", $mapredSiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "mapred-site.xml configured (framework=yarn)"

# --- yarn-site.xml ---
Write-Step "5.4" "Writing yarn-site.xml..."
$yarnSiteContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<!-- yarn-site.xml - Generated by Hadoop Installer Script -->
<configuration>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.nodemanager.env-whitelist</name>
        <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_HOME,PATH,LANG,TZ,HADOOP_MAPRED_HOME</value>
    </property>
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>localhost</value>
    </property>
</configuration>
"@
[System.IO.File]::WriteAllText("$hadoopEtc\yarn-site.xml", $yarnSiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "yarn-site.xml configured (aux-services=mapreduce_shuffle)"

# --- capacity-scheduler.xml ---
Write-Step "5.5" "Writing capacity-scheduler.xml..."
$capacitySiteContent = @"
<?xml version="1.0"?>
<configuration>
  <property>
    <name>yarn.scheduler.capacity.root.queues</name>
    <value>default</value>
  </property>
  <property>
    <name>yarn.scheduler.capacity.root.default.capacity</name>
    <value>100</value>
  </property>
  <property>
    <name>yarn.scheduler.capacity.root.default.maximum-capacity</name>
    <value>100</value>
  </property>
  <property>
    <name>yarn.scheduler.capacity.root.default.state</name>
    <value>RUNNING</value>
  </property>
</configuration>
"@
[System.IO.File]::WriteAllText("$hadoopEtc\capacity-scheduler.xml", $capacitySiteContent, (New-Object System.Text.UTF8Encoding $false))
Write-Success "capacity-scheduler.xml configured (ResourceManager queues)"

# ============================================================================
#  STEP 6: FIX hadoop-env.cmd (JAVA_HOME with short path)

# ============================================================================

Write-Banner "STEP 6: Fix hadoop-env.cmd"

$hadoopEnvCmd = "$hadoopEtc\hadoop-env.cmd"
if (Test-Path $hadoopEnvCmd) {
    Write-Step "6.1" "Updating JAVA_HOME in hadoop-env.cmd..."
    $envContent = Get-Content $hadoopEnvCmd -Raw
    
    # Replace any existing JAVA_HOME line with the short path
    if ($envContent -match '(?m)^set\s+JAVA_HOME=') {
        $envContent = $envContent -replace '(?m)^set\s+JAVA_HOME=.*', "set JAVA_HOME=$javaHomeShort"
    }
    else {
        # Prepend the JAVA_HOME setting
        $envContent = "set JAVA_HOME=$javaHomeShort`r`n$envContent"
    }

    # Add HADOOP_LOG_DIR redirect
    if ($envContent -notmatch '(?m)^set\s+HADOOP_LOG_DIR=') {
        $envContent = $envContent + "`r`n@rem Redirect logs to a user-owned directory to avoid Access Denied`r`nset HADOOP_LOG_DIR=$LOG_DIR`r`n"
    }
    
    Set-Content -Path $hadoopEnvCmd -Value $envContent -Encoding ASCII
    Write-Success "hadoop-env.cmd updated with JAVA_HOME and HADOOP_LOG_DIR"
}
else {
    # Create hadoop-env.cmd from scratch if it doesn't exist
    Write-Step "6.1" "Creating hadoop-env.cmd (was missing)..."
    $envContent = "@rem hadoop-env.cmd - Generated by Hadoop Installer Script`r`n"
    $envContent += "@rem Set JAVA_HOME - using short path to avoid spaces issue`r`n"
    $envContent += "set JAVA_HOME=$javaHomeShort`r`n"
    $envContent += "@rem Redirect logs to a user-owned directory to avoid Access Denied`r`n"
    $envContent += "set HADOOP_LOG_DIR=$LOG_DIR`r`n"
    Set-Content -Path $hadoopEnvCmd -Value $envContent -Encoding ASCII
    Write-Success "hadoop-env.cmd created with JAVA_HOME and HADOOP_LOG_DIR"
}

# ============================================================================
#  STEP 7: FIX hadoop-config.cmd (JAVA_HOME SPACE IN PATH)
# ============================================================================

Write-Banner "STEP 7: Fix hadoop-config.cmd (Program Files space issue)"

$hadoopConfigCmd = "$INSTALL_DIR\libexec\hadoop-config.cmd"
if (Test-Path $hadoopConfigCmd) {
    Write-Step "7.1" "Patching hadoop-config.cmd for spaces in JAVA_HOME path..."
    $configContent = Get-Content $hadoopConfigCmd -Raw
    
    if ($configContent -match 'if exist %JAVA_HOME%\\bin\\java\.exe') {
        $configContent = $configContent -replace 'if exist %JAVA_HOME%\\bin\\java\.exe', 'if exist "%JAVA_HOME%\bin\java.exe"'
        Set-Content -Path $hadoopConfigCmd -Value $configContent -Encoding ASCII
        Write-Success "Patched hadoop-config.cmd to handle spaces in JAVA_HOME"
    }
    else {
        Write-Success "hadoop-config.cmd already patched or doesn't need patching"
    }
}
else {
    Write-Warn "hadoop-config.cmd not found at $hadoopConfigCmd"
}

# ============================================================================
#  STEP 8: CREATE DATA DIRECTORIES
# ============================================================================

Write-Banner "STEP 8: Data Directories"

$dirs = @(
    "$DATA_DIR\namenode",
    "$DATA_DIR\datanode",
    "$DATA_DIR\tmp",
    $LOG_DIR
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Success "Created: $dir"
    }
    else {
        Write-Success "Already exists: $dir"
    }
}

# ============================================================================
#  STEP 9: FORMAT NAMENODE
# ============================================================================

Write-Banner "STEP 9: Format NameNode"

# --- Port conflict check ---
# NameNode RPC (9000), NameNode Web UI (9870), and YARN ResourceManager (8088) must be free.
# A previous Hadoop that wasn't shut down, or any other service on these ports, will cause
# a cryptic java.net.BindException during format/startup with no clear hint of the cause.
Write-Step "9.0" "Checking for port conflicts ($NAMENODE_PORT, 9870, 8088)..."
$portsToCheck = @($NAMENODE_PORT, "9870", "8088")
$blockedPorts = @()
foreach ($port in $portsToCheck) {
    $portInt = [int]$port
    $inUse = (netstat -ano 2>$null | Select-String ":$portInt\s+.*LISTENING")
    if ($inUse) { $blockedPorts += $port }
}
if ($blockedPorts.Count -gt 0) {
    Write-Err "Port(s) already in use: $($blockedPorts -join ', ')"
    Write-Host "  These ports must be free for Hadoop to start." -ForegroundColor Yellow
    Write-Host "  Find what is using them:" -ForegroundColor Yellow
    foreach ($p in $blockedPorts) {
        Write-Host "    netstat -ano | findstr :$p" -ForegroundColor Cyan
    }
    Write-Host "  Then kill the process with:  taskkill /PID <pid> /F" -ForegroundColor Cyan
    if (-not (Confirm-Continue "Ports are in use. Continue anyway (NameNode format may fail)?")) {
        exit 1
    }
} else {
    Write-Success "Ports $($portsToCheck -join ', ') are all free"
}

$namenodeFormatted = Test-Path "$DATA_DIR\namenode\current\VERSION"

if ($namenodeFormatted) {
    Write-Warn "NameNode appears to be already formatted."
    Write-Warn "Re-formatting will ERASE all HDFS data!"
    if (-not (Confirm-Continue "Re-format NameNode? (This will delete all HDFS data)")) {
        Write-Success "Keeping existing NameNode format"
    }
    else {
        # Clean namenode and datanode directories
        Remove-Item "$DATA_DIR\namenode\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$DATA_DIR\datanode\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Step "9.1" "Formatting NameNode..."
        try {
            $formatResult = & "$INSTALL_DIR\bin\hdfs.cmd" namenode -format -force 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "NameNode formatted successfully"
            }
            else {
                Write-Err "NameNode format failed (exit code $LASTEXITCODE). Output:"
                $formatResult | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
        catch {
            Write-Err "hdfs.cmd could not be launched: $_"
            Write-Warn "Check that $INSTALL_DIR\bin\hdfs.cmd exists and JAVA_HOME is valid."
        }
    }
}
else {
    Write-Step "9.1" "Formatting NameNode for first time..."
    try {
        $formatResult = & "$INSTALL_DIR\bin\hdfs.cmd" namenode -format -force 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "NameNode formatted successfully"
        }
        else {
            Write-Err "NameNode format may have failed (exit code $LASTEXITCODE). Check output below:"
            $formatResult | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
    catch {
        Write-Err "hdfs.cmd could not be launched: $_"
        Write-Warn "Check that $INSTALL_DIR\bin\hdfs.cmd exists and JAVA_HOME is valid."
    }
}

# --- Fix permissions on data directory ---
# CRITICAL: This script runs as Administrator (elevated), so all files created
# above are owned by the admin token. The non-elevated user session CANNOT access
# them, causing "Access is denied" when NameNode starts from a normal terminal.
# icacls /T is used as the primary method - it is more reliable than PowerShell's
# Set-Acl because it correctly handles children with ProtectedFromInheritance set.
Write-Step "9.2" "Granting user permissions on data directory..."
cmd /c "icacls `"$DATA_DIR`" /grant `"BUILTIN\Users:(OI)(CI)F`" /T /Q" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Success "BUILTIN\Users granted full control on $DATA_DIR (recursive)"
}
else {
    Write-Warn "icacls failed (exit $LASTEXITCODE), trying PowerShell ACL fallback..."
    try {
        $acl = Get-Acl $DATA_DIR
        $usersRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Users", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.AddAccessRule($usersRule)
        Set-Acl -Path $DATA_DIR -AclObject $acl
        Get-ChildItem $DATA_DIR -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Set-Acl -Path $_.FullName -AclObject $acl -ErrorAction SilentlyContinue } catch {}
        }
        Write-Success "BUILTIN\Users granted full control on $DATA_DIR (recursive)"
    }
    catch {
        Write-Err "Could not fix permissions: $_"
        Write-Warn "Run manually:  icacls `"$DATA_DIR`" /grant `"BUILTIN\Users:(OI)(CI)F`" /T"
    }
}

# --- Fix permissions on Hadoop install bin dir (needed for winutils.exe access) ---
cmd /c "icacls `"$INSTALL_DIR\bin`" /grant `"BUILTIN\Users:(OI)(CI)RX`" /T /Q" 2>&1 | Out-Null

# --- Create and fix permissions on $INSTALL_DIR\logs ---
# Hadoop scripts ALWAYS try to write to $HADOOP_HOME\logs on startup, even when
# HADOOP_LOG_DIR is set. If this directory doesn't exist or requires admin to
# create, the service fails silently from a normal (non-admin) terminal.
$hadoopInstallLogs = "$INSTALL_DIR\logs"
if (-not (Test-Path $hadoopInstallLogs)) {
    New-Item -ItemType Directory -Path $hadoopInstallLogs -Force | Out-Null
}
cmd /c "icacls `"$hadoopInstallLogs`" /grant `"BUILTIN\Users:(OI)(CI)F`" /T /Q" 2>&1 | Out-Null
Write-Success "Created and granted user permissions on $hadoopInstallLogs"

# --- Add Windows Firewall rules for Hadoop Web UIs ---
# Without these, localhost access still works, but network/VM access to the web UIs
# (NameNode :9870, YARN :8088) may be blocked by Windows Firewall on first launch.
Write-Step "9.3" "Adding Windows Firewall rules for Hadoop Web UIs..."
try {
    $existingNN = Get-NetFirewallRule -DisplayName "Hadoop NameNode Web UI" -ErrorAction SilentlyContinue
    if (-not $existingNN) {
        New-NetFirewallRule -DisplayName "Hadoop NameNode Web UI" -Direction Inbound -LocalPort 9870 -Protocol TCP -Action Allow -ErrorAction Stop | Out-Null
        Write-Success "Firewall rule added: port 9870 (NameNode Web UI)"
    } else {
        Write-Success "Firewall rule already exists: port 9870"
    }
    $existingYARN = Get-NetFirewallRule -DisplayName "Hadoop YARN ResourceManager" -ErrorAction SilentlyContinue
    if (-not $existingYARN) {
        New-NetFirewallRule -DisplayName "Hadoop YARN ResourceManager" -Direction Inbound -LocalPort 8088 -Protocol TCP -Action Allow -ErrorAction Stop | Out-Null
        Write-Success "Firewall rule added: port 8088 (YARN ResourceManager)"
    } else {
        Write-Success "Firewall rule already exists: port 8088"
    }
}
catch {
    Write-Warn "Could not add firewall rules: $_"
    Write-Warn "Localhost access still works. Add rules manually if remote/VM access is needed."
}

# ============================================================================
#  STEP 10: SUMMARY & NEXT STEPS
# ============================================================================

Write-Banner "INSTALLATION COMPLETE!"

Write-Host "  Installation Summary:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  JAVA_HOME    : $javaHomeShort" -ForegroundColor Gray
Write-Host "  HADOOP_HOME  : $INSTALL_DIR" -ForegroundColor Gray
Write-Host "  Data Dir     : $DATA_DIR" -ForegroundColor Gray
Write-Host "  NameNode Port: $NAMENODE_PORT" -ForegroundColor Gray
Write-Host "  Replication  : $REPLICATION" -ForegroundColor Gray
Write-Host ""

Write-Host "  IMPORTANT: Open a NEW Command Prompt to pick up environment variables!" -ForegroundColor Yellow
Write-Host ""

Write-Host "  Quick Start Commands (run in a NEW cmd.exe window):" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  Start HDFS     :  " -NoNewline -ForegroundColor Gray
Write-Host "$INSTALL_DIR\sbin\start-dfs.cmd" -ForegroundColor Green
Write-Host "  Start YARN     :  " -NoNewline -ForegroundColor Gray
Write-Host "$INSTALL_DIR\sbin\start-yarn.cmd" -ForegroundColor Green
Write-Host "  Stop HDFS      :  " -NoNewline -ForegroundColor Gray
Write-Host "$INSTALL_DIR\sbin\stop-dfs.cmd" -ForegroundColor Green
Write-Host "  Stop YARN      :  " -NoNewline -ForegroundColor Gray
Write-Host "$INSTALL_DIR\sbin\stop-yarn.cmd" -ForegroundColor Green
Write-Host ""

Write-Host "  Web UIs:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  NameNode       :  " -NoNewline -ForegroundColor Gray
Write-Host "http://localhost:9870" -ForegroundColor Cyan
Write-Host "  YARN Manager   :  " -NoNewline -ForegroundColor Gray
Write-Host "http://localhost:8088" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Test HDFS:" -ForegroundColor White
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  hdfs dfs -mkdir /user" -ForegroundColor Gray
Write-Host "  hdfs dfs -mkdir /user/$env:USERNAME" -ForegroundColor Gray
Write-Host "  hdfs dfs -ls /" -ForegroundColor Gray
Write-Host ""

# Cleanup prompt
if (Test-Path $TEMP_DIR) {
    if (Confirm-Continue "Delete temporary download files ($TEMP_DIR)?") {
        Remove-Item $TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Temp files cleaned up"
    }
}

Write-Host ""
Write-Host "  Done! Happy Hadooping!" -ForegroundColor Green
Write-Host ""

# ============================================================================
#  VERIFICATION: Confirm Hadoop is working
# ============================================================================

Write-Host ""
Write-Step "VERIFY" "Running 'hadoop version' to confirm installation..."
# Ensure environment is refreshed for verification
$env:HADOOP_HOME = $INSTALL_DIR
$env:JAVA_HOME = $javaHomeShort
$env:Path = "$INSTALL_DIR\bin;$INSTALL_DIR\sbin;$javaHomeShort\bin;" + $env:Path
try {
    $hadoopVer = & "$INSTALL_DIR\bin\hadoop.cmd" version 2>&1
    $hadoopVerText = @($hadoopVer | ForEach-Object { $_.ToString() })
    $exitOk = $LASTEXITCODE -eq 0
    # Also check if output contains "Hadoop" as a secondary validation
    $outputOk = ($hadoopVerText -join " ") -match "Hadoop"
    if ($exitOk -or $outputOk) {
        Write-Success "Hadoop is installed and working:"
        $hadoopVerText | Select-Object -First 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    else {
        Write-Warn "Hadoop command returned a non-zero exit code. You may need to open a new terminal."
        $hadoopVerText | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}
catch {
    Write-Warn "Could not run hadoop version: $_"
    Write-Warn "Open a NEW Command Prompt and run: hadoop version"
}

# ============================================================================
#  STAR ON GITHUB
# ============================================================================

Write-Host ""
Write-Host "  ======================================================================" -ForegroundColor DarkGray
Write-Host "  If this installer saved you time, please star the repo on GitHub!" -ForegroundColor Yellow
Write-Host ""
Write-Host "    https://github.com/vanshrana369/hadoop-automated-deployment" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Your star helps others find this tool. Thank you!" -ForegroundColor Yellow
Write-Host "  ======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host ""
