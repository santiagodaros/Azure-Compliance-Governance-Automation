#Requires -Modules Az.Accounts, Az.RecoveryServices, Az.Network, Az.Compute, Az.Storage, Az.Resources, ThreadJob
<#
.SYNOPSIS
    Ejecuta Test Failover (TFO) por VM en Azure Site Recovery, con pre-cleanup,
    cleanup final, verificacion de boot, validacion de red interna aislada
    y envio de reporte HTML via Logic App.

MEJORAS APLICADAS (PARALELIZACION Y STRESS-TEST):
  1) Fase 0: Pre-cleanup paralelo (Fire & Forget + Polling Masivo).
  2) Fase 1: Lanzamiento TFO masivo (Fire & Forget).
  3) Fase 2: Polling global simultaneo con cap al deadline global.
  4) Fase 3: Boot check secuencial + validaciones intra-VM en paralelo (Net+OS+Disk+SQL via Start-ThreadJob).
  5) Garantia de reporte parcial: $vmResultObj guardado en finally.
  6) Proteccion OOM: Control de caracteres en $script:LogBufferCharCount + ThreadJobs limitados a 4 per VM.
  7) SQL Server False Positives: Captura de excepcion por login de cuenta SYSTEM.
  8) Cache refresh in-loop en Phase 3 con regex endurecido para evitar falsos positivos.
  9) Wait-AsrJobsMasivo con retry por job + deadline global respetado.
#>

[CmdletBinding()]
param(
    # Pais para leer las variables especificas (Pa, Br, etc.)
    [string]$Country = "Br",

    # --- Timeouts y configuracion operativa (no sensible, se deja como parametro) ---
    [int]$JobTimeoutMinutes = 180,
    [int]$CleanupTimeoutMinutes = 60,
    [int]$MaxItems = 0,

    # --- Boot Verification ---
    [int]$BootCheckMaxRetries = 5,
    [int]$BootCheckIntervalSeconds = 180,

    # --- Payload guardrails ---
    [int]$MaxRawLogChars = 120000,
    [int]$MaxHtmlBytesInline = 250000,
    [int]$MaxVmNotesChars = 1500,

    # Timeout global del script en minutos (< 180 fair share Azure Automation)
    [int]$ScriptDeadlineMinutes = 170,

    # Intervalo de polling en Wait-AsrJob
    [int]$JobPollIntervalSeconds = 20
)

$ErrorActionPreference = "Stop"

# Forzar codificacion UTF-8 para evitar caracteres rotos en el output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ========================= Leer Variables de Automation Account =========================

Write-Output "[INFO] Leyendo variables de Automation Account para pais: $Country"

try {
    # Variables compartidas (sin sufijo de pais)
    $SubscriptionId     = Get-AutomationVariable -Name 'ASR_SubscriptionId'
    $LogicAppWebhookUrl = Get-AutomationVariable -Name 'ASR_LogicAppWebhookUrl'
    $MailToRaw          = Get-AutomationVariable -Name 'ASR_MailTo'
    
    if ([string]::IsNullOrWhiteSpace($MailToRaw)) { 
        throw "La variable ASR_MailTo esta vacia o no existe." 
    }
    
    $MailTo = @(($MailToRaw -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
    
    if ($MailTo.Count -eq 0) { 
        throw "ASR_MailTo no contiene ninguna direccion de email valida tras normalizar: '$MailToRaw'" 
    }

    # Variables por pais (con sufijo)
    ${VaultResourceGroup} = Get-AutomationVariable -Name "ASR_VaultResourceGroup_$Country"
    $VaultName          = Get-AutomationVariable -Name "ASR_VaultName_$Country"
    $TestVnetResourceId = Get-AutomationVariable -Name "ASR_TestVnetResourceId_$Country"
    $MailSubject        = Get-AutomationVariable -Name "ASR_MailSubject_$Country"

    Write-Output "[INFO] Variables cargadas OK:"
    Write-Output "[INFO]   SubscriptionId: $SubscriptionId"
    Write-Output "[INFO]   VaultResourceGroup: ${VaultResourceGroup}"
    Write-Output "[INFO]   VaultName: $VaultName"
    Write-Output "[INFO]   TestVnetResourceId: $($TestVnetResourceId.Substring(0, [Math]::Min(60, $TestVnetResourceId.Length)))..."
    Write-Output "[INFO]   MailTo: $($MailTo -join ', ')"
    Write-Output "[INFO]   MailSubject: $MailSubject"
    Write-Output "[INFO]   LogicAppWebhookUrl: (encrypted, cargada OK)"
}
catch {
    Write-Output "[ERROR] No se pudieron leer las variables de Automation Account: $($_.Exception.Message)"
    Write-Output "[ERROR] Verifique que existan las variables."
    throw
}

# Deadline global
$script:ScriptDeadline = (Get-Date).AddMinutes($ScriptDeadlineMinutes)

# ========================= Logging (OOM Protection) =========================

$script:LogBuffer = [System.Collections.Generic.List[string]]::new()
$script:LogBufferCharCount = 0

function Add-LogLine([string]$txt) { 
    try { 
        if ($script:LogBufferCharCount -lt $MaxRawLogChars) {
            [void]$script:LogBuffer.Add($txt) 
            $script:LogBufferCharCount += $txt.Length
        } 
        elseif ($script:LogBufferCharCount -eq $MaxRawLogChars) {
            [void]$script:LogBuffer.Add("... [TRUNCADO POR LIMITE DE MEMORIA OOM]")
            $script:LogBufferCharCount += 1
        }
    } catch {} 
}

function Write-Section([string]$t) { 
    $l = "`n==== $t ===="
    Write-Output $l
    Add-LogLine $l 
}

function Write-Info([string]$t) { 
    $l = "[INFO] $t"
    Write-Output $l
    Add-LogLine $l 
}

function Write-Warn([string]$t) { 
    $l = "[WARN] $t"
    Write-Output $l
    Add-LogLine $l 
}

function Write-ErrL([string]$t) { 
    $l = "[ERROR] $t"
    Write-Output $l
    Add-LogLine $l 
}

function Show-ExceptionDetail([Parameter(Mandatory)][System.Exception]$ex) {
    try {
        $resp = $ex.Response
        if ($resp -is [System.Net.HttpWebResponse] -and $resp.GetResponseStream) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $txt = $sr.ReadToEnd()
            if ($txt) { Write-ErrL "Backend response: $txt" }
        }
    }
    catch {}
    
    Write-ErrL ("Exception: {0}" -f $ex.Message)
    if ($ex.InnerException) { 
        Write-ErrL ("Inner: {0}" -f $ex.InnerException.Message) 
    }
}

# ========================= Utilidades =========================

function Protect-Uri([string]$u) {
    try { 
        $uri = [uri]$u
        return "{0}://{1}{2}?***" -f $uri.Scheme, $uri.Host, $uri.AbsolutePath 
    }
    catch { 
        return "<invalid-uri>" 
    }
}

function ConvertTo-HtmlSafe([string]$s) {
    if (-not $s) { 
        return "" 
    }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function Get-Prop {
    param([Parameter(Mandatory)]$Obj, [Parameter(Mandatory)][string[]]$Names)
    foreach ($n in $Names) {
        if ($Obj -and ($Obj.PSObject.Properties.Name -contains $n)) {
            $v = $Obj.$n
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { 
                return $v 
            }
        }
    }
    return $null
}

function Get-ItemDisplayName {
    param([Parameter(Mandatory)]$Item)
    $name = Get-Prop $Item @("FriendlyName", "DisplayName", "Name")
    if (-not $name) { 
        $name = "<unknown-item>" 
    }
    return [string]$name
}

function Test-HealthyProtectedItem {
    param([Parameter(Mandatory)]$Item)
    $protState = Get-Prop $Item @("ProtectionState", "ProtectionStatus", "State", "Status")
    $health = Get-Prop $Item @("ReplicationHealth", "Health", "FailoverHealth", "HealthStatus")
    $protOk = $true
    $healthOk = $true
    
    if ($protState) { 
        $protOk = ($protState -notmatch "Unprotected|Failed") 
    }
    
    if ($health) { 
        $healthOk = ($health -notmatch "Critical|Failed") 
    }
    
    return ($protOk -and $healthOk)
}

function Get-UnhealthyReason {
    param([Parameter(Mandatory)]$Item)
    $protState = Get-Prop $Item @("ProtectionState", "ProtectionStatus", "State", "Status")
    $health = Get-Prop $Item @("ReplicationHealth", "Health", "FailoverHealth", "HealthStatus")
    $reasons = @()
    
    if ($protState -and $protState -match "Unprotected|Failed") { 
        $reasons += "ProtectionState=$protState" 
    }
    
    if ($health -and $health -match "Critical|Failed") { 
        $reasons += "Health=$health" 
    }
    
    if ($reasons.Count -eq 0) { 
        return "Estado desconocido" 
    }
    
    return ($reasons -join ', ')
}

function Get-ReplicationHealthErrors {
    param([Parameter(Mandatory)]$Item)
    $errors = @()
    try {
        $healthErrors = Get-Prop $Item @("ReplicationHealthErrors", "HealthErrors")
        if ($healthErrors) {
            foreach ($e in @($healthErrors)) {
                $code    = Get-Prop $e @("ErrorCode", "Code")
                $msg     = Get-Prop $e @("ErrorMessage", "Message", "SummaryMessage")
                $sev     = Get-Prop $e @("ErrorLevel", "Severity", "Level")
                $source  = Get-Prop $e @("ErrorSource", "Source")
                $recomm  = Get-Prop $e @("RecommendedAction", "PossibleCauses")

                if ($msg) {
                    $errors += [pscustomobject]@{
                        Code        = if ($code) { $code } else { "N/A" }
                        Severity    = if ($sev) { $sev } else { "Warning" }
                        Source      = if ($source) { $source } else { "" }
                        Message     = $msg
                        Recommended = if ($recomm) { $recomm } else { "" }
                    }
                }
            }
        }
    } catch {}
    return $errors
}

function ConvertFrom-ArmResourceId {
    param([Parameter(Mandatory)][string]$Id)
    try {
        $parts = $Id.Trim().Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
        if (-not $parts -or $parts.Count -lt 6) { 
            return $null 
        }

        $lower = $parts | ForEach-Object { $_.ToLowerInvariant() }
        $subIndex = [Array]::IndexOf($lower, 'subscriptions')
        $rgIndex = [Array]::IndexOf($lower, 'resourcegroups')
        $provIndex = [Array]::IndexOf($lower, 'providers')

        if ($subIndex -lt 0 -or $rgIndex -lt 0 -or $provIndex -lt 0) { 
            return $null 
        }
        if ($subIndex + 1 -ge $parts.Count -or $rgIndex + 1 -ge $parts.Count) { 
            return $null 
        }
        if ($provIndex + 3 -ge $parts.Count) { 
            return $null 
        }

        return @{
            subscriptionId = $parts[$subIndex + 1]
            resourceGroup  = $parts[$rgIndex + 1]
            provider       = $parts[$provIndex + 1]
            rtype          = $parts[$provIndex + 2]
            name           = $parts[$provIndex + 3]
        }
    }
    catch { 
        return $null 
    }
}

function Test-DeadlineReached {
    return ((Get-Date) -gt $script:ScriptDeadline)
}


# ========================= POLLING MASIVO (LA MAGIA DE LA PARALELIZACION) =========================

function Wait-AsrJobsMasivo {
    param(
        [Parameter(Mandatory)][hashtable]$JobDict,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [int]$PollIntervalSeconds = 20,
        [int]$MaxConsecutiveFailures = 5
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $activeJobs = $JobDict.Clone()
    $totalJobs = $activeJobs.Count
    $failCounts = @{}
    foreach ($k in @($activeJobs.Keys)) { $failCounts[$k] = 0 }

    Write-Info "Iniciando polling masivo paralelo para $totalJobs jobs (MaxFallas=$MaxConsecutiveFailures, Timeout=${TimeoutMinutes}min)..."

    while ($activeJobs.Count -gt 0 -and (Get-Date) -lt $deadline -and -not (Test-DeadlineReached)) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $keys = @($activeJobs.Keys)

        foreach ($k in $keys) {
            try {
                $jobName = $activeJobs[$k]
                $j = Get-AzRecoveryServicesAsrJob -Name $jobName -ErrorAction Stop
                $failCounts[$k] = 0

                if ($j.State -notin @("InProgress", "NotStarted", "Running")) {
                    Write-Info ("Job de VM '$k' termino con estado: $($j.State)")
                    $activeJobs.Remove($k)
                }
            }
            catch {
                $failCounts[$k] = ($failCounts[$k] + 1)
                Write-Warn ("Error consultando job masivo para '{0}' (fallo {1}/{2}): {3}" -f $k, $failCounts[$k], $MaxConsecutiveFailures, $_.Exception.Message)
                if ($failCounts[$k] -ge $MaxConsecutiveFailures) {
                    Write-ErrL ("Job '{0}' removido del polling tras {1} fallas consecutivas. Se marcara como Unknown en Phase 2." -f $k, $MaxConsecutiveFailures)
                    $activeJobs.Remove($k)
                }
            }
        }
    }

    if ((Test-DeadlineReached) -and $activeJobs.Count -gt 0) {
        Write-Warn ("Deadline global del script alcanzado durante Polling Masivo. Quedan {0} jobs sin verificar." -f $activeJobs.Count)
    }
    elseif ($activeJobs.Count -gt 0) {
        Write-Warn ("Timeout local alcanzado en Polling Masivo. Quedaron {0} jobs colgados." -f $activeJobs.Count)
    }
}

function Wait-AsrJob {
    param(
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [int]$PollIntervalSeconds = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $job = $null
    $consecutiveFailures = 0
    $maxConsecutiveFailures = 3
    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $job = Get-AzRecoveryServicesAsrJob -Name $JobName -ErrorAction Stop
            $consecutiveFailures = 0
        }
        catch {
            $consecutiveFailures++
            Write-Warn ("Error consultando job '{0}' (intento {1}/{2}): {3}" -f $JobName, $consecutiveFailures, $maxConsecutiveFailures, $_.Exception.Message)
            if ($consecutiveFailures -ge $maxConsecutiveFailures) {
                throw ("No se pudo consultar el job ASR '{0}' tras {1} intentos consecutivos: {2}" -f $JobName, $maxConsecutiveFailures, $_.Exception.Message)
            }
            Start-Sleep -Seconds ([Math]::Min(30, $PollIntervalSeconds * $consecutiveFailures))
            continue
        }
        $task = $null
        if ($job -and $job.Tasks -and $job.Tasks.Count -gt 0) { $task = $job.Tasks[0].Name }
        $taskLabel = if ($task) { "($task)" } else { "" }
        Write-Info ("Job {0}: {1} {2}" -f $job.Name, $job.State, $taskLabel)
    } while ($job -and $job.State -in @("InProgress", "NotStarted", "Running") -and (Get-Date) -lt $deadline)
    return $job
}

# ========================= Boot Verification =========================

function Test-VmBootStatus {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [int]$MaxRetries = 5,
        [int]$IntervalSeconds = 180
    )

    $powerState = "unknown"
    $agentReady = $false

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Info ("Boot check intento {0}/{1} para '{2}' (espera {3}s)..." -f $attempt, $MaxRetries, $VmName, $IntervalSeconds)
        if ($attempt -gt 1) { 
            Start-Sleep -Seconds $IntervalSeconds 
        }

        try {
            $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        }
        catch {
            Write-Warn ("No se pudo obtener estado de VM '{0}': {1}" -f $VmName, $_.Exception.Message)
            continue
        }

        $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).Code
        $isRunning = ($powerState -eq 'PowerState/running')

        $agentReady = $false
        if ($vm.VMAgent -and $vm.VMAgent.Statuses) {
            $agentStatus = ($vm.VMAgent.Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' }).Code
            $agentReady = ($agentStatus -eq 'ProvisioningState/succeeded')
            if (-not $agentReady) {
                $agentReady = ($null -ne ($vm.VMAgent.Statuses | Where-Object { $_.DisplayStatus -eq 'Ready' }))
            }
        }

        Write-Info ("VM '{0}': PowerState={1}, AgentReady={2}" -f $VmName, $powerState, $agentReady)

        if ($isRunning -and $agentReady) {
            return [pscustomobject]@{ Booted = $true; Details = "PowerState=$powerState, Agent=Ready (intento $attempt/$MaxRetries)" }
        }
    }

    return [pscustomobject]@{ Booted = $false; Details = "Boot no verificado tras $MaxRetries intentos (PowerState=$powerState, AgentReady=$agentReady)" }
}

