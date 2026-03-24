# fix-hadoop.ps1 - Run this as Administrator
# Fixes AccessDeniedException on namenode\current after NameNode reformat

Write-Host "=== Hadoop Fix Script ===" -ForegroundColor Cyan

# Step 1: Stop all hadoop processes
Write-Host "`n[1/5] Stopping all Hadoop processes..." -ForegroundColor Yellow
Get-Process -Name "java" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Write-Host "Done." -ForegroundColor Green

# Step 2: Take full ownership and set permissions
Write-Host "`n[2/5] Taking ownership of hadoop-data..." -ForegroundColor Yellow
takeown /F "C:\Users\VANSH\hadoop-data" /R /D Y | Out-Null
icacls "C:\Users\VANSH\hadoop-data" /grant "VANSH:(OI)(CI)F" /T /Q | Out-Null
icacls "C:\Users\VANSH\hadoop-data" /grant "Administrators:(OI)(CI)F" /T /Q | Out-Null
Write-Host "Done." -ForegroundColor Green

# Step 3: Delete old namenode AND datanode data
Write-Host "`n[3/5] Clearing old NameNode and DataNode data..." -ForegroundColor Yellow
Remove-Item -Recurse -Force "C:\Users\VANSH\hadoop-data\namenode" -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\VANSH\hadoop-data\datanode"  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "C:\Users\VANSH\hadoop-data\tmp"       -ErrorAction SilentlyContinue
Write-Host "Done." -ForegroundColor Green

# Step 4: Recreate the directories
Write-Host "`n[4/5] Recreating directories..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path "C:\Users\VANSH\hadoop-data\namenode" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Users\VANSH\hadoop-data\datanode"  | Out-Null
New-Item -ItemType Directory -Force -Path "C:\Users\VANSH\hadoop-data\tmp"       | Out-Null
# Set permissions on fresh directories
icacls "C:\Users\VANSH\hadoop-data" /grant "VANSH:(OI)(CI)F" /T /Q | Out-Null
Write-Host "Done." -ForegroundColor Green

# Step 5: Format the NameNode
Write-Host "`n[5/5] Formatting NameNode..." -ForegroundColor Yellow
& "C:\hadoop\bin\hdfs.cmd" namenode -format -force -nonInteractive
Write-Host "Done." -ForegroundColor Green

Write-Host "`n=== Fix Complete! ===" -ForegroundColor Cyan
Write-Host "Now run: C:\hadoop\sbin\start-dfs.cmd  then  C:\hadoop\sbin\start-yarn.cmd" -ForegroundColor White
Write-Host "Then verify with: jps" -ForegroundColor White
