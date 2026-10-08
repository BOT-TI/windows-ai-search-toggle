#Requires -Version 5.1
<#
.SYNOPSIS
Inspect or change Windows Search policies and optionally block AI Fabric.
.DESCRIPTION
DisableAIFabric is experimental. A stopped service is not proof that semantic
search is disabled. DisableSearchUI disables the full Windows Search interface.
Use Status to inspect, WhatIf to preview and Restore to undo recorded changes.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param([switch]$Status, [switch]$Restore, [switch]$DisableAIFabric, [switch]$DisableSearchUI)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WindowsSearchToggle.psm1') -Force
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
if (($Status -or $Restore) -and ($DisableAIFabric -or $DisableSearchUI) -or ($Status -and $Restore)) {
    throw 'Status and Restore must be used separately from disable options.'
}
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ([int]$os.CurrentBuildNumber -lt 22000 -or $os.InstallationType -ne 'Client') { throw 'Windows 11 is required.' }
$searchPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
$aiPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
$serviceName = 'WSAIFabricSvc'
$servicePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\WSAIFabricSvc'
$backupDir = Join-Path $env:ProgramData 'WindowsSearchPolicyBackup'
$backupFile = Join-Path $backupDir 'original.json'
$serviceBackupFile = Join-Path $backupDir 'ai-service.json'
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
$policies = @(
    @{ Path=$searchPath; Name='ConnectedSearchUseWeb' },
    @{ Path=$aiPath; Name='DisableSettingsAgent' },
    @{ Path=$searchPath; Name='DisableSearch' }
)

if ($Status) {
    [pscustomobject]@{ WindowsEdition=$os.EditionID; Build=$os.CurrentBuildNumber; AIServiceInstalled=($null -ne $service); AIServiceState=$(if ($service) { [string]$service.Status } else { 'Not installed' }); AIServiceStart=$(if ($service) { Get-ItemPropertyValue $servicePath -Name Start } else { $null }); SemanticSearchDisabled='Unknown - cannot be determined from service/policy state' }
    foreach ($policy in $policies) { Get-RegistryValueSnapshot -Path $policy.Path -Name $policy.Name }
    return
}

# Plan and validate all requested policy changes before changing the service.
$changes = @()
if (-not $Restore) {
    if ($os.EditionID -match 'Enterprise|Education') {
        $changes += [pscustomobject]@{ Path=$searchPath; Name='ConnectedSearchUseWeb'; Value=0 }
        $admx = Join-Path $env:windir 'PolicyDefinitions\WindowsCopilot.admx'
        if ((Test-Path -LiteralPath $admx) -and (Select-String -LiteralPath $admx -Pattern 'name="DisableSettingsAgent"' -Quiet)) {
            $changes += [pscustomobject]@{ Path=$aiPath; Name='DisableSettingsAgent'; Value=1 }
        } else { Write-Warning 'Settings AI agent policy is absent in this build; skipped.' }
    } else { Write-Warning 'Settings AI agent/web policy support is documented for Enterprise/Education; skipped on Home/Pro.' }
    if ($DisableSearchUI) {
        if ($os.EditionID -notmatch 'Professional|Enterprise|Education' -or [int]$os.CurrentBuildNumber -lt 22621) { throw 'DisableSearchUI requires Windows 11 22H2+ Pro, Enterprise or Education.' }
        $changes += [pscustomobject]@{ Path=$searchPath; Name='DisableSearch'; Value=1 }
        Write-Warning 'DisableSearchUI blocks ALL Windows Search UI, including Start type-to-search and Win+S. Indexing is not removed.'
    }
    if ($DisableAIFabric) {
        Write-Warning 'AI Fabric service blocking is experimental and may affect other AI features. It is not a verified semantic-search switch.'
        if (-not $service) { throw 'WSAIFabricSvc is not installed. No changes made. Run -Status and check the Windows build.' }
    }
}

$policyBackup = $null
$serviceBackup = $null
if (Test-Path -LiteralPath $backupFile) {
    $policyBackup = Get-Content -LiteralPath $backupFile -Raw | ConvertFrom-Json
    Assert-PolicyBackup $policyBackup
}
if (Test-Path -LiteralPath $serviceBackupFile) {
    $serviceBackup = Get-Content -LiteralPath $serviceBackupFile -Raw | ConvertFrom-Json
    if ($serviceBackup.Start -notin @(2,3,4) -or $serviceBackup.WasRunning -isnot [bool] -or $serviceBackup.DelayedExists -isnot [bool] -or $serviceBackup.Delayed -notin @(0,1)) { throw 'Invalid service backup.' }
}
if ($Restore -and -not $policyBackup -and -not $serviceBackup) { throw 'No backup exists. No changes made.' }
if (-not $Restore -and $changes.Count -eq 0 -and -not $DisableAIFabric) {
    Write-Warning 'No supported changes selected on this edition. Use -Status, or explicitly select an available service/UI block.'
    return
}

