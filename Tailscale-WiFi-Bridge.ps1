[CmdletBinding()]
param (
    [ValidateLength(1, 32)]
    [string]$SSID = "WiFi_Hotspot",

    [ValidateLength(8, 63)]
    [string]$Password = "12345678",

    [bool]$AllowAccessToThisPC = $true,

    # Internal flag used only when the script relaunches itself.
    [switch]$ElevatedRelaunch
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Self-elevation / PowerShell host
#
# WinRT integration used by Windows Mobile Hotspot is most predictable from
# built-in Windows PowerShell 5.1. If this script is launched from PowerShell 7
# or without elevation, it relaunches itself using elevated Windows PowerShell.
# ============================================================================

function Test-IsAdministrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if ($ElevatedRelaunch) {
    if ($null -ne $env:TAILSCALE_BRIDGE_SSID) {
        $SSID = $env:TAILSCALE_BRIDGE_SSID
    }
    elseif ($null -ne $env:TAILSCALE_HOTSPOT_SSID) {
        $SSID = $env:TAILSCALE_HOTSPOT_SSID
    }

    if ($null -ne $env:TAILSCALE_BRIDGE_PASSWORD) {
        $Password = $env:TAILSCALE_BRIDGE_PASSWORD
    }
    elseif ($null -ne $env:TAILSCALE_HOTSPOT_PASSWORD) {
        $Password = $env:TAILSCALE_HOTSPOT_PASSWORD
    }

    if ($null -ne $env:TAILSCALE_BRIDGE_ALLOW_LOCAL) {
        $AllowAccessToThisPC = ($env:TAILSCALE_BRIDGE_ALLOW_LOCAL -eq "1")
    }
    elseif ($null -ne $env:TAILSCALE_HOTSPOT_ALLOW_LOCAL) {
        $AllowAccessToThisPC = ($env:TAILSCALE_HOTSPOT_ALLOW_LOCAL -eq "1")
    }
}

$RunningWindowsPowerShell =
    ($PSVersionTable.PSEdition -eq "Desktop")

$RunningAsAdministrator =
    Test-IsAdministrator

if (
    -not $RunningWindowsPowerShell -or
    -not $RunningAsAdministrator
) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw "The script cannot self-elevate because its file path is unavailable."
    }

    if (
        [Environment]::Is64BitOperatingSystem -and
        -not [Environment]::Is64BitProcess
    ) {
        $WindowsPowerShell =
            "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    }
    else {
        $WindowsPowerShell =
            "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    if (-not (Test-Path $WindowsPowerShell)) {
        throw "Windows PowerShell 5.1 was not found at: $WindowsPowerShell"
    }

    # Pass configurable values through inherited environment variables rather
    # than exposing the Wi-Fi password on the process command line.
    $env:TAILSCALE_BRIDGE_SSID = $SSID
    $env:TAILSCALE_BRIDGE_PASSWORD = $Password

    if ($AllowAccessToThisPC) {
        $env:TAILSCALE_BRIDGE_ALLOW_LOCAL = "1"
    }
    else {
        $env:TAILSCALE_BRIDGE_ALLOW_LOCAL = "0"
    }

    $Arguments =
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ElevatedRelaunch"

    Write-Host ""
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow

    if (-not $RunningWindowsPowerShell) {
        Write-Host "Switching to Windows PowerShell 5.1 for WinRT compatibility..." -ForegroundColor Yellow
    }

    try {
        Start-Process `
            -FilePath $WindowsPowerShell `
            -Verb RunAs `
            -ArgumentList $Arguments `
            -WorkingDirectory (Split-Path -Parent $PSCommandPath)
    }
    catch {
        throw "Elevation was cancelled or failed: $($_.Exception.Message)"
    }

    exit
}


# ============================================================================
# Configuration
# ============================================================================

$NatName =
    "TailscaleWiFiBridgeNAT"
$LegacyNatName =
    "TailscaleHotspotNAT"

$FirewallRuleName =
    "Tailscale WiFi Bridge - Allow clients to this PC"
$LegacyFirewallRuleName =
    "Tailscale Hotspot - Allow clients to this PC"

