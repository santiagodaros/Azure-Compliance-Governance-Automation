#Requires -Modules Az.DesktopVirtualization, Az.Resources
<#
.SYNOPSIS
    Audits authorized users and RDP security properties across all AVD Host Pools.

.DESCRIPTION
    Enumerates every Application Group in the subscription and retrieves all users
    with the "Desktop Virtualization User" role assignment. For each user, it captures
    the RDP security properties configured on the parent Host Pool (device redirection,
    drive redirection, clipboard, and printer redirection).

    Designed to run in Azure Cloud Shell. Output is a CSV written to the current
    working directory.

.OUTPUTS
    ./Auditoria_AVD.csv

.NOTES
    Required roles: Desktop Virtualization Reader (or higher) on the subscription.
#>

# ========================= Helper: Parse RDP Property =========================

function Get-RdpProperty {
    param(
        [string]$rdpString,
        [string]$property
    )
    if ($rdpString -match "$property:.:([^;]+)") {
        $val = $matches[1]
        if ($val -eq "0") { return "Disabled" }
        if ($val -eq "1") { return "Enabled" }
        return $val
    }
    return "Default"
}

# ========================= Data Collection =========================

Write-Host "[INFO] Obteniendo Host Pools y Application Groups..." -ForegroundColor Cyan

$hostPools = Get-AzWvdHostPool
$appGroups = Get-AzWvdApplicationGroup
$report    = @()

foreach ($ag in $appGroups) {

    $hpName = $ag.HostPoolArmPath.Split('/')[-1]
    $hp     = $hostPools | Where-Object { $_.Name -eq $hpName }

    # Role assignments scoped to this Application Group
    $assignments = Get-AzRoleAssignment -Scope $ag.Id |
                   Where-Object { $_.RoleDefinitionName -eq "Desktop Virtualization User" }

    foreach ($assign in $assignments) {
        $report += [PSCustomObject]@{
            HostPool        = $hpName
            AppGroup        = $ag.Name
            User            = $assign.DisplayName
            Email           = $assign.SignInName
            MTP_PTP_Redir   = Get-RdpProperty $hp.RdpProperty "deviceredirect"
            Drive_Redir     = Get-RdpProperty $hp.RdpProperty "drivesteredirect"
            Clipboard_Redir = Get-RdpProperty $hp.RdpProperty "redirectclipboard"
            Printer_Redir   = Get-RdpProperty $hp.RdpProperty "redirectprinters"
        }
    }
}

# ========================= Export =========================

$outputPath = "./Auditoria_AVD.csv"
$report | Export-Csv -Path $outputPath -NoTypeInformation -Encoding utf8

Write-Host "Archivo generado: $outputPath  ($($report.Count) registros)" -ForegroundColor Green
