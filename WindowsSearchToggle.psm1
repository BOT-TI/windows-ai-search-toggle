Set-StrictMode -Version Latest

function Get-RegistryValueSnapshot {
    param([string]$Path, [string]$Name)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $exists = $null -ne $key -and $key.GetValueNames() -contains $Name
    $value = $null
    if ($exists) {
        if ($key.GetValueKind($Name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            throw "Unexpected registry type for $Path : $Name; expected DWORD."
        }
        $value = [uint32]$key.GetValue($Name)
    }
    [pscustomobject]@{ Path=$Path; Name=$Name; Exists=$exists; Value=$value }
}

function Restore-RegistryValueSnapshot {
    param([object]$Snapshot)
    if ($Snapshot.Exists) {
        New-Item -Path $Snapshot.Path -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $Snapshot.Path -Name $Snapshot.Name -PropertyType DWord -Value ([uint32]$Snapshot.Value) -Force -ErrorAction Stop | Out-Null
    } elseif (Test-Path -LiteralPath $Snapshot.Path) {
        $key = Get-Item -LiteralPath $Snapshot.Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Snapshot.Name) {
            Remove-ItemProperty -Path $Snapshot.Path -Name $Snapshot.Name -ErrorAction Stop
        }
    }
}

function Merge-OriginalSnapshots {
    param([object[]]$Original=@(), [object[]]$Candidate=@())
    $result = @($Original)
    foreach ($entry in $Candidate) {
        if (@($result | Where-Object { $_.Path -eq $entry.Path -and $_.Name -eq $entry.Name }).Count -eq 0) {
            $result += $entry
        }
    }
    $result
}

function Assert-PolicyBackup {
    param([object]$Backup)
    $search = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
    $ai = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
    if ($Backup.Version -ne 1) { throw 'Unsupported backup version.' }
    foreach ($entry in $Backup.Values) {
        $valid = ($entry.Path -eq $search -and $entry.Name -in @('ConnectedSearchUseWeb','DisableSearch')) -or
            ($entry.Path -eq $ai -and $entry.Name -eq 'DisableSettingsAgent')
        if (-not $valid -or $entry.Exists -isnot [bool]) { throw 'Invalid policy backup entry.' }
        if ($entry.Exists -and ($null -eq $entry.Value -or $entry.Value -is [string] -or [double]$entry.Value -lt 0 -or [double]$entry.Value -gt 4294967295 -or [math]::Floor([double]$entry.Value) -ne [double]$entry.Value)) {
            throw 'Invalid policy backup value.'
        }
    }
}

function Save-ProtectedJson {
    param([string]$Path, [object]$Data)
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    $dirInfo = Get-Item -LiteralPath $dir -Force
    if ($dirInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Backup directory must not be a reparse point.' }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $dir -AclObject $acl -ErrorAction Stop
    $temp = Join-Path $dir ([guid]::NewGuid().ToString() + '.tmp')
    try {
        $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

Export-ModuleMember -Function Get-RegistryValueSnapshot, Restore-RegistryValueSnapshot, Merge-OriginalSnapshots, Assert-PolicyBackup, Save-ProtectedJson
