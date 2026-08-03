param(
    [switch]$ExportJSON,
    [switch]$ExportCSV,
    [switch]$ExportHTML,
    [string]$OutputPath = "$env:USERPROFILE\Desktop",
    [switch]$IncludePerformance,
    [switch]$IncludeRegistry,
    [ValidateSet('System','CPU','Memory','GPU','Disk','Network','All')]
    [string]$Category = 'All',
    [string]$ComputerName,
    [string]$LogFile,
    [string]$CompareWith,
    [switch]$IncludeAdvancedNetwork,
    [int]$ThrottleLimit = 5,
    [string[]]$ComputerList
)

#Requires -RunAsAdministrator

$script:LogPath = $LogFile
$script:StartTime = Get-Date

function Write-Log {
    param([string]$M, [string]$L = "INFO")
    if ($script:LogPath) {
        "$(Get-Date -Format 'HH:mm:ss.fff') [$L] $M" | Out-File $script:LogPath -Append
    }
}

$colors = @{
    H='Cyan'; S='Yellow'; SS='Magenta'; L='Green'; V='White'
    D='Yellow'; A='Green'; R='Red'; W='DarkYellow'; E='Red'
    SU='Green'; I='Gray'; P='Cyan'
}

function Write-PB {
    param([string]$A, [string]$S, [int]$P)
    $c = [math]::Floor($P/100*50)
    Write-Host "`r$A : [$('='*$c)$(' '*(50-$c))] $P% - $S" -ForegroundColor $colors.P
}