$StateDirectory =
    Join-Path $env:ProgramData "TailscaleWiFiBridge"
$StateFile =
    Join-Path $StateDirectory "state.json"

$LegacyStateDirectory =
    Join-Path $env:ProgramData "TailscaleHotspotRouter"
$LegacyStateFile =
    Join-Path $LegacyStateDirectory "state.json"


# ============================================================================
# General helpers
# ============================================================================

function Test-PrintableAscii {
    param (
        [Parameter(Mandatory)]
        [string]$Value
    )

    foreach ($Char in $Value.ToCharArray()) {
        $Code = [int][char]$Char

        if ($Code -lt 32 -or $Code -gt 126) {
            return $false
        }
    }

    return $true
}


function Get-TailscaleExecutable {
    $Command =
        Get-Command "tailscale.exe" `
            -ErrorAction SilentlyContinue

    if ($Command) {
        return $Command.Source
    }

    $DefaultPath =
        Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"

    if (Test-Path $DefaultPath) {
        return $DefaultPath
    }

    throw "tailscale.exe was not found. Install Tailscale first."
}


function Get-TailscaleStatus {
    $Exe = Get-TailscaleExecutable

    $Output =
        & $Exe status --json 2>&1

    $ExitCode =
        $LASTEXITCODE

    if ($ExitCode -ne 0) {
        throw @"
Unable to query Tailscale status.

$($Output -join "`n")
"@
    }

    return (
        ($Output -join "`n") |
        ConvertFrom-Json
    )
}


function Assert-TailscaleRunning {
    $Status =
        Get-TailscaleStatus

    if ($Status.BackendState -ne "Running") {
        throw "Tailscale is not connected. Current state: $($Status.BackendState)"
    }
}


function Assert-Prerequisites {
    if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) {
        throw "The Windows NetNat PowerShell module is unavailable."
    }

    if (-not (Get-Command New-NetNat -ErrorAction SilentlyContinue)) {
        throw "New-NetNat is unavailable on this Windows installation."
    }

    if (-not (Get-Command Set-NetIPInterface -ErrorAction SilentlyContinue)) {
        throw "The NetTCPIP PowerShell module is unavailable."
    }

    [void](Get-TailscaleExecutable)
}


# ============================================================================
# WinRT / Mobile Hotspot
# ============================================================================

function Initialize-WinRT {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime

    $script:NetworkInformationType =
        [Type]::GetType(
            'Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime',
            $true
        )

    $script:TetheringManagerType =
        [Type]::GetType(
            'Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime',
            $true
        )

    $script:TetheringResultType =
        [Type]::GetType(
            'Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime',
            $true
        )

    # PowerShell cannot directly await WinRT IAsyncOperation/IAsyncAction.
    #
    # Find the System.WindowsRuntimeSystemExtensions AsTask overloads.
    # Do not depend only on ParameterType.Name because that varies between
    # PowerShell/.NET projections.
    $AsTaskMethods =
        [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            $_.GetParameters().Count -eq 1
        }

    $script:AsTaskOperation =
        $AsTaskMethods |
        Where-Object {
            $_.IsGenericMethodDefinition -and
            $_.GetGenericArguments().Count -eq 1 -and
            (
                $_.GetParameters()[0].ParameterType.ToString() -match
                "IAsyncOperation"
            )
        } |
        Select-Object -First 1

    # Fallback matching method used by the established PowerShell/WinRT
    # pattern if ToString() differs.
    if (-not $script:AsTaskOperation) {
        $script:AsTaskOperation =
            $AsTaskMethods |
            Where-Object {
                $_.IsGenericMethod -and
                $_.GetParameters()[0].ParameterType.Name -eq
                "IAsyncOperation``1"
            } |
            Select-Object -First 1
    }

    $script:AsTaskAction =
        $AsTaskMethods |
        Where-Object {
            -not $_.IsGenericMethod -and
            (
                $_.GetParameters()[0].ParameterType.ToString() -match
                "IAsyncAction"
            )
        } |
        Select-Object -First 1

    if (-not $script:AsTaskAction) {
        $script:AsTaskAction =
            $AsTaskMethods |
            Where-Object {
                -not $_.IsGenericMethod -and
                $_.GetParameters()[0].ParameterType.Name -eq
                "IAsyncAction"
            } |
            Select-Object -First 1
    }

    if (-not $script:AsTaskOperation) {
        $Available =
            $AsTaskMethods |
            ForEach-Object {
                $_.ToString()
            }

        throw @"
Could not locate the WinRT IAsyncOperation<T> AsTask overload.

PowerShell:
$($PSVersionTable.PSVersion)

Edition:
$($PSVersionTable.PSEdition)

Available AsTask overloads:
$($Available -join "`n")
"@
    }

    if (-not $script:AsTaskAction) {
        throw "Could not locate the WinRT IAsyncAction AsTask overload."
    }
}


