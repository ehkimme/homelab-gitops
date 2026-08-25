<#
.SYNOPSIS
Creates a SharePoint Server 2019 Subscription Settings service application.

.DESCRIPTION
Run this script in the SharePoint Management Shell as a farm administrator on
the SharePoint application server that should host the service instance.

The script is idempotent: it reuses an existing service application pool and
service application by name, and the farm's existing Subscription Settings proxy.

.PARAMETER ManagedAccount
The registered SharePoint managed account used by the service application pool.

.PARAMETER ApplicationPoolName
The service application pool to create or reuse.

.PARAMETER ServiceApplicationName
The Subscription Settings service application to create or reuse.

.PARAMETER DatabaseName
The Subscription Settings database name.

.PARAMETER DatabaseServer
Optional SQL Server instance or alias. When omitted, SharePoint uses the farm's
default database server.

.EXAMPLE
.\New-SP2019SubscriptionSettingsService.ps1 `
    -ManagedAccount 'CONTOSO\sp_services' `
    -DatabaseName 'SP2019_SubscriptionSettings'

.EXAMPLE
.\New-SP2019SubscriptionSettingsService.ps1 `
    -ManagedAccount 'CONTOSO\sp_services' `
    -ApplicationPoolName 'SharePoint Service Applications' `
    -DatabaseName 'SP2019_SubscriptionSettings' `
    -DatabaseServer 'SQLALIAS'
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedAccount,

    [ValidateNotNullOrEmpty()]
    [string]$ApplicationPoolName = 'SharePoint Service Applications',

    [ValidateNotNullOrEmpty()]
    [string]$ServiceApplicationName = 'Subscription Settings Service Application',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DatabaseName,

    [ValidateNotNullOrEmpty()]
    [string]$DatabaseServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-PSSnapin -Name Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
    Add-PSSnapin Microsoft.SharePoint.PowerShell
}

$farm = Get-SPFarm
if (-not $farm) {
    throw 'This computer is not connected to a SharePoint farm.'
}

$localServer = [Microsoft.SharePoint.Administration.SPServer]::Local
$serviceInstance = Get-SPServiceInstance -Server $localServer |
    Where-Object {
        $_.TypeName -eq 'Microsoft SharePoint Foundation Subscription Settings Service'
    } |
    Select-Object -First 1

if (-not $serviceInstance) {
    throw "The Subscription Settings service instance was not found on server '$($localServer.Address)'."
}

if ($serviceInstance.Status -ne [Microsoft.SharePoint.Administration.SPObjectStatus]::Online) {
    if ($PSCmdlet.ShouldProcess(
            $localServer.Address,
            'Start the Subscription Settings service instance'
        )) {
        Write-Verbose "Starting the Subscription Settings service instance on '$($localServer.Address)'."
        Start-SPServiceInstance -Identity $serviceInstance | Out-Null
    }
}

$applicationPool = Get-SPServiceApplicationPool |
    Where-Object { $_.Name -eq $ApplicationPoolName } |
    Select-Object -First 1

if (-not $applicationPool) {
    $account = Get-SPManagedAccount |
        Where-Object { $_.UserName -eq $ManagedAccount } |
        Select-Object -First 1

    if (-not $account) {
        throw "Managed account '$ManagedAccount' is not registered in SharePoint. Register it before running this script."
    }

    if ($PSCmdlet.ShouldProcess(
            $ApplicationPoolName,
            "Create service application pool using '$ManagedAccount'"
        )) {
        Write-Verbose "Creating service application pool '$ApplicationPoolName'."
        $applicationPool = New-SPServiceApplicationPool `
            -Name $ApplicationPoolName `
            -Account $account
    }
}

$serviceApplication = Get-SPServiceApplication |
    Where-Object { $_.Name -eq $ServiceApplicationName } |
    Select-Object -First 1

if ($serviceApplication -and
    $serviceApplication.TypeName -ne 'Microsoft SharePoint Foundation Subscription Settings Service Application') {
    throw "A different service application named '$ServiceApplicationName' already exists."
}

if (-not $serviceApplication -and $applicationPool) {
    $newServiceApplicationParameters = @{
        Name            = $ServiceApplicationName
        ApplicationPool = $applicationPool
        DatabaseName    = $DatabaseName
    }

    if ($DatabaseServer) {
        $newServiceApplicationParameters.DatabaseServer = $DatabaseServer
    }

    if ($PSCmdlet.ShouldProcess(
            $ServiceApplicationName,
            "Create Subscription Settings service application and database '$DatabaseName'"
        )) {
        Write-Verbose "Creating Subscription Settings service application '$ServiceApplicationName'."
        $serviceApplication = New-SPSubscriptionSettingsServiceApplication `
            @newServiceApplicationParameters
    }
}

$proxy = Get-SPServiceApplicationProxy |
    Where-Object {
        $_.TypeName -eq 'Microsoft SharePoint Foundation Subscription Settings Service Application Proxy'
    } |
    Select-Object -First 1

if (-not $proxy -and $serviceApplication) {
    if ($PSCmdlet.ShouldProcess(
            $ServiceApplicationName,
            'Create Subscription Settings service application proxy'
        )) {
        Write-Verbose "Creating a proxy for '$ServiceApplicationName'."
        $proxy = New-SPSubscriptionSettingsServiceApplicationProxy `
            -ServiceApplication $serviceApplication
    }
}

[pscustomobject]@{
    Server                 = $localServer.Address
    ServiceInstanceStatus  = $serviceInstance.Status
    ApplicationPool        = if ($applicationPool) { $applicationPool.Name } else { $ApplicationPoolName }
    ServiceApplication     = if ($serviceApplication) { $serviceApplication.Name } else { $ServiceApplicationName }
    Proxy                  = if ($proxy) { $proxy.Name } else { '(not created)' }
    Database               = $DatabaseName
    DatabaseServer         = if ($DatabaseServer) { $DatabaseServer } else { '(farm default)' }
}