function Test-VmInternalNetworking {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName
    )
    
    $ScriptContent = @"
        `$result = @{
            Success        = `$false
            IP             = 'N/A'
            SubnetMask     = 'N/A'
            Gateway        = 'N/A'
            PingGateway    = 'N/A'
            PingGwDetail   = ''
            PingWireServer = 'N/A'
            DnsServers     = 'N/A'
            DnsResolve     = 'N/A (VNet aislada - informativo)'
            PingDnsServer  = 'N/A'
            NicStatus      = 'N/A'
            NicName        = 'N/A'
            NicMac         = 'N/A'
            DhcpEnabled    = 'N/A'
            FirewallICMP   = 'N/A'
            FirewallProfiles = 'N/A'
            RouteTable     = 'N/A'
            ArpEntries     = 'N/A'
            AllAdapters    = 'N/A'
            PingSubnetTest = 'N/A'
            TcpConnections = 'N/A'
            ErrorDetail    = ''
        }

        try {
            `$adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { `$_.Name -notmatch 'Loopback' }
            if (`$adapters) {
                `$result.AllAdapters = (`$adapters | ForEach-Object { "`$(`$_.Name):[`$(`$_.Status)]MAC:`$(`$_.MacAddress)" }) -join ' | '
                `$activeNic = `$adapters | Where-Object { `$_.Status -eq 'Up' } | Select-Object -First 1
                if (-not `$activeNic) { `$activeNic = `$adapters | Select-Object -First 1 }
                `$result.NicName   = `$activeNic.Name
                `$result.NicStatus = `$activeNic.Status
                `$result.NicMac    = `$activeNic.MacAddress
                try {
                    `$ipIntf = Get-NetIPInterface -InterfaceIndex `$activeNic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if (`$ipIntf) { `$result.DhcpEnabled = `$ipIntf.Dhcp }
                } catch {}
            } else {
                `$result.ErrorDetail = 'No se encontraron adaptadores de red.'
            }

            `$ipObj = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias '*' -ErrorAction SilentlyContinue | Where-Object { `$_.InterfaceAlias -notmatch 'Loopback' -and `$_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
            if (`$ipObj) {
                `$result.IP         = `$ipObj.IPAddress
                `$result.SubnetMask = `$ipObj.PrefixLength.ToString() + ' (/' + `$ipObj.PrefixLength.ToString() + ')'
            } else {
                `$result.ErrorDetail += ' No se detecto IP IPv4 asignada.'
            }

            `$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
            if (`$gw -and `$gw -ne '0.0.0.0') {
                `$result.Gateway = `$gw
                try {
                    `$pings = Test-Connection -ComputerName `$gw -Count 4 -ErrorAction SilentlyContinue
                    if (`$pings) {
                        `$received = @(`$pings | Where-Object { `$_.StatusCode -eq 0 -or `$_.Status -eq 'Success' }).Count
                        `$latencies = @(`$pings | ForEach-Object { if (`$_.PSObject.Properties['Latency']) { `$_.Latency } elseif (`$_.PSObject.Properties['ResponseTime']) { `$_.ResponseTime } })
                        `$avgMs = if (`$latencies.Count -gt 0) { [math]::Round((`$latencies | Measure-Object -Average).Average, 1) } else { -1 }
                        `$result.PingGateway = if (`$received -gt 0) { 'OK' } else { 'FAIL' }
                        `$result.PingGwDetail = "`${received}/4 recibidos, latencia prom: `${avgMs}ms"
                    } else {
                        `$result.PingGateway  = 'FAIL'
                        `$result.PingGwDetail = '0/4 recibidos - sin respuesta'
                    }
                } catch {
                    `$result.PingGateway  = 'ERROR'
                    `$result.PingGwDetail = "Exception: `$(`$_.Exception.Message)"
                }
            } else {
                `$result.Gateway     = 'NO_GATEWAY'
                `$result.PingGateway = 'N/A'
                `$result.ErrorDetail += ' No Default Gateway.'
            }

            try {
                if (`$ipObj -and `$ipObj.IPAddress) {
                    `$octets = `$ipObj.IPAddress.Split('.')
                    `$subnetFirst = "`$(`$octets[0]).`$(`$octets[1]).`$(`$octets[2]).1"
                    if (`$subnetFirst -ne `$ipObj.IPAddress) {
                        `$subPing = Test-Connection -ComputerName `$subnetFirst -Count 2 -Quiet -ErrorAction SilentlyContinue
                        `$result.PingSubnetTest = "Ping `$subnetFirst : `$(if (`$subPing) {'OK'} else {'FAIL'})"
                    } else {
                        `$result.PingSubnetTest = 'Skipped (VM es .1)'
                    }
                }
            } catch {
                `$result.PingSubnetTest = "ERROR: `$(`$_.Exception.Message)"
            }

            try {
                `$wsTcp = Test-NetConnection -ComputerName '168.63.129.16' -Port 80 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if (`$wsTcp -and `$wsTcp.TcpTestSucceeded) {
                    `$result.PingWireServer = 'OK (TCP:80 abierto)'
                } else {
                    `$result.PingWireServer = 'FAIL (TCP:80 cerrado o sin respuesta)'
                }
            } catch {
                `$result.PingWireServer = "ERROR: `$(`$_.Exception.Message)"
            }

            try {
                `$dnsConfig = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { `$_.InterfaceAlias -notmatch 'Loopback' -and `$_.ServerAddresses.Count -gt 0 } | Select-Object -First 1
                if (`$dnsConfig -and `$dnsConfig.ServerAddresses) {
                    `$result.DnsServers = (`$dnsConfig.ServerAddresses -join ', ')
                    `$primaryDns = `$dnsConfig.ServerAddresses[0]
                    `$dnsPing = Test-Connection -ComputerName `$primaryDns -Count 2 -Quiet -ErrorAction SilentlyContinue
                    `$result.PingDnsServer = if (`$dnsPing) { 'OK' } else { 'FAIL' }
                } else {
                    `$result.DnsServers    = 'NO_DNS'
                    `$result.PingDnsServer = 'N/A'
                }
            } catch {}

            try {
                `$dns = Resolve-DnsName -Name 'microsoft.com' -DnsOnly -ErrorAction Stop
                `$result.DnsResolve = 'OK (inesperado)'
            } catch {
                `$result.DnsResolve = 'FAIL (esperado)'
            }

            try {
                `$fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { "`$(`$_.Name):`$(if(`$_.Enabled){'ON'}else{'OFF'})" }
                `$result.FirewallProfiles = (`$fwProfiles -join ', ')
            } catch {}
            try {
                `$icmpRules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { `$_.DisplayName -match 'ICMPv4|Echo Request' }
                if (`$icmpRules) {
                    `$enabled = @(`$icmpRules | Where-Object { `$_.Enabled -eq 'True' -and `$_.Action -eq 'Allow' })
                    `$result.FirewallICMP = if (`$enabled.Count -gt 0) { "Permitido" } else { 'BLOQUEADO' }
                } else {
                    `$result.FirewallICMP = 'SIN_REGLAS_ICMP'
                }
            } catch {
                `$result.FirewallICMP = "ERROR: `$(`$_.Exception.Message)"
            }

            try {
                `$routes = Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { "`$(`$_.DestinationPrefix)->`$(`$_.NextHop)" }
                `$result.RouteTable = (`$routes -join ' | ')
            } catch {
                `$result.RouteTable = 'ERROR'
            }

            try {
                `$arp = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { `$_.State -ne 'Permanent' -and `$_.IPAddress -ne '255.255.255.255' } | Select-Object -First 10 | ForEach-Object { "`$(`$_.IPAddress)=`$(`$_.LinkLayerAddress)(`$(`$_.State))" }
                `$result.ArpEntries = if (`$arp) { (`$arp -join ' | ') } else { 'VACIA' }
            } catch {
                `$result.ArpEntries = 'ERROR'
            }

            try {
                `$tcp = Get-NetTCPConnection -State Established,Listen -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { "`$(`$_.LocalAddress):`$(`$_.LocalPort)->`$(`$_.RemoteAddress):`$(`$_.RemotePort)(`$(`$_.State))" }
                `$result.TcpConnections = if (`$tcp) { (`$tcp -join ' | ') } else { 'NINGUNA' }
            } catch {
                `$result.TcpConnections = 'ERROR'
            }

            `$nicOk       = (`$result.NicStatus -eq 'Up')
            `$hasIp       = (`$result.IP -ne 'N/A')
            `$wireServerOk = (`$result.PingWireServer -match 'OK')

            if (`$nicOk -and `$hasIp -and `$wireServerOk) {
                `$result.Success = `$true
            }

        } catch {
            `$result.ErrorDetail += " Exception general: `$(`$_.Exception.Message)"
        }

        `$result | ConvertTo-Json -Compress
"@
    
    Write-Info ("Ejecutando RunCommand de red en '{0}'..." -f $VmName)

    $runCmd = $null
    $rawOutput = ""
    try {
        $runCmd = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $ScriptContent `
            -ErrorAction Stop
    }
    catch {
        $errDetail = $_.Exception.Message
        Write-Warn ("RunCommand fallo para '{0}': {1}" -f $VmName, $errDetail)
        return [pscustomobject]@{
            Success = $false; IP = "?"; SubnetMask = "?"; Gateway = "?"; PingGateway = "?"
            PingGwDetail = ""; DnsServers = "?"; DnsResolve = "?"; PingDnsServer = "?"
            NicStatus = "?"; NicName = "?"; NicMac = "?"; DhcpEnabled = "?"; FirewallICMP = "?"
            FirewallProfiles = "?"; RouteTable = "?"; ArpEntries = "?"; AllAdapters = "?"
            PingSubnetTest = "?"; PingWireServer = "?"; TcpConnections = "?"
            ErrorDetail = "Invoke-AzVMRunCommand exception: $errDetail"
        }
    }

    try {
        if ($runCmd -and $runCmd.Value -and $runCmd.Value.Count -gt 0) {
            $rawOutput = $runCmd.Value[0].Message
        }
    }
    catch {
        Write-Warn ("No se pudo leer output del RunCommand: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ ErrorDetail = "No se pudo leer output." }
    }

    if (-not $rawOutput) {
        Write-Warn "RunCommand retorno output vacio."
        return [pscustomobject]@{ ErrorDetail = "RunCommand retorno output vacio." }
    }
    
    if ($rawOutput -match "(\{.*\})") {
        try {
            return ($matches[1] | ConvertFrom-Json)
        }
        catch {
            Write-Warn "JSON parse error."
            return [pscustomobject]@{ ErrorDetail = "JSON parse error." }
        }
    }
    else {
        return [pscustomobject]@{ ErrorDetail = "RunCommand no retorno JSON valido." }
    }
}
# ========================= OS Health Check =========================

function Test-VmOsHealth {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName
    )

    $ScriptContent = @"
        `$result = @{
            Success              = `$true
            CriticalErrors       = 'Ninguno'
            InformationalErrors  = ''
            FailedServices       = 'Ninguno'
            UptimeMinutes        = 'N/A'
            LastBootTime         = 'N/A'
            ErrorDetail          = ''
        }

        try {
            try {
                `$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                `$result.LastBootTime = `$os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
                `$result.UptimeMinutes = [math]::Round(((Get-Date) - `$os.LastBootUpTime).TotalMinutes, 1)
            } catch {
                `$result.UptimeMinutes = 'ERROR'
            }

            try {
                `$since = (Get-Date).AddMinutes(-30)
                `$critEvents = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=`$since} -MaxEvents 200 -ErrorAction SilentlyContinue

                `$isolatedVnetPatterns = @(
                    'domain controller','GroupPolicy','Group Policy','NETLOGON','secure session',
                    'secure channel','Kerberos','LsaSrv','KDC','LDAP','DNS Client','NlaSvc',
                    'Network Location Awareness','WinHTTP','WinINet','vmwTimeProvider','VMTools',
                    'VMware Tools','preshutdown control','transaction response from the VMTools',
                    'vmci','vmhgfs','VGAuth','Not running in a VM','GLPI','vsepflt','vfileFilter',
                    'Symantec','Broadcom','template-based certificate','RdAgent','RD Session Host',
                    'Kernel-Power','without cleanly shutting down','previous system shutdown',
                    'shutdown was unexpected','EventLog','TPM-WMI','Secure Boot certificates',
                    'Veeam','Zabbix','OMS','Microsoft Monitoring Agent','System Center','SCOM',
                    'Windows Update','wuauserv','SoftwareProtectionPlatform','SPPSvc',
                    'LicenseManager','CryptSvc'
                )

                `$filteredEvents = @()
                `$informationalEvents = @()
                `$skippedCount = 0
                if (`$critEvents) {
                    foreach (`$evt in `$critEvents) {
                        `$safeMsg = if (`$evt.Message) { `$evt.Message } else { "(sin descripcion: provider no registrado)" }
                        `$safeProv = if (`$evt.ProviderName) { `$evt.ProviderName } else { 'UnknownProvider' }
                        `$msgSnippet = `$safeMsg.Substring(0, [Math]::Min(300, `$safeMsg.Length))
                        `$isExpected = `$false
                        foreach (`$pattern in `$isolatedVnetPatterns) {
                            if (`$msgSnippet -match `$pattern -or `$safeProv -match `$pattern) { `$isExpected = `$true; break }
                        }
                        if (`$isExpected) { `$skippedCount++ }
                        else {
                            `$filteredEvents += `$evt
                            `$informationalEvents += "[`$(`$evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [`$safeProv] `$safeMsg"
                        }
                    }
                }

                `$result.InformationalErrors = ''
                if (`$filteredEvents.Count -gt 0) {
                    `$result.CriticalErrors = (`$filteredEvents | ForEach-Object {
                        `$m = if (`$_.Message) { `$_.Message } else { '(sin descripcion)' }
                        `$p = if (`$_.ProviderName) { `$_.ProviderName } else { 'Unknown' }
                        "[`$(`$_.TimeCreated.ToString('HH:mm:ss'))] `$p : `$(`$m.Substring(0, [Math]::Min(120, `$m.Length)))"
                    }) -join ' | '
                    `$result.InformationalErrors = (`$informationalEvents -join "`n")
                    `$result.Success = `$false
                } elseif (`$skippedCount -gt 0) {
                    `$result.CriticalErrors = "Ninguno real (`$skippedCount errores filtrados por VNet aislada/VMware/ASR)"
                }
            } catch {
                `$result.CriticalErrors = 'No se pudo leer Event Log'
            }

            `$criticalSvcs = @('EventLog','Winmgmt','RpcSs','Dhcp','LanmanWorkstation','W32Time')
            try {
                `$failedSvcs = @()
                foreach (`$svc in `$criticalSvcs) {
                    `$s = Get-Service -Name `$svc -ErrorAction SilentlyContinue
                    if (`$s -and `$s.Status -ne 'Running') {
                        `$failedSvcs += "`$(`$svc):(`$(`$s.Status))"
                    }
                }
                if (`$failedSvcs.Count -gt 0) {
                    `$result.FailedServices = (`$failedSvcs -join ', ')
                    `$result.Success = `$false
                }
            } catch {
                `$result.FailedServices = 'ERROR'
            }

        } catch {
            `$result.ErrorDetail = `$_.Exception.Message
            `$result.Success = `$false
        }

        `$result | ConvertTo-Json -Compress
"@

    Write-Info ("Ejecutando OS Health check en '{0}'..." -f $VmName)

    $runCmd = $null
    try {
        $runCmd = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $ScriptContent `
            -ErrorAction Stop
    }
    catch {
        Write-Warn ("OS Health RunCommand fallo para '{0}': {1}" -f $VmName, $_.Exception.Message)
        return [pscustomobject]@{ ErrorDetail = "RunCommand exception: $($_.Exception.Message)" }
    }

    $rawOutput = ""
    try {
        if ($runCmd -and $runCmd.Value -and $runCmd.Value.Count -gt 0) {
            $rawOutput = $runCmd.Value[0].Message
        }
    }
    catch { return [pscustomobject]@{ ErrorDetail = "No se pudo leer output." } }

    if ($rawOutput -match "(\{.*\})") {
        try { return ($matches[1] | ConvertFrom-Json) }
        catch { return [pscustomobject]@{ ErrorDetail = "JSON parse error." } }
    }
    else { return [pscustomobject]@{ ErrorDetail = "RunCommand output vacio o invalido." } }
}

# ========================= Disk Validation =========================

function Test-VmDiskHealth {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName
    )

    $ScriptContent = @"
        `$result = @{
            Success      = `$true
            Disks        = 'N/A'
            Volumes      = 'N/A'
            OfflineDisks = 'Ninguno'
            Issues       = 'Ninguno'
            DiskSizesGB  = 'N/A'
            DiskDetails  = 'N/A'
            ErrorDetail  = ''
        }

        try {
            try {
                `$disks = Get-Disk -ErrorAction Stop
                `$diskInfo = @()
                `$offlineList = @()
                `$diskDetailList = @()
                foreach (`$d in `$disks) {
                    `$sizeGB = [math]::Round(`$d.Size / 1GB, 1)
                    `$diskInfo += "Disk`$(`$d.Number):`$(`$d.FriendlyName)(`${sizeGB}GB,`$(`$d.OperationalStatus))"
                    `$diskDetailList += "`$(`$d.Number):`${sizeGB}:`$(`$d.OperationalStatus)"
                    if (`$d.OperationalStatus -ne 'Online') {
                        `$offlineList += "Disk`$(`$d.Number):Offline(`${sizeGB}GB)"
                    }
                }
                `$result.Disks = (`$diskInfo -join ' | ')
                `$result.DiskDetails = (`$diskDetailList -join ',')
                `$allSizes = (`$disks | ForEach-Object { [math]::Round(`$_.Size / 1GB, 1) }) | Sort-Object
                `$result.DiskSizesGB = (`$allSizes -join ',')
                if (`$offlineList.Count -gt 0) {
                    `$result.OfflineDisks = (`$offlineList -join ', ')
                }
            } catch {
                `$result.Disks = "ERROR: `$(`$_.Exception.Message)"
                `$result.Success = `$false
            }

            try {
                `$vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { `$_.DriveLetter -and `$_.DriveType -eq 'Fixed' }
                `$volInfo = @()
                `$issues = @()
                foreach (`$v in `$vols) {
                    `$totalGB = [math]::Round(`$v.Size / 1GB, 1)
                    `$freeGB = [math]::Round(`$v.SizeRemaining / 1GB, 1)
                    `$freePercent = if (`$v.Size -gt 0) { [math]::Round((`$v.SizeRemaining / `$v.Size) * 100, 0) } else { 0 }
                    `$label = if (`$v.FileSystemLabel) { `$v.FileSystemLabel } else { 'Sin etiqueta' }
                    `$volInfo += "`$(`$v.DriveLetter):(`$label,`${totalGB}GB,Libre:`${freeGB}GB/`${freePercent}%,`$(`$v.HealthStatus))"

                    if (`$v.HealthStatus -ne 'Healthy') {
                        `$issues += "`$(`$v.DriveLetter): HealthStatus=`$(`$v.HealthStatus)"
                        `$result.Success = `$false
                    }
                    if (`$freePercent -lt 5 -and `$totalGB -gt 1) {
                        `$issues += "`$(`$v.DriveLetter): Disco casi lleno (`${freePercent}% libre)"
                    }
                }
                `$result.Volumes = if (`$volInfo.Count -gt 0) { (`$volInfo -join ' | ') } else { 'Sin volumenes Fixed detectados' }
                if (`$issues.Count -gt 0) {
                    `$result.Issues = (`$issues -join '; ')
                }
            } catch {
                `$result.Volumes = "ERROR: `$(`$_.Exception.Message)"
            }

        } catch {
            `$result.ErrorDetail = `$_.Exception.Message
            `$result.Success = `$false
        }

        `$result | ConvertTo-Json -Compress
"@

    Write-Info ("Ejecutando validacion de discos en '{0}'..." -f $VmName)

    $runCmd = $null
    try {
        $runCmd = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $ScriptContent `
            -ErrorAction Stop
    }
    catch {
        Write-Warn ("Disk Health RunCommand fallo para '{0}': {1}" -f $VmName, $_.Exception.Message)
        return [pscustomobject]@{ ErrorDetail = "RunCommand exception: $($_.Exception.Message)" }
    }

    $rawOutput = ""
    try {
        if ($runCmd -and $runCmd.Value -and $runCmd.Value.Count -gt 0) {
            $rawOutput = $runCmd.Value[0].Message
        }
    }
    catch { return [pscustomobject]@{ ErrorDetail = "No se pudo leer output." } }

    if ($rawOutput -match "(\{.*\})") {
        try { return ($matches[1] | ConvertFrom-Json) }
        catch { return [pscustomobject]@{ ErrorDetail = "JSON parse error." } }
    }
    else { return [pscustomobject]@{ ErrorDetail = "RunCommand output vacio o invalido." } }
}

# ========================= SQL Health Check =========================

function Test-VmSqlHealth {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName
    )

    $ScriptContent = @"
        `$result = @{ HasSql = `$false; SqlStatus = 'N/A'; SqlVersion = 'N/A'; QueryResult = 'N/A'; ServiceName = 'N/A'; InstanceName = 'N/A'; StartType = 'N/A'; ErrorDetail = '' }
        try {
            `$sqlSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { `$_.Name -match '^MSSQL(\`$|SERVER)' -and `$_.Name -notmatch 'WID|SSEE' } | Select-Object -First 1
            if (-not `$sqlSvc) {
                `$result.SqlStatus = 'NO_SQL_INSTALLED'
                `$result | ConvertTo-Json -Compress
                return
            }
            `$result.HasSql = `$true
            `$result.ServiceName = `$sqlSvc.Name
            `$result.SqlStatus = `$sqlSvc.Status.ToString()
            `$result.StartType = `$sqlSvc.StartType.ToString()

            if (`$sqlSvc.Name -eq 'MSSQLSERVER') {
                `$instanceName = 'localhost'
            } else {
                `$namedPart = `$sqlSvc.Name -replace '^MSSQL\`$', ''
                `$instanceName = "localhost\`$namedPart"
            }
            `$result.InstanceName = `$instanceName

            if (`$sqlSvc.Status -eq 'Running') {
                `$browserSvc = Get-Service -Name 'SQLBrowser' -ErrorAction SilentlyContinue
                `$browserRunning = (`$browserSvc -and `$browserSvc.Status -eq 'Running')

                `$connectTo = `$instanceName
                if (`$instanceName -ne 'localhost' -and -not `$browserRunning) {
                    try {
                        `$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\`$(`$namedPart)\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                        `$port = (Get-ItemProperty -Path `$regPath -ErrorAction SilentlyContinue).TcpPort
                        if (-not `$port) { `$port = (Get-ItemProperty -Path `$regPath -ErrorAction SilentlyContinue).TcpDynamicPorts }
                        if (`$port) { `$connectTo = "localhost,`$port" }
                    } catch {}
                }

                `$hasSqlCmd = [bool](Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)
                if (`$hasSqlCmd) {
                    try {
                        `$ver = Invoke-Sqlcmd -ServerInstance `$connectTo -Query 'SELECT @@VERSION AS Ver' -QueryTimeout 15 -ErrorAction Stop
                        `$result.SqlVersion = `$ver.Ver.Substring(0, [Math]::Min(80, `$ver.Ver.Length))
                        try {
                            `$dbCheck = Invoke-Sqlcmd -ServerInstance `$connectTo -Query "SELECT name, state_desc FROM sys.databases WHERE state_desc != 'ONLINE'" -QueryTimeout 15 -ErrorAction Stop
                            if (`$dbCheck -and @(`$dbCheck).Count -gt 0) {
                                `$result.QueryResult = "DBs no-online: `$((@(`$dbCheck) | ForEach-Object { "`$(`$_.name):`$(`$_.state_desc)" }) -join ', ')"
                            } else {
                                `$result.QueryResult = 'Todas las DBs ONLINE'
                            }
                        } catch {
                            `$result.QueryResult = "Error consultando DBs: `$(`$_.Exception.Message)"
                        }
                    } catch {
                        `$errMsg = `$_.Exception.Message
                        if (`$errMsg -match "Login failed for user 'NT AUTHORITY\\SYSTEM'") {
                            `$result.SqlVersion = 'Desconocida (Acceso denegado a SYSTEM)'
                            `$result.QueryResult = 'Estado DBs: Desconocido (Falta permiso sysadmin para NT AUTHORITY\SYSTEM)'
                        } else {
                            `$result.SqlVersion = 'Error: sin acceso'
                            `$result.ErrorDetail = "Conexion Invoke-Sqlcmd a '`$connectTo' fallo: `$errMsg"
                        }
                    }
                } else {
                    try {
                        `$serverForClient = `$connectTo -replace ',', ','
                        `$connStr = "Server=`$serverForClient;Database=master;Integrated Security=True;Connection Timeout=15"
                        `$conn = New-Object System.Data.SqlClient.SqlConnection(`$connStr)
                        `$conn.Open()
                        `$cmd = `$conn.CreateCommand(); `$cmd.CommandTimeout = 15; `$cmd.CommandText = 'SELECT @@VERSION'
                        `$verStr = [string]`$cmd.ExecuteScalar()
                        if (`$verStr) { `$result.SqlVersion = `$verStr.Substring(0, [Math]::Min(80, `$verStr.Length)) }
                        try {
                            `$cmd.CommandText = "SELECT name, state_desc FROM sys.databases WHERE state_desc != 'ONLINE'"
                            `$reader = `$cmd.ExecuteReader()
                            `$rows = @()
                            while (`$reader.Read()) { `$rows += "`$(`$reader['name']):`$(`$reader['state_desc'])" }
                            `$reader.Close()
                            if (`$rows.Count -gt 0) { `$result.QueryResult = "DBs no-online: `$(`$rows -join ', ')" }
                            else { `$result.QueryResult = 'Todas las DBs ONLINE' }
                        } catch {
                            `$result.QueryResult = "Error consultando DBs (SqlClient): `$(`$_.Exception.Message)"
                        }
                        `$conn.Close()
                    } catch {
                        `$errMsg = `$_.Exception.Message
                        if (`$errMsg -match "Login failed for user 'NT AUTHORITY\\SYSTEM'") {
                            `$result.SqlVersion = 'Desconocida (Acceso denegado a SYSTEM)'
                            `$result.QueryResult = 'Estado DBs: Desconocido (Falta permiso sysadmin para NT AUTHORITY\SYSTEM)'
                        } else {
                            `$result.SqlVersion = 'Error: sin acceso (SqlClient)'
                            `$result.ErrorDetail = "Conexion SqlClient a '`$connectTo' fallo: `$errMsg"
                        }
                    }
                }
            } else {
                `$result.ErrorDetail = "Servicio SQL detenido: `$(`$sqlSvc.Status)"
            }
        } catch {
            `$result.ErrorDetail = `$_.Exception.Message
        }
        `$result | ConvertTo-Json -Compress
"@

    Write-Info ("Ejecutando SQL Health check en '{0}'..." -f $VmName)

    $runCmd = $null
    try {
        $runCmd = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName `
            -VMName $VmName `
            -CommandId 'RunPowerShellScript' `
            -ScriptString $ScriptContent `
            -ErrorAction Stop
    }
    catch {
        Write-Warn ("SQL Health RunCommand fallo para '{0}': {1}" -f $VmName, $_.Exception.Message)
        return [pscustomobject]@{ HasSql = $false; ErrorDetail = "RunCommand exception: $($_.Exception.Message)" }
    }

    $rawOutput = ""
    try {
        if ($runCmd -and $runCmd.Value -and $runCmd.Value.Count -gt 0) {
            $rawOutput = $runCmd.Value[0].Message
        }
    }
    catch { return [pscustomobject]@{ HasSql = $false; ErrorDetail = "No se pudo leer output." } }

    if ($rawOutput -match "(\{.*\})") {
        try { return ($matches[1] | ConvertFrom-Json) }
        catch { return [pscustomobject]@{ HasSql = $false; ErrorDetail = "JSON parse error." } }
    }
    else { return [pscustomobject]@{ HasSql = $false; ErrorDetail = "RunCommand output vacio o invalido." } }
}

# ========================= Reporte HTML =========================

function Build-ReportHtml {
    param($vault, $ctx, $testVnetId, $vmResults, $summary)

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $total = 0; $ok = 0; $fail = 0; $percent = 0
    if ($vmResults) {
        $total = $vmResults.Count
        $ok = ($vmResults | Where-Object { $_.status -eq "Succeeded" }).Count
        $fail = ($vmResults | Where-Object { $_.status -eq "Failed" }).Count
        if ($total -gt 0) { $percent = [math]::Round(($ok / $total) * 100) }
    }

    $barColor = if ($percent -ge 80) { "#198754" } elseif ($percent -ge 50) { "#e6a817" } else { "#dc3545" }

    $rowIndex = 0
    $rows = ""
    if ($total -gt 0) {
        $rows = ($vmResults | ForEach-Object {
                $rowIndex++

                # Badge Failover
                $tfoBg  = switch ($_.status) { "Succeeded" { "#d1e7dd" } "Failed" { "#f8d7da" } default { "#fff3cd" } }
                $tfoTxt = switch ($_.status) { "Succeeded" { "#0f5132" } "Failed" { "#842029" } default { "#664d03" } }

                # Badge Boot
                $bootBg  = switch ($_.bootStatus) { "Booted" { "#d1e7dd" } "Failed" { "#f8d7da" } default { "#e9ecef" } }
                $bootTxt = switch ($_.bootStatus) { "Booted" { "#0f5132" } "Failed" { "#842029" } default { "#495057" } }

                # Badge Red
                $netBg  = switch ($_.netStatus) { "OK" { "#d1e7dd" } "Failed" { "#f8d7da" } "Error" { "#f8d7da" } default { "#e9ecef" } }
                $netTxt = switch ($_.netStatus) { "OK" { "#0f5132" } "Failed" { "#842029" } "Error" { "#842029" } default { "#495057" } }

                # Badge OS Health
                $osBg  = switch ($_.osHealthStatus) { "OK" { "#d1e7dd" } "Warning" { "#fff3cd" } "Error" { "#f8d7da" } default { "#e9ecef" } }
                $osTxt = switch ($_.osHealthStatus) { "OK" { "#0f5132" } "Warning" { "#664d03" } "Error" { "#842029" } default { "#495057" } }

                # Badge Discos
                $diskBg  = switch ($_.diskHealthStatus) { "OK" { "#d1e7dd" } "Warning" { "#fff3cd" } "Error" { "#f8d7da" } default { "#e9ecef" } }
                $diskTxt = switch ($_.diskHealthStatus) { "OK" { "#0f5132" } "Warning" { "#664d03" } "Error" { "#842029" } default { "#495057" } }

                # Badge SQL
                $sqlBg  = switch ($_.sqlStatus) { "OK" { "#d1e7dd" } "Warning" { "#fff3cd" } "Failed" { "#f8d7da" } "Error" { "#f8d7da" } "Stopped" { "#e9ecef" } default { "#e9ecef" } }
                $sqlTxt = switch ($_.sqlStatus) { "OK" { "#0f5132" } "Warning" { "#664d03" } "Failed" { "#842029" } "Error" { "#842029" } "Stopped" { "#495057" } default { "#495057" } }

                # RPO color
                $rpDisplay = ConvertTo-HtmlSafe $_.rpAge
                $rpBg = "#e9ecef"; $rpTx = "#495057"
                if ($_.rpAge -match '(\d+\.?\d*)h') {
                    $h = [double]$matches[1]
                    if ($h -le 4) { $rpBg = "#d1e7dd"; $rpTx = "#0f5132" }
                    elseif ($h -le 24) { $rpBg = "#fff3cd"; $rpTx = "#664d03" }
                    else { $rpBg = "#f8d7da"; $rpTx = "#842029" }
                }

                $safeVmName   = ConvertTo-HtmlSafe $_.vmName
                $safeCleanSummary = ConvertTo-HtmlSafe ("IP: $($_.testVmIp) | Duracion: $($_.duration)")
                $safeFullNotes = ConvertTo-HtmlSafe $_.notes

                $notesHtml = "<div style='font-size:12px;color:#495057;margin-bottom:4px;'>$safeCleanSummary</div>
                    <details>
                        <summary style='cursor:pointer;font-size:11px;color:#0d6efd;'>Ver detalle</summary>
                        <div style='margin-top:6px;padding:8px 10px;background:#f8f9fa;border-radius:6px;font-size:11px;line-height:1.5;color:#495057;word-break:break-word;white-space:pre-wrap;'>$safeFullNotes</div>
                    </details>"

                "<tr>
                    <td style='font-weight:600;'>$safeVmName</td>
                    <td style='text-align:center;'><span class='badge' style='background:$tfoBg;color:$tfoTxt;'>$($_.status)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$bootBg;color:$bootTxt;'>$($_.bootStatus)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$netBg;color:$netTxt;'>$($_.netStatus)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$osBg;color:$osTxt;'>$($_.osHealthStatus)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$diskBg;color:$diskTxt;'>$($_.diskHealthStatus)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$sqlBg;color:$sqlTxt;'>$($_.sqlStatus)</span></td>
                    <td style='text-align:center;'><span class='badge' style='background:$rpBg;color:$rpTx;'>$rpDisplay</span></td>
                    <td class='notes-cell'>$notesHtml</td>
                </tr>"
            }) -join "`n"
    }
    else {
        $rows = "<tr><td colspan='9' style='text-align:center;color:#888;padding:24px;font-style:italic;'>No se procesaron items/VMs.</td></tr>"
    }

    $safeVaultName = ConvertTo-HtmlSafe $vault.Name
    $safeVaultRg   = ConvertTo-HtmlSafe $vault.ResourceGroupName
    $safeSubName   = ConvertTo-HtmlSafe $ctx.Subscription.Name
    $safeVnet      = ConvertTo-HtmlSafe $testVnetId
    $safeSummary   = ConvertTo-HtmlSafe $summary

    @"
<!DOCTYPE html>
<html>
<head>
    <meta charset='utf-8'>
    <style>
        * { box-sizing: border-box; }
        body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background-color: #f0f2f5; color: #333; margin: 0; padding: 24px; }
        .container { max-width: 980px; margin: 0 auto; }
        .header-card { background: #fff; border-radius: 10px; padding: 28px 32px; margin-bottom: 20px; border: 1px solid #e3e6ea; }
        .report-label { font-size: 11px; font-weight: 600; letter-spacing: 1.5px; color: #6c757d; text-transform: uppercase; margin: 0 0 4px; }
        .report-title { font-size: 22px; font-weight: 600; color: #1a1a2e; margin: 0 0 20px; }
        .meta-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6px 32px; font-size: 13px; color: #555; line-height: 1.6; }
        .meta-grid strong { color: #333; }
        .dashboard { display: flex; gap: 14px; margin-bottom: 20px; }
        .card { flex: 1; background: #fff; border-radius: 10px; padding: 20px 16px; text-align: center; border: 1px solid #e3e6ea; }
        .card-title { font-size: 11px; font-weight: 600; letter-spacing: 1px; color: #6c757d; text-transform: uppercase; margin-bottom: 8px; }
        .card-value { font-size: 30px; font-weight: 700; }
        .val-total { color: #495057; }
        .val-ok { color: #198754; }
        .val-err { color: #dc3545; }
        .val-sla { color: #1a1a2e; }
        .progress-card { background: #fff; border-radius: 10px; padding: 18px 28px; margin-bottom: 20px; border: 1px solid #e3e6ea; }
        .progress-label { display: flex; justify-content: space-between; font-size: 12px; font-weight: 600; color: #495057; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 8px; }
        .progress-bg { background-color: #e9ecef; border-radius: 4px; height: 8px; overflow: hidden; }
        .progress-fill { height: 100%; border-radius: 4px; background-color: ${barColor}; width: ${percent}%; }
        .table-card { background: #fff; border-radius: 10px; border: 1px solid #e3e6ea; overflow: hidden; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #f8f9fa; color: #495057; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.8px; padding: 14px 12px; text-align: left; border-bottom: 1px solid #dee2e6; }
        td { padding: 14px 12px; font-size: 13px; border-bottom: 1px solid #f0f0f0; vertical-align: middle; }
        tr:last-child td { border-bottom: none; }
        .badge { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: 11px; font-weight: 600; }
        .notes-cell { font-size: 12px; color: #6c757d; line-height: 1.4; min-width: 200px; }
        details summary { cursor: pointer; list-style: none; }
        details summary::-webkit-details-marker { display: none; }
        details summary::after { content: ' \25BC'; font-size: 9px; color: #0d6efd; }
        details[open] summary::after { content: ' \25B2'; }
    </style>
</head>
<body>
    <div class='container'>
        <div class='header-card'>
            <p class='report-label'>Reporte ejecutivo</p>
            <p class='report-title'>ASR Test Failover</p>
            <div class='meta-grid'>
                <div><strong>Fecha ejecuci&oacute;n:</strong> $ts</div>
                <div><strong>Suscripci&oacute;n:</strong> $safeSubName</div>
                <div><strong>Recovery Vault:</strong> $safeVaultName / $safeVaultRg</div>
                <div><strong>VNet de prueba:</strong> $safeVnet</div>
            </div>
            <div style="margin-top: 12px; font-size: 13px; color: #555;"><strong>Resumen:</strong> $safeSummary</div>
        </div>
        <div class='dashboard'>
            <div class='card'><div class='card-title'>Total VMs</div><div class='card-value val-total'>$total</div></div>
            <div class='card'><div class='card-title'>Exitosas</div><div class='card-value val-ok'>$ok</div></div>
            <div class='card'><div class='card-title'>Fallidas</div><div class='card-value val-err'>$fail</div></div>
            <div class='card'><div class='card-title'>SLA</div><div class='card-value val-sla'>${percent}%</div></div>
        </div>
        <div class='progress-card'>
            <div class='progress-label'><span>Cumplimiento SLA Test Failover</span><span>${percent}%</span></div>
            <div class='progress-bg'><div class='progress-fill'></div></div>
        </div>
        <div class='table-card'>
            <table>
                <thead>
                    <tr>
                        <th>Servidor</th>
                        <th style='text-align:center;'>Failover</th>
                        <th style='text-align:center;'>Booteo</th>
                        <th style='text-align:center;'>Red</th>
                        <th style='text-align:center;'>OS Health</th>
                        <th style='text-align:center;'>Discos</th>
                        <th style='text-align:center;'>SQL</th>
                        <th style='text-align:center;'>RPO</th>
                        <th>Notas</th>
                    </tr>
                </thead>
                <tbody>$rows</tbody>
            </table>
        </div>
    </div>
</body>
</html>
"@
}

# ========================= Envio de Reporte =========================

function Send-Report {
    param(
        [string]$SummaryOverride = $null,
        [string]$SubjectSuffix = ""
    )
    try {
        if ([string]::IsNullOrWhiteSpace($LogicAppWebhookUrl)) { 
            Write-ErrL "LogicAppWebhookUrl vacio. No se puede enviar reporte."
            return 
        }
        
        if (-not $script:vmResults) { 
            Write-Warn "No hay resultados de VM para reportar."
            return 
        }

        $rTotal = $script:vmResults.Count
        $rOk    = ($script:vmResults | Where-Object { $_.status -eq "Succeeded" }).Count
        $rFail  = ($script:vmResults | Where-Object { $_.status -eq "Failed" }).Count
        $rSummary = if ($SummaryOverride) { $SummaryOverride } else { "Procesadas: $rTotal | OK: $rOk | Failed: $rFail" }

        $rVault = if (Get-Variable -Name "vault" -Scope Script -ErrorAction SilentlyContinue) { $script:vault } else { [pscustomobject]@{ Name = "N/A"; ResourceGroupName = "N/A" } }
        $rCtx   = if (Get-Variable -Name "ctx" -Scope Script -ErrorAction SilentlyContinue) { $script:ctx } else { [pscustomobject]@{ Subscription = @{ Name = "N/A"; Id = "N/A" } } }

        $html = Build-ReportHtml -vault $rVault -ctx $rCtx -testVnetId $TestVnetResourceId -vmResults $script:vmResults -summary $rSummary
        $tmpHtml = Join-Path $env:TEMP ("ASR-TFO-Report-{0}.html" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        $html | Out-File -FilePath $tmpHtml -Encoding UTF8

        $rawLog = ($script:LogBuffer -join [Environment]::NewLine)
        $rawLogBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rawLog))
        $overall = if ($rFail -eq 0 -and -not $SubjectSuffix) { "Succeeded" } else { "Failed" }

        $vmResultsArray = @($script:vmResults | ForEach-Object { $_ })

        $subjectFinal = $MailSubject
        if ($SubjectSuffix) { 
            $subjectFinal += " $SubjectSuffix" 
        }

        $infoErrorsBase64 = ""
        $infoErrorsContent = @()
        foreach ($vmr in $script:vmResults) {
            if ($vmr.osInfoErrors) {
                $infoErrorsContent += "=========================================="
                $infoErrorsContent += "VM: $($vmr.vmName)"
                $infoErrorsContent += "=========================================="
                $infoErrorsContent += $vmr.osInfoErrors
                $infoErrorsContent += ""
            }
        }
        
        if ($infoErrorsContent.Count -gt 0) {
            $infoHeader = @("ERRORES INFORMATIVOS DETECTADOS","Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')","")
            $infoTxt = ($infoHeader + $infoErrorsContent) -join "`n"
            $infoErrorsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($infoTxt))
        } else {
            $infoTxt = "Sin errores informativos.`nFecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            $infoErrorsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($infoTxt))
        }

        $payload = [ordered]@{
            subscription       = @{ name = $rCtx.Subscription.Name; id = $rCtx.Subscription.Id }
            vault              = @{ name = $rVault.Name; rg = $rVault.ResourceGroupName }
            testVnet           = @{ id = $TestVnetResourceId }
            overallStatus      = $overall
            summary            = $rSummary
            vmResults          = $vmResultsArray
            htmlReportBase64   = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmpHtml))
            rawLogBase64       = $rawLogBase64
            infoErrorsBase64   = $infoErrorsBase64
            sendTo             = $MailTo
            subject            = $subjectFinal
        }

        $headers = @{}
        if (Get-Variable -Name "LogicAppApiKey" -ErrorAction SilentlyContinue) { 
            $headers["x-api-key"] = $LogicAppApiKey 
        }
        
        $jsonBody = $payload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Method POST -Uri $LogicAppWebhookUrl -Headers $headers -Body $jsonBody -ContentType "application/json" -TimeoutSec 120 | Out-Null
        Write-Info ("Reporte enviado a: {0}" -f ($MailTo -join ', '))
    }
    catch { 
        Write-ErrL ("Error al enviar reporte: {0}" -f $_.Exception.Message) 
    }
}

# ========================= Trap Global =========================

$script:vmResults = [System.Collections.Generic.List[object]]::new()
$script:vault = $null
$script:ctx = $null
$script:TrapFired = $false

trap {
    if ($script:TrapFired) { 
        continue 
    }
    
    $script:TrapFired = $true
    Write-ErrL "ERROR FATAL NO CONTROLADO: $($_.Exception.Message)"
    
    if ($script:vmResults -and $script:vmResults.Count -gt 0) {
        Write-Warn "Intentando enviar reporte parcial..."
        try { 
            Send-Report -SummaryOverride "REPORTE PARCIAL - Script interrumpido. Procesadas: $($script:vmResults.Count)" -SubjectSuffix "(PARCIAL - Error)" 
        } catch {}
    }
    continue
}

# ========================= INICIO DE EJECUCION Y SETUP =========================

Write-Section "Iniciando autenticacion (MI) y contexto"
try {
    $acct = Connect-AzAccount -Identity -ErrorAction Stop
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $ctx = Get-AzContext
    $script:ctx = $ctx
    Write-Info ("Contexto en suscripcion: {0}" -f $ctx.Subscription.Name)
} catch { throw "Fallo la autenticacion" }

try {
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName ${VaultResourceGroup} -Name $VaultName -ErrorAction Stop
    $script:vault = $vault
    Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop | Out-Null
} catch { throw "Fallo la configuracion del Vault" }

$vparts = ConvertFrom-ArmResourceId -Id $TestVnetResourceId
if (-not $vparts) { 
    throw "TestVnetResourceId no tiene formato ARM valido." 
}

try {
    Get-AzVirtualNetwork -ResourceGroupName $vparts.resourceGroup -Name $vparts.name -ErrorAction Stop | Out-Null
    Write-Info "VNet de test existe."
} catch { 
    throw "La VNet de test no existe o no es accesible." 
}

$fabrics = Get-AzRecoveryServicesAsrFabric -ErrorAction Stop
$containers = [System.Collections.Generic.List[object]]::new()
foreach ($f in $fabrics) { 
    Get-AzRecoveryServicesAsrProtectionContainer -Fabric $f | ForEach-Object { $containers.Add($_) } 
}

$allItems = [System.Collections.Generic.List[object]]::new()
foreach ($pc in $containers) { 
    Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $pc | ForEach-Object { $allItems.Add($_) } 
}

$filtered = $allItems
if ($MaxItems -gt 0) { 
    $filtered = $filtered | Select-Object -First $MaxItems 
}
Write-Info ("Items a procesar: {0}" -f ($filtered.Count))

$script:AllVmsCache = @(Get-AzVM -ResourceGroupName ${VaultResourceGroup} -Status -ErrorAction SilentlyContinue)

# Capturar cuerpos de funciones para inyectar en Start-ThreadJob (paralelizacion intra-VM en Phase 3).
# Los ThreadJobs corren en runspaces separados y no ven las funciones del parent; las reinyectamos via Set-Item function:.
$script:FnNetDef  = ${function:Test-VmInternalNetworking}.ToString()
$script:FnOsDef   = ${function:Test-VmOsHealth}.ToString()
$script:FnDiskDef = ${function:Test-VmDiskHealth}.ToString()
$script:FnSqlDef  = ${function:Test-VmSqlHealth}.ToString()

# Verificar que Start-ThreadJob este disponible (PS 7+, Azure Automation runbooks PowerShell 7.2 lo soportan).
# Intentamos forzar la carga manual si Get-Command no lo ve inicialmente
# Intentamos forzar la carga si Get-Command no lo ve al inicio
# Forzamos la importacion usando el nombre completo del modulo para evitar ambiguedades
# Diagnostico: ¿Que version estamos corriendo y que modulos hay?
# Diagnostico avanzado usando la ruta que ya conocemos
# Intentamos cargar ambos posibles nombres del modulo
$threadModules = @("Microsoft.PowerShell.ThreadJob", "ThreadJob")

foreach ($m in $threadModules) {
    try {
        Import-Module -Name $m -ErrorAction SilentlyContinue
        if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
            Write-Info "Modulo $m cargado y comando Start-ThreadJob detectado."
            break
        }
    } catch { }
}

# Verificacion final
if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $script:UseParallelValidations = $true
    Write-Info "¡EXITO! Phase 3 usara paralelizacion intra-VM."
} else {
    Write-Warn "Start-ThreadJob sigue invisible. Revisa si 'Microsoft.PowerShell.ThreadJob' esta instalado en el Portal."
    $script:UseParallelValidations = $false
}

$cmdStartTfo = Get-Command Start-AzRecoveryServicesAsrTestFailoverJob -ErrorAction Stop
$startParams = $cmdStartTfo.Parameters.Keys
$paramNetwork = if ($startParams -contains "AzureVMNetworkId") { "AzureVMNetworkId" } elseif ($startParams -contains "NetworkId") { "NetworkId" } else { "AzureVMNetworkId" }
$paramItem = if ($startParams -contains "ReplicationProtectedItem") { "ReplicationProtectedItem" } else { "ReplicationProtectedItemId" }

$cmdCleanup = Get-Command Start-AzRecoveryServicesAsrTestFailoverCleanupJob -ErrorAction SilentlyContinue
$cleanupParams = if ($cmdCleanup) { $cmdCleanup.Parameters.Keys } else { @() }

function Invoke-ItemCleanup {
    param($Item, [string]$Phase, [int]$TimeoutMinutes = 60)
    if (-not $cmdCleanup) { return $null }

    $cargs = @{}
    if ($cleanupParams -contains "Comment") {
        $cargs["Comment"] = "$Phase automatico"
    }

    if ($cleanupParams -contains "ReplicationProtectedItem") {
        $cargs["ReplicationProtectedItem"] = $Item
    }
    else {
        $cargs["ReplicationProtectedItemId"] = (Get-Prop $Item @("Id", "ID"))
    }

    $cjob = Start-AzRecoveryServicesAsrTestFailoverCleanupJob @cargs -ErrorAction Stop
    return (Wait-AsrJob -JobName $cjob.Name -TimeoutMinutes $TimeoutMinutes -PollIntervalSeconds $JobPollIntervalSeconds)
}

function Start-ItemCleanupJob {
    # Version Fire & Forget: lanza el cleanup job y retorna el nombre del job sin esperar.
    param($Item, [string]$Phase)
    if (-not $cmdCleanup) { return $null }

    $cargs = @{}
    if ($cleanupParams -contains "Comment") { $cargs["Comment"] = "$Phase automatico" }

    if ($cleanupParams -contains "ReplicationProtectedItem") { $cargs["ReplicationProtectedItem"] = $Item }
    else { $cargs["ReplicationProtectedItemId"] = (Get-Prop $Item @("Id","ID")) }

    $cjob = Start-AzRecoveryServicesAsrTestFailoverCleanupJob @cargs -ErrorAction Stop
    return $cjob.Name
}


# ========================= PREPARACION DE VARIABLES DE ESTADO =========================

$vmIndex = 0
$vmTotal = @($filtered).Count

# Diccionario maestro para trackear el estado de todas las VMs durante las fases paralelas
$JobTrackingMap = @{}

foreach ($it in $filtered) {
    $vmName = Get-ItemDisplayName $it
    $vmResultObj = [pscustomobject]@{
        vmName           = $vmName
        status           = "Processing"
        bootStatus       = "Pending"
        netStatus        = "Pending"
        osHealthStatus   = "Pending"
        osHealthDetail   = ""
        osInfoErrors     = ""
        asrHealthErrors  = ""
        diskHealthStatus = "Pending"
        sqlStatus        = "Pending"
        rpAge            = "Pending"
        rpTime           = "Pending"
        testVmIp         = "Pending"
        jobName          = ""
        notes            = "Iniciando proceso..."
        duration         = "00:00:00"
    }
    
    $script:vmResults.Add($vmResultObj)
    
    $JobTrackingMap[$vmName] = @{
        ItemObj = $it
        ResultObj = $vmResultObj
        StartTime = Get-Date
        JobId = ""
        TfoLaunched = $false
        TfoSucceeded = $false
        NeedsCleanup = $false
    }
}


# ========================= FASE 0: PRE-CLEANUP PARALELO =========================

Write-Section "FASE 0: Pre-cleanup Paralelo (Fire & Forget + Polling Masivo)"

$preCleanupJobs = @{}
foreach ($it in $filtered) {
    if (Test-DeadlineReached) { break }
    $vmName = Get-ItemDisplayName $it
    try {
        $jobName = Start-ItemCleanupJob -Item $it -Phase "Pre-cleanup"
        if ($jobName) {
            $preCleanupJobs[$vmName] = $jobName
            Write-Info "Pre-cleanup disparado para '$vmName' (Job: $jobName)"
        } else {
            Write-Info "Pre-cleanup no aplicable para '$vmName' (cmdlet cleanup no disponible)."
        }
        Start-Sleep -Seconds 2  # Mitigacion de throttling ARM
    } catch {
        # Si no esta en estado de TFO previo, el cmdlet tira error. Es esperable: seguimos.
        Write-Info "Pre-cleanup skip para '$vmName' (probablemente sin TFO previo): $($_.Exception.Message)"
    }
}

if ($preCleanupJobs.Count -gt 0) {
    $remainingMinutes = [int](($script:ScriptDeadline - (Get-Date)).TotalMinutes) - 20
    if ($remainingMinutes -lt 5) { $remainingMinutes = 5 }
    $preCleanupTimeout = [Math]::Min(15, $remainingMinutes)
    Write-Info "Iniciando polling masivo de pre-cleanup ($($preCleanupJobs.Count) jobs, timeout ${preCleanupTimeout}min)..."
    Wait-AsrJobsMasivo -JobDict $preCleanupJobs -TimeoutMinutes $preCleanupTimeout
} else {
    Write-Info "No hubo pre-cleanups que lanzar. Saltando polling masivo de Fase 0."
}


# ========================= FASE 1: LANZAMIENTO MASIVO DE TFO =========================

Write-Section "FASE 1: Lanzamiento de TFO Masivo (Fire & Forget)"

foreach ($it in $filtered) {
    if (Test-DeadlineReached) { break }

    $vmName = Get-ItemDisplayName $it
    $track = $JobTrackingMap[$vmName]
    $vmResultObj = $track.ResultObj

    try {
        if (-not (Test-HealthyProtectedItem -Item $it)) {
            $unhealthyReason = Get-UnhealthyReason -Item $it
            $vmResultObj.status = "Failed"
            $vmResultObj.notes = "Skipped por mala salud: $unhealthyReason"
            continue
        }

        # Pre-cleanup ya fue ejecutado en Fase 0 (paralelo). No repetir aqui.

        $rp = Get-AzRecoveryServicesAsrRecoveryPoint -ReplicationProtectedItem $it | Sort-Object RecoveryPointTime -Descending | Select-Object -First 1
        $tfoArgs = @{ ReplicationProtectedItem = $it; AzureVMNetworkId = $TestVnetResourceId; Direction = "PrimaryToRecovery" }
        
        if ($rp -and $rp.RecoveryPointTime) {
            $tfoArgs.RecoveryPoint = $rp
            $vmResultObj.rpTime = $rp.RecoveryPointTime.ToUniversalTime().ToString("yyyy-MM-dd HH:mm 'UTC'")
            $vmResultObj.rpAge = "$([math]::Round(((Get-Date).ToUniversalTime() - $rp.RecoveryPointTime.ToUniversalTime()).TotalHours, 1))h"
        }

        # Lanzamos el trabajo sin usar Wait-AsrJob (Esto es Fire & Forget)
        $job = Start-AzRecoveryServicesAsrTestFailoverJob @tfoArgs -ErrorAction Stop
        
        $vmResultObj.jobName = $job.Name
        $track.JobId = $job.Name
        $track.TfoLaunched = $true
        $track.NeedsCleanup = $true
        $vmResultObj.notes = "TFO Lanzado. Esperando completitud..."
        
        Write-Info "TFO disparado para la VM: $vmName (Job: $($job.Name))"
        
        # CAMBIO SRE: Aumentamos la espera para evitar saturar el Replication Provider (Error 539)
        # Especialmente critico cuando hay servidores de Base de Datos (SQL/DB) en el lote.
        Write-Info "Esperando 60 segundos para estabilizacion del Provider antes de la proxima VM..."
        Start-Sleep -Seconds 60
        
    }
    catch {
        $vmResultObj.status = "Failed"
        $vmResultObj.notes = "Fallo al lanzar TFO: $($_.Exception.Message)"
        Write-Warn "Error disparando TFO para $vmName : $($_.Exception.Message)"
    }
}


# ========================= FASE 2: POLLING MASIVO GLOBAL =========================

Write-Section "FASE 2: Polling Global Simultaneo"

$activeTfoJobs = @{}
foreach ($k in $JobTrackingMap.Keys) {
    if ($JobTrackingMap[$k].TfoLaunched) {
        $activeTfoJobs[$k] = $JobTrackingMap[$k].JobId
    }
}

if ($activeTfoJobs.Count -gt 0) {
    # Capar el timeout de Phase 2 al tiempo restante del deadline global (menos 10 min de buffer para Phase 3/cleanup)
    $remainingMinutes = [int](($script:ScriptDeadline - (Get-Date)).TotalMinutes) - 10
    if ($remainingMinutes -lt 5) { $remainingMinutes = 5 }
    $effectiveTimeout = [Math]::Min($JobTimeoutMinutes, $remainingMinutes)
    Write-Info ("Phase 2 timeout efectivo: {0} min (param {1} min, restante global {2} min)" -f $effectiveTimeout, $JobTimeoutMinutes, $remainingMinutes)
    Wait-AsrJobsMasivo -JobDict $activeTfoJobs -TimeoutMinutes $effectiveTimeout
}

# Actualizar el estado de los objetos basados en el resultado del polling
foreach ($k in $JobTrackingMap.Keys) {
    $track = $JobTrackingMap[$k]
    if ($track.TfoLaunched) {
        try {
            $j = Get-AzRecoveryServicesAsrJob -Name $track.JobId -ErrorAction Stop
            if ($j.State -eq "Succeeded") {
                $track.TfoSucceeded = $true
                $track.ResultObj.notes = "TFO Succeeded."
            } else {
                $track.ResultObj.status = "Failed"
                $track.ResultObj.notes = "TFO Failed: $($j.State)"
            }
        }
        catch {
            $track.ResultObj.status = "Failed"
            $track.ResultObj.notes = "Error consultando estado final del Job TFO."
        }
    }
}


# ========================= FASE 3: VALIDACIONES SECUENCIALES Y POST-CLEANUP =========================

Write-Section "FASE 3: Validaciones de Salud y Post-Cleanup"

# Invalidar cache: despues de Phase 1/2 hay VMs nuevas de prueba que no estaban al arranque.
Write-Info "Refrescando cache de VMs tras Phase 1/2 (captura VMs de prueba recien creadas)..."
try {
    $script:AllVmsCache = @(Get-AzVM -ResourceGroupName ${VaultResourceGroup} -Status -ErrorAction Stop)
    Write-Info ("Cache refrescado: {0} VMs en RG '{1}'." -f $script:AllVmsCache.Count, ${VaultResourceGroup})
} catch {
    Write-Warn ("Fallo refrescar cache de VMs: {0}. Se fetcheara por iteracion." -f $_.Exception.Message)
    $script:AllVmsCache = $null
}

$vmIndex = 0
foreach ($it in $filtered) {
    $vmIndex++
    $vmName = Get-ItemDisplayName $it
    $track = $JobTrackingMap[$vmName]
    $vmResultObj = $track.ResultObj
    
    if (Test-DeadlineReached) { Write-Warn "Deadline alcanzado en Fase 3."; break }
    
    if ($vmResultObj.status -eq "Failed") {
        Write-Info "Omitiendo validaciones para $vmName porque TFO fallo o no arranco."
        continue
    }

    try {
        if ($track.TfoSucceeded) {
            Write-Section ("Búsqueda de VM clonada en ${VaultResourceGroup} para verificación de Booteo: {0}" -f $vmName)
            
            $testVm = $null
            $maxWaitMinutes = 5
            $WaitDeadline = (Get-Date).AddMinutes($maxWaitMinutes)
            $pollIntervalSecs = 20
            
            $prefixLength = if ($vmName.Length -gt 8) { 8 } else { $vmName.Length }
            $searchPrefix = $vmName.Substring(0, $prefixLength)
            $escapedPrefix = [regex]::Escape($searchPrefix)
            $escapedVmName = [regex]::Escape($vmName)

            Write-Info ("Esperando a que la VM clonada ('{0}*-test' o '{1}*-test') aparezca..." -f $searchPrefix, $vmName)
            do {
                # Refrescar el cache en cada iteracion para capturar VMs recien creadas por ASR.
                try {
                    $script:AllVmsCache = @(Get-AzVM -ResourceGroupName ${VaultResourceGroup} -Status -ErrorAction Stop)
                } catch {
                    Write-Warn ("Fallo refresco de cache dentro del poll: {0}" -f $_.Exception.Message)
                }
                $vmSource = if ($script:AllVmsCache) { $script:AllVmsCache } else { @() }

                # Regex endurecido: ambas alternativas exigen sufijo '-test' para evitar matchear la VM source u otras no relacionadas.
                $candidates = $vmSource | Where-Object {
                    ($_.Name -match "^$escapedPrefix.*-test(-|$)" -or $_.Name -match "^$escapedVmName.*-test(-|$)") -and
                    ($_.Name -notmatch "^azr-vm-test-velo$")
                }
                
                if ($candidates) {
                    $definitive = $candidates | Where-Object { $_.Name -notmatch "temp" } | Sort-Object {
                        $p = ($_.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).Code
                        if ($p -eq 'PowerState/running') { 2 } elseif ($p -eq 'PowerState/starting') { 1 } else { 0 }
                    } -Descending | Select-Object -First 1

                    if ($definitive) {
                        $testVm = $definitive
                        Write-Info ("¡VM definitiva detectada! Nombre: {0}" -f $testVm.Name)
                        break
                    }
                    else {
                        $tempVm = $candidates | Where-Object { $_.Name -match "temp" } | Select-Object -First 1
                        if ($tempVm) {
                            $testVm = $tempVm
                            Write-Info ("Detectada VM de transición: {0}. Esperando a la definitiva..." -f $tempVm.Name)
                        }
                    }
                }
                
                if ((Get-Date) -lt $WaitDeadline) {
                    Start-Sleep -Seconds $pollIntervalSecs
                }
            } while ((Get-Date) -lt $WaitDeadline)

            if ($testVm) {
                Write-Info ("¡VM de prueba encontrada! Nombre: {0}" -f $testVm.Name)
                try {
                    if ($testVm.NetworkProfile -and $testVm.NetworkProfile.NetworkInterfaces) {
                        $nic = Get-AzNetworkInterface -ResourceId $testVm.NetworkProfile.NetworkInterfaces[0].Id -ErrorAction SilentlyContinue
                        if ($nic) { $vmResultObj.testVmIp = $nic.IpConfigurations[0].PrivateIpAddress }
                    }
                }
                catch { Write-Warn "No se pudo extraer la IP de la VM clonada." }

                Write-Info "Verificando estado de Boot OS..."
                $bootResult = Test-VmBootStatus -ResourceGroupName ${VaultResourceGroup} -VmName $testVm.Name -MaxRetries $BootCheckMaxRetries -IntervalSeconds $BootCheckIntervalSeconds
                
                if ($bootResult.Booted) {
                    $vmResultObj.bootStatus = "Booted"
                    $vmResultObj.notes += " | Boot OS: OK"
                    Write-Info ("Boot OS exitoso para '{0}'." -f $testVm.Name)
                    
                    Write-Info "Esperando 60s post-boot para estabilizacion del VM Agent..."
                    Start-Sleep -Seconds 60

                    # --- PARALELIZACION INTRA-VM: Net + OS + Disk + SQL concurrentes ---
                    $rgForJob = ${VaultResourceGroup}
                    $vmForJob = $testVm.Name

                    $netOk = $null; $osHealth = $null; $diskHealth = $null; $sqlResult = $null

                    if ($script:UseParallelValidations) {
                        Write-Info "Lanzando 4 validaciones en paralelo (Net, OS, Disk, SQL) via Start-ThreadJob..."
                        $parallelStart = Get-Date

                        $validationJobs = @{}
                        try {
                            $validationJobs['Net'] = Start-ThreadJob -Name "Net-$vmForJob" -ScriptBlock {
                                param($rg, $vm, $fnDef)
                                Set-Item -Path function:Test-VmInternalNetworking -Value ([scriptblock]::Create($fnDef))
                                try { return Test-VmInternalNetworking -ResourceGroupName $rg -VmName $vm }
                                catch { return [pscustomobject]@{ Success = $false; ErrorDetail = "ThreadJob exception: $($_.Exception.Message)" } }
                            } -ArgumentList $rgForJob, $vmForJob, $script:FnNetDef

                            $validationJobs['Os'] = Start-ThreadJob -Name "Os-$vmForJob" -ScriptBlock {
                                param($rg, $vm, $fnDef)
                                Set-Item -Path function:Test-VmOsHealth -Value ([scriptblock]::Create($fnDef))
                                try { return Test-VmOsHealth -ResourceGroupName $rg -VmName $vm }
                                catch { return [pscustomobject]@{ Success = $false; ErrorDetail = "ThreadJob exception: $($_.Exception.Message)" } }
                            } -ArgumentList $rgForJob, $vmForJob, $script:FnOsDef

                            $validationJobs['Disk'] = Start-ThreadJob -Name "Disk-$vmForJob" -ScriptBlock {
                                param($rg, $vm, $fnDef)
                                Set-Item -Path function:Test-VmDiskHealth -Value ([scriptblock]::Create($fnDef))
                                try { return Test-VmDiskHealth -ResourceGroupName $rg -VmName $vm }
                                catch { return [pscustomobject]@{ Success = $false; ErrorDetail = "ThreadJob exception: $($_.Exception.Message)" } }
                            } -ArgumentList $rgForJob, $vmForJob, $script:FnDiskDef

                            $validationJobs['Sql'] = Start-ThreadJob -Name "Sql-$vmForJob" -ScriptBlock {
                                param($rg, $vm, $fnDef)
                                Set-Item -Path function:Test-VmSqlHealth -Value ([scriptblock]::Create($fnDef))
                                try { return Test-VmSqlHealth -ResourceGroupName $rg -VmName $vm }
                                catch { return [pscustomobject]@{ HasSql = $false; ErrorDetail = "ThreadJob exception: $($_.Exception.Message)" } }
                            } -ArgumentList $rgForJob, $vmForJob, $script:FnSqlDef

                            # Esperar los 4 jobs con timeout de seguridad (10 min total)
                            $null = $validationJobs.Values | Wait-Job -Timeout 600

                            foreach ($kind in @('Net','Os','Disk','Sql')) {
                                $j = $validationJobs[$kind]
                                if ($j.State -eq 'Completed') {
                                    try { $val = Receive-Job -Job $j -ErrorAction SilentlyContinue } catch { $val = $null }
                                } else {
                                    Write-Warn ("ThreadJob '$kind' no termino en tiempo (State: $($j.State)). Cancelando.")
                                    try { Stop-Job -Job $j -ErrorAction SilentlyContinue } catch {}
                                    $val = [pscustomobject]@{ ErrorDetail = "ThreadJob $kind timeout/$($j.State)"; Success = $false; HasSql = $false }
                                }
                                switch ($kind) {
                                    'Net'  { $netOk = $val }
                                    'Os'   { $osHealth = $val }
                                    'Disk' { $diskHealth = $val }
                                    'Sql'  { $sqlResult = $val }
                                }
                            }
                        }
                        finally {
                            foreach ($j in $validationJobs.Values) {
                                try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
                            }
                        }

                        $parallelElapsed = [math]::Round(((Get-Date) - $parallelStart).TotalSeconds, 1)
                        Write-Info ("Validaciones paralelas completadas en {0}s (Net+OS+Disk+SQL concurrentes)." -f $parallelElapsed)
                    }
                    else {
                        # Fallback secuencial si Start-ThreadJob no disponible
                        Write-Info "Ejecutando validaciones secuencialmente (fallback)..."
                        try { $netOk      = Test-VmInternalNetworking -ResourceGroupName $rgForJob -VmName $vmForJob } catch { $netOk = [pscustomobject]@{ Success=$false; ErrorDetail=$_.Exception.Message } }
                        try { $osHealth   = Test-VmOsHealth           -ResourceGroupName $rgForJob -VmName $vmForJob } catch { $osHealth = [pscustomobject]@{ Success=$false; ErrorDetail=$_.Exception.Message } }
                        try { $diskHealth = Test-VmDiskHealth         -ResourceGroupName $rgForJob -VmName $vmForJob } catch { $diskHealth = [pscustomobject]@{ Success=$false; ErrorDetail=$_.Exception.Message } }
                        try { $sqlResult  = Test-VmSqlHealth          -ResourceGroupName $rgForJob -VmName $vmForJob } catch { $sqlResult = [pscustomobject]@{ HasSql=$false; ErrorDetail=$_.Exception.Message } }
                    }

                    # --- PROCESAR RESULTADO: RED ---
                    try {
                        if (-not $netOk) { throw "netOk nulo tras validacion paralela." }

                        Write-Info ("  Adaptadores: {0}" -f $netOk.AllAdapters)
                        Write-Info ("  NIC activa: {0} (Estado: {1}, MAC: {2}, DHCP: {3})" -f $netOk.NicName, $netOk.NicStatus, $netOk.NicMac, $netOk.DhcpEnabled)
                        Write-Info ("  IP: {0}, Subnet: {1}" -f $netOk.IP, $netOk.SubnetMask)
                        Write-Info ("  Gateway: {0}, Ping GW: {1} ({2})" -f $netOk.Gateway, $netOk.PingGateway, $netOk.PingGwDetail)
                        Write-Info ("  Ping subnet (.1): {0}" -f $netOk.PingSubnetTest)
                        Write-Info ("  Ping Wire Server (168.63.129.16): {0}" -f $netOk.PingWireServer)
                        Write-Info ("  DNS Servers: {0} (informativo)" -f $netOk.DnsServers)
                        Write-Info ("  DNS Resolve: {0} (informativo)" -f $netOk.DnsResolve)
                        Write-Info ("  Firewall perfiles: {0}" -f $netOk.FirewallProfiles)
                        Write-Info ("  Firewall ICMP: {0}" -f $netOk.FirewallICMP)
                        Write-Info ("  Rutas: {0}" -f $netOk.RouteTable)
                        Write-Info ("  ARP: {0}" -f $netOk.ArpEntries)
                        Write-Info ("  TCP activas: {0}" -f $netOk.TcpConnections)

                        $diagStr = "NIC:$($netOk.NicStatus), IP:$($netOk.IP), WireServer:$($netOk.PingWireServer), GW:$($netOk.Gateway)(Ping:$($netOk.PingGateway)), FW_ICMP:$($netOk.FirewallICMP)"

                        if ($netOk.Success) {
                            $vmResultObj.netStatus = "OK"
                            $vmResultObj.notes += " | Red: OK ($diagStr)"
                            Write-Info "Conectividad L2/L3 verificada en VNet aislada. Red operativa."
                        } else {
                            $vmResultObj.netStatus = "Failed"
                            $failReasons = @()
                            if ($netOk.NicStatus -and $netOk.NicStatus -ne 'Up') { $failReasons += "NIC_DOWN($($netOk.NicStatus))" }
                            if ($netOk.IP -eq 'N/A') { $failReasons += "SIN_IP_ASIGNADA" }
                            if ($netOk.PingWireServer -and $netOk.PingWireServer -notmatch 'OK') { $failReasons += "WIRESERVER_UNREACHABLE($($netOk.PingWireServer))" }
                            if ($netOk.ErrorDetail) { $failReasons += $netOk.ErrorDetail }
                            $failReason = if ($failReasons.Count -gt 0) { $failReasons -join '; ' } else { "Sin conectividad a infraestructura Azure" }

                            $vmResultObj.notes += " | Red: FAILED ($failReason)"
                            Write-Warn ("La VM fallo el diagnostico de red: {0}" -f $failReason)
                        }
                    } catch {
                        Write-Warn ("El chequeo de red interno fallo con excepcion: {0}" -f $_.Exception.Message)
                        $vmResultObj.netStatus = "Error"
                        $vmResultObj.notes += " | Red: Error Fatal de Agente ($($_.Exception.Message))"
                    }

                    # --- PROCESAR RESULTADO: OS HEALTH ---
                    try {
                        if (-not $osHealth) { throw "osHealth nulo tras validacion paralela." }

                        Write-Info ("  Ultimo boot: {0}" -f $osHealth.LastBootTime)
                        Write-Info ("  Uptime: {0} minutos" -f $osHealth.UptimeMinutes)
                        Write-Info ("  Errores criticos (Event Log): {0}" -f $osHealth.CriticalErrors)
                        Write-Info ("  Servicios fallidos: {0}" -f $osHealth.FailedServices)

                        $vmResultObj.osHealthDetail = "Ultimo boot: $($osHealth.LastBootTime)`nUptime: $($osHealth.UptimeMinutes) min`nErrores Event Log: $($osHealth.CriticalErrors)`nServicios fallidos: $($osHealth.FailedServices)"

                        if ($osHealth.InformationalErrors) { $vmResultObj.osInfoErrors = $osHealth.InformationalErrors }

                        if ($osHealth.FailedServices -ne 'Ninguno') {
                            $vmResultObj.osHealthStatus = "Warning"
                            $vmResultObj.notes += " | OS Health: WARNING (Servicios: $($osHealth.FailedServices))"
                            Write-Warn ("OS Health: servicios criticos caidos: {0}" -f $osHealth.FailedServices)
                            $svcDetail = "SERVICIOS CRITICOS CAIDOS: $($osHealth.FailedServices)"
                            $vmResultObj.osInfoErrors = if ($vmResultObj.osInfoErrors) { "$svcDetail`n$($vmResultObj.osInfoErrors)" } else { $svcDetail }
                        }
                        elseif ($osHealth.InformationalErrors) {
                            $vmResultObj.osHealthStatus = "OK"
                            $vmResultObj.notes += " | OS Health: OK (Uptime: $($osHealth.UptimeMinutes) min, errores informativos en adjunto)"
                            Write-Info "OS Health OK. Errores informativos detectados (no criticos), se incluiran en adjunto TXT."
                        }
                        elseif ($osHealth.Success) {
                            $vmResultObj.osHealthStatus = "OK"
                            $vmResultObj.notes += " | OS Health: OK (Uptime: $($osHealth.UptimeMinutes) min)"
                            Write-Info "OS Health OK. Sin errores criticos ni servicios caidos."
                        }
                        else {
                            $vmResultObj.osHealthStatus = "Warning"
                            $healthIssues = @()
                            if ($osHealth.CriticalErrors -ne 'Ninguno') { $healthIssues += "EventLog: errores criticos detectados" }
                            if ($osHealth.ErrorDetail) { $healthIssues += $osHealth.ErrorDetail }
                            $healthDetail = if ($healthIssues.Count -gt 0) { $healthIssues -join '; ' } else { "Problema no identificado" }
                            $vmResultObj.notes += " | OS Health: WARNING ($healthDetail)"
                            Write-Warn ("OS Health con advertencias: {0}" -f $healthDetail)
                        }
                    } catch {
                        Write-Warn ("OS Health check fallo: {0}" -f $_.Exception.Message)
                        $vmResultObj.osHealthStatus = "Error"
                        $vmResultObj.notes += " | OS Health: Error ($($_.Exception.Message))"
                    }

                    # --- PROCESAR RESULTADO: DISK HEALTH ---
                    try {
                        if (-not $diskHealth) { throw "diskHealth nulo tras validacion paralela." }

                        Write-Info ("  Discos: {0}" -f $diskHealth.Disks)
                        Write-Info ("  Volumenes: {0}" -f $diskHealth.Volumes)
                        Write-Info ("  Discos offline: {0}" -f $diskHealth.OfflineDisks)
                        Write-Info ("  Problemas: {0}" -f $diskHealth.Issues)

                        if ($diskHealth.Success -and $diskHealth.OfflineDisks -eq 'Ninguno' -and $diskHealth.Issues -eq 'Ninguno') {
                            $vmResultObj.diskHealthStatus = "OK"
                            $vmResultObj.notes += " | Discos: OK"
                            Write-Info "Validacion de discos OK."
                        } else {
                            $vmResultObj.diskHealthStatus = "Warning"
                            $diskIssues = @()
                            if ($diskHealth.OfflineDisks -ne 'Ninguno') { $diskIssues += "Offline: $($diskHealth.OfflineDisks)" }
                            if ($diskHealth.Issues -ne 'Ninguno') { $diskIssues += $diskHealth.Issues }
                            $diskDetail = if ($diskIssues.Count -gt 0) { $diskIssues -join '; ' } else { "Problema no identificado" }
                            $vmResultObj.notes += " | Discos: WARNING ($diskDetail)"
                            Write-Warn ("Validacion de discos con advertencias: {0}" -f $diskDetail)
                        }
                    } catch {
                        Write-Warn ("Disk Health check fallo: {0}" -f $_.Exception.Message)
                        $vmResultObj.diskHealthStatus = "Error"
                        $vmResultObj.notes += " | Discos: Error ($($_.Exception.Message))"
                    }

                    # --- PROCESAR RESULTADO: SQL SERVER ---
                    try {
                        if (-not $sqlResult) { throw "sqlResult nulo tras validacion paralela." }

                        if ($sqlResult.HasSql) {
                            Write-Info ("  SQL Server detectado. Servicio: {0}, Instancia: {1}, Estado: {2}, StartType: {3}" -f $sqlResult.ServiceName, $sqlResult.InstanceName, $sqlResult.SqlStatus, $sqlResult.StartType)
                            Write-Info ("  Version: {0}" -f $sqlResult.SqlVersion)
                            Write-Info ("  Estado DBs: {0}" -f $sqlResult.QueryResult)

                            if ($sqlResult.SqlStatus -eq 'Running' -and $sqlResult.QueryResult -match 'Todas las DBs ONLINE') {
                                $vmResultObj.sqlStatus = "OK"
                                $vmResultObj.notes += " | SQL: OK ($($sqlResult.QueryResult))"
                                Write-Info "SQL Server operativo. Todas las bases de datos online."
                            }
                            elseif ($sqlResult.SqlStatus -eq 'Running') {
                                $vmResultObj.sqlStatus = "Warning"
                                $vmResultObj.notes += " | SQL: WARNING ($($sqlResult.QueryResult))"
                                Write-Warn ("SQL Server con advertencias: {0}" -f $sqlResult.QueryResult)
                            }
                            elseif ($sqlResult.SqlStatus -eq 'Stopped' -and $sqlResult.StartType -eq 'Automatic') {
                                $vmResultObj.sqlStatus = "Warning"
                                $vmResultObj.notes += " | SQL: WARNING (Stopped pero StartType=Automatic)"
                                Write-Warn "SQL Server detenido pero tiene StartType Automatic."
                            }
                            elseif ($sqlResult.SqlStatus -eq 'Stopped') {
                                $vmResultObj.sqlStatus = "Stopped"
                                $vmResultObj.notes += " | SQL: Stopped (StartType: $($sqlResult.StartType), intencional)"
                                Write-Info ("SQL Server detenido con StartType {0}. Comportamiento esperado." -f $sqlResult.StartType)
                            }
                            else {
                                $vmResultObj.sqlStatus = "Warning"
                                $vmResultObj.notes += " | SQL: $($sqlResult.SqlStatus)"
                                Write-Warn ("SQL Server en estado: {0}" -f $sqlResult.SqlStatus)
                            }
                        }
                        elseif ($sqlResult.ErrorDetail) {
                            Write-Warn ("SQL check retorno error: {0}" -f $sqlResult.ErrorDetail)
                            $vmResultObj.sqlStatus = "Error"
                            $vmResultObj.notes += " | SQL: Error ($($sqlResult.ErrorDetail))"
                        }
                        else {
                            Write-Info "  SQL Server no instalado en esta VM."
                            $vmResultObj.sqlStatus = "N/A"
                        }
                    } catch {
                        Write-Warn ("SQL check fallo: {0}" -f $_.Exception.Message)
                        $vmResultObj.sqlStatus = "Error"
                        $vmResultObj.notes += " | SQL: Error ($($_.Exception.Message))"
                    }

                    $vmResultObj.status = "Succeeded"
                } else {
                    $vmResultObj.bootStatus = "Failed"
                    $vmResultObj.status = "Failed"
                    $vmResultObj.notes += " | Boot OS: FAILED ($($bootResult.Details))"
                    Write-ErrL ("Boot OS fallo para '{0}'." -f $testVm.Name)
                }
            } else {
                Write-Warn "No se encontro la VM de prueba en ${VaultResourceGroup}. Se omite comprobacion de booteo."
                $vmResultObj.notes += " | Boot OS: VM No Encontrada en RG."
                $vmResultObj.status = "Failed"
            }
        }
    }
    catch {
        $vmResultObj.status = "Failed"
        $vmResultObj.notes += " | Excepcion durante validaciones: $($_.Exception.Message)"
        Write-Warn "Error validando $vmName : $($_.Exception.Message)"
    }
    finally {
        # CALCULO DE DURACION Y GUARDADO
        $dur = (Get-Date) - $track.StartTime
        $vmResultObj.duration = "{0:D2}:{1:D2}:{2:D2}" -f [int]$dur.TotalHours, $dur.Minutes, $dur.Seconds
        
        Write-Info ("Duracion VM '{0}': {1}" -f $vmName, $vmResultObj.duration)

        $doneOk   = ($script:vmResults | Where-Object { $_.status -eq "Succeeded" }).Count
        $doneFail = ($script:vmResults | Where-Object { $_.status -eq "Failed" }).Count
        Write-Info ("[PROGRESO] {0}/{1} completadas - {2} OK, {3} Failed" -f $vmIndex, $vmTotal, $doneOk, $doneFail)

        if ($track.NeedsCleanup) {
            Write-Section ("Cleanup final (por item): {0}" -f $vmName)
            try { Invoke-ItemCleanup -Item $it -Phase "Cleanup" -TimeoutMinutes $CleanupTimeoutMinutes | Out-Null }
            catch {
                Write-Warn ("Error en cleanup para '{0}'." -f $vmName)
                Show-ExceptionDetail $_.Exception
            }
        }
    }
}

# ========================= Resumen =========================

Write-Section "Resumen"
$total = $script:vmResults.Count
$ok = ($script:vmResults | Where-Object { $_.status -eq "Succeeded" }).Count
$fail = ($script:vmResults | Where-Object { $_.status -eq "Failed" }).Count
# Skipped: VMs que quedaron en estado "Processing" o "Pending" porque no se llego a validarlas (deadline/corte).
$skipped = ($script:vmResults | Where-Object { $_.status -notin @("Succeeded","Failed") }).Count
$summary = "Procesadas: $total | OK: $ok | Failed: $fail"

if ($skipped -gt 0) {
    $summary += " | Skipped (deadline/corte): $skipped"
}
Write-Info $summary

# ========================= Enviar Reporte a Logic App =========================

Write-Section "Enviando informe a Logic App"
Send-Report
Write-Info "Proceso completado (TFO Paralelizado + Reporte)."