function Wait-WinRTAction {
    param (
        [Parameter(Mandatory)]
        $AsyncAction
    )

    $Task =
        $script:AsTaskAction.Invoke(
            $null,
            @($AsyncAction)
        )

    # GetAwaiter().GetResult() unwraps the actual exception rather than
    # returning AggregateException from Task.Wait().
    [void]$Task.GetAwaiter().GetResult()
}


function Wait-WinRTOperation {
    param (
        [Parameter(Mandatory)]
        $AsyncOperation,

        [Parameter(Mandatory)]
        [Type]$ResultType
    )

    $Method =
        $script:AsTaskOperation.MakeGenericMethod(
            $ResultType
        )

    $Task =
        $Method.Invoke(
            $null,
            @($AsyncOperation)
        )

    return $Task.GetAwaiter().GetResult()
}


function Get-UpstreamConnectionProfile {
    # Preferred route: Windows default internet profile.
    $Profile =
        $script:NetworkInformationType::
        GetInternetConnectionProfile()

    if ($Profile) {
        return $Profile
    }

    # Fallback route: first profile that indicates internet connectivity.
    $Profiles =
        $script:NetworkInformationType::
        GetConnectionProfiles()

    foreach ($Candidate in $Profiles) {
        $Level =
            $Candidate.GetNetworkConnectivityLevel().ToString()

        if ($Level -eq "InternetAccess") {
            return $Candidate
        }
    }

    return $null
}


function Get-TetheringManager {
    $Profile =
        Get-UpstreamConnectionProfile

    if (-not $Profile) {
        throw "No active network connection is available for Windows Mobile Hotspot."
    }

    $Manager =
        $script:TetheringManagerType::
        CreateFromConnectionProfile($Profile)

    if (-not $Manager) {
        throw "Windows could not create a Mobile Hotspot tethering manager."
    }

    return $Manager
}


