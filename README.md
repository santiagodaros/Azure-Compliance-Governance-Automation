# Azure Compliance & Governance Automation

> **Senior-level portfolio demonstrating a production-grade Azure governance ecosystem where Policy enforcement and SRE-class automation operate as a unified resilience framework.**

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Repository Structure](#repository-structure)
- [Governance Layer: Azure Policies](#governance-layer-azure-policies)
  - [Design Philosophy: Hybrid Prevention + Auto-Remediation](#design-philosophy-hybrid-prevention--auto-remediation)
  - [Policy 1 — Naming Convention (Deny)](#policy-1--naming-convention-deny)
  - [Policy 2 — Mandatory Tag: Ambiente (Deny)](#policy-2--mandatory-tag-ambiente-deny)
  - [Policy 3 — Inherit Tag from Resource Group (Modify)](#policy-3--inherit-tag-from-resource-group-modify)
  - [Policy 4 — Deploy Agent on Azure Arc Machines (DeployIfNotExists)](#policy-4--deploy-agent-on-azure-arc-machines-deployifnotexists)
- [Infrastructure Layer: Terraform IaC](#infrastructure-layer-terraform-iac)
  - [Module: resiliency](#module-resiliency)
  - [Module: identity](#module-identity)
  - [Backend & Scaffolding](#backend--scaffolding)
- [Resilience Layer: ASR Parallel Test Failover](#resilience-layer-asr-parallel-test-failover)
  - [SRE Guardrails](#sre-guardrails)
  - [Execution Phases](#execution-phases)
  - [HTML Executive Report](#html-executive-report)
- [Audit Automation: AVD User Audit](#audit-automation-avd-user-audit)
- [Key Features](#key-features)
- [Prerequisites & Deployment](#prerequisites--deployment)
- [Environment Taxonomy](#environment-taxonomy)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GOVERNANCE LAYER                              │
│                                                                       │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  naming-          │  │  mandatory-tag-  │  │  inherit-tag-    │  │
│  │  convention-rg   │  │  ambiente        │  │  ambiente        │  │
│  │  Effect: DENY    │  │  Effect: DENY    │  │  Effect: MODIFY  │  │
│  │  Mode: All       │  │  Mode: All       │  │  Mode: Indexed   │  │
│  │  RG-[ENV]-[SYS]- │  │  tag 'Ambiente'  │  │  child resources │  │
│  │  [REGION]        │  │  required on RG  │  │  from parent RG  │  │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘  │
│           │  Prevention          │  Prevention          │ Remediation│
│           └──────────────────────┴──────────────────────┘           │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  deploy-agent-arc-dine  (DeployIfNotExists)                  │    │
│  │  Target: Microsoft.HybridCompute/machines (Windows)          │    │
│  │  Checks: CustomScriptExtension presence                      │    │
│  │  Deploys: MSI via Managed Identity token → Blob Storage      │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                  │                                   │
│                   Resources born COMPLIANT + Arc agents enforced     │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ Tag 'Ambiente' flows down
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      INFRASTRUCTURE LAYER (Terraform)                │
│                                                                       │
│  module "resiliency"              module "identity"                  │
│  ┌──────────────────────────┐    ┌──────────────────────────┐       │
│  │ Recovery Services Vault  │    │ Entra App Registration   │       │
│  │ Automation Account       │    │ App Role: L1.Support      │       │
│  │   └─ Runbook (PS1)       │    │ App Role: DR.Admin        │       │
│  │ Logic App (HTTP trigger) │    │ Service Principal         │       │
│  │ Storage Account          │    └──────────────────────────┘       │
│  │   └─ compliance-reports  │                                        │
│  └──────────────────────────┘                                        │
│                                                                       │
│  Backend: Azure Blob Storage (OIDC) · Providers: azurerm ~> 3.117   │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ Provisions infra consumed by
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        RESILIENCE LAYER                              │
│                                                                       │
│  Invoke-ParallelTFO.ps1  (Azure Automation Runbook — PS 7.2)        │
│                                                                       │
│  Phase 0 ──► Pre-Cleanup [Fire & Forget × N VMs]                    │
│  Phase 1 ──► TFO Launch  [Fire & Forget × N VMs]                    │
│  Phase 2 ──► Global Polling [Wait-AsrJobsMasivo — simultaneous]     │
│  Phase 3 ──► Per-VM: Boot → [Net ║ OS ║ Disk ║ SQL] via ThreadJob   │
│           └► Post-Cleanup [per VM in finally block]                  │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  VM Validation (concurrent via Start-ThreadJob)              │    │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │    │
│  │  │ Network  │ │ OS Health│ │  Disks   │ │   SQL    │       │    │
│  │  │ L2/L3    │ │ EventLog │ │ Offline  │ │ MSSQL    │       │    │
│  │  │ WireSvr  │ │ Services │ │ Volumes  │ │ DBs state│       │    │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                      HTML Report → Logic App Webhook → Email         │
└──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       AUDIT AUTOMATION LAYER                         │
│                                                                       │
│  Get-AvdUserAudit.ps1  (Cloud Shell / local PowerShell)             │
│                                                                       │
│  Per App Group: Desktop Virtualization User role assignments         │
│  Per Host Pool: RDP properties (device/drive/clipboard/printer)      │
│  Output: Auditoria_AVD.csv                                           │
└─────────────────────────────────────────────────────────────────────┘
```

The governance layer guarantees that every Resource Group carries the `Ambiente` tag with a valid environment value (`PROD`, `DESA`, or `PREPROD`). This structured tagging is the foundation the ASR automation relies on to scope, filter, and report on disaster recovery tests per environment.

---

## Repository Structure

```
azure-compliance-governance-automation/
├── policies/
│   ├── governance/
│   │   ├── naming-convention-rg.json      # Deny: enforce RG naming standard
│   │   ├── mandatory-tag-ambiente.json    # Deny: require 'Ambiente' tag on RGs
│   │   └── inherit-tag-ambiente.json      # Modify: auto-tag child resources from RG
│   └── arc/
│       └── deploy-agent-arc-dine.json     # DeployIfNotExists: install agent on Arc machines
├── automation/
│   ├── asr/
│   │   └── Invoke-ParallelTFO.ps1         # ASR Test Failover — parallelized runbook
│   └── avd/
│       └── Get-AvdUserAudit.ps1           # AVD user authorization + RDP properties audit
└── infra/
    └── terraform/
        ├── versions.tf                    # Provider versions (azurerm ~> 3.117, azuread ~> 2.53)
        ├── backend.tf                     # Remote state — Azure Blob Storage, OIDC auth
        ├── backend-dev.tfbackend          # Backend config for dev environment
        ├── backend-prod.tfbackend         # Backend config for prod environment
        ├── variables.tf                   # Global input variables
        ├── dev.tfvars                     # Dev variable values (placeholder IDs)
        ├── prod.tfvars                    # Prod variable values (placeholder IDs)
        └── modules/
            ├── resiliency/                # RSV · Automation Account · Runbook · Logic App · Storage
            │   ├── main.tf
            │   ├── variables.tf
            │   └── outputs.tf
            └── identity/                  # Entra App Registration · L1.Support · DR.Admin roles
                ├── main.tf
                ├── variables.tf
                └── outputs.tf
```

---

## Governance Layer: Azure Policies

### Design Philosophy: Hybrid Prevention + Auto-Remediation

This project uses a **two-tier policy strategy** that addresses governance at the resource lifecycle level:

| Tier | Effect | Scope | Goal |
|------|--------|-------|------|
| **Prevention** | `Deny` | Resource Groups | Blocks non-compliant resources from being created in the first place |
| **Auto-Remediation** | `Modify` | Child Resources | Fixes tag drift on existing resources automatically via remediation tasks |

**Why this matters:** `Deny` alone creates friction without healing existing drift. `Modify` alone lets bad resources in. Together, they form a closed loop: nothing enters the environment without the correct tag, and anything that slips through (legacy resources, ARM template gaps) gets corrected automatically.

---

### Policy 1 — Naming Convention (Deny)

**File:** [`policies/governance/naming-convention-rg.json`](policies/governance/naming-convention-rg.json)

Enforces the corporate naming standard for Resource Groups. Any RG that does not start with `RG-` **and** contain one of the valid environment segments is blocked at creation time.

**Standard format:** `RG-[ENV]-[SYSTEM]-[REGION]`

| Segment | Valid Values | Example |
|---------|-------------|---------|
| Prefix | `RG-` | `RG-` |
| Environment | `PROD`, `DESA`, `PREPROD` | `PROD` |
| System | Free text, team-defined | `PAYMENTS` |
| Region | Free text, team-defined | `BRAZILSOUTH` |

**Full example:** `RG-PROD-PAYMENTS-BRAZILSOUTH`

The policy is parameterized (`Deny` / `Audit` / `Disabled`) so teams can deploy in `Audit` mode for discovery before enforcing.

```json
"anyOf": [
  { "field": "name", "contains": "-PROD-" },
  { "field": "name", "contains": "-DESA-" },
  { "field": "name", "contains": "-PREPROD-" }
]
```

---

### Policy 2 — Mandatory Tag: Ambiente (Deny)

**File:** [`policies/governance/mandatory-tag-ambiente.json`](policies/governance/mandatory-tag-ambiente.json)

Blocks creation of any Resource Group that does not include the `Ambiente` tag. No RG can exist without explicitly declaring which environment it belongs to.

The tag name is parameterized (`tagName`, defaults to `Ambiente`) for reuse across similar tag-enforcement policies.

```json
{
  "field": "[concat('tags[', parameters('tagName'), ']')]",
  "exists": "false"
}
```

**Combined effect with Policy 1:** A Resource Group must be named correctly **and** carry the `Ambiente` tag. Both are `Deny` — failing either check blocks the deployment.

---

### Policy 3 — Inherit Tag from Resource Group (Modify)

**File:** [`policies/governance/inherit-tag-ambiente.json`](policies/governance/inherit-tag-ambiente.json)

Automatically propagates the `Ambiente` tag from the parent Resource Group down to any child resource that is missing it. This is the **auto-remediation** layer.

- **Effect:** `modify` with `add` operation
- **Trigger:** Child resource exists without `tags['Ambiente']`, AND parent RG has a non-empty `Ambiente` tag
- **Required role:** Tag Contributor (`4a9ae15a-e44a-4174-8b7a-7e1d58d91244`) assigned to the Policy Managed Identity

```json
"then": {
  "effect": "modify",
  "details": {
    "roleDefinitionIds": [
      "/providers/microsoft.authorization/roleDefinitions/4a9ae15a-e44a-4174-8b7a-7e1d58d91244"
    ],
    "operations": [
      { "operation": "add", "field": "tags['Ambiente']", "value": "[resourceGroup().tags['Ambiente']]" }
    ]
  }
}
```

After assignment, create a **Remediation Task** in Azure Policy to back-fill existing non-compliant resources.

---

### Policy 4 — Deploy Agent on Azure Arc Machines (DeployIfNotExists)

**File:** [`policies/arc/deploy-agent-arc-dine.json`](policies/arc/deploy-agent-arc-dine.json)

Ensures a monitoring agent is installed on every Azure Arc-enabled Windows server. Unlike the `Deny` policies, this one takes **active corrective action**: if the `CustomScriptExtension` is absent, the policy deploys it automatically via a nested ARM template.

**Effect:** `DeployIfNotExists` (configurable: `AuditIfNotExists` | `Disabled`)

#### How it works

```
Arc Machine evaluated
        │
        ▼
existenceCondition: CustomScriptExtension present?
        │
   NO ──┴──► DeployIfNotExists triggers ARM deployment
                      │
                      ▼
        CustomScriptExtension deployed with inline script:
           1. Get OAuth2 token via Arc IMDS endpoint (localhost:40342)
           2. Download agent.msi from Blob Storage using Bearer token
           3. Install silently via msiexec /quiet /norestart
```

#### Security design: credential-free download

The script uses the Arc machine's **System-Assigned Managed Identity** to obtain a storage token — no SAS tokens, no connection strings stored anywhere:

```powershell
$token = (Invoke-RestMethod -Method Get `
    -Uri "http://localhost:40342/metadata/identity/oauth2/token?api-version=2019-11-01&resource=https://storage.azure.com/" `
    -Headers @{Metadata="True"}).access_token

Invoke-WebRequest -Uri "URL_DE_TU_BLOB" -OutFile "C:\temp\agent.msi" `
    -Headers @{Authorization="Bearer $token"; "x-ms-version"="2019-12-12"}

Start-Process msiexec.exe -ArgumentList '/i C:\temp\agent.msi /quiet /norestart' -Wait
```

> Note: `localhost:40342` is the Arc-specific IMDS endpoint. This differs from the standard Azure VM IMDS (`169.254.169.254`) — the script only works on Arc-connected machines, preventing accidental execution on non-Arc resources.

#### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `effect` | String | `DeployIfNotExists` (default) · `AuditIfNotExists` · `Disabled` |
| `agentBlobUrl` | String | Full HTTPS URL of the agent `.msi` in Azure Blob Storage |

#### Required role for remediation

The Policy Managed Identity needs **Contributor** (`b24988ac-...`) on the resource group scope to deploy the extension. Declared in `roleDefinitionIds` within the policy.

---

## Infrastructure Layer: Terraform IaC

The Terraform modules in `infra/terraform/` provision every Azure resource the resilience layer depends on. Deploying the policies alone enforces governance; deploying these modules delivers the operational infrastructure.

### Module: resiliency

**Path:** [`infra/terraform/modules/resiliency/`](infra/terraform/modules/resiliency/)

Provisions the complete ASR operational stack as a single, cohesive unit:

| Resource | Name pattern | Purpose |
|----------|-------------|---------|
| `azurerm_recovery_services_vault` | `rsv-core-{env}` | Hosts ASR replication and failover jobs. `prevent_destroy = true` guards against accidental deletion. |
| `azurerm_automation_account` | `aa-core-{env}` | Runs the `Invoke-ParallelTFO.ps1` runbook. System-Assigned Managed Identity used for all Azure API calls. |
| `azurerm_automation_runbook` | `Runbook-ASR-TFO` | The parallelized TFO script, loaded from the `automation/asr/` path at plan time via `file()`. |
| `azurerm_logic_app_workflow` + trigger | `la-core-{env}` | HTTP webhook receiver. The callback URL is exposed as a sensitive output and injected into the Automation Account as the `ASR_LogicAppWebhookUrl` variable. |
| `azurerm_storage_account` + container | `stcore{env}{random}` | Stores HTML compliance reports. Container access is `private`; the API reads via SAS tokens. |

**Key outputs:** `vault_name`, `automation_account_id`, `logic_app_callback_url` (sensitive), `storage_account_id`, `storage_account_name`.

---

### Module: identity

**Path:** [`infra/terraform/modules/identity/`](infra/terraform/modules/identity/)

Provisions the Entra ID identity plane for the resiliency engine, implementing RBAC at the application level:

| Resource | Purpose |
|----------|---------|
| `azuread_application` | App Registration `CORE-ResiliencyEngine-{env}`. SPA redirect URIs for local dev (`localhost:5173`, `localhost:4173`). Microsoft Graph `User.Read` scope. |
| `azuread_application_app_role` × 2 | `L1.Support` — read-only access (view dashboards, export reports). `DR.Admin` — full access (execute drills, manage settings). |
| `azuread_service_principal` | Service Principal bound to the App Registration for RBAC assignments. |

The role values (`L1.Support`, `DR.Admin`) are what the frontend checks via MSAL's `getActiveAccount().idTokenClaims.roles` after authentication.

**Key outputs:** `app_client_id`, `app_object_id`, `service_principal_id`, `api_principal_id`.

---

### Backend & Scaffolding

| File | Purpose |
|------|---------|
| [`versions.tf`](infra/terraform/versions.tf) | Pins `azurerm ~> 3.117`, `azuread ~> 2.53`, `random ~> 3.6`. Requires Terraform `>= 1.7.0`. |
| [`backend.tf`](infra/terraform/backend.tf) | Remote state in Azure Blob Storage. Uses `use_oidc = true` — no stored credentials. Initialize with `terraform init -backend-config=backend-<env>.tfbackend`. |
| [`backend-dev.tfbackend`](infra/terraform/backend-dev.tfbackend) | Dev backend: storage account, container, and state key. |
| [`backend-prod.tfbackend`](infra/terraform/backend-prod.tfbackend) | Prod backend: separate storage account and state key. |
| [`variables.tf`](infra/terraform/variables.tf) | Global inputs: `environment` (validated: `dev` or `prod`), `subscription_id`, `tenant_id`, `location`, `tags`. |
| [`dev.tfvars`](infra/terraform/dev.tfvars) / [`prod.tfvars`](infra/terraform/prod.tfvars) | Example variable files with placeholder IDs. Sensitive values (`sql_admin_password`) are expected via `TF_VAR_*` environment variables — never committed. |

---

## Resilience Layer: ASR Parallel Test Failover

**File:** [`automation/asr/Invoke-ParallelTFO.ps1`](automation/asr/Invoke-ParallelTFO.ps1)

A production-grade Azure Automation Runbook (PowerShell 7.2) that executes Azure Site Recovery Test Failovers at scale. This is not a sequential script — every phase is engineered for parallelism and resilience.

### SRE Guardrails

#### Out-of-Memory (OOM) Protection
Log accumulation across dozens of VMs with nested RunCommand outputs can exhaust the runbook memory limit. The script implements a **char-count buffer**:

```powershell
[int]$MaxRawLogChars = 120000  # hard cap on in-memory log size

function Add-LogLine([string]$txt) {
    if ($script:LogBufferCharCount -lt $MaxRawLogChars) {
        [void]$script:LogBuffer.Add($txt)
        $script:LogBufferCharCount += $txt.Length
    }
    elseif ($script:LogBufferCharCount -eq $MaxRawLogChars) {
        [void]$script:LogBuffer.Add("... [TRUNCADO POR LIMITE DE MEMORIA OOM]")
        $script:LogBufferCharCount += 1  # prevent re-entry
    }
}
```

Once the cap is hit, a single sentinel message replaces all further lines, keeping the buffer size bounded.

#### SQL Server False Positive Handling
When Azure Automation runs `Invoke-Sqlcmd` via `Invoke-AzVMRunCommand`, the executing identity is `NT AUTHORITY\SYSTEM`. SQL Server installations that do not grant `sysadmin` to this account will throw a login error. This is **not a SQL failure** — SQL is running, the service is healthy. The script explicitly detects and handles this:

```powershell
if ($errMsg -match "Login failed for user 'NT AUTHORITY\\SYSTEM'") {
    $result.SqlVersion  = 'Desconocida (Acceso denegado a SYSTEM)'
    $result.QueryResult = 'Estado DBs: Desconocido (Falta permiso sysadmin para NT AUTHORITY\SYSTEM)'
    # Does NOT set $result.Success = $false — the service is running
}
```

Without this guard, every SQL Server VM would report a false `Failed` status in the executive report.

#### Global Deadline Enforcement
Azure Automation sandboxes have a 3-hour fair-share limit. The script sets a `$ScriptDeadlineMinutes = 170` guard and checks it at every phase boundary. Phase 2 and Phase 3 dynamically cap their timeouts against the remaining global budget:

```powershell
$remainingMinutes = [int](($script:ScriptDeadline - (Get-Date)).TotalMinutes) - 10
$effectiveTimeout = [Math]::Min($JobTimeoutMinutes, $remainingMinutes)
```

#### Guaranteed Partial Report via Trap
A global `trap` block ensures that even on a fatal unhandled exception, a partial report is sent to stakeholders:

```powershell
trap {
    if ($script:TrapFired) { continue }
    $script:TrapFired = $true
    if ($script:vmResults -and $script:vmResults.Count -gt 0) {
        Send-Report -SummaryOverride "REPORTE PARCIAL - Script interrumpido." -SubjectSuffix "(PARCIAL - Error)"
    }
    continue
}
```

---

### Execution Phases

#### Phase 0 — Parallel Pre-Cleanup
Before any TFO is launched, cleanup jobs for any leftover previous TFO environments are fired concurrently across all VMs. Uses a **Fire & Forget** pattern followed by `Wait-AsrJobsMasivo` (bulk polling), not sequential waits.

```
Phase 0: Pre-cleanup [VM1] ──┐
          Pre-cleanup [VM2] ──┤──► Wait-AsrJobsMasivo (poll all simultaneously)
          Pre-cleanup [VMn] ──┘
```

ARM throttling mitigation: a 2-second stagger between job submissions prevents hitting the Azure Resource Manager request rate limit.

#### Phase 1 — Massive TFO Launch (Fire & Forget)
All Test Failover jobs are submitted to ASR without waiting for any individual result. A 60-second stabilization wait between submissions prevents Replication Provider saturation (Error 539), particularly critical when the batch includes SQL Server VMs.

#### Phase 2 — Global Simultaneous Polling
`Wait-AsrJobsMasivo` polls all in-flight TFO jobs in a single loop, removing completed jobs from the active set. Includes **per-job consecutive failure counting** — a job that fails to query 5 times in a row is removed from the tracking set and marked `Unknown`, preventing the polling loop from hanging on a single stuck job.

#### Phase 3 — Intra-VM Parallel Validations
For each VM that succeeded TFO and booted, four validation probes run **concurrently** via `Start-ThreadJob`:

| ThreadJob | Probe | Key Checks |
|-----------|-------|-----------|
| `Net` | `Test-VmInternalNetworking` | NIC status, IP assignment, Default Gateway ping, Wire Server (168.63.129.16) TCP:80, DNS config, Firewall ICMP rules, Route table, ARP table |
| `OS` | `Test-VmOsHealth` | System Event Log (Level 1/2, last 30 min), filtered for expected isolated-VNet noise (domain, Kerberos, VMware, Windows Update), critical Windows services (EventLog, Winmgmt, RpcSs, Dhcp, W32Time) |
| `Disk` | `Test-VmDiskHealth` | Disk operational status, offline disk detection, volume health, free space (< 5% threshold) |
| `SQL` | `Test-VmSqlHealth` | MSSQL service detection, Running/Stopped state, `sys.databases` query for offline DBs (via `Invoke-Sqlcmd` or `SqlClient` fallback), browser service and named instance TCP port resolution |

**Function injection pattern:** `Start-ThreadJob` runs in isolated runspaces. The parent functions are serialized to strings at startup and re-injected into each runspace via `Set-Item function:`:

```powershell
$script:FnNetDef = ${function:Test-VmInternalNetworking}.ToString()

$validationJobs['Net'] = Start-ThreadJob -ScriptBlock {
    param($rg, $vm, $fnDef)
    Set-Item -Path function:Test-VmInternalNetworking -Value ([scriptblock]::Create($fnDef))
    return Test-VmInternalNetworking -ResourceGroupName $rg -VmName $vm
} -ArgumentList $rgForJob, $vmForJob, $script:FnNetDef
```

All 4 jobs are waited with a 600-second safety timeout. Any job that does not complete is stopped, and its result is marked as `ThreadJob timeout`.

---

### HTML Executive Report

The report is generated by `Build-ReportHtml` and delivered via `Send-Report` → Logic App Webhook → Email.

**Report contents:**
- Execution metadata (subscription, vault, test VNet, timestamp)
- Dashboard KPI cards: Total VMs, Succeeded, Failed, SLA %
- Color-coded progress bar (green ≥ 80%, amber ≥ 50%, red < 50%)
- Per-VM status table with **color-coded badges** for each dimension: Failover, Boot, Network, OS Health, Disks, SQL, RPO age
- Expandable detail panel per VM (IP, duration, full diagnostic notes)
- Attached base64-encoded raw log and informational errors TXT

**RPO age color thresholds:**
| Range | Badge color | Meaning |
|-------|------------|---------|
| ≤ 4h | Green | Within RTO/RPO target |
| 4h – 24h | Amber | Monitor |
| > 24h | Red | Replication lag — investigate |

**HTML payload safety:** The report is size-capped (`MaxHtmlBytesInline = 250000`) and all dynamic content is HTML-encoded via `ConvertTo-HtmlSafe` before injection to prevent XSS in email clients.

---

## Audit Automation: AVD User Audit

**File:** [`automation/avd/Get-AvdUserAudit.ps1`](automation/avd/Get-AvdUserAudit.ps1)

A compliance audit script for Azure Virtual Desktop environments. It enumerates every Application Group in the subscription and reports which users have access, alongside the RDP security properties configured on the parent Host Pool.

**Designed for Cloud Shell** — outputs a CSV directly to the working directory with no extra dependencies.

#### What it captures

| Column | Source | Description |
|--------|--------|-------------|
| `HostPool` | `Get-AzWvdHostPool` | Host Pool name parent of the Application Group |
| `AppGroup` | `Get-AzWvdApplicationGroup` | Application Group name |
| `User` | `Get-AzRoleAssignment` | Display name of the assigned user |
| `Email` | `Get-AzRoleAssignment` | UPN / sign-in name |
| `MTP_PTP_Redir` | `RdpProperty` → `deviceredirect` | Multi-Transport / PTP device redirection |
| `Drive_Redir` | `RdpProperty` → `drivesteredirect` | Drive redirection |
| `Clipboard_Redir` | `RdpProperty` → `redirectclipboard` | Clipboard redirection |
| `Printer_Redir` | `RdpProperty` → `redirectprinters` | Printer redirection |

RDP property values are normalized: `0` → `Disabled`, `1` → `Enabled`, absent → `Default`.

#### Usage

```powershell
# Run in Azure Cloud Shell or any session with Az modules authenticated
.\Get-AvdUserAudit.ps1
# Output: ./Auditoria_AVD.csv
```

#### Required permissions

`Desktop Virtualization Reader` (or higher) on the subscription scope.

---

## Key Features

| Feature | Implementation |
|---------|---------------|
| **Massive parallelism** | `Wait-AsrJobsMasivo` polls N TFO jobs simultaneously in a single loop; `Start-ThreadJob` runs Net/OS/Disk/SQL validations concurrently per VM |
| **OOM protection** | Char-count buffer with hard cap (`MaxRawLogChars`) prevents log accumulation from exhausting runbook memory |
| **SQL false positive guard** | Detects `NT AUTHORITY\SYSTEM` login failure and correctly classifies SQL Server as `Running` (not failed) |
| **Isolated VNet noise filter** | OS Health check filters 30+ known-benign event patterns (Kerberos, domain, VMware, Windows Update) before flagging errors |
| **Guaranteed partial report** | Global `trap` handler sends a partial HTML report even on fatal script interruption |
| **Global deadline enforcement** | All phase timeouts are capped against `$ScriptDeadlineMinutes = 170` to respect Azure Automation's 3-hour fair-share limit |
| **Tag auto-remediation** | `Modify` policy propagates `Ambiente` tag from RG to child resources without human intervention |
| **Parameterized policy effects** | Naming and tag policies support `Deny / Audit / Disabled` — deploy in `Audit` first, then harden |
| **ARM throttling mitigation** | 60s stagger between TFO launches, 2s stagger between pre-cleanup submissions |
| **Function injection to runspaces** | Serializes parent scope functions to strings; re-injects via `Set-Item function:` into isolated ThreadJob runspaces |
| **Named instance SQL resolution** | Falls back to registry TCP port lookup when SQL Browser is stopped on named instances |
| **Regex-hardened VM clone detection** | Requires `-test` suffix in clone name to avoid false positives matching the source VM or unrelated resources |
| **IaC-provisioned infrastructure** | Terraform modules provision the full ASR stack (Vault, Automation Account, Logic App, Storage) as a single deployable unit |
| **OIDC-only authentication** | Terraform backend and provider both use `use_oidc = true` — no client secrets or storage access keys committed or stored |
| **Entra RBAC as code** | App Roles (`L1.Support`, `DR.Admin`) declared in Terraform — role definitions are version-controlled and auditable |
| **Environment-isolated state** | Separate `.tfbackend` files per environment prevent state cross-contamination between dev and prod |
| **Soft-delete + prevent_destroy** | RSV has `soft_delete_enabled = true` and `prevent_destroy = true` — protects production replication data from accidental `terraform destroy` |
| **Arc DINE — credential-free agent install** | DINE policy deploys agent MSI via Arc IMDS (`localhost:40342`) Managed Identity token — no SAS tokens, no stored credentials anywhere in the policy definition |
| **Arc IMDS vs VM IMDS scoping** | Script uses port `40342` (Arc-specific endpoint), not `169.254.169.254` — prevents accidental execution on non-Arc VMs |
| **AVD compliance audit** | Cross-host-pool user enumeration with RDP security property mapping — exportable CSV for security reviews and access certifications |
| **RDP property normalization** | `Get-RdpProperty` maps raw RDP string values (`0`/`1`/absent) to human-readable `Disabled`/`Enabled`/`Default` across all redirection dimensions |

---

## Prerequisites & Deployment

### Policies

1. **Deploy each policy definition** to the target Management Group or Subscription:

```bash
az policy definition create \
  --name "enforce-rg-naming-convention" \
  --display-name "Enforce Naming Convention on Resource Groups" \
  --rules policies/governance/naming-convention-rg.json \
  --mode All

az policy definition create \
  --name "mandatory-tag-ambiente" \
  --display-name "Mandatory Tag: Ambiente on Resource Groups" \
  --rules policies/governance/mandatory-tag-ambiente.json \
  --mode All

az policy definition create \
  --name "inherit-tag-ambiente" \
  --display-name "Inherit Tag Ambiente from Resource Group" \
  --rules policies/governance/inherit-tag-ambiente.json \
  --mode Indexed
```

2. **Assign** each definition to the desired scope with appropriate parameters.

3. For `inherit-tag-ambiente`: enable the **System-Assigned Managed Identity** on the assignment and grant it the **Tag Contributor** role on the subscription.

4. Create a **Remediation Task** to back-fill existing non-compliant resources.

---

### Terraform IaC

#### Prerequisites

- Terraform `>= 1.7.0`
- Azure CLI with OIDC-capable service principal (Federated Identity Credential)
- Two Azure Storage Accounts pre-created for Terraform state (one per environment)

#### Deployment

```bash
cd infra/terraform

# Initialize with the target environment backend
terraform init -backend-config=backend-dev.tfbackend

# Preview changes
terraform plan -var-file=dev.tfvars

# Apply
terraform apply -var-file=dev.tfvars
```

Sensitive values are passed via environment variables — never stored in `.tfvars`:

```bash
export TF_VAR_subscription_id="<your-subscription-id>"
export TF_VAR_tenant_id="<your-tenant-id>"
export TF_VAR_sql_admin_password="<strong-password>"
```

#### Required Permissions for the Terraform Service Principal

| Role | Scope | Purpose |
|------|-------|---------|
| `Contributor` | Subscription | Create and manage all resources |
| `User Access Administrator` | Subscription | Assign RBAC roles to the Automation Account Managed Identity |
| Application Administrator | Entra ID | Create App Registrations and Service Principals |

---

### ASR Automation Runbook

#### Required Azure Automation Variables

| Variable Name | Scope | Description |
|--------------|-------|-------------|
| `ASR_SubscriptionId` | Shared | Target subscription ID |
| `ASR_LogicAppWebhookUrl` | Shared | Logic App HTTP trigger URL for report delivery |
| `ASR_MailTo` | Shared | Comma/semicolon-separated recipient list |
| `ASR_VaultResourceGroup_[Country]` | Per-country | Resource Group hosting the Recovery Services Vault |
| `ASR_VaultName_[Country]` | Per-country | Recovery Services Vault name |
| `ASR_TestVnetResourceId_[Country]` | Per-country | Full ARM Resource ID of the isolated test VNet |
| `ASR_MailSubject_[Country]` | Per-country | Email subject prefix for reports |

#### Required Modules (Azure Automation)

```
Az.Accounts
Az.RecoveryServices
Az.Network
Az.Compute
Az.Storage
Az.Resources
Microsoft.PowerShell.ThreadJob  ← required for Phase 3 parallelism
```

#### Managed Identity Permissions

The Automation Account Managed Identity requires the following roles on the target subscription:

| Role | Purpose |
|------|---------|
| `Virtual Machine Contributor` | Execute `Invoke-AzVMRunCommand` for in-guest probes |
| `Site Recovery Operator` | Start/cleanup TFO jobs |
| `Network Contributor` (Reader minimum) | Validate test VNet existence and fetch NIC IPs |
| `Reader` | List VMs, disks, and Recovery Services items |

#### Logic App

The Logic App triggered by `ASR_LogicAppWebhookUrl` should:
1. Receive the JSON payload (subscription, vault, vmResults, htmlReportBase64, rawLogBase64, sendTo, subject)
2. Base64-decode `htmlReportBase64` → attach as `ASR-Report.html`
3. Base64-decode `rawLogBase64` → attach as `execution.log`
4. Base64-decode `infoErrorsBase64` → attach as `informational-errors.txt`
5. Send via Office 365 / SendGrid connector

---

## Environment Taxonomy

All policies and the ASR runbook operate around a **three-tier environment taxonomy**:

| Tag Value | Meaning | Naming segment |
|-----------|---------|---------------|
| `PROD` | Production workloads | `-PROD-` |
| `PREPROD` | Pre-production / staging | `-PREPROD-` |
| `DESA` | Development (from Spanish: *Desarrollo*) | `-DESA-` |

This taxonomy is enforced at the Resource Group level (Deny), inherited by all child resources (Modify), and used by the ASR runbook as the primary classification dimension in the executive HTML report.
