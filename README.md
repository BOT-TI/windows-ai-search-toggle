# Windows AI Search Toggle

PowerShell controls for Windows Search policies, with an **experimental, reversible AI Fabric service block**.

**This is not a verified switch for disabling semantic search.** Disabling `WSAIFabricSvc` may affect other Windows AI features and may not block every semantic-search path. A stopped service or a registry value alone does not prove that AI search is disabled. Test the same natural-language query before and after, following a reboot.

## Download and run

Download the repository ZIP using **Code > Download ZIP**, then extract it. Keep `Disable-Windows-AI-Search.ps1` and `WindowsSearchToggle.psm1` together. Open 64-bit PowerShell in the extracted folder. Changes and restore require **Run as administrator**.

Inspect without changing settings:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-Windows-AI-Search.ps1 -Status
```

Preview the experimental service block:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-Windows-AI-Search.ps1 -DisableAIFabric -WhatIf
```

Apply it from an administrator PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-Windows-AI-Search.ps1 -DisableAIFabric
```

Restart Windows, run `-Status`, and repeat your original semantic-search query. The execution-policy override applies to this PowerShell process only.

## Options

| Option | Behavior |
| --- | --- |
| `-Status` | Displays Windows edition/build, service presence/state, startup registry value and policy values. No changes. |
| `-WhatIf` | Previews the selected operation; does not write backups, change policies, or stop services. |
| `-DisableAIFabric` | Experimental: sets `WSAIFabricSvc` startup to Disabled and stops it. Fails clearly if the service is absent. May affect other AI features. |
| `-DisableSearchUI` | Disables the entire Windows Search interface, including Win+S and Start type-to-search, on Windows 11 22H2+ Pro/Enterprise/Education. Does not remove indexing or specifically disable semantic search. |
| `-Restore` | Restores the recorded original registry values and service configuration. Requires administrator rights. |
| No options | Applies supported web-result/Settings-agent policies on Enterprise/Education; may make no changes on Home/Pro. |

When applying either disable option, the script also applies supported web-result and Settings-agent policies on Enterprise/Education. The Settings-agent policy is skipped if its local ADMX definition is absent. The Microsoft documentation lists it for Insider builds; local ADMX presence is only a capability check, not proof of enforcement.

The web-result policy writes `ConnectedSearchUseWeb=0`. The Settings-agent policy writes `DisableSettingsAgent=1`; this leaves semantic search available. `DisableSearch=1` hides the complete Windows Search UI. Home/Pro support is not assumed for Enterprise-only policies.

## Restore

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Disable-Windows-AI-Search.ps1 -Restore
```

Restart Windows after restoring. Backups are stored under `%ProgramData%\WindowsSearchPolicyBackup` with access restricted to Administrators and SYSTEM. Repeating an apply operation preserves the first recorded values. Backups are retained when an operation fails. Policy keys created by the script may remain as empty keys after restore; unrelated values are preserved.

## If it does not work

- **Service not installed:** this service block is unavailable on your build; the script exits before making changes. Run `-Status` to confirm.
- **Access denied / service cannot stop:** the script reports the actual error and retains backups. It does not bypass protected services or force-stop dependent services. Run `-Restore` to undo partial changes.
- **Service is stopped but semantic results remain:** this workaround does not cover your search path. Restore rather than assuming that AI search has been disabled.
- **No policy changes on Home/Pro:** this is expected for Enterprise-only policies. The optional service block is separate from those policies.
- **Settings change back:** managed policies or Windows updates can override local settings. Inspect again with `-Status`.

Do not delete backup files if you want to restore the original state. Do not publish local backup files or diagnostic output containing personal data.

## Verification

GitHub Actions runs syntax and registry backup/restore checks on Windows PowerShell 5.1 and PowerShell 7. The tests use a disposable HKCU registry key; they do not change the actual Search policies or AI Fabric service. They check existing/absent value restoration, repeated-run backup preservation, unexpected registry types, and rejection of invalid backup destinations.

These checks do **not** verify semantic-search behavior on Copilot+ hardware. A manual Windows 11 test is still required. The repository does not claim a successful on-device semantic-search test.

## Microsoft references

- [WindowsAI policy documentation](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai#disablesettingsagent)
- [Windows Search policies](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search)
- [Windows search indexing](https://support.microsoft.com/en-us/windows/experience/performance-optimization/search-indexing-in-windows)

The AI Fabric service block is an experimental implementation choice, not a Microsoft-documented semantic-search disable policy.