function Assert-TetheringSuccess {
    param (
        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    if ($Result.Status.ToString() -eq "Success") {
        return
    }

    $Details = $null

    try {
        $Details =
            $Result.AdditionalErrorMessage
    }
    catch {
        $Details = $null
    }

    if ([string]::IsNullOrWhiteSpace($Details)) {
        throw "$Operation failed. Status: $($Result.Status)"
    }

    throw "$Operation failed. Status: $($Result.Status). Details: $Details"
}


# ============================================================================
# IPv4 helpers
# ============================================================================

function ConvertTo-IPv4NetworkCIDR {
    param (
        [Parameter(Mandatory)]
        [string]$IPAddress,

        [Parameter(Mandatory)]
        [ValidateRange(0, 32)]
        [int]$PrefixLength
    )

    $Address =
        [Net.IPAddress]::Parse($IPAddress)

    $Bytes =
        $Address.GetAddressBytes()

    if ($Bytes.Length -ne 4) {
        throw "$IPAddress is not an IPv4 address."
    }

    $NetworkBytes =
        New-Object byte[] 4

    $RemainingBits =
        $PrefixLength

    for ($i = 0; $i -lt 4; $i++) {
        if ($RemainingBits -ge 8) {
            $Mask = 255
            $RemainingBits -= 8
        }
        elseif ($RemainingBits -gt 0) {
            $Mask =
                256 - [math]::Pow(
                    2,
                    8 - $RemainingBits
                )

            $RemainingBits = 0
        }
        else {
            $Mask = 0
        }

        $NetworkBytes[$i] =
            [byte](
                $Bytes[$i] -band [byte]$Mask
            )
    }

    $NetworkAddress =
        New-Object Net.IPAddress (, $NetworkBytes)

    return "$($NetworkAddress.IPAddressToString)/$PrefixLength"
}


function Get-HotspotInterface {
    param (
        [int]$TimeoutSeconds = 20
    )

    $Deadline =
        (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        # Normal Windows ICS/Mobile Hotspot address.
        $Standard =
            Get-NetIPAddress `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -eq "192.168.137.1"
            } |
            Select-Object -First 1

        if ($Standard) {
            $Adapter =
                Get-NetAdapter `
                    -InterfaceIndex $Standard.InterfaceIndex `
                    -ErrorAction SilentlyContinue

            return [PSCustomObject]@{
                InterfaceIndex = $Standard.InterfaceIndex
                InterfaceAlias = $Standard.InterfaceAlias
                Description    = $Adapter.InterfaceDescription
                IPAddress      = $Standard.IPAddress
                PrefixLength   = $Standard.PrefixLength
            }
        }

        # Fallback if Windows selected another range.
        $Adapters =
            Get-NetAdapter `
                -IncludeHidden `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Status -eq "Up" -and
                (
                    $_.InterfaceDescription -match "Wi-Fi Direct" -or
                    $_.InterfaceDescription -match "Hosted Network"
                )
            }

        foreach ($Adapter in $Adapters) {
            $Address =
                Get-NetIPAddress `
                    -InterfaceIndex $Adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -ne "127.0.0.1" -and
                    $_.IPAddress -notlike "169.254.*"
                } |
                Select-Object -First 1

            if ($Address) {
                return [PSCustomObject]@{
                    InterfaceIndex = $Adapter.ifIndex
                    InterfaceAlias = $Adapter.Name
                    Description    = $Adapter.InterfaceDescription
                    IPAddress      = $Address.IPAddress
                    PrefixLength   = $Address.PrefixLength
                }
            }
        }

        Start-Sleep -Milliseconds 500

    } while ((Get-Date) -lt $Deadline)

    throw "Mobile Hotspot started, but its IPv4 interface could not be identified."
}


function Get-ForwardingState {
    $Interfaces =
        Get-NetIPInterface `
            -AddressFamily IPv4 `
            -ErrorAction Stop |
        Where-Object {
            $_.ConnectionState -eq "Connected" -and
            $_.InterfaceAlias -notmatch "Loopback"
        }

    return @(
        foreach ($Interface in $Interfaces) {
            [PSCustomObject]@{
                InterfaceIndex =
                    [int]$Interface.InterfaceIndex

                InterfaceAlias =
                    [string]$Interface.InterfaceAlias

                Forwarding =
                    [string]$Interface.Forwarding
            }
        }
    )
}


function Enable-IPv4Forwarding {
    param (
        [Parameter(Mandatory)]
        $States
    )

    foreach ($State in @($States)) {
        Set-NetIPInterface `
            -InterfaceIndex ([int]$State.InterfaceIndex) `
            -AddressFamily IPv4 `
            -Forwarding Enabled `
            -ErrorAction Stop
    }
}


function Restore-IPv4Forwarding {
    param (
        [Parameter(Mandatory)]
        $States
    )

    foreach ($State in @($States)) {
        $Interface =
            Get-NetIPInterface `
                -InterfaceIndex ([int]$State.InterfaceIndex) `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if (-not $Interface) {
            continue
        }

        if ([string]$State.Forwarding -eq "Enabled") {
            Set-NetIPInterface `
                -InterfaceIndex ([int]$State.InterfaceIndex) `
                -AddressFamily IPv4 `
                -Forwarding Enabled `
                -ErrorAction SilentlyContinue
        }
        else {
            Set-NetIPInterface `
                -InterfaceIndex ([int]$State.InterfaceIndex) `
                -AddressFamily IPv4 `
                -Forwarding Disabled `
                -ErrorAction SilentlyContinue
        }
    }
}


# ============================================================================
# Persistent state
# ============================================================================

