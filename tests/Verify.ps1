$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') } | ForEach-Object {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True ($errors.Count -eq 0) ("Parse errors in $($_.Name): $errors")
}
Import-Module (Join-Path $root 'WindowsSearchToggle.psm1') -Force
$path = 'HKCU:\Software\WindowsSearchToggleTests-' + [guid]::NewGuid().ToString('N')
try {
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name 'Existing' -PropertyType DWord -Value 7 | Out-Null
    $existing = Get-RegistryValueSnapshot $path 'Existing'
    $absent = Get-RegistryValueSnapshot $path 'OriginallyAbsent'
    Assert-True ($existing.Exists -and $existing.Value -eq 7) 'Original existing value not captured.'
    Assert-True (-not $absent.Exists) 'Absent original value reported as present.'
    New-ItemProperty -Path $path -Name 'Existing' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $path -Name 'OriginallyAbsent' -PropertyType DWord -Value 1 | Out-Null
    Restore-RegistryValueSnapshot $existing
    Restore-RegistryValueSnapshot $absent
    Assert-True ((Get-ItemPropertyValue $path -Name Existing) -eq 7) 'Restore did not recover original value.'
    Assert-True (-not (Get-RegistryValueSnapshot $path 'OriginallyAbsent').Exists) 'Restore did not remove newly introduced value.'
    $second = [pscustomobject]@{ Path=$path; Name='Existing'; Exists=$true; Value=1 }
    $merged = @(Merge-OriginalSnapshots -Original @($existing) -Candidate @($second,$absent))
    Assert-True ($merged.Count -eq 2 -and $merged[0].Value -eq 7) 'Repeated apply overwrote the original backup.'
    New-ItemProperty -Path $path -Name 'WrongType' -PropertyType String -Value 'text' | Out-Null
    $rejected = $false
    try { Get-RegistryValueSnapshot $path 'WrongType' | Out-Null } catch { $rejected = $true }
    Assert-True $rejected 'Unexpected registry types must be rejected.'
    $valid = @{ Version=1; Values=@(@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='DisableSearch'; Exists=$false; Value=$null }) }
    Assert-PolicyBackup $valid
    $invalid = @{ Version=1; Values=@(@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableSearch'; Exists=$false; Value=$null }) }
    $rejected = $false
    try { Assert-PolicyBackup $invalid } catch { $rejected = $true }
    Assert-True $rejected 'Cross-key backup injection must be rejected.'
} finally { Remove-Item -LiteralPath $path -Recurse -Force }

# Exercise the public script's dry-run path with simulated Windows 11/service
# observations. Any service mutation immediately fails the test.
$savedProgramData = $env:ProgramData
$tempRoot = Join-Path $env:TEMP ('WindowsSearchToggle-' + [guid]::NewGuid().ToString('N'))
try {
    $env:ProgramData = $tempRoot
    function global:Get-ItemProperty {
        param([string]$Path)
        if ($Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') {
            return [pscustomobject]@{ CurrentBuildNumber='26100'; InstallationType='Client'; EditionID='Professional' }
        }
        throw "Unexpected registry read in dry run: $Path"
    }
    function global:Get-Service {
        param([string]$Name)
        if ($Name -ne 'WSAIFabricSvc') { throw 'Unexpected service read.' }
        [pscustomobject]@{ Name=$Name; Status='Running' }
    }
    function global:Get-Item {
        param([string]$LiteralPath)
        if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Services\WSAIFabricSvc') { throw 'Unexpected registry read.' }
        $fake = New-Object PSObject
        $fake | Add-Member ScriptMethod GetValue { param($Name,$Default) if ($Name -eq 'Start') { 3 } else { 0 } }
        $fake | Add-Member ScriptMethod GetValueNames { @('Start') }
        $fake
    }
    function global:Set-Service { throw 'WhatIf attempted a service startup mutation.' }
    function global:Stop-Service { throw 'WhatIf attempted to stop a service.' }
    & (Join-Path $root 'Disable-Windows-AI-Search.ps1') -DisableAIFabric -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $tempRoot)) 'WhatIf created backup files.'
} finally {
    $env:ProgramData = $savedProgramData
    foreach ($name in @('Get-ItemProperty','Get-Service','Get-Item','Set-Service','Stop-Service')) { Remove-Item "Function:\$name" -Force -ErrorAction Stop }
}

# Verify actual backup file serialization and permissions in a temporary folder.
try {
    $file = Join-Path $tempRoot 'backup.json'
    Save-ProtectedJson -Path $file -Data @{ Version=1; Values=@($existing,$absent) }
    $readback = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Assert-True ($readback.Values.Count -eq 2 -and $readback.Values[0].Value -eq 7) 'Backup JSON did not preserve original state.'
    $acl = Get-Acl -LiteralPath $tempRoot
    Assert-True $acl.AreAccessRulesProtected 'Backup directory inherited untrusted permissions.'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Host "$count checks passed; real Search policies and AI services were not modified."
