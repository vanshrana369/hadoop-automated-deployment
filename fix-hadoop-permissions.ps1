#Requires -RunAsAdministrator
# ============================================================
# fix-hadoop-permissions.ps1  -  by VANSH RANA
# Fixes: NativeIO.chmod error(5) / DiskErrorException
# Root cause: dirs owned by Administrators, not current user
# Run as: Administrator (right-click > Run as Administrator)
# ============================================================

$HADOOP_HOME = "C:\hadoop"
$DATA_DIR    = "$env:USERPROFILE\hadoop-data"

# .Trim() catches whitespace-only values which -not alone would miss (' ' is truthy)
if (-not $env:USERDOMAIN.Trim() -or -not $env:USERNAME.Trim()) {
    Write-Host "[ERROR] USERDOMAIN or USERNAME env var is empty/whitespace. Cannot determine user." -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
$user = "$env:USERDOMAIN\$env:USERNAME"

function W-Ok   { param($t); Write-Host "  [OK]  $t" -ForegroundColor Green }
function W-Warn { param($t); Write-Host " [WARN] $t" -ForegroundColor Yellow }
function W-Err  { param($t); Write-Host "[ERROR] $t" -ForegroundColor Red }
function W-Step { param($s,$t); Write-Host "`n  >>> STEP $s : $t" -ForegroundColor Cyan }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  HADOOP PERMISSION FIXER - VANSH RANA" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "  User       : $user"
Write-Host "  HADOOP_HOME: $HADOOP_HOME"
Write-Host "  DATA_DIR   : $DATA_DIR"
Write-Host ""

# Validate paths
if (!(Test-Path $HADOOP_HOME)) {
    W-Err "HADOOP_HOME not found: $HADOOP_HOME"
    Write-Host "  Edit the `$HADOOP_HOME variable at the top of this script." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 1
}
W-Ok "HADOOP_HOME found: $HADOOP_HOME"

if (!(Test-Path $env:USERPROFILE)) {
    W-Err "USERPROFILE not found: $env:USERPROFILE"
    Read-Host "Press Enter to exit"; exit 1
}

# -------------------------------------------------------
# STEP 1: Stop Java processes (release file locks)
# -------------------------------------------------------
W-Step 1 "Stop Running Java Processes"
# @() forces array so .Count is always valid even if only 1 process is returned
$javaProcs = @(Get-Process -Name "java" -ErrorAction SilentlyContinue)
if ($javaProcs.Count -gt 0) {
    $count = $javaProcs.Count
    $javaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    W-Ok "Stopped $count Java process(es)"
} else {
    W-Ok "No Java processes running"
}

# -------------------------------------------------------
# STEP 2: Create any missing directories
# -------------------------------------------------------
W-Step 2 "Create Missing Directories"
$allDirs = @(
    "$DATA_DIR\namenode",
    "$DATA_DIR\datanode",
    "$DATA_DIR\tmp",
    "$DATA_DIR\logs",
    "$HADOOP_HOME\logs"
)
foreach ($d in $allDirs) {
    if (!(Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        W-Ok "Created : $d"
    } else {
        W-Ok "Exists  : $d"
    }
}

# -------------------------------------------------------
# STEP 3: Take Ownership  <-- CORE FIX
# -------------------------------------------------------
# winutils.exe chmod calls SetFileSecurity() internally.
# Windows ONLY allows this if the caller OWNS the object.
# Granting permissions via icacls is NOT enough on its own.
W-Step 3 "Take Ownership of Data Directories"
$ownDirs = @($DATA_DIR, "$HADOOP_HOME\logs")
foreach ($d in $ownDirs) {
    if (!(Test-Path $d)) { W-Warn "Skipping (not found): $d"; continue }
    $before = (Get-Acl $d -ErrorAction SilentlyContinue).Owner
    # Capture stdout (keeps $LASTEXITCODE intact), suppress stderr
    $takeownOut  = takeown /F "$d" /R /D Y 2>$null
    $takeownCode = $LASTEXITCODE
    # NOTE: takeown writes 'Access is denied' to STDOUT on some Windows versions.
    # Check captured stdout for denial even if exit code is 0.
    $accessDenied = $takeownOut | Where-Object { $_ -match 'Access is denied|access denied' }
    $takeownOut | Out-Null    # discard remaining noisy per-file stdout lines
    $after = (Get-Acl $d -ErrorAction SilentlyContinue).Owner
    if ($takeownCode -eq 0 -and -not $accessDenied) {
        W-Ok "Owned: $d  ($before -> $after)"
    } elseif ($accessDenied) {
        W-Warn "takeown: Access Denied on some files in: $d"
        W-Warn "Current owner: $after  (partial ownership change - may still work)"
    } else {
        W-Warn "takeown exit $takeownCode for: $d (may be OK if already owned)"
        W-Ok  "Current owner: $after"
    }
}

# -------------------------------------------------------
# STEP 4: Grant Explicit Full Control ACLs
# -------------------------------------------------------
W-Step 4 "Set Full Control ACLs"
$aclDirs = @(
    $DATA_DIR,
    "$DATA_DIR\namenode",
    "$DATA_DIR\datanode",
    "$DATA_DIR\tmp",
    "$DATA_DIR\logs"
)

# Helper: check if a user has FullControl on a path.
# FileSystemRights can be 'FullControl' (string) OR an integer on some Windows builds.
# FIX-CAST:  Use '-as [int]' (safe cast, returns $null on failure) instead of
#            '[int]' hard cast which throws if the enum cannot be converted.
# FIX-VALUE: 268435456 = GENERIC_ALL (rarely stored in ACL entries by icacls).
#            2032127   = FILE_ALL_ACCESS (what icacls actually writes). Use consistently.
function Test-HasFullControl {
    param([string]$Path, [string]$Identity)
    # BUG-FIX-1: Guard against Get-Acl returning $null (path inaccessible/denied).
    # Without this, $acl.Access throws NullReferenceException and crashes the script.
    $acl = Get-Acl $Path -ErrorAction SilentlyContinue
    if ($null -eq $acl) { return $false }

    $idUC  = $Identity.ToUpper()
    # BUG-FIX-2: Where-Object returns an empty array (not $null) when nothing matches.
    # ($null -ne @()) is $true -> false positive. Use .Count -gt 0 instead.
    # BUG-FIX-3: $acl.Access can be $null on an ACL with no entries (rare but valid).
    # @($null) returns Count=1 which would be another false positive.
    # Guard it first before piping into Where-Object.
    if ($null -eq $acl.Access) { return $false }
    $match = @($acl.Access | Where-Object {
        $_.IdentityReference.ToString().ToUpper() -eq $idUC -and
        $_.AccessControlType -eq "Allow" -and
        (
            $_.FileSystemRights -match "FullControl" -or        # string form
            ($_.FileSystemRights -as [int]) -eq 2032127 -or    # FILE_ALL_ACCESS (icacls)
            (($_.FileSystemRights -as [int]) -band 2032127) -eq 2032127  # bitmask check
        )
    })
    return ($match.Count -gt 0)
}

foreach ($d in $aclDirs) {
    if (!(Test-Path $d)) { W-Warn "Skipping (not found): $d"; continue }

    # Disable inheritance & convert inherited ACEs to explicit ones.
    # This lets winutils later modify ACEs without hitting inheritance-lock errors.
    icacls "$d" /inheritance:d /Q 2>&1 | Out-Null

    # Remove any explicit DENY ACEs for the user BEFORE granting.
    # DENY always overrides ALLOW in Windows ACLs, so a leftover DENY would
    # silently block access even after /grant FullControl succeeds.
    icacls "$d" /remove:d "${user}"          /T /Q 2>&1 | Out-Null
    icacls "$d" /remove:d "BUILTIN\Users"    /T /Q 2>&1 | Out-Null

    # Grant required parties Full Control with OI+CI (inherit to files & subfolders)
    icacls "$d" /grant "${user}:(OI)(CI)F"                /T /Q 2>&1 | Out-Null
    icacls "$d" /grant "BUILTIN\Users:(OI)(CI)F"          /T /Q 2>&1 | Out-Null
    icacls "$d" /grant "NT AUTHORITY\SYSTEM:(OI)(CI)F"    /T /Q 2>&1 | Out-Null
    icacls "$d" /grant "BUILTIN\Administrators:(OI)(CI)F" /T /Q 2>&1 | Out-Null

    # Verify the grant actually worked
    if (Test-HasFullControl -Path $d -Identity $user) {
        W-Ok  "ACL verified: $d"
    } else {
        W-Warn "Grant may not have applied cleanly for: $d"
    }
}

# HADOOP_HOME: grant access (no ownership change needed for install dir).
# /T recurses all subdirs so granting on the parent covers \bin and \logs too.
if (Test-Path $HADOOP_HOME) {
    icacls "$HADOOP_HOME" /grant "${user}:(OI)(CI)F"       /T /Q 2>&1 | Out-Null
    icacls "$HADOOP_HOME" /grant "BUILTIN\Users:(OI)(CI)F" /T /Q 2>&1 | Out-Null
    W-Ok "ACL set: $HADOOP_HOME (recursive - covers bin + logs)"
} else {
    W-Warn "HADOOP_HOME not found, skipping: $HADOOP_HOME"
}

# -------------------------------------------------------
# STEP 5: Verify with winutils chmod
# -------------------------------------------------------
W-Step 5 "Test winutils chmod (the actual Hadoop permission call)"
$wu = "$HADOOP_HOME\bin\winutils.exe"
if (!(Test-Path $wu)) {
    W-Warn "winutils.exe not found at: $wu"
    W-Warn "Download : https://github.com/cdarlint/winutils/raw/master/hadoop-3.3.6/bin/winutils.exe"
    W-Warn "Place in : $HADOOP_HOME\bin\"
} else {
    $testDirs = @("$DATA_DIR\datanode", "$DATA_DIR\namenode", "$DATA_DIR\tmp")
    $passed   = 0
    $failed   = 0
    $skipped  = 0

    # FIX-TEMPFILE: Use unique temp file name to avoid race condition if script
    # is run twice simultaneously (static name caused file sharing conflicts)
    $tmpErr = "$env:TEMP\winutils-err-$(Get-Random).txt"

    foreach ($td in $testDirs) {
        if (!(Test-Path $td)) { W-Warn "Skipping (not found): $td"; $skipped++; continue }

        # NOTE: Start-Process inherits the current ADMIN token, so this chmod test
        # runs as Administrator (who always has access). This proves winutils works
        # mechanically, but to confirm normal-user access we ALSO verify ownership below.
        $proc = Start-Process -FilePath "$wu" `
                              -ArgumentList @("chmod", "755", $td) `
                              -Wait -PassThru -NoNewWindow `
                              -RedirectStandardError $tmpErr

        if ($proc.ExitCode -eq 0) {
            # Secondary check: confirm directory owned by the target user (not just admin-accessible)
            $dirAcl  = Get-Acl $td -ErrorAction SilentlyContinue
            # Null-safe: guard both $dirAcl and $dirAcl.Owner before calling .ToUpper()
            $ownedOk = $dirAcl -and $dirAcl.Owner -and ($dirAcl.Owner.ToUpper() -eq $user.ToUpper())
            if ($ownedOk) {
                W-Ok "chmod PASSED + owner OK : $td"
            } else {
                $ownerStr = if ($dirAcl -and $dirAcl.Owner) { $dirAcl.Owner } else { "unknown" }
                W-Ok "chmod PASSED (Admin) but owner=$ownerStr - re-run Step 3"
            }
            $passed++
        } else {
            $errMsg = Get-Content $tmpErr -ErrorAction SilentlyContinue
            W-Err "chmod FAILED : $td  (exit $($proc.ExitCode)) $errMsg"
            $failed++
        }
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
    }

    Write-Host ""
    # FIX-PASSZERO: Only print "ALL PASSED" if at least 1 test ran
    if ($failed -eq 0 -and $passed -gt 0) {
        Write-Host "  ALL $passed CHMOD TESTS PASSED!" -ForegroundColor Green
    } elseif ($passed -eq 0 -and $skipped -gt 0) {
        W-Warn "No tests ran - all test directories were missing. Create them first."
    } else {
        Write-Host "  $passed passed, $failed FAILED, $skipped skipped." -ForegroundColor Red
        Write-Host "  Re-run this script or check ownership manually." -ForegroundColor Red
    }
}

# -------------------------------------------------------
# FINAL OUTPUT
# -------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DONE! Open a NEW normal CMD and run:" -ForegroundColor Green
Write-Host "    start-dfs.cmd       <- start NameNode + DataNode" -ForegroundColor White
Write-Host "    hdfs dfs -ls /      <- test HDFS access" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan
Read-Host "Press Enter to close"
