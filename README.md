# 🔬 Synopsis.ps1

<div align="center">

**[PowerShell 5.1+] | [Windows 10/11] | [Admin Required]**

*A production-grade hardware intelligence platform for Windows fleet management*

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows)](https://www.microsoft.com/windows)
[![License](https://img.shields.io/badge/License-BSL-green)](LICENSE)

</div>

---

## 📊>> What It Does

A single PowerShell script that transforms any Windows machine into a **fully audited hardware asset**. From a single workstation to an entire data center, this tool collects, analyzes, and reports on virtually every piece of hardware information the operating system can expose.

###  Key Capabilities

- ** Deep Hardware Inventory**  CPU, GPU, RAM, disks, network, PCI devices, USB, TPM, battery, and more
- ** Thermal Monitoring**  NVIDIA and AMD GPU temperatures with multiple fallback methods
- ** Storage Health**  SMART attributes, NVMe wear leveling, read/write latency, error counts
- ** Network Intelligence**  Jumbo frames, VLAN, RSS, TCP offload, buffer sizes
- ** Performance Metrics**  27 real-time counters across CPU, memory, disk, and network
- ** Change Detection**  Compare snapshots to identify hardware modifications
- ** Driver Updates**  Windows Update driver availability awareness
- ** Remote & Batch** Single-system, remote CIM, or fleet-wide batch scanning
- ** Multi-Format Export**  JSON, CSV, and professional dark-themed HTML reports
- ** Operational Logging**  Timestamped diagnostic logs with severity levels

---

## Quick Start

```powershell
# Basic local scan with console output
.\HardwareScanner.ps1

# Export everything as a professional HTML report with performance data
.\HardwareScanner.ps1 -ExportHTML -IncludePerformance -IncludeRegistry

# Remote audit of a server with logging
.\HardwareScanner.ps1 -ComputerName "SRV-DC01" -ExportJSON -LogFile "audit.log"

# Batch scan your entire fleet
.\HardwareScanner.ps1 -ComputerList @("PC01","PC02","SRV01") -ExportJSON -ExportHTML

# Detect hardware changes since baseline
.\HardwareScanner.ps1 -CompareWith "baseline.json" -ExportHTML

# GPU-focused diagnostics with thermal data
.\HardwareScanner.ps1 -Category GPU -IncludePerformance -ExportHTML

# Network deep-dive with advanced properties
.\HardwareScanner.ps1 -Category Network -IncludeAdvancedNetwork -ExportJSON