function New-CimSessionSafe {
    if ($script:CimSession) { return }
    try {
        $script:CimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop -SessionOption (New-CimSessionOption -Protocol Dcom)
        Write-Log "CIM session established" "SUCCESS"
    } catch {
        Write-Log "CIM failed: $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Get-Cim {
    param([string]$C, [string]$NS="root/cimv2", [string]$F, [string[]]$Prop)
    $p = @{ClassName=$C; Namespace=$NS; ErrorAction='SilentlyContinue'}
    if ($script:CimSession) {$p.CimSession=$script:CimSession}
    if ($Prop) {$p.Property=$Prop}
    if ($F) {$p.Filter=$F}
    try {Get-CimInstance @p} catch {$null}
}

function Get-Reg {
    param([string]$P, [string]$N)
    try {
        if ($script:CimSession) {
            $r = Invoke-CimMethod -CimSession $script:CimSession -ClassName StdRegProv -MethodName GetStringValue -Arguments @{hDefKey=2147483650; sSubKeyName=$P -replace '^HKLM:\\',''; sValueName=$N} -ErrorAction Stop
            return $r.sValue
        } else {
            return (Get-ItemProperty -Path $P -Name $N -ErrorAction Stop).$N
        }
    } catch {"N/A"}
}

function Get-SMART {
    param([string]$SN)
    try {
        $pd = Get-Cim -C MSFT_PhysicalDisk -NS "root/microsoft/windows/storage" -F "SerialNumber='$SN'"
        if (-not $pd) {return $null}
        [ordered]@{
            Health=$pd.HealthStatus; OpStatus=$pd.OperationalStatus; Media=$pd.MediaType; Bus=$pd.BusType
            Temp=if($pd.Temperature){"$($pd.Temperature) C"}else{"N/A"}
            TempMax=if($pd.TemperatureMax){"$($pd.TemperatureMax) C"}else{"N/A"}
            Hours=if($pd.PowerOnHours){$pd.PowerOnHours}else{"N/A"}
            PowerCycles=if($pd.PowerOnCount){$pd.PowerOnCount}else{"N/A"}
            ReadErrors=if($pd.ReadErrorsTotal){$pd.ReadErrorsTotal}else{"N/A"}
            WriteErrors=if($pd.WriteErrorsTotal){$pd.WriteErrorsTotal}else{"N/A"}
            Wear=if($pd.Wear){"$($pd.Wear)%"}else{"N/A"}
        }
    } catch {$null}
}

function Get-NVMe {
    try {
        $drives = Get-Cim -C MSFT_PhysicalDisk -NS "root/microsoft/windows/storage" | ? {$_.MediaType -eq 4}
        if (-not $drives) {return @()}
        $result = @()
        foreach ($d in $drives) {
            $rel = Get-Cim -C MSFT_StorageReliabilityCounter -NS "root/microsoft/windows/storage" -F "DeviceId='$($d.DeviceId)'"
            if ($rel) {
                $result += [ordered]@{
                    Device=$d.FriendlyName; Temp=$d.Temperature; Hours=$rel.PowerOnHours
                    Wear=$rel.Wear; ReadErrors=$rel.ReadErrorsTotal; WriteErrors=$rel.WriteErrorsTotal
                    ReadLatMax=$rel.ReadLatencyMax; WriteLatMax=$rel.WriteLatencyMax; FlushLatMax=$rel.FlushLatencyMax
                }
            }
        }
        $result
    } catch {Write-Log "NVMe failed" "WARN"; @()}
}

function Get-GPUTemp {
    try {
        $temps = @()
        try {
            $nv = Get-Cim -NS "root/wmi" -C "NVThermalSensors"
            if ($nv) {
                foreach ($s in $nv) {
                    $temps += [ordered]@{Name="NVIDIA"; Temp="$([math]::Round($s.ThermalSensors/1000,1)) C"; Method="Direct"}
                }
            }
        } catch {Write-Log "NVIDIA temp N/A" "DEBUG"}
        try {
            $amd = Get-Cim -NS "root/wmi" -C "AMD_Thermal"
            if ($amd) {
                foreach ($s in $amd) {
                    $temps += [ordered]@{Name="AMD"; Temp="$([math]::Round($s.Temperature/1000,1)) C"; Method="Direct"}
                }
            }
        } catch {Write-Log "AMD temp N/A" "DEBUG"}
        try {
            $pc = Get-Counter "\GPU Engine(*)\Utilization Percentage" -EA 0
            if ($pc) {
                $groups = $pc.CounterSamples | Group {($_.Path -split '\\')[3]}
                foreach ($g in $groups) {
                    $avg = ($g.Group | Measure CookedValue -Average).Average
                    if ($avg -gt 0) {
                        $temps += [ordered]@{Name=($g.Name -replace '_',' '); Util="$( [math]::Round($avg,2))%"; Method="PerfCounter"}
                    }
                }
            }
        } catch {}
        $temps
    } catch {@()}
}

function Get-AdvNet {
    param($Adapter)
    try {
        $props = @{}
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
        if (-not $script:CimSession) {
            $subs = Get-ChildItem $key -EA 0
            if ($subs) {
                foreach ($k in $subs) {
                    $desc = Get-Reg $k.PSPath "DriverDesc"
                    if ($desc -ne "N/A" -and $Adapter.Name -like "*$desc*") {
                        $props.Jumbo=Get-Reg $k.PSPath "*JumboPacket"
                        $props.VLAN=Get-Reg $k.PSPath "VlanID"
                        $props.RSS=Get-Reg $k.PSPath "*RSS"
                        $props.TCPChk=Get-Reg $k.PSPath "*TCPUDPChecksumOffloadIPv4"
                        $props.LSO=Get-Reg $k.PSPath "*LsoV2IPv4"
                        $props.RxBuf=Get-Reg $k.PSPath "*ReceiveBuffers"
                        $props.TxBuf=Get-Reg $k.PSPath "*TransmitBuffers"
                        $props.WoL=Get-Reg $k.PSPath "*WakeOnMagicPacket"
                        $props.EEE=Get-Reg $k.PSPath "*EEELinkAdvertisement"
                        break
                    }
                }
            }
        }
        if ($props.Count -gt 0) {$props} else {$null}
    } catch {$null}
}

function Get-PCI {
    param([int]$Max=50)
    try {
        $devs = Get-Cim -C Win32_PnPEntity | ? {$_.PNPDeviceID -match '^(PCI|ACPI|SCSI|USB)\\VEN_'} | select -First $Max
        if (-not $devs) {return @()}
        $devs | % {
            [ordered]@{
                Name=if($_.Name){$_.Name}else{"Unknown"}
                PNPID=$_.PNPDeviceID; Class=if($_.PNPClass){$_.PNPClass}else{"N/A"}
                Mfr=if($_.Manufacturer){$_.Manufacturer}else{"N/A"}
                Driver=if($_.DriverVersion){$_.DriverVersion}else{"N/A"}
                DriverDate=if($_.DriverDate){$_.DriverDate}else{"N/A"}
                Status=$_.Status
            }
        }
    } catch {@()}
}

function Get-Perf {
    try {
        [ordered]@{
            CPU=[ordered]@{
                Util=[math]::Round((Get-Counter "\Processor(_Total)\% Processor Time" -EA 0).CounterSamples.CookedValue,2)
                DPC=[math]::Round((Get-Counter "\Processor(_Total)\DPCs Queued/sec" -EA 0).CounterSamples.CookedValue,2)
                IntPS=[math]::Round((Get-Counter "\Processor(_Total)\Interrupts/sec" -EA 0).CounterSamples.CookedValue,2)
                CtxSw=[math]::Round((Get-Counter "\System\Context Switches/sec" -EA 0).CounterSamples.CookedValue,2)
            }
            Memory=[ordered]@{
                AvailMB=[math]::Round((Get-Counter "\Memory\Available MBytes" -EA 0).CounterSamples.CookedValue,2)
                CommitGB=[math]::Round((Get-Counter "\Memory\Committed Bytes" -EA 0).CounterSamples.CookedValue/1GB,2)
                LimitGB=[math]::Round((Get-Counter "\Memory\Commit Limit" -EA 0).CounterSamples.CookedValue/1GB,2)
                PageFaults=[math]::Round((Get-Counter "\Memory\Page Faults/sec" -EA 0).CounterSamples.CookedValue,2)
                PoolPagedMB=[math]::Round((Get-Counter "\Memory\Pool Paged Bytes" -EA 0).CounterSamples.CookedValue/1MB,2)
                PoolNonPagedMB=[math]::Round((Get-Counter "\Memory\Pool Nonpaged Bytes" -EA 0).CounterSamples.CookedValue/1MB,2)
                CacheMB=[math]::Round((Get-Counter "\Memory\Cache Bytes" -EA 0).CounterSamples.CookedValue/1MB,2)
            }
            Disk=[ordered]@{
                QueueLen=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Current Disk Queue Length" -EA 0).CounterSamples.CookedValue,2)
                ReadMBs=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Disk Read Bytes/sec" -EA 0).CounterSamples.CookedValue/1MB,2)
                WriteMBs=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Disk Write Bytes/sec" -EA 0).CounterSamples.CookedValue/1MB,2)
                ReadLatMs=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Avg. Disk sec/Read" -EA 0).CounterSamples.CookedValue*1000,2)
                WriteLatMs=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Avg. Disk sec/Write" -EA 0).CounterSamples.CookedValue*1000,2)
                SplitIO=[math]::Round((Get-Counter "\PhysicalDisk(_Total)\Split IO/Sec" -EA 0).CounterSamples.CookedValue,2)
            }
            Network=[ordered]@{
                MBs=[math]::Round((Get-Counter "\Network Interface(_Total)\Bytes Total/sec" -EA 0).CounterSamples.CookedValue/1MB,2)
                Pkts=[math]::Round((Get-Counter "\Network Interface(_Total)\Packets/sec" -EA 0).CounterSamples.CookedValue,2)
                Discard=[math]::Round((Get-Counter "\Network Interface(_Total)\Packets Outbound Discarded" -EA 0).CounterSamples.CookedValue,2)
                BwMbps=[math]::Round((Get-Counter "\Network Interface(_Total)\Current Bandwidth" -EA 0).CounterSamples.CookedValue/1e6,2)
            }
            System=[ordered]@{
                Procs=(Get-Counter "\System\Processes" -EA 0).CounterSamples.CookedValue
                Threads=(Get-Counter "\System\Threads" -EA 0).CounterSamples.CookedValue
                Handles=(Get-Counter "\System\Handles" -EA 0).CounterSamples.CookedValue
                UpSec=(Get-Counter "\System\System Up Time" -EA 0).CounterSamples.CookedValue
            }
        }
    } catch {$null}
}

function Get-DriverUpdates {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 3
        $results = $searcher.Search("IsInstalled=0 AND Type='Driver'")
        $updates = @()
        if ($results.Updates.Count -gt 0) {
            $results.Updates | select -First 20 | % {
                $updates += [ordered]@{Title=$_.Title; DriverClass=$_.Categories.Name; Date=$_.LastDeploymentChangeTime}
            }
        }
        if ($updates.Count -gt 0) {$updates} else {$null}
    } catch {$null}
}