function Save-State {
    param (
        [Parameter(Mandatory)]
        $State
    )

    if (-not (Test-Path $StateDirectory)) {
        New-Item `
            -ItemType Directory `
            -Path $StateDirectory `
            -Force |
            Out-Null
    }

    $State |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $StateFile `
            -Encoding UTF8
}


function Get-SavedState {
    if (Test-Path $StateFile) {
        return (
            Get-Content `
                -LiteralPath $StateFile `
                -Raw |
            ConvertFrom-Json
        )
    }

    if (Test-Path $LegacyStateFile) {
        return (
            Get-Content `
                -LiteralPath $LegacyStateFile `
                -Raw |
            ConvertFrom-Json
        )
    }

    return $null
}


# ============================================================================
# START
# ============================================================================

function Start-TailscaleWiFiBridge {
    Write-Host ""
    Write-Host "--- Starting Tailscale WiFi Bridge ---" -ForegroundColor Cyan

    $ExistingState = Get-SavedState
    if ($ExistingState) {
        throw @"
A previous router state already exists:

$StateFile

Run STOP first.
"@
    }

    if (-not (Test-PrintableAscii -Value $Password)) {
        throw "The hotspot password must contain only printable ASCII characters."
    }

    Assert-Prerequisites
    Assert-TailscaleRunning
    Initialize-WinRT

    $Manager =
        Get-TetheringManager

    $HotspotStarted =
        $false

    $NatCreated =
        $false

    $FirewallCreated =
        $false

    $ForwardingStates =
        @()

    try {
        # --------------------------------------------------------------------
        # Stop an existing hotspot before reconfiguring it.
        # --------------------------------------------------------------------

        if (
            $Manager.TetheringOperationalState.ToString() -eq
            "On"
        ) {
            Write-Host "Stopping existing Mobile Hotspot..." -ForegroundColor Yellow

            $StopResult =
                Wait-WinRTOperation `
                    -AsyncOperation (
                        $Manager.StopTetheringAsync()
                    ) `
                    -ResultType $script:TetheringResultType

            Assert-TetheringSuccess `
                -Result $StopResult `
                -Operation "Stopping existing Mobile Hotspot"
        }


        # --------------------------------------------------------------------
        # Configure hotspot.
        # --------------------------------------------------------------------

        Write-Host "Configuring Mobile Hotspot..." -ForegroundColor Yellow

        $Configuration =
            $Manager.GetCurrentAccessPointConfiguration()

        $Configuration.Ssid =
            $SSID

        $Configuration.Passphrase =
            $Password

        $ConfigureOperation =
            $Manager.ConfigureAccessPointAsync(
                $Configuration
            )

        Wait-WinRTAction `
            -AsyncAction $ConfigureOperation


        # --------------------------------------------------------------------
        # Start hotspot.
        # --------------------------------------------------------------------

        Write-Host "Starting Mobile Hotspot..." -ForegroundColor Yellow

        $StartResult =
            Wait-WinRTOperation `
                -AsyncOperation (
                    $Manager.StartTetheringAsync()
                ) `
                -ResultType $script:TetheringResultType

        Assert-TetheringSuccess `
            -Result $StartResult `
            -Operation "Starting Mobile Hotspot"

        $HotspotStarted =
            $true


        # --------------------------------------------------------------------
        # Discover hotspot interface/subnet.
        # --------------------------------------------------------------------

        $Hotspot =
            Get-HotspotInterface

        $HotspotCIDR =
            ConvertTo-IPv4NetworkCIDR `
                -IPAddress $Hotspot.IPAddress `
                -PrefixLength $Hotspot.PrefixLength

        Write-Host ""
        Write-Host "Hotspot interface detected:" -ForegroundColor Gray
        Write-Host "  Adapter : $($Hotspot.InterfaceAlias)"
        Write-Host "  Gateway : $($Hotspot.IPAddress)"
        Write-Host "  Subnet  : $HotspotCIDR"


        # --------------------------------------------------------------------
        # Refuse to overwrite unrelated WinNAT configurations.
        # --------------------------------------------------------------------

        $ExistingNats =
            @(Get-NetNat -ErrorAction Stop)

        if ($ExistingNats.Count -gt 0) {
            $Descriptions =
                $ExistingNats |
                ForEach-Object {
                    "$($_.Name) [$($_.InternalIPInterfaceAddressPrefix)]"
                }

            throw @"
An existing WinNAT configuration was found:

$($Descriptions -join "`n")

This script will not automatically remove another application's NAT.

Inspect it with:

Get-NetNat
"@
        }


        # --------------------------------------------------------------------
        # Save existing forwarding settings.
        # --------------------------------------------------------------------

        $ForwardingStates =
            Get-ForwardingState

        $State =
            [ordered]@{
                Version           = 3
                HotspotCIDR       = $HotspotCIDR
                HotspotGateway    = $Hotspot.IPAddress
                HotspotInterface  = $Hotspot.InterfaceAlias
                ForwardingStates  = $ForwardingStates
                NatCreated        = $false
                FirewallCreated   = $false
            }

        Save-State `
            -State $State


        # --------------------------------------------------------------------
        # Enable routing.
        # --------------------------------------------------------------------

        Write-Host "Enabling IPv4 forwarding..." -ForegroundColor Yellow

        Enable-IPv4Forwarding `
            -States $ForwardingStates


        # --------------------------------------------------------------------
        # NAT hotspot clients.
        #
        # Client device:
        #
        #   192.168.137.x
        #          |
        #          v
        #   Host Windows PC / Gateway
        #          |
        #          +--> Normal Wi-Fi / Internet route
        #          +--> Local LAN
        #          +--> Tailscale 100.x route
        #          +--> Tailscale subnet routes
        #
        # Destination is selected using host PC routing table.
        # --------------------------------------------------------------------

        Write-Host "Creating WinNAT for $HotspotCIDR..." -ForegroundColor Yellow

        New-NetNat `
            -Name $NatName `
            -InternalIPInterfaceAddressPrefix $HotspotCIDR `
            -ErrorAction Stop |
            Out-Null

        $NatCreated =
            $true

        $State.NatCreated =
            $true

        Save-State `
            -State $State


        # --------------------------------------------------------------------
        # Allow hotspot clients to access services hosted on host PC itself.
        # --------------------------------------------------------------------

        if ($AllowAccessToThisPC) {
            $ExistingFirewallRule =
                Get-NetFirewallRule `
                    -DisplayName $FirewallRuleName `
                    -ErrorAction SilentlyContinue

            if ($ExistingFirewallRule) {
                throw "Firewall rule '$FirewallRuleName' already exists unexpectedly."
            }

            Write-Host "Allowing hotspot clients to access this PC..." -ForegroundColor Yellow

            New-NetFirewallRule `
                -DisplayName $FirewallRuleName `
                -Direction Inbound `
                -Action Allow `
                -RemoteAddress $HotspotCIDR `
                -Profile Any `
                -ErrorAction Stop |
                Out-Null

            $FirewallCreated =
                $true

            $State.FirewallCreated =
                $true

            Save-State `
                -State $State
        }


        # --------------------------------------------------------------------
        # Final status
        # --------------------------------------------------------------------

        $TailscaleStatus =
            Get-TailscaleStatus

        $TailIPs =
            @($TailscaleStatus.Self.TailscaleIPs)

        Write-Host ""
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host "   Tailscale WiFi Bridge is running          " -ForegroundColor Green
        Write-Host "=============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "SSID            : $SSID"
        Write-Host "Password        : $Password"
        Write-Host "Hotspot gateway : $($Hotspot.IPAddress)"
        Write-Host "Hotspot subnet  : $HotspotCIDR"

        if ($TailIPs.Count -gt 0) {
            Write-Host "Tailscale IPs   : $($TailIPs -join ', ')"
        }

        Write-Host ""
        Write-Host "Connected devices require no Tailscale installation." -ForegroundColor Cyan
        Write-Host "They use this host as their transparent gateway."
        Write-Host ""
        Write-Host "No Tailscale route advertisement required."
        Write-Host "No Tailscale admin route approval needed."
        Write-Host ""
    }
    catch {
        $OriginalError =
            $_

        Write-Warning "Startup failed. Rolling back changes..."

        if ($FirewallCreated) {
            Remove-NetFirewallRule `
                -DisplayName $FirewallRuleName `
                -ErrorAction SilentlyContinue
        }

        if ($NatCreated) {
            Remove-NetNat `
                -Name $NatName `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }

        if ($ForwardingStates.Count -gt 0) {
            Restore-IPv4Forwarding `
                -States $ForwardingStates
        }

        if ($HotspotStarted) {
            try {
                [void](
                    Wait-WinRTOperation `
                        -AsyncOperation (
                            $Manager.StopTetheringAsync()
                        ) `
                        -ResultType $script:TetheringResultType
                )
            }
            catch {
                # Preserve original error.
            }
        }

        Remove-Item `
            -LiteralPath $StateFile `
            -Force `
            -ErrorAction SilentlyContinue

        throw $OriginalError
    }
}


# ============================================================================
# STOP
# ============================================================================

function Stop-TailscaleWiFiBridge {
    Write-Host ""
    Write-Host "--- Stopping Tailscale WiFi Bridge ---" -ForegroundColor Yellow

    $State =
        Get-SavedState

    if ($State) {
        if ($State.FirewallCreated) {
            foreach ($RuleName in @($FirewallRuleName, $LegacyFirewallRuleName)) {
                if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
                    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
                    Write-Host "Removed firewall rule: $RuleName" -ForegroundColor Gray
                }
            }
        }

        if ($State.NatCreated) {
            foreach ($Name in @($NatName, $LegacyNatName)) {
                if (Get-NetNat -Name $Name -ErrorAction SilentlyContinue) {
                    Remove-NetNat -Name $Name -Confirm:$false -ErrorAction SilentlyContinue
                    Write-Host "Removed WinNAT: $Name" -ForegroundColor Gray
                }
            }
        }

        if ($State.ForwardingStates) {
            Restore-IPv4Forwarding `
                -States $State.ForwardingStates

            Write-Host "Restored IPv4 forwarding state." -ForegroundColor Gray
        }
    }
    else {
        # Check and cleanup any orphaned rules/NAT if state file was missing
        foreach ($RuleName in @($FirewallRuleName, $LegacyFirewallRuleName)) {
            if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
                Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
                Write-Host "Cleaned up orphaned firewall rule: $RuleName" -ForegroundColor Gray
            }
        }
        foreach ($Name in @($NatName, $LegacyNatName)) {
            if (Get-NetNat -Name $Name -ErrorAction SilentlyContinue) {
                Remove-NetNat -Name $Name -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "Cleaned up orphaned WinNAT: $Name" -ForegroundColor Gray
            }
        }
        Write-Warning "No saved router state was found."
    }

    try {
        Initialize-WinRT

        $Manager =
            Get-TetheringManager

        if (
            $Manager.TetheringOperationalState.ToString() -eq
            "On"
        ) {
            $StopResult =
                Wait-WinRTOperation `
                    -AsyncOperation (
                        $Manager.StopTetheringAsync()
                    ) `
                    -ResultType $script:TetheringResultType

            if ($StopResult.Status.ToString() -eq "Success") {
                Write-Host "Mobile Hotspot stopped." -ForegroundColor Gray
            }
            else {
                Write-Warning "Mobile Hotspot stop returned: $($StopResult.Status)"
            }
        }
    }
    catch {
        Write-Warning "Could not stop Mobile Hotspot: $($_.Exception.Message)"
    }

    Remove-Item `
        -LiteralPath $StateFile `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $LegacyStateFile `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Teardown complete." -ForegroundColor Green
}


# ============================================================================
# STATUS
# ============================================================================

function Show-TailscaleWiFiBridgeStatus {
    Write-Host ""
    Write-Host "--- Tailscale WiFi Bridge Status ---" -ForegroundColor Cyan
    Write-Host ""

    try {
        $Status =
            Get-TailscaleStatus

        Write-Host "Tailscale       : $($Status.BackendState)"

        $TailIPs =
            @($Status.Self.TailscaleIPs)

        if ($TailIPs.Count -gt 0) {
            Write-Host "Tailscale IPs   : $($TailIPs -join ', ')"
        }
    }
    catch {
        Write-Host "Tailscale       : unavailable"
        Write-Host "Reason          : $($_.Exception.Message)"
    }

    try {
        Initialize-WinRT

        $Manager =
            Get-TetheringManager

        Write-Host "Mobile Hotspot  : $($Manager.TetheringOperationalState)"
    }
    catch {
        Write-Host "Mobile Hotspot  : unknown"
        Write-Host "WinRT error     : $($_.Exception.Message)"
    }

    $State =
        Get-SavedState

    if ($State) {
        Write-Host "Router state    : configured"
        Write-Host "Hotspot subnet  : $($State.HotspotCIDR)"
        Write-Host "Hotspot gateway : $($State.HotspotGateway)"
    }
    else {
        Write-Host "Router state    : not configured"
    }

    $Nat =
        Get-NetNat `
            -Name $NatName `
            -ErrorAction SilentlyContinue

    if (-not $Nat) {
        $Nat = Get-NetNat -Name $LegacyNatName -ErrorAction SilentlyContinue
    }

    if ($Nat) {
        Write-Host "WinNAT          : active ($($Nat.Name))"
        Write-Host "NAT prefix      : $($Nat.InternalIPInterfaceAddressPrefix)"
    }
    else {
        Write-Host "WinNAT          : inactive"
    }

    Write-Host ""
    Write-Host "Active NAT sessions:" -ForegroundColor Gray

    $Sessions =
        Get-NetNatSession `
            -ErrorAction SilentlyContinue

    if ($Sessions) {
        $Sessions |
            Format-Table `
                Protocol,
                InternalSourceAddress,
                InternalSourcePort,
                ExternalSourceAddress,
                ExternalSourcePort,
                RemoteDestinationAddress,
                RemoteDestinationPort `
                -AutoSize
    }
    else {
        Write-Host "  None"
    }

    Write-Host ""
    Write-Host "Connected IPv4 interfaces:" -ForegroundColor Gray

    Get-NetIPInterface `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ConnectionState -eq "Connected"
    } |
    Select-Object `
        InterfaceIndex,
        InterfaceAlias,
        ConnectionState,
        Forwarding,
        InterfaceMetric |
    Format-Table -AutoSize
}

