$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$count = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
Get-ChildItem -LiteralPath $root -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
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
Write-Host "$count checks passed; only a disposable HKCU test key was modified."