$snapshots = @()
foreach ($change in $changes) { $snapshots += Get-RegistryValueSnapshot -Path $change.Path -Name $change.Name }
$newServiceBackup = $null
if ($DisableAIFabric -and -not $serviceBackup) {
    $key = Get-Item -LiteralPath $servicePath
    $start = $key.GetValue('Start')
    if ($start -notin @(2,3,4)) { throw 'Unsupported service startup type. No changes made.' }
    $newServiceBackup = @{ Start=$start; WasRunning=($service.Status -eq 'Running'); DelayedExists=($key.GetValueNames() -contains 'DelayedAutoStart'); Delayed=$key.GetValue('DelayedAutoStart',0) }
}

$action = if ($Restore) { 'Restore original Search policies and AI Fabric service configuration' } else { "Write $($changes.Count) Search policies; block AI Fabric: $DisableAIFabric" }
if (-not $PSCmdlet.ShouldProcess('This Windows installation', $action)) { return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open PowerShell as Administrator. Status and WhatIf do not require elevation.' }

try {
    if ($Restore) {
        # Retain backups until ALL restore operations complete successfully.
        if ($policyBackup) { foreach ($item in $policyBackup.Values) { Restore-RegistryValueSnapshot $item } }
        if ($serviceBackup) {
            $startup = switch ([int]$serviceBackup.Start) { 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } }
            Set-Service -Name $serviceName -StartupType $startup
            Restore-RegistryValueSnapshot ([pscustomobject]@{ Path=$servicePath; Name='DelayedAutoStart'; Exists=$serviceBackup.DelayedExists; Value=$serviceBackup.Delayed })
            if ($serviceBackup.WasRunning) { Start-Service -Name $serviceName } else { Stop-Service -Name $serviceName }
            $actual = Get-ItemPropertyValue -LiteralPath $servicePath -Name Start
            if ($actual -ne [int]$serviceBackup.Start) { throw 'Service startup restoration could not be verified.' }
        }
        if ($policyBackup) { Remove-Item -LiteralPath $backupFile }
        if ($serviceBackup) { Remove-Item -LiteralPath $serviceBackupFile }
        Write-Host 'Original settings restored. Restart Windows.' -ForegroundColor Green
        return
    }
    if ($changes.Count -gt 0) {
        $original = @()
        if ($policyBackup) { $original = @($policyBackup.Values) }
        $merged = @(Merge-OriginalSnapshots -Original $original -Candidate $snapshots)
        Save-ProtectedJson -Path $backupFile -Data @{ Version=1; Values=$merged }
    }
    if ($newServiceBackup) { Save-ProtectedJson -Path $serviceBackupFile -Data $newServiceBackup }
    if ($DisableAIFabric) {
        Set-Service -Name $serviceName -StartupType Disabled
        Stop-Service -Name $serviceName
        $current = Get-Service -Name $serviceName
        $startValue = Get-ItemPropertyValue -LiteralPath $servicePath -Name Start
        if ($current.Status -ne 'Stopped' -or $startValue -ne 4) { throw 'AI Fabric is not both stopped and disabled.' }
        Write-Host 'Verified: WSAIFabricSvc is stopped, startup Disabled. Semantic search behavior still requires a manual test.' -ForegroundColor Green
    }
    foreach ($change in $changes) {
        New-Item -Path $change.Path -Force | Out-Null
        New-ItemProperty -Path $change.Path -Name $change.Name -Value $change.Value -PropertyType DWord -Force | Out-Null
        if ((Get-ItemPropertyValue -LiteralPath $change.Path -Name $change.Name) -ne $change.Value) { throw "Policy verification failed: $($change.Name)" }
        Write-Host "Policy written: $($change.Name) = $($change.Value)"
    }
    Write-Host 'Restart Windows, run -Status, then test the same semantic query.'
} catch {
    throw "Operation failed: $($_.Exception.Message) Changes may be partial. Backups are retained in $backupDir; use -Restore."
}
