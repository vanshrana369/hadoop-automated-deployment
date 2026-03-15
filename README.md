<div align="center">

# Hadoop Automated Deployment for Windows

**The only tool you need to get Apache Hadoop running on Windows — fully automated, zero manual steps.**

[![Stars](https://img.shields.io/github/stars/vanshrana369/hadoop-automated-deployment?style=for-the-badge&color=yellow)](https://github.com/vanshrana369/hadoop-automated-deployment/stargazers)
[![Forks](https://img.shields.io/github/forks/vanshrana369/hadoop-automated-deployment?style=for-the-badge&color=blue)](https://github.com/vanshrana369/hadoop-automated-deployment/network/members)
[![License](https://img.shields.io/github/license/vanshrana369/hadoop-automated-deployment?style=for-the-badge)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Hadoop](https://img.shields.io/badge/Hadoop-3.4.3-66CCFF?style=for-the-badge&logo=apachehadoop&logoColor=white)](https://hadoop.apache.org/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://www.microsoft.com/windows)

---

> Setting up Hadoop on Windows is a nightmare — broken guides, missing winutils, environment variable hell.
> **This script fixes all of that in one command.**

</div>

---

## Why This Exists

Every tutorial for installing Hadoop on Windows is either outdated, incomplete, or skips the Windows-specific fixes that make it actually work. After spending hours fighting with winutils, PATH issues, and Windows Defender quarantines — this installer was built to handle all of it automatically.

**One script. One run. Fully working Hadoop.**

---

## What It Does

Runs **10 steps fully automatically** in under 5 minutes:

| Step | What Happens |
|------|-------------|
| 1 | Detects existing Java 8 or installs Eclipse Temurin JDK 8 automatically |
| 2 | Downloads Hadoop 3.4.3 (~380 MB) with 3-mirror fallback — never fails on a single mirror |
| 3 | Downloads winutils.exe + hadoop.dll (the Windows-critical files most guides miss) |
| 4 | Sets `JAVA_HOME`, `HADOOP_HOME`, and `PATH` at system level — works in every terminal |
| 5 | Writes all XML config files: `core-site`, `hdfs-site`, `mapred-site`, `yarn-site` |
| 6 | Patches `hadoop-env.cmd` for paths with spaces (e.g. `C:\Program Files`) |
| 7 | Creates HDFS NameNode + DataNode directories with correct permissions |
| 8 | Formats the NameNode automatically |
| 9 | Adds Windows Defender exclusion + Firewall rules (ports 9870, 8088) |
| 10 | Verifies with `hadoop version` — you see it working before the script ends |

---

## Quick Start

> **Requirements:** Windows 10 (1803+) or Windows 11, internet connection, Administrator access.

**1. Open PowerShell as Administrator**

Press `Win + S` → type **PowerShell** → right-click → **Run as Administrator**

**2. Run this single command:**

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hadoop.ps1
```

That's it. The script handles everything else.

---

## After Installation

Open a **new** Command Prompt or PowerShell window, then:

### Start Hadoop
```cmd
C:\hadoop\sbin\start-dfs.cmd
C:\hadoop\sbin\start-yarn.cmd
```

### Verify Everything is Running
```cmd
jps
```
Expected output:
```
NameNode
DataNode
ResourceManager
NodeManager
```

### Web UIs
| Service | URL |
|---------|-----|
| HDFS NameNode | http://localhost:9870 |
| YARN ResourceManager | http://localhost:8088 |

### Test HDFS
```cmd
hdfs dfs -mkdir /user
hdfs dfs -mkdir /user/%USERNAME%
hdfs dfs -put C:\Windows\System32\drivers\etc\hosts /user/%USERNAME%/
hdfs dfs -ls /user/%USERNAME%/
```

### Stop Hadoop
```cmd
C:\hadoop\sbin\stop-yarn.cmd
C:\hadoop\sbin\stop-dfs.cmd
```

---

## Customization

Edit these variables at the top of `install-hadoop.ps1` before running:

| Variable | Default | Description |
|----------|---------|-------------|
| `$HADOOP_VERSION` | `3.4.3` | Hadoop version to install |
| `$INSTALL_DIR` | `C:\hadoop` | Where Hadoop is installed |
| `$DATA_DIR` | `%USERPROFILE%\hadoop-data` | HDFS data directory |
| `$NAMENODE_PORT` | `9000` | NameNode RPC port |
| `$REPLICATION` | `1` | Replication factor (keep 1 for single-node) |

---

## Installation Layout

```
C:\hadoop\                          ← HADOOP_HOME
├── bin\                            ← hadoop.cmd, hdfs.cmd, winutils.exe
├── sbin\                           ← start-dfs.cmd, start-yarn.cmd
├── etc\hadoop\                     ← core-site.xml, hdfs-site.xml, ...
└── share\                          ← Libraries

%USERPROFILE%\hadoop-data\          ← HDFS data (safe, user-owned)
├── namenode\                       ← HDFS metadata
├── datanode\                       ← HDFS data blocks
└── logs\                           ← Hadoop logs
```

---

## Troubleshooting

<details>
<summary><b>"Running scripts is disabled on this system"</b></summary>

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```
</details>

<details>
<summary><b>winutils.exe missing after install (Windows Defender quarantine)</b></summary>

Go to: **Windows Security → Virus & threat protection → Protection history**
Find `winutils.exe` → click **Allow on device** → re-run the installer.

Or run this before re-running:
```powershell
Add-MpPreference -ExclusionPath "C:\hadoop\bin"
```
</details>

<details>
<summary><b>hadoop / java not found after install</b></summary>

Open a **new** terminal window (environment variables don't apply to already-open windows):
```cmd
echo %JAVA_HOME%
echo %HADOOP_HOME%
hadoop version
```
</details>

<details>
<summary><b>NameNode won't start</b></summary>

```cmd
hdfs namenode -format -force
C:\hadoop\sbin\start-dfs.cmd
```
</details>

<details>
<summary><b>Ports 9870 / 8088 not accessible from another machine</b></summary>

The script adds firewall rules automatically. If they're missing:
```powershell
New-NetFirewallRule -DisplayName "Hadoop NameNode" -Direction Inbound -LocalPort 9870 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "Hadoop YARN" -Direction Inbound -LocalPort 8088 -Protocol TCP -Action Allow
```
</details>

---

## Compatibility

| Component | Version |
|-----------|---------|
| Hadoop | 3.4.3 |
| Java | 8 (Eclipse Temurin) |
| Windows | 10 (1803+), 11 |
| PowerShell | 5.1+ |

---

## Roadmap

- [x] Hadoop 3.4.3 single-node installer
- [x] Auto Java 8 installation
- [x] winutils + hadoop.dll download with mirror fallback
- [x] Windows Defender + Firewall auto-configuration
- [x] Upgrade-safe (preserves HDFS data on reinstall)
- [ ] Apache Hive installer (coming soon)
- [ ] Multi-node cluster support

---

## Contributing

Pull requests are welcome! If you find a bug, open an issue. If you tested this on a specific Windows version, let us know in the discussions tab.

---

## Author

**Vansh Rana**
- GitHub: [@vanshrana369](https://github.com/vanshrana369)

---

<div align="center">

### If this saved you an hour of frustration, please star the repo!

[![Star this repo](https://img.shields.io/badge/Star%20on%20GitHub-%E2%AD%90-yellow?style=for-the-badge&logo=github)](https://github.com/vanshrana369/hadoop-automated-deployment)

*Stars help other developers find this tool when they're stuck setting up Hadoop on Windows.*

</div>
