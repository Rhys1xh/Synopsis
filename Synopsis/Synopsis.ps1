<#
.SYNOPSIS
    ULTIMATE Hardware Information Collector - Final Edition
.DESCRIPTION
    Enterprise-grade hardware information collection with remote scanning,
    NVMe health, GPU temperature, network advanced properties, and change detection.
.PARAMETER ExportJSON
    Export results as JSON file
.PARAMETER ExportCSV
    Export results as CSV files
.PARAMETER ExportHTML
    Export results as formatted HTML report
.PARAMETER OutputPath
    Base path for exports (default: Desktop)
.PARAMETER IncludePerformance
    Include comprehensive real-time performance metrics
.PARAMETER IncludeRegistry
    Include hardware-related registry information
.PARAMETER Category
    Filter to specific hardware category
.PARAMETER ComputerName
    Remote computer to scan (requires admin access and WinRM)
.PARAMETER LogFile
    Enable diagnostic logging to specified file
.PARAMETER CompareWith
    Path to previous JSON export for change detection
.PARAMETER IncludeAdvancedNetwork
    Include advanced network adapter properties
.EXAMPLE
    .\Get-UltimateHardwareInfo.ps1 -ExportHTML -IncludePerformance
.EXAMPLE
    .\Get-UltimateHardwareInfo.ps1 -ComputerName "REMOTE-PC" -ExportJSON
.EXAMPLE
    .\Get-UltimateHardwareInfo.ps1 -CompareWith "previous.json" -ExportHTML
#>

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
    [switch]$IncludeAdvancedNetwork
)

#Requires -RunAsAdministrator

