<#
.SYNOPSIS
    Quick SSH connect to a remote support session.

.DESCRIPTION
    Connects to an on-site PC through the tunnel set up by site-setup.sh.
    Just paste the details the script gave you.

.EXAMPLE
    .\office-connect.ps1
    # Interactive — asks for host, port, user

.EXAMPLE
    .\office-connect.ps1 -Host bore.pub -Port 54321 -User support_a3f8
    # Direct connection
#>

param(
    [string]$RemoteHost,
    [int]$Port,
    [string]$User
)

# ── Interactive mode if params not provided ───────────────────
Write-Host ""
Write-Host "  ══════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   Remote Support — Office Connect" -ForegroundColor Cyan
Write-Host "  ══════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if (-not $RemoteHost) {
    $RemoteHost = Read-Host "  Enter host (e.g. bore.pub)"
}
if (-not $Port) {
    $Port = Read-Host "  Enter port (e.g. 54321)"
}
if (-not $User) {
    $User = Read-Host "  Enter username (e.g. support_a3f8)"
}

Write-Host ""
Write-Host "  Connecting to $User@${RemoteHost}:$Port ..." -ForegroundColor Green
Write-Host ""

# ── Connect ───────────────────────────────────────────────────
ssh "${User}@${RemoteHost}" -p $Port