function Get-Hardware {
    param([string]$Cat='All', [switch]$Perf, [switch]$Reg, [switch]$AdvNet)
    
    $info = [ordered]@{}
    $step = 0; $total = 28
    
    Write-Host ""
    Write-Log "Scan started" "INFO"
    
    if ($Cat -in @('System','All')) {
        $step++; Write-PB "[$step/$total] System" "Gathering..." ([math]::Round($step/$total*100))
        $cs = Get-Cim -C Win32_ComputerSystem
        $csp = Get-Cim -C Win32_ComputerSystemProduct
        $bios = Get-Cim -C Win32_BIOS
        $bb = Get-Cim -C Win32_BaseBoard
        $info.System = [ordered]@{
            Mfr=$cs.Manufacturer; Model=$cs.Model; UUID=if($csp.UUID){$csp.UUID}else{"N/A"}
            RAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2); CPUs=$cs.NumberOfProcessors
            LogicalCPUs=$cs.NumberOfLogicalProcessors; HyperV=$cs.HypervisorPresent; Host=$cs.DNSHostName
        }
        $info.BIOS = [ordered]@{Mfr=$bios.Manufacturer; Ver=$bios.SMBIOSBIOSVersion; Date=$bios.ReleaseDate; SN=$bios.SerialNumber}
        $info.Motherboard = [ordered]@{Mfr=$bb.Manufacturer; Product=$bb.Product; Ver=$bb.Version; SN=$bb.SerialNumber}
    }
    
    if ($Cat -in @('CPU','All')) {
        $step++; Write-PB "[$step/$total] CPU" "Analyzing..." ([math]::Round($step/$total*100))
        $cpus = Get-Cim -C Win32_Processor
        $cpuArr = @()
        if ($cpus) {
            foreach ($c in $cpus) {
                $cpuArr += [ordered]@{
                    Name=($c.Name -replace '\s+',' '); Arch=switch($c.Architecture){0{"x86"}9{"x64"}12{"ARM64"}default{"?"}}
                    MaxMHz=$c.MaxClockSpeed; Cores=$c.NumberOfCores; Logical=$c.NumberOfLogicalProcessors
                    L2=if($c.L2CacheSize){"$($c.L2CacheSize)KB"}else{"N/A"}
                    L3=if($c.L3CacheSize){"$($c.L3CacheSize)KB"}else{"N/A"}
                    Socket=$c.SocketDesignation; VT=$c.VirtualizationFirmwareEnabled; Load="$($c.LoadPercentage)%"
                }
            }
        }
        $info.CPU = $cpuArr
    }
    
    if ($Cat -in @('Memory','All')) {
        $step++; Write-PB "[$step/$total] RAM" "Detecting..." ([math]::Round($step/$total*100))
        $mem = Get-Cim -C Win32_PhysicalMemory
        $memArr = @()
        if ($mem) {
            foreach ($m in $mem) {
                $memArr += [ordered]@{
                    Mfr=$m.Manufacturer; PN=$m.PartNumber; SN=$m.SerialNumber
                    GB=[math]::Round($m.Capacity/1GB,2); MHz=$m.Speed
                    FF=switch($m.FormFactor){8{"DIMM"}12{"SODIMM"}default{$m.FormFactor}}
                    Type=switch($m.MemoryType){20{"DDR"}21{"DDR2"}24{"DDR3"}26{"DDR4"}34{"DDR5"}default{$m.MemoryType}}
                    Slot=$m.DeviceLocator; Bank=$m.BankLabel
                    V=if($m.ConfiguredVoltage){"$([math]::Round($m.ConfiguredVoltage/1000,3))V"}else{"N/A"}
                }
            }
        }
        $info.Memory = $memArr
    }
    
    if ($Cat -in @('GPU','All')) {
        $step++; Write-PB "[$step/$total] GPU" "Analyzing..." ([math]::Round($step/$total*100))
        $vc = Get-Cim -C Win32_VideoController
        $gpuArr = @()
        if ($vc) {
            foreach ($g in $vc) {
                $gpuArr += [ordered]@{
                    Name=$g.Name; RAM=if($g.AdapterRAM){"$([math]::Round($g.AdapterRAM/1GB,2))GB"}else{"N/A"}
                    Driver=$g.DriverVersion; Date=$g.DriverDate; Mode=$g.VideoModeDescription
                    Hz="$($g.CurrentRefreshRate)Hz"; Res="$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"
                    VPU=$g.VideoProcessor; Status=$g.Status
                }
            }
        }
        $info.GPU = $gpuArr
        if ($Perf) {
            $gt = Get-GPUTemp
            if ($gt.Count -gt 0) {$info.GPUPerf = $gt}
        }
    }
    
    if ($Cat -in @('Disk','All')) {
        $step++; Write-PB "[$step/$total] Disks" "Scanning..." ([math]::Round($step/$total*100))
        $disks = Get-Cim -C Win32_DiskDrive
        $diskArr = @()
        if ($disks) {
            foreach ($d in $disks) {
                $parts = Get-CimAssociatedInstance -InputObject $d -ResultClassName Win32_DiskPartition -EA 0
                $partInfo = @()
                if ($parts) {
                    foreach ($p in $parts) {
                        $ld = Get-CimAssociatedInstance -InputObject $p -ResultClassName Win32_LogicalDisk -EA 0
                        if ($ld) {
                            foreach ($l in $ld) {
                                if ($l.DeviceID) {
                                    $partInfo += [ordered]@{
                                        Drive=$l.DeviceID; Label=if($l.VolumeName){$l.VolumeName}else{"N/A"}
                                        GB=if($l.Size){[math]::Round($l.Size/1GB,2)}else{"N/A"}
                                        Free=if($l.FreeSpace){[math]::Round($l.FreeSpace/1GB,2)}else{"N/A"}
                                        FreePct=if($l.Size-and$l.Size-gt0){[math]::Round($l.FreeSpace/$l.Size*100,2)}else{"N/A"}
                                        FS=$l.FileSystem
                                    }
                                }
                            }
                        }
                    }
                }
                $di = [ordered]@{
                    Model=($d.Model -replace '\s+',' '); Mfr=$d.Manufacturer
                    GB=if($d.Size){[math]::Round($d.Size/1GB,2)}else{"N/A"}
                    Interface=$d.InterfaceType; Media=$d.MediaType; SN=$d.SerialNumber; FW=$d.FirmwareRevision
                    Partitions=$partInfo
                }
                $smart = Get-SMART $d.SerialNumber
                if ($smart) {$di.SMART = $smart}
                $diskArr += $di
            }
        }
        $info.Disks = $diskArr
        $nvme = Get-NVMe
        if ($nvme.Count -gt 0) {$info.NVMe = $nvme}
    }
    
    if ($Cat -in @('Network','All')) {
        $step++; Write-PB "[$step/$total] Network" "Scanning..." ([math]::Round($step/$total*100))
        $adapters = Get-Cim -C Win32_NetworkAdapter | ? {$_.PhysicalAdapter}
        $netArr = @()
        if ($adapters) {
            foreach ($a in $adapters) {
                $cfg = Get-Cim -C Win32_NetworkAdapterConfiguration -F "Index=$($a.Index)"
                $ni = [ordered]@{
                    Name=$a.Name; Product=$a.ProductName; Mfr=$a.Manufacturer; MAC=$a.MACAddress
                    Speed=if($a.Speed-and$a.Speed-gt0){if($a.Speed-ge1e9){"$([math]::Round($a.Speed/1e9,2))Gbps"}else{"$([math]::Round($a.Speed/1e6,2))Mbps"}}else{"N/A"}
                    Status=$a.Status; Conn=switch($a.NetConnectionStatus){0{"Disconnected"}2{"Connected"}default{$a.NetConnectionStatus}}
                }
                if ($cfg) {
                    $ni.IP=if($cfg.IPAddress){$cfg.IPAddress -join ','}else{"N/A"}
                    $ni.GW=if($cfg.DefaultIPGateway){$cfg.DefaultIPGateway -join ','}else{"N/A"}
                    $ni.DHCP=$cfg.DHCPEnabled
                    $ni.DNS=if($cfg.DNSServerSearchOrder){$cfg.DNSServerSearchOrder -join ','}else{"N/A"}
                }
                if ($AdvNet) {
                    $ap = Get-AdvNet $a
                    if ($ap) {$ni.Advanced = $ap}
                }
                $netArr += $ni
            }
        }
        $info.Network = $netArr
    }
    
    if ($Cat -in @('All')) {
        $step++; Write-PB "[$step/$total] PCI" "Enumerating..." ([math]::Round($step/$total*100))
        $pci = Get-PCI
        if ($pci.Count -gt 0) {$info.PCI = $pci}
        
        $step++; Write-PB "[$step/$total] Peripherals" "Checking..." ([math]::Round($step/$total*100))
        try {
            $tpm = Get-Cim -C Win32_Tpm -NS "root/cimv2/Security/MicrosoftTpm"
            if ($tpm) {$info.TPM = [ordered]@{Active=$tpm.IsActivated_InitialValue; Enabled=$tpm.IsEnabled_InitialValue; Spec=$tpm.SpecVersion}}
        } catch {}
        try {
            $bat = Get-Cim -C Win32_Battery
            if ($bat) {
                $info.Battery = [ordered]@{
                    Charge="$($bat.EstimatedChargeRemaining)%"
                    Chem=$bat.Chemistry; Design=$bat.DesignCapacity; Full=$bat.FullChargeCapacity
                    Status=switch($bat.BatteryStatus){1{"Discharging"}2{"AC"}3{"Full"}6{"Charging"}default{"?"}}
                }
            }
        } catch {}
    }
    
    if ($Reg) {
        $step++; Write-PB "[$step/$total] Registry" "Reading..." ([math]::Round($step/$total*100))
        $info.Registry = [ordered]@{
            CPU=Get-Reg "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" "ProcessorNameString"
            BIOS=Get-Reg "HKLM:\HARDWARE\DESCRIPTION\System" "SystemBiosVersion"
            BoardMfr=Get-Reg "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" "BaseBoardManufacturer"
            BoardProd=Get-Reg "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" "BaseBoardProduct"
        }
    }
    
    if ($Perf) {
        $step++; Write-PB "[$step/$total] Performance" "Collecting..." ([math]::Round($step/$total*100))
        $pd = Get-Perf
        if ($pd) {$info.Performance = $pd}
        
        $step++; Write-PB "[$step/$total] Driver Updates" "Checking..." ([math]::Round($step/$total*100))
        $du = Get-DriverUpdates
        if ($du) {$info.DriverUpdates = $du}
    }
    
    if ($Cat -in @('System','All')) {
        $step++; Write-PB "[$step/$total] OS" "Reading..." ([math]::Round($step/$total*100))
        $os = Get-Cim -C Win32_OperatingSystem
        if ($os) {
            $info.OS = [ordered]@{
                Name=$os.Name; Ver=$os.Version; Build=$os.BuildNumber; Arch=$os.OSArchitecture
                Installed=$os.InstallDate; Boot=$os.LastBootUpTime
                FreeGB=[math]::Round($os.FreePhysicalMemory/1MB,2); TotalGB=[math]::Round($os.TotalVisibleMemorySize/1MB,2)
                Procs=$os.NumberOfProcesses
            }
        }
    }
    
    for ($i=$step+1; $i-le$total; $i++) {
        Write-PB "[$i/$total]" "Finalizing..." ([math]::Round($i/$total*100))
        Start-Sleep -Milliseconds 80
    }
    Write-Host ""
    Write-Log "Scan complete" "SUCCESS"
    if ($script:CimSession) {Remove-CimSession $script:CimSession}
    return $info
}

