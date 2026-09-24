# =============================================================================
# Script: setup-iis.ps1
# Description: Configure a cache-free IIS hostname page and health endpoint.
# =============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installation = Install-WindowsFeature -Name Web-Server -IncludeManagementTools
if (-not $installation.Success) {
    throw 'IIS installation failed.'
}
if ($installation.RestartNeeded -eq 'Yes') {
    throw 'IIS installation requires a restart; rerun setup after restarting.'
}

$webRoot = 'C:\inetpub\wwwroot'
New-Item -ItemType Directory -Path $webRoot -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\ChaosTemp' -Force | Out-Null

$hostname = $env:COMPUTERNAME
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($hostname))
}
finally {
    $sha256.Dispose()
}
$background = '#{0:x2}{1:x2}{2:x2}' -f (32 + ($hash[0] % 96)), (32 + ($hash[1] % 96)), (32 + ($hash[2] % 96))
$safeHostname = [System.Net.WebUtility]::HtmlEncode($hostname)
$page = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
  <title>IIS - $safeHostname</title>
  <style>body { background: $background; color: white; font-family: sans-serif; text-align: center; padding-top: 15vh; } h1 { font-size: 4rem; }</style>
</head>
<body><h1>$safeHostname</h1><p>Windows Server 2022 - IIS</p></body>
</html>
"@
$webConfig = @'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <defaultDocument enabled="true">
      <files><clear /><add value="Default.htm" /></files>
    </defaultDocument>
    <staticContent><clientCache cacheControlMode="NoControl" /></staticContent>
    <httpProtocol>
      <customHeaders>
        <remove name="Cache-Control" />
        <remove name="Pragma" />
        <remove name="Expires" />
        <add name="Cache-Control" value="no-store, no-cache, must-revalidate" />
        <add name="Pragma" value="no-cache" />
        <add name="Expires" value="0" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
'@
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path $webRoot 'Default.htm'), $page, $utf8)
[System.IO.File]::WriteAllText((Join-Path $webRoot 'health.htm'), 'OK', $utf8)
[System.IO.File]::WriteAllText((Join-Path $webRoot 'web.config'), $webConfig, $utf8)

$firewallRule = Get-NetFirewallRule -Name 'ChaosLab-HTTP' -ErrorAction SilentlyContinue
if ($firewallRule) {
    Remove-NetFirewallRule -Name 'ChaosLab-HTTP'
}
New-NetFirewallRule -Name 'ChaosLab-HTTP' -DisplayName 'Chaos Lab IIS HTTP' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Profile Any | Out-Null

Set-Service -Name W3SVC -StartupType Automatic
Start-Service -Name W3SVC
if ((Get-Service -Name W3SVC).Status -ne 'Running') {
    throw 'IIS W3SVC did not start.'
}

$health = Invoke-WebRequest -Uri 'http://localhost/health.htm' -UseBasicParsing -TimeoutSec 30
if ($health.StatusCode -ne 200 -or $health.Content.Trim() -ne 'OK') {
    throw 'IIS health endpoint did not return HTTP 200 with OK.'
}