# Compatibility aliases
Set-Alias -Name Start-TailscaleHotspot -Value Start-TailscaleWiFiBridge -ErrorAction SilentlyContinue
Set-Alias -Name Stop-TailscaleHotspot -Value Stop-TailscaleWiFiBridge -ErrorAction SilentlyContinue
Set-Alias -Name Show-TailscaleHotspotStatus -Value Show-TailscaleWiFiBridgeStatus -ErrorAction SilentlyContinue


# ============================================================================
# Entry point
# ============================================================================

if (-not (Test-IsAdministrator)) {
    throw "Administrator elevation failed."
}

if ($PSVersionTable.PSEdition -ne "Desktop") {
    throw "The script failed to relaunch under Windows PowerShell 5.1."
}

if (-not (Test-PrintableAscii -Value $Password)) {
    throw "The hotspot password must contain only printable ASCII characters."
}

Clear-Host

do {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "        Tailscale WiFi Bridge             " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "PowerShell      : $($PSVersionTable.PSVersion)"
    Write-Host "Administrator   : Yes"
    Write-Host ""
    Write-Host "1. START hotspot + NAT routing"
    Write-Host "2. STOP hotspot + restore configuration"
    Write-Host "3. Show status / NAT sessions"
    Write-Host "4. Exit"
    Write-Host ""
    Write-Host "------------------------------------------"

    $Choice =
        Read-Host "Select an option (1-4)"

    try {
        switch ($Choice) {
            "1" {
                Start-TailscaleWiFiBridge
            }

            "2" {
                Stop-TailscaleWiFiBridge
            }

            "3" {
                Show-TailscaleWiFiBridgeStatus
            }

            "4" {
                break
            }

            default {
                Write-Warning "Invalid option."
            }
        }
    }
    catch {
        Write-Host ""
        Write-Error $_.Exception.Message
    }

} while ($Choice -ne "4")