function Compare-Data {
    param($New, $Path)
    try {
        $old = Get-Content $Path -EA Stop | ConvertFrom-Json
        $diffs = @()
        foreach ($s in $New.Keys) {
            if ($s -in $old.PSObject.Properties.Name) {
                $nval = ($New[$s] | ConvertTo-Json -Compress -Depth 5)
                $oval = ($old.$s | ConvertTo-Json -Compress -Depth 5)
                if ($nval -ne $oval) {$diffs += "$s : MODIFIED"}
            } else {$diffs += "$s : NEW"}
        }
        foreach ($s in $old.PSObject.Properties.Name) {
            if ($s -notin $New.Keys) {$diffs += "$s : REMOVED"}
        }
        if ($diffs.Count -gt 0) {$diffs} else {$null}
    } catch {$null}
}

function Out-HTML {
    param($D, $P)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $rows = ""
    foreach ($s in $D.Keys) {
        if ($s -eq 'ChangesDetected') {continue}
        $rows += "<h2>$s</h2>"
        if ($D[$s] -is [array]) {
            if ($D[$s].Count -eq 0) {$rows += "<p><i>No data</i></p>"; continue}
            $props = $D[$s][0].Keys
            $rows += "<table><tr>$(($props | % {"<th>$_</th>"}) -join '')</tr>"
            foreach ($item in $D[$s]) {
                $rows += "<tr>"
                foreach ($k in $props) {
                    $v = $item[$k]
                    $cls = if ($v -match '^(Healthy|OK|Connected)$') {' class="ok"'} elseif ($v -match '^(Error|Disconnected|Critical)$') {' class="bad"'} else {''}
                    $rows += "<td$cls>$v</td>"
                }
                $rows += "</tr>"
            }
            $rows += "</table>"
        } elseif ($D[$s] -is [System.Collections.Specialized.OrderedDictionary]) {
            $rows += "<table>"
            foreach ($k in $D[$s].Keys) {
                $v = $D[$s][$k]
                if ($v -isnot [System.Collections.Specialized.OrderedDictionary] -and $v -isnot [array]) {
                    $rows += "<tr><th>$k</th><td>$v</td></tr>"
                }
            }
            $rows += "</table>"
        }
    }
@"
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Hardware Report $ts</title>
<style>body{font:14px Segoe UI,sans-serif;margin:20px;background:#1a1a2e;color:#e0e0e0}
h1{color:#00d4ff;border-bottom:2px solid #00d4ff}h2{color:#7b2ff7;background:#16213e;padding:10px;border-radius:5px;margin-top:25px}
table{width:100%;border-collapse:collapse;margin:10px 0;background:#0f3460}
th{background:#533483;padding:8px;text-align:left}td{padding:6px 8px;border-bottom:1px solid #16213e}
tr:hover{background:#1a1a4e}.ok{color:#00ff88}.bad{color:#ff4757}
</style></head><body>
<h1>Ultimate Hardware Report</h1><p>Generated: $ts | Duration: $([math]::Round(((Get-Date)-$script:StartTime).TotalSeconds,1))s</p>
$rows
</body></html>
"@ | Out-File $P -Encoding UTF8
}

# Main
Clear-Host
Write-Host "`n$('='*70)`n  ULTIMATE HARDWARE SCANNER v3.0`n$('='*70)" -ForegroundColor Cyan
if ($ComputerName) {Write-Host "  Target: $ComputerName" -ForegroundColor Blue}
if ($ComputerList) {Write-Host "  Batch: $($ComputerList.Count) systems" -ForegroundColor Blue}

if ($ComputerName) {New-CimSessionSafe}
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'

if ($ComputerList) {
    $allResults = @{}
    foreach ($comp in $ComputerList) {
        Write-Host "`n--- $comp ---" -ForegroundColor Yellow
        $ComputerName = $comp
        $script:CimSession = $null
        New-CimSessionSafe
        $allResults[$comp] = Get-Hardware -Cat $Category -Perf:$IncludePerformance -Reg:$IncludeRegistry -AdvNet:$IncludeAdvancedNetwork
        if ($script:CimSession) {Remove-CimSession $script:CimSession}
    }
    if ($ExportJSON) {
        $jp = Join-Path $OutputPath "BatchHardware_$ts.json"
        $allResults | ConvertTo-Json -Depth 10 | Out-File $jp -Encoding UTF8
        Write-Host "`nBatch exported: $jp" -ForegroundColor Green
    }
} else {
    try {
        $data = Get-Hardware -Cat $Category -Perf:$IncludePerformance -Reg:$IncludeRegistry -AdvNet:$IncludeAdvancedNetwork
        
        if ($CompareWith) {
            $diffs = Compare-Data $data $CompareWith
            if ($diffs) {
                Write-Host "`n=== CHANGES ===" -ForegroundColor Yellow
                $diffs | % {Write-Host $_ -ForegroundColor Magenta}
                $data.ChangesDetected = $diffs
            } else {Write-Host "`nNo changes detected" -ForegroundColor Green}
        }
        
        if ($ExportJSON) {
            $jp = Join-Path $OutputPath "Hardware_$ts.json"
            $data | ConvertTo-Json -Depth 20 | Out-File $jp -Encoding UTF8
            Write-Host "JSON: $jp ($([math]::Round((Get-Item $jp).Length/1KB,1))KB)" -ForegroundColor Green
        }
        if ($ExportCSV) {
            $cp = Join-Path $OutputPath "HardwareCSV_$ts"
            New-Item -ItemType Directory $cp -Force | Out-Null
            foreach ($s in $data.Keys) {
                if ($data[$s] -is [array] -and $data[$s].Count -gt 0) {
                    $data[$s] | % {
                        $o = [PSCustomObject]@{}
                        foreach ($k in $_.Keys) {
                            $v = $_[$k]
                            if ($v -is [System.Collections.Specialized.OrderedDictionary]) {$v = $v | ConvertTo-Json -Compress}
                            $o | Add-Member -NotePropertyName $k -NotePropertyValue $v
                        }
                        $o
                    } | Export-Csv (Join-Path $cp "$s.csv") -NoTypeInformation
                }
            }
            Write-Host "CSV: $cp" -ForegroundColor Green
        }
        if ($ExportHTML) {
            $hp = Join-Path $OutputPath "HardwareReport_$ts.html"
            Out-HTML $data $hp
            Write-Host "HTML: $hp ($([math]::Round((Get-Item $hp).Length/1KB,1))KB)" -ForegroundColor Green
        }
        
        if (-not ($ExportJSON -or $ExportCSV -or $ExportHTML)) {
            Write-Host "`n=== SUMMARY ===`n" -ForegroundColor Cyan
            foreach ($s in $data.Keys) {
                if ($s -eq 'ChangesDetected') {continue}
                Write-Host "[$s]" -ForegroundColor Yellow
                if ($data[$s] -is [array]) {
                    Write-Host "  Items: $($data[$s].Count)" -ForegroundColor Gray
                } elseif ($data[$s] -is [System.Collections.Specialized.OrderedDictionary]) {
                    foreach ($k in $data[$s].Keys) {
                        $v = $data[$s][$k]
                        if ($v -isnot [System.Collections.Specialized.OrderedDictionary] -and $v -isnot [array]) {
                            Write-Host "  $k : $v" -ForegroundColor White
                        }
                    }
                }
            }
        }
        Write-Host "`n$('='*70)`n  COMPLETE ($([math]::Round(((Get-Date)-$script:StartTime).TotalSeconds,1))s)`n$('='*70)" -ForegroundColor Green
    } catch {
        Write-Host "`nFATAL: $($_.Exception.Message)" -ForegroundColor Red
        if ($script:CimSession) {Remove-CimSession $script:CimSession}
        exit 1
    }
}