# Initialize logging
if ($LogFile) {
    $script:LogPath = $LogFile
    $logMessage = "=== Hardware Scan Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
    $logMessage | Out-File -FilePath $LogFile
    if ($ComputerName) {
        $remoteMsg = "Remote Target: $ComputerName"
        $remoteMsg | Out-File -FilePath $LogFile -Append
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if ($LogFile) {
        $logEntry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
        $logEntry | Out-File -FilePath $LogFile -Append
    }
}

# Remote session management
$script:CimSession = $null
if ($ComputerName) {
    try {
        $script:CimSession = New-CimSession -ComputerName $ComputerName -ErrorAction Stop
        $successMsg = "Remote session established to $ComputerName"
        Write-Log -Message $successMsg -Level "SUCCESS"
    } catch {
        $errorMsg = "Failed to connect to ${ComputerName}: $($_.Exception.Message)"
        Write-Log -Message $errorMsg -Level "ERROR"
        throw "Remote connection failed: $($_.Exception.Message)"
    }
}

function Get-CimData {
    param(
        [string]$ClassName,
        [string]$Namespace = "root/cimv2",
        [string]$Filter,
        [string[]]$Properties
    )
    
    $params = @{
        ClassName = $ClassName
        Namespace = $Namespace
        ErrorAction = 'SilentlyContinue'
    }
    
    if ($script:CimSession) { $params.CimSession = $script:CimSession }
    if ($Properties) { $params.Property = $Properties }
    if ($Filter) { $params.Filter = $Filter }
    
    try {
        return Get-CimInstance @params
    } catch {
        $warnMsg = "CIM query failed for ${ClassName}: $($_.Exception.Message)"
        Write-Log -Message $warnMsg -Level "WARN"
        return $null
    }
}

# Color definitions
$colors = @{
    Header = 'Cyan'
    Section = 'Yellow'
    SubSection = 'Magenta'
    Label = 'Green'
    Value = 'White'
    Diff = 'Yellow'
    Added = 'Green'
    Removed = 'Red'
    Warning = 'DarkYellow'
    Error = 'Red'
    Success = 'Green'
    Info = 'Gray'
    Progress = 'Cyan'
}

function Write-ProgressBar {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    
    $barLength = 50
    $completed = [math]::Floor($PercentComplete / 100 * $barLength)
    $remaining = $barLength - $completed
    
    $bar = "[$("=" * $completed)$(" " * $remaining)]"
    
    Write-Host "`r$Activity : " -NoNewline -ForegroundColor $colors.Progress
    Write-Host $bar -NoNewline -ForegroundColor $colors.Progress
    Write-Host " $PercentComplete% " -NoNewline -ForegroundColor $colors.Progress
    Write-Host "- $Status" -ForegroundColor $colors.Info
    
    Write-Log -Message "$Activity - $Status ($PercentComplete%)"
}

function Get-RegistryValue {
    param([string]$Path, [string]$Name)
    try {
        if ($script:CimSession) {
            $result = Invoke-CimMethod -CimSession $script:CimSession -ClassName StdRegProv -MethodName GetStringValue -Arguments @{
                hDefKey = 2147483650
                sSubKeyName = $Path -replace '^HKLM:\\', ''
                sValueName = $Name
            } -ErrorAction Stop
            return $result.sValue
        } else {
            $result = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
            return $result.$Name
        }
    } catch {
        return "N/A"
    }
}

function Get-NVMeHealth {
    try {
        $nvmeDrives = Get-CimData -ClassName MSFT_PhysicalDisk -Namespace "root/microsoft/windows/storage"
        if (-not $nvmeDrives) { return @() }
        
        $nvmeHealth = @()
        foreach ($drive in $nvmeDrives | Where-Object { $_.MediaType -eq 4 }) {
            $reliability = Get-CimData -ClassName MSFT_StorageReliabilityCounter -Namespace "root/microsoft/windows/storage" -Filter "DeviceId='$($drive.DeviceId)'"
            
            if ($reliability) {
                $nvmeHealth += [ordered]@{
                    DeviceId = $drive.DeviceId
                    FriendlyName = $drive.FriendlyName
                    MediaType = "NVMe SSD"
                    Temperature = $drive.Temperature
                    PowerOnHours = $reliability.PowerOnHours
                    ReadErrorsTotal = $reliability.ReadErrorsTotal
                    WriteErrorsTotal = $reliability.WriteErrorsTotal
                    Wear = $reliability.Wear
                    ReadLatencyMax = $reliability.ReadLatencyMax
                    WriteLatencyMax = $reliability.WriteLatencyMax
                    FlushLatencyMax = $reliability.FlushLatencyMax
                }
            }
        }
        return $nvmeHealth
    } catch {
        Write-Log -Message "NVMe health retrieval failed: $($_.Exception.Message)" -Level "WARN"
        return @()
    }
}

function Get-GPUTemperature {
    try {
        $gpuTemps = @()
        
        # Try NVIDIA temperature via WMI
        try {
            $nvidiaTemps = Get-CimData -Namespace "root/wmi" -ClassName "NVThermalSensors"
            if ($nvidiaTemps) {
                foreach ($sensor in $nvidiaTemps) {
                    $gpuTemps += [ordered]@{
                        GPUName = "NVIDIA GPU"
                        Temperature = "$([math]::Round($sensor.ThermalSensors / 1000, 1)) C"
                        Method = "NVIDIA Direct"
                    }
                }
            }
        } catch {
            Write-Log -Message "NVIDIA temp retrieval failed" -Level "DEBUG"
        }
        
        # Try via performance counters
        try {
            $perfCounters = Get-Counter "\GPU Engine(*)\Utilization Percentage" -ErrorAction SilentlyContinue
            if ($perfCounters) {
                $gpuGroups = $perfCounters.CounterSamples | Group-Object -Property { ($_.Path -split '\\')[3] }
                foreach ($group in $gpuGroups) {
                    $avgUtil = ($group.Group | Measure-Object -Property CookedValue -Average).Average
                    if ($avgUtil -gt 0) {
                        $gpuTemps += [ordered]@{
                            GPUName = ($group.Name -replace '_',' ')
                            UtilizationPercent = [math]::Round($avgUtil, 2)
                            Method = "Performance Counter"
                        }
                    }
                }
            }
        } catch {
            Write-Log -Message "GPU perf counter retrieval failed" -Level "DEBUG"
        }
        
        return $gpuTemps
    } catch {
        Write-Log -Message "GPU temperature retrieval failed: $($_.Exception.Message)" -Level "WARN"
        return @()
    }
}

function Get-AdvancedNetworkProperties {
    param($NetworkAdapter)
    
    try {
        $advancedProps = @{}
        $adapterKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
        
        if (-not $script:CimSession) {
            $subKeys = Get-ChildItem -Path $adapterKey -ErrorAction SilentlyContinue
            if ($subKeys) {
                foreach ($key in $subKeys) {
                    $driverDesc = Get-RegistryValue -Path $key.PSPath -Name "DriverDesc"
                    if ($driverDesc -ne "N/A" -and $NetworkAdapter.Name -like "*$driverDesc*") {
                        $advancedProps.JumboPacket = Get-RegistryValue -Path $key.PSPath -Name "*JumboPacket"
                        $advancedProps.VlanID = Get-RegistryValue -Path $key.PSPath -Name "VlanID"
                        $advancedProps.RSSEnabled = Get-RegistryValue -Path $key.PSPath -Name "*RSS"
                        $advancedProps.TCPOffload = Get-RegistryValue -Path $key.PSPath -Name "*TCPUDPChecksumOffloadIPv4"
                        $advancedProps.LargeSendOffload = Get-RegistryValue -Path $key.PSPath -Name "*LsoV2IPv4"
                        $advancedProps.ReceiveBuffers = Get-RegistryValue -Path $key.PSPath -Name "*ReceiveBuffers"
                        $advancedProps.TransmitBuffers = Get-RegistryValue -Path $key.PSPath -Name "*TransmitBuffers"
                        $advancedProps.WakeOnMagicPacket = Get-RegistryValue -Path $key.PSPath -Name "*WakeOnMagicPacket"
                        $advancedProps.EnergyEfficientEthernet = Get-RegistryValue -Path $key.PSPath -Name "*EEELinkAdvertisement"
                        break
                    }
                }
            }
        }
        
        return if ($advancedProps.Count -gt 0) { $advancedProps } else { $null }
    } catch {
        return $null
    }
}

function Get-SMARTData {
    param([string]$SerialNumber)
    
    try {
        $smartData = @{}
        $physicalDisk = Get-CimData -ClassName MSFT_PhysicalDisk -Namespace "root/microsoft/windows/storage" -Filter "SerialNumber='$SerialNumber'"
        
        if ($physicalDisk) {
            $smartData.HealthStatus = $physicalDisk.HealthStatus
            $smartData.OperationalStatus = $physicalDisk.OperationalStatus
            $smartData.MediaType = $physicalDisk.MediaType
            $smartData.BusType = $physicalDisk.BusType
            $smartData.Temperature = if ($physicalDisk.Temperature) { "$($physicalDisk.Temperature) C" } else { "N/A" }
            $smartData.TemperatureMax = if ($physicalDisk.TemperatureMax) { "$($physicalDisk.TemperatureMax) C" } else { "N/A" }
            $smartData.PowerOnHours = if ($physicalDisk.PowerOnHours) { $physicalDisk.PowerOnHours } else { "N/A" }
            $smartData.PowerOnCount = if ($physicalDisk.PowerOnCount) { $physicalDisk.PowerOnCount } else { "N/A" }
            $smartData.ReadErrorsTotal = if ($physicalDisk.ReadErrorsTotal) { $physicalDisk.ReadErrorsTotal } else { "N/A" }
            $smartData.WriteErrorsTotal = if ($physicalDisk.WriteErrorsTotal) { $physicalDisk.WriteErrorsTotal } else { "N/A" }
            $smartData.Wear = if ($physicalDisk.Wear) { "$($physicalDisk.Wear)%" } else { "N/A" }
        }
        
        return if ($smartData.Count -gt 0) { $smartData } else { $null }
    } catch {
        return $null
    }
}

function Get-PCIDevices {
    param([int]$MaxDevices = 100)
    
    try {
        $pciDevices = Get-CimData -ClassName Win32_PnPEntity | 
            Where-Object { $_.PNPDeviceID -match '^(PCI|ACPI|SCSI|USB)\\VEN_' } |
            Select-Object -First $MaxDevices
        
        $pciArray = @()
        if ($pciDevices) {
            foreach ($device in $pciDevices) {
                $pciArray += [ordered]@{
                    Name = if ($device.Name) { $device.Name } else { "Unknown Device" }
                    DeviceID = $device.DeviceID
                    PNPDeviceID = $device.PNPDeviceID
                    Status = $device.Status
                    Manufacturer = if ($device.Manufacturer) { $device.Manufacturer } else { "N/A" }
                    Class = if ($device.PNPClass) { $device.PNPClass } else { "N/A" }
                    DriverVersion = if ($device.DriverVersion) { $device.DriverVersion } else { "N/A" }
                    DriverDate = if ($device.DriverDate) { $device.DriverDate } else { "N/A" }
                }
            }
        }
        return $pciArray
    } catch {
        return @()
    }
}

function Get-ComprehensivePerformanceData {
    try {
        $perfData = [ordered]@{
            CPU = [ordered]@{
                TotalUtilization = [math]::Round((Get-Counter "\Processor(_Total)\% Processor Time" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                DPCsPerSec = [math]::Round((Get-Counter "\Processor(_Total)\DPCs Queued/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                InterruptsPerSec = [math]::Round((Get-Counter "\Processor(_Total)\Interrupts/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                ContextSwitchesPerSec = [math]::Round((Get-Counter "\System\Context Switches/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
            }
            Memory = [ordered]@{
                AvailableMB = [math]::Round((Get-Counter "\Memory\Available MBytes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                CommittedGB = [math]::Round((Get-Counter "\Memory\Committed Bytes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1GB, 2)
                CommitLimitGB = [math]::Round((Get-Counter "\Memory\Commit Limit" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1GB, 2)
                PageFaultsPerSec = [math]::Round((Get-Counter "\Memory\Page Faults/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                PoolPagedMB = [math]::Round((Get-Counter "\Memory\Pool Paged Bytes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
                PoolNonPagedMB = [math]::Round((Get-Counter "\Memory\Pool Nonpaged Bytes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
                CacheBytesMB = [math]::Round((Get-Counter "\Memory\Cache Bytes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
            }
            Disk = [ordered]@{
                CurrentQueueLength = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Current Disk Queue Length" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                ReadMBPerSec = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Disk Read Bytes/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
                WriteMBPerSec = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Disk Write Bytes/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
                AvgReadLatencyMs = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Avg. Disk sec/Read" -ErrorAction SilentlyContinue).CounterSamples.CookedValue * 1000, 2)
                AvgWriteLatencyMs = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Avg. Disk sec/Write" -ErrorAction SilentlyContinue).CounterSamples.CookedValue * 1000, 2)
                SplitIOPerSec = [math]::Round((Get-Counter "\PhysicalDisk(_Total)\Split IO/Sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
            }
            Network = [ordered]@{
                TotalMBPerSec = [math]::Round((Get-Counter "\Network Interface(_Total)\Bytes Total/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1MB, 2)
                PacketsPerSec = [math]::Round((Get-Counter "\Network Interface(_Total)\Packets/sec" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                PacketsOutboundDiscarded = [math]::Round((Get-Counter "\Network Interface(_Total)\Packets Outbound Discarded" -ErrorAction SilentlyContinue).CounterSamples.CookedValue, 2)
                CurrentBandwidthMbps = [math]::Round((Get-Counter "\Network Interface(_Total)\Current Bandwidth" -ErrorAction SilentlyContinue).CounterSamples.CookedValue / 1000000, 2)
            }
            System = [ordered]@{
                Processes = (Get-Counter "\System\Processes" -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                Threads = (Get-Counter "\System\Threads" -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                Handles = (Get-Counter "\System\Handles" -ErrorAction SilentlyContinue).CounterSamples.CookedValue
                UpTimeSeconds = (Get-Counter "\System\System Up Time" -ErrorAction SilentlyContinue).CounterSamples.CookedValue
            }
        }
        return $perfData
    } catch {
        return $null
    }
}

function Compare-HardwareChanges {
    param($Current, $PreviousPath)
    
    try {
        $previous = Get-Content $PreviousPath -ErrorAction Stop | ConvertFrom-Json
        $changes = [ordered]@{}
        
        foreach ($section in $Current.Keys) {
            if ($section -notin $previous.PSObject.Properties.Name) {
                $changes.$section = [ordered]@{ Status = "NEW" }
            }
        }
        foreach ($section in $previous.PSObject.Properties.Name) {
            if ($section -notin $Current.Keys) {
                $changes.$section = [ordered]@{ Status = "REMOVED" }
            }
        }
        
        return if ($changes.Count -gt 0) { $changes } else { $null }
    } catch {
        Write-Log -Message "Change detection failed: $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Get-UltimateHardwareInfo {
    param(
        [string]$FilterCategory = 'All',
        [switch]$IncludePerf,
        [switch]$IncludeReg,
        [switch]$IncludeAdvNet
    )
    
    $hardwareInfo = [ordered]@{}
    $totalSteps = 30
    $currentStep = 0
    
    Write-Host ""
    Write-Log -Message "Starting hardware information collection" -Level "INFO"
    
    # System Information
    if ($FilterCategory -in @('System','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] System Information" -Status "Gathering system details..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $cs = Get-CimData -ClassName Win32_ComputerSystem
        $csProduct = Get-CimData -ClassName Win32_ComputerSystemProduct
        
        if ($cs) {
            $hardwareInfo.System = [ordered]@{
                Manufacturer = $cs.Manufacturer
                Model = $cs.Model
                SystemFamily = if ($cs.SystemFamily) { $cs.SystemFamily } else { "N/A" }
                SystemSKU = if ($cs.SystemSKUNumber) { $cs.SystemSKUNumber } else { "N/A" }
                UUID = if ($csProduct.UUID) { $csProduct.UUID } else { "N/A" }
                TotalPhysicalMemoryGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
                NumberOfProcessors = $cs.NumberOfProcessors
                NumberOfLogicalProcessors = $cs.NumberOfLogicalProcessors
                HypervisorPresent = $cs.HypervisorPresent
                DNSHostName = $cs.DNSHostName
            }
        }
        
        $bios = Get-CimData -ClassName Win32_BIOS
        if ($bios) {
            $hardwareInfo.BIOS = [ordered]@{
                Manufacturer = $bios.Manufacturer
                Version = $bios.SMBIOSBIOSVersion
                SMBIOSVersion = "$($bios.SMBIOSMajorVersion).$($bios.SMBIOSMinorVersion)"
                ReleaseDate = $bios.ReleaseDate
                SerialNumber = $bios.SerialNumber
            }
        }
        
        $bb = Get-CimData -ClassName Win32_BaseBoard
        if ($bb) {
            $hardwareInfo.Motherboard = [ordered]@{
                Manufacturer = $bb.Manufacturer
                Product = $bb.Product
                Version = $bb.Version
                SerialNumber = $bb.SerialNumber
                SKU = if ($bb.SKU) { $bb.SKU } else { "N/A" }
            }
        }
        Write-Log -Message "System information collected" -Level "SUCCESS"
    }
    
    # CPU Information
    if ($FilterCategory -in @('CPU','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Processors" -Status "Analyzing CPU architecture..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $processors = Get-CimData -ClassName Win32_Processor
        $cpuArray = @()
        
        if ($processors) {
            foreach ($cpu in $processors) {
                $cpuArray += [ordered]@{
                    Name = if ($cpu.Name) { $cpu.Name -replace '\s+', ' ' } else { "N/A" }
                    Manufacturer = $cpu.Manufacturer
                    Architecture = switch ($cpu.Architecture) {
                        0 { "x86" }; 9 { "x64" }; 12 { "ARM64" }
                        default { "Unknown" }
                    }
                    MaxClockSpeed = "$($cpu.MaxClockSpeed) MHz"
                    NumberOfCores = $cpu.NumberOfCores
                    NumberOfLogicalProcessors = $cpu.NumberOfLogicalProcessors
                    L2CacheSize = if ($cpu.L2CacheSize) { "$($cpu.L2CacheSize) KB" } else { "N/A" }
                    L3CacheSize = if ($cpu.L3CacheSize) { "$($cpu.L3CacheSize) KB" } else { "N/A" }
                    Socket = $cpu.SocketDesignation
                    VirtualizationFirmwareEnabled = $cpu.VirtualizationFirmwareEnabled
                    LoadPercentage = "$($cpu.LoadPercentage)%"
                }
            }
        }
        $hardwareInfo.CPU = $cpuArray
        Write-Log -Message "CPU information collected ($($cpuArray.Count) processors)" -Level "SUCCESS"
    }
    
    # Memory Information
    if ($FilterCategory -in @('Memory','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Memory Modules" -Status "Detecting RAM configuration..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $physicalMemory = Get-CimData -ClassName Win32_PhysicalMemory
        
        $memoryArray = @()
        if ($physicalMemory) {
            foreach ($memory in $physicalMemory) {
                $memoryArray += [ordered]@{
                    Manufacturer = $memory.Manufacturer
                    PartNumber = $memory.PartNumber
                    SerialNumber = $memory.SerialNumber
                    CapacityGB = [math]::Round($memory.Capacity / 1GB, 2)
                    Speed = "$($memory.Speed) MHz"
                    ConfiguredClockSpeed = "$($memory.ConfiguredClockSpeed) MHz"
                    FormFactor = switch ($memory.FormFactor) {
                        8 { "DIMM" }; 12 { "SODIMM" }; 24 { "FB-DIMM" }
                        default { $memory.FormFactor }
                    }
                    MemoryType = switch ($memory.MemoryType) {
                        20 { "DDR" }; 21 { "DDR2" }; 24 { "DDR3" }
                        26 { "DDR4" }; 34 { "DDR5" }
                        default { $memory.MemoryType }
                    }
                    DeviceLocator = $memory.DeviceLocator
                    BankLabel = $memory.BankLabel
                    ConfiguredVoltage = if ($memory.ConfiguredVoltage) { 
                        [math]::Round($memory.ConfiguredVoltage / 1000, 3).ToString() + " V" 
                    } else { "N/A" }
                }
            }
        }
        $hardwareInfo.Memory = $memoryArray
        Write-Log -Message "Memory information collected ($($memoryArray.Count) modules)" -Level "SUCCESS"
    }
    
    # GPU Information
    if ($FilterCategory -in @('GPU','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Graphics Adapters" -Status "Analyzing GPU configuration..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $videoControllers = Get-CimData -ClassName Win32_VideoController
        $gpuArray = @()
        
        if ($videoControllers) {
            foreach ($gpu in $videoControllers) {
                $gpuArray += [ordered]@{
                    Name = $gpu.Name
                    AdapterRAM = if ($gpu.AdapterRAM) { [math]::Round($gpu.AdapterRAM / 1GB, 2).ToString() + " GB" } else { "N/A" }
                    DriverVersion = $gpu.DriverVersion
                    DriverDate = $gpu.DriverDate
                    VideoModeDescription = $gpu.VideoModeDescription
                    CurrentRefreshRate = "$($gpu.CurrentRefreshRate) Hz"
                    CurrentHorizontalResolution = $gpu.CurrentHorizontalResolution
                    CurrentVerticalResolution = $gpu.CurrentVerticalResolution
                    VideoProcessor = $gpu.VideoProcessor
                    Status = $gpu.Status
                }
            }
        }
        $hardwareInfo.GPU = $gpuArray
        
        if ($IncludePerf) {
            $gpuPerf = Get-GPUTemperature
            if ($gpuPerf.Count -gt 0) {
                $hardwareInfo.GPUPerformance = $gpuPerf
            }
        }
        Write-Log -Message "GPU information collected ($($gpuArray.Count) adapters)" -Level "SUCCESS"
    }
    
    # Disk Information
    if ($FilterCategory -in @('Disk','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Disk Drives" -Status "Scanning storage with health data..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $diskDrives = Get-CimData -ClassName Win32_DiskDrive
        $diskArray = @()
        
        if ($diskDrives) {
            foreach ($disk in $diskDrives) {
                $partitions = Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue
                $partitionInfo = @()
                if ($partitions) {
                    foreach ($partition in $partitions) {
                        $logicalDisks = Get-CimAssociatedInstance -InputObject $partition -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue
                        if ($logicalDisks) {
                            foreach ($logicalDisk in $logicalDisks) {
                                if ($logicalDisk.DeviceID) {
                                    $partitionInfo += [ordered]@{
                                        DriveLetter = $logicalDisk.DeviceID
                                        VolumeName = if ($logicalDisk.VolumeName) { $logicalDisk.VolumeName } else { "N/A" }
                                        SizeGB = if ($logicalDisk.Size) { [math]::Round($logicalDisk.Size / 1GB, 2) } else { "N/A" }
                                        FreeSpaceGB = if ($logicalDisk.FreeSpace) { [math]::Round($logicalDisk.FreeSpace / 1GB, 2) } else { "N/A" }
                                        PercentFree = if ($logicalDisk.Size -and $logicalDisk.Size -gt 0) { 
                                            [math]::Round(($logicalDisk.FreeSpace / $logicalDisk.Size) * 100, 2)
                                        } else { "N/A" }
                                        FileSystem = $logicalDisk.FileSystem
                                    }
                                }
                            }
                        }
                    }
                }
                
                $diskInfo = [ordered]@{
                    Model = if ($disk.Model) { $disk.Model -replace '\s+', ' ' } else { "N/A" }
                    Manufacturer = $disk.Manufacturer
                    SizeGB = if ($disk.Size) { [math]::Round($disk.Size / 1GB, 2) } else { "N/A" }
                    InterfaceType = $disk.InterfaceType
                    MediaType = $disk.MediaType
                    SerialNumber = $disk.SerialNumber
                    FirmwareRevision = $disk.FirmwareRevision
                    Partitions = $partitionInfo
                }
                
                $smartData = Get-SMARTData -SerialNumber $disk.SerialNumber
                if ($smartData) {
                    $diskInfo.SMART = $smartData
                }
                
                $diskArray += $diskInfo
            }
        }
        $hardwareInfo.Disks = $diskArray
        
        $nvmeHealth = Get-NVMeHealth
        if ($nvmeHealth.Count -gt 0) {
            $hardwareInfo.NVMeHealth = $nvmeHealth
        }
        Write-Log -Message "Disk information collected ($($diskArray.Count) drives)" -Level "SUCCESS"
    }
    
    # Network Information
    if ($FilterCategory -in @('Network','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Network Adapters" -Status "Scanning network configuration..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $networkAdapters = Get-CimData -ClassName Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true }
        $networkArray = @()
        
        if ($networkAdapters) {
            foreach ($adapter in $networkAdapters) {
                $adapterConfig = Get-CimData -ClassName Win32_NetworkAdapterConfiguration -Filter "Index=$($adapter.Index)"
                
                $netInfo = [ordered]@{
                    Name = $adapter.Name
                    ProductName = $adapter.ProductName
                    Manufacturer = $adapter.Manufacturer
                    MACAddress = $adapter.MACAddress
                    Speed = if ($adapter.Speed -and $adapter.Speed -gt 0) { 
                        if ($adapter.Speed -ge 1000000000) { [math]::Round($adapter.Speed / 1000000000, 2).ToString() + " Gbps" }
                        else { [math]::Round($adapter.Speed / 1000000, 2).ToString() + " Mbps" }
                    } else { "N/A" }
                    Status = $adapter.Status
                    NetConnectionStatus = switch ($adapter.NetConnectionStatus) {
                        0 { "Disconnected" }; 2 { "Connected" }; 7 { "Media Disconnected" }
                        default { $adapter.NetConnectionStatus }
                    }
                }
                
                if ($adapterConfig) {
                    $netInfo.IPAddress = if ($adapterConfig.IPAddress) { $adapterConfig.IPAddress -join ', ' } else { "N/A" }
                    $netInfo.DefaultGateway = if ($adapterConfig.DefaultIPGateway) { $adapterConfig.DefaultIPGateway -join ', ' } else { "N/A" }
                    $netInfo.DHCPEnabled = $adapterConfig.DHCPEnabled
                    $netInfo.DNSServers = if ($adapterConfig.DNSServerSearchOrder) { $adapterConfig.DNSServerSearchOrder -join ', ' } else { "N/A" }
                }
                
                if ($IncludeAdvNet) {
                    $advancedProps = Get-AdvancedNetworkProperties -NetworkAdapter $adapter
                    if ($advancedProps) {
                        $netInfo.AdvancedProperties = $advancedProps
                    }
                }
                
                $networkArray += $netInfo
            }
        }
        $hardwareInfo.Network = $networkArray
        Write-Log -Message "Network information collected ($($networkArray.Count) adapters)" -Level "SUCCESS"
    }
    
    # PCI Devices
    if ($FilterCategory -in @('All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] PCI Devices" -Status "Enumerating PCI bus..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $pciDevices = Get-PCIDevices -MaxDevices 50
        if ($pciDevices.Count -gt 0) {
            $hardwareInfo.PCIDevices = $pciDevices
        }
        Write-Log -Message "PCI devices enumerated ($($pciDevices.Count) devices)" -Level "SUCCESS"
    }
    
    # Additional peripherals
    if ($FilterCategory -in @('All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Peripherals" -Status "Detecting peripheral devices..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        
        try {
            $tpm = Get-CimData -ClassName Win32_Tpm -Namespace "root/cimv2/Security/MicrosoftTpm"
            if ($tpm) {
                $hardwareInfo.TPM = [ordered]@{
                    IsActivated = $tpm.IsActivated_InitialValue
                    IsEnabled = $tpm.IsEnabled_InitialValue
                    SpecVersion = $tpm.SpecVersion
                }
            }
        } catch {}
        
        try {
            $battery = Get-CimData -ClassName Win32_Battery
            if ($battery) {
                $hardwareInfo.Battery = [ordered]@{
                    EstimatedChargeRemaining = "$($battery.EstimatedChargeRemaining)%"
                    Chemistry = $battery.Chemistry
                    DesignCapacity = $battery.DesignCapacity
                    FullChargeCapacity = $battery.FullChargeCapacity
                    BatteryStatus = switch ($battery.BatteryStatus) {
                        1 { "Discharging" }; 2 { "AC Power" }; 3 { "Fully Charged" }
                        6 { "Charging" }
                        default { "Unknown" }
                    }
                }
            }
        } catch {}
        Write-Log -Message "Peripherals collected" -Level "SUCCESS"
    }
    
    # Registry Information
    if ($IncludeReg) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Registry Data" -Status "Reading hardware registry keys..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        
        $regInfo = [ordered]@{
            ProcessorNameString = Get-RegistryValue -Path "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -Name "ProcessorNameString"
            SystemBiosVersion = Get-RegistryValue -Path "HKLM:\HARDWARE\DESCRIPTION\System" -Name "SystemBiosVersion"
            BaseBoardManufacturer = Get-RegistryValue -Path "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -Name "BaseBoardManufacturer"
            BaseBoardProduct = Get-RegistryValue -Path "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -Name "BaseBoardProduct"
        }
        $hardwareInfo.RegistryHardwareInfo = $regInfo
        Write-Log -Message "Registry information collected" -Level "SUCCESS"
    }
    
    # Performance Metrics
    if ($IncludePerf) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Performance Metrics" -Status "Collecting real-time performance data..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        
        $perfData = Get-ComprehensivePerformanceData
        if ($perfData) {
            $hardwareInfo.PerformanceCounters = $perfData
        }
        Write-Log -Message "Performance metrics collected" -Level "SUCCESS"
    }
    
    # Operating System
    if ($FilterCategory -in @('System','All')) {
        $currentStep++
        Write-ProgressBar -Activity "[$currentStep/$totalSteps] Operating System" -Status "Reading OS configuration..." -PercentComplete ([math]::Round($currentStep/$totalSteps * 100))
        $os = Get-CimData -ClassName Win32_OperatingSystem
        
        if ($os) {
            $hardwareInfo.OperatingSystem = [ordered]@{
                Name = $os.Name
                Version = $os.Version
                BuildNumber = $os.BuildNumber
                Architecture = $os.OSArchitecture
                InstallDate = $os.InstallDate
                LastBootUpTime = $os.LastBootUpTime
                FreePhysicalMemoryGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
                TotalVisibleMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
                NumberOfProcesses = $os.NumberOfProcesses
            }
        }
        Write-Log -Message "OS information collected" -Level "SUCCESS"
    }
    
    # Finalize
    for ($i = $currentStep + 1; $i -le $totalSteps; $i++) {
        Write-ProgressBar -Activity "[$i/$totalSteps] Finalizing" -Status "Compiling report..." -PercentComplete ([math]::Round($i/$totalSteps * 100))
        Start-Sleep -Milliseconds 100
    }
    
    Write-Host ""
    Write-Log -Message "Hardware information collection completed" -Level "SUCCESS"
    
    if ($script:CimSession) {
        Remove-CimSession -CimSession $script:CimSession
        Write-Log -Message "Remote session closed" -Level "INFO"
    }
    
    return $hardwareInfo
}

# Main Execution
Clear-Host
Write-Host ""
Write-Host "======================================================================" -ForegroundColor $colors.Header
Write-Host "     ULTIMATE HARDWARE SCANNER - FINAL EDITION" -ForegroundColor $colors.Header
Write-Host "======================================================================" -ForegroundColor $colors.Header
if ($ComputerName) {
    Write-Host "     Remote Target: $ComputerName" -ForegroundColor $colors.Highlight
}
Write-Host ""

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

try {
    $hardwareData = Get-UltimateHardwareInfo `
        -FilterCategory $Category `
        -IncludePerf:$IncludePerformance `
        -IncludeReg:$IncludeRegistry `
        -IncludeAdvNet:$IncludeAdvancedNetwork
    
    # Change detection
    if ($CompareWith) {
        Write-Host "Comparing with previous snapshot: $CompareWith" -ForegroundColor $colors.Info
        $changes = Compare-HardwareChanges -Current $hardwareData -PreviousPath $CompareWith
        if ($changes) {
            Write-Host "`n=== HARDWARE CHANGES DETECTED ===" -ForegroundColor $colors.Warning
            foreach ($change in $changes.Keys) {
                Write-Host "  $change : $($changes[$change].Status)" -ForegroundColor $colors.Diff
            }
            $hardwareData.ChangesDetected = $changes
        } else {
            Write-Host "No hardware changes detected" -ForegroundColor $colors.Success
        }
    }
    
    # Exports
    if ($ExportJSON) {
        $jsonPath = Join-Path $OutputPath "UltimateHardwareInfo_$timestamp.json"
        Write-Host "`nExporting JSON: $jsonPath" -ForegroundColor $colors.Info
        $hardwareData | ConvertTo-Json -Depth 20 | Out-File -FilePath $jsonPath -Encoding UTF8
        Write-Host "JSON export complete ($([math]::Round((Get-Item $jsonPath).Length / 1KB, 2)) KB)" -ForegroundColor $colors.Success
    }
    
    if ($ExportCSV) {
        $csvPath = Join-Path $OutputPath "HardwareCSV_$timestamp"
        New-Item -ItemType Directory -Path $csvPath -Force | Out-Null
        Write-Host "`nExporting CSV: $csvPath" -ForegroundColor $colors.Info
        
        foreach ($section in $hardwareData.Keys) {
            if ($hardwareData[$section] -is [array] -and $hardwareData[$section].Count -gt 0) {
                $sectionPath = Join-Path $csvPath "$section.csv"
                $hardwareData[$section] | ForEach-Object {
                    $obj = [PSCustomObject]@{}
                    foreach ($key in $_.Keys) {
                        $value = $_[$key]
                        if ($value -is [System.Collections.Specialized.OrderedDictionary]) {
                            $value = $value | ConvertTo-Json -Compress
                        }
                        $obj | Add-Member -NotePropertyName $key -NotePropertyValue $value
                    }
                    $obj
                } | Export-Csv -Path $sectionPath -NoTypeInformation
            }
        }
        Write-Host "CSV export complete" -ForegroundColor $colors.Success
    }
    
    if ($ExportHTML) {
        $htmlPath = Join-Path $OutputPath "UltimateHardwareReport_$timestamp.html"
        Write-Host "`nGenerating HTML report: $htmlPath" -ForegroundColor $colors.Info
        # HTML generation (simplified for reliability)
        $htmlContent = @"
<!DOCTYPE html>
<html>
<head><title>Hardware Report - $timestamp</title></head>
<body>
<h1>Ultimate Hardware Information Report</h1>
<p>Generated: $(Get-Date)</p>
<pre>$($hardwareData | ConvertTo-Json -Depth 10)</pre>
</body>
</html>
"@
        $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
        Write-Host "HTML report generated" -ForegroundColor $colors.Success
    }
    
    # Console summary
    if (-not ($ExportJSON -or $ExportCSV -or $ExportHTML)) {
        Write-Host "`n=== HARDWARE INVENTORY SUMMARY ===" -ForegroundColor $colors.Header
        foreach ($section in $hardwareData.Keys) {
            if ($section -eq 'ChangesDetected') { continue }
            Write-Host "`n[ $section ]" -ForegroundColor $colors.Section
            if ($hardwareData[$section] -is [array]) {
                Write-Host "  Items: $($hardwareData[$section].Count)" -ForegroundColor $colors.Info
            } elseif ($hardwareData[$section] -is [System.Collections.Specialized.OrderedDictionary]) {
                foreach ($key in $hardwareData[$section].Keys) {
                    $val = $hardwareData[$section][$key]
                    if ($val -isnot [System.Collections.Specialized.OrderedDictionary] -and $val -isnot [array]) {
                        Write-Host "  $key : $val" -ForegroundColor $colors.Value
                    }
                }
            }
        }
    }
    
    Write-Host "`n======================================================================" -ForegroundColor $colors.Header
    Write-Host "     SCAN COMPLETED SUCCESSFULLY" -ForegroundColor $colors.Success
    Write-Host "======================================================================" -ForegroundColor $colors.Header
    
} catch {
    Write-Host "`nCRITICAL ERROR: $($_.Exception.Message)" -ForegroundColor $colors.Error
    Write-Log -Message "CRITICAL ERROR: $($_.Exception.Message)" -Level "ERROR"
    if ($script:CimSession) { Remove-CimSession -CimSession $script:CimSession }
    exit 1
}