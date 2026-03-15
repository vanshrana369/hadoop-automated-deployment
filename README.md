# Hadoop Automated Installer for Windows

Installs and configures a single-node **Hadoop 3.4.3** + **Java 8** cluster on Windows automatically — no manual steps required.

---

## Prerequisites

- **Windows 10 (1803+)** or **Windows 11**
- **Internet connection** (downloads Hadoop, Java, and winutils)
- **Administrator access**

---

## How to Run

**Step 1:** Open PowerShell as Administrator
- Press `Win + S`, type **PowerShell**, right-click → **Run as Administrator**

**Step 2:** Allow script execution for this session
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

**Step 3:** Navigate to the script folder
```powershell
cd "path\to\hadoop-installer"
```

**Step 4:** Run the installer
```powershell
.\install-hadoop.ps1
```

**Step 5:** Wait — the script handles everything automatically.

---

## What the Script Does

| Step | Action |
|------|--------|
| 1 | Detects or installs **Java 8** (Eclipse Temurin) |
| 2 | Downloads **Hadoop 3.4.3** (~380 MB) with mirror fallback |
| 3 | Downloads **winutils.exe** (required for Hadoop on Windows) |
| 4 | Sets environment variables: `JAVA_HOME`, `HADOOP_HOME`, `PATH` |
| 5 | Writes XML config files: `core-site`, `hdfs-site`, `mapred-site`, `yarn-site` |
| 6 | Fixes `hadoop-env.cmd` for paths with spaces (e.g. `Program Files`) |
| 7 | Creates HDFS data directories (NameNode + DataNode) |
| 8 | Formats the NameNode |
| 9 | Adds Windows Defender exclusion for `hadoop\bin` (prevents winutils quarantine) |
| 9 | Opens Windows Firewall ports 9870 and 8088 for Web UI access |
| 10 | Runs `hadoop version` to verify the installation |

---

## After Installation

> **Open a NEW Command Prompt** after the script finishes — environment variables only apply to new terminals.

### Start Hadoop
```cmd
C:\hadoop\sbin\start-dfs.cmd
C:\hadoop\sbin\start-yarn.cmd
```

### Verify Services
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
|---|---|
| NameNode (HDFS) | http://localhost:9870 |
| YARN ResourceManager | http://localhost:8088 |

### Test HDFS
```cmd
hdfs dfs -mkdir /user
hdfs dfs -mkdir /user/%USERNAME%
hdfs dfs -ls /
```

### Stop Hadoop
```cmd
C:\hadoop\sbin\stop-yarn.cmd
C:\hadoop\sbin\stop-dfs.cmd
```

---

## Configuration

Edit these variables at the top of `install-hadoop.ps1` before running:

| Variable | Default | Description |
|---|---|---|
| `$HADOOP_VERSION` | `3.4.3` | Hadoop version |
| `$INSTALL_DIR` | `C:\hadoop` | Hadoop installation path |
| `$DATA_DIR` | `%USERPROFILE%\hadoop-data` | HDFS data directory |
| `$NAMENODE_PORT` | `9000` | NameNode RPC port |
| `$REPLICATION` | `1` | Replication factor (1 = single node) |

---

## Troubleshooting

**"Running scripts is disabled on this system"**
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

**"Must be run as Administrator"**
Right-click PowerShell → Run as Administrator

**`winutils.exe` missing after install**
Windows Defender quarantined it. Go to:
Windows Security → Virus & threat protection → Protection history → find winutils.exe → Allow on device.
Then re-run the installer.

**`hadoop`/`java` not found after install**
Open a **new** Command Prompt (not the same window) and try again:
```cmd
echo %JAVA_HOME%
echo %HADOOP_HOME%
hadoop version
```

**NameNode won't start**
```cmd
hdfs namenode -format -force
C:\hadoop\sbin\start-dfs.cmd
```

---

## Installation Layout

```
C:\hadoop\                         <- HADOOP_HOME
├── bin\                           <- hadoop.cmd, hdfs.cmd, winutils.exe
├── sbin\                          <- start-dfs.cmd, start-yarn.cmd, ...
├── etc\hadoop\                    <- core-site.xml, hdfs-site.xml, ...
└── share\                         <- Libraries

%USERPROFILE%\hadoop-data\         <- HDFS data (user-owned)
├── namenode\                      <- HDFS metadata
├── datanode\                      <- HDFS data blocks
└── logs\                          <- Hadoop logs

C:\Program Files\Eclipse Adoptium\ <- JAVA_HOME
└── jdk-8.x.x-hotspot\
```

**Environment variables set:**
- `JAVA_HOME` → Java 8 installation path
- `HADOOP_HOME` → `C:\hadoop`
- `PATH` → includes `%JAVA_HOME%\bin`, `%HADOOP_HOME%\bin`, `%HADOOP_HOME%\sbin`

---

## Author

**Vansh Rana** — v2.0, March 2026
