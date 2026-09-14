[CmdletBinding()]
param(
    [string]$Target = "",
    [ValidateSet("repo", "org")]
    [string]$Scope = "repo",
    [ValidateSet("auto", "gpu", "mac", "scanner", "android", "robot", "generic")]
    [string]$Preset = "auto",
    [string]$RunnerName = "",
    [string]$InstallRoot = "C:\actions-runners",
    [string]$Labels = "",
    [ValidateSet("auto", "service", "user")]
    [string]$Mode = "auto",
    [switch]$AllowPublicRepository
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-PlainText([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-GitHubToken {
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $value = (& gh auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $value) { return $value.Trim() }
    }
    Write-Host "No GH_TOKEN / gh auth token found." -ForegroundColor Yellow
    Write-Host "Paste a GitHub token with repository Administration:write permission." -ForegroundColor Yellow
    return Get-PlainText (Read-Host "GitHub token" -AsSecureString)
}

function Invoke-GitHubGet([string]$Url, [string]$Token) {
    return Invoke-RestMethod -Method Get -Uri $Url -Headers @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $Token"
        "X-GitHub-Api-Version" = "2026-03-10"
        "User-Agent" = "whichow-runner-bootstrap"
    }
}

function Invoke-GitHubPost([string]$Url, [string]$Token) {
    return Invoke-RestMethod -Method Post -Uri $Url -Headers @{
        Accept = "application/vnd.github+json"
        Authorization = "Bearer $Token"
        "X-GitHub-Api-Version" = "2026-03-10"
        "User-Agent" = "whichow-runner-bootstrap"
    }
}

function Normalize-Label([string]$Value) {
    $v = $Value.ToLowerInvariant() -replace '[^a-z0-9._-]', '-'
    return $v.Trim('-')
}

function Resolve-CustomLabels([string]$PresetName, [string]$ExtraLabels) {
    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("host-$(Normalize-Label $env:COMPUTERNAME)")

    switch ($PresetName) {
        "gpu" {
            $items.Add("gpu"); $items.Add("unity"); $items.Add("ai-video")
            try {
                $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -ExpandProperty Name) -join " "
                if ($gpuNames -match 'RTX\s*5080') { $items.Add("rtx5080") }
                if ($gpuNames -match 'NVIDIA') { $items.Add("nvidia") }
            } catch { }
        }
        "scanner" {
            $items.Add("scanner-x1"); $items.Add("usb"); $items.Add("ble"); $items.Add("wifi"); $items.Add("unity")
        }
        "android" {
            $items.Add("android-device"); $items.Add("adb"); $items.Add("camera")
        }
        "robot" {
            $items.Add("robot"); $items.Add("esp32"); $items.Add("camera")
        }
        "mac" { $items.Add("xcode"); $items.Add("unity") }
        "generic" { $items.Add("ci") }
        "auto" {
            $items.Add("ci")
            try {
                $gpuNames = (Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -ExpandProperty Name) -join " "
                if ($gpuNames -match 'NVIDIA') { $items.Add("gpu"); $items.Add("nvidia") }
                if ($gpuNames -match 'RTX\s*5080') { $items.Add("rtx5080"); $items.Add("unity"); $items.Add("ai-video") }
            } catch { }
            if (Get-Command adb -ErrorAction SilentlyContinue) { $items.Add("adb") }
        }
    }

    if ($ExtraLabels) {
        foreach ($label in ($ExtraLabels -split ',')) {
            $clean = Normalize-Label $label
            if ($clean) { $items.Add($clean) }
        }
    }

    return (($items | Select-Object -Unique) -join ',')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Target) {
    $defaultTarget = "whichow/PrivacyCamera"
    $answer = Read-Host "Repository (owner/repo) or organization [$defaultTarget]"
    $Target = if ($answer) { $answer } else { $defaultTarget }
}

$token = Get-GitHubToken
if (-not $token) { throw "GitHub authentication token is required." }

if ($Scope -eq "repo") {
    if ($Target -notmatch '^[^/]+/[^/]+$') { throw "Repo scope target must be owner/repo." }
    Write-Step "Checking repository $Target"
    $repo = Invoke-GitHubGet "https://api.github.com/repos/$Target" $token
    if (-not $repo.private -and -not $AllowPublicRepository) {
        throw "Refusing to attach a self-hosted runner to public repository '$Target'. Use -AllowPublicRepository only if you accept the security risk."
    }
    $registrationUrl = "https://api.github.com/repos/$Target/actions/runners/registration-token"
    $scopeUrl = "https://github.com/$Target"
} else {
    if ($Target -match '/') { throw "Org scope target must be the organization login only." }
    $registrationUrl = "https://api.github.com/orgs/$Target/actions/runners/registration-token"
    $scopeUrl = "https://github.com/$Target"
}

if (-not $RunnerName) {
    $RunnerName = "$(Normalize-Label $env:COMPUTERNAME)-$Preset"
}
$RunnerName = Normalize-Label $RunnerName
if ($RunnerName.Length -gt 64) { $RunnerName = $RunnerName.Substring(0, 64) }

$customLabels = Resolve-CustomLabels $Preset $Labels
if ($Mode -eq "auto") {
    $Mode = if ($Preset -in @("gpu", "scanner", "android", "robot")) { "user" } else { "service" }
}

$targetKey = Normalize-Label ($Target -replace '/', '-')
$installDir = Join-Path $InstallRoot "$targetKey-$RunnerName"

Write-Step "Runner plan"
Write-Host "Target : $Scope $Target"
Write-Host "Name   : $RunnerName"
Write-Host "Labels : $customLabels"
Write-Host "Mode   : $Mode"
Write-Host "Path   : $installDir"

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

if (Test-Path (Join-Path $installDir '.runner')) {
    Write-Host "Runner is already configured in $installDir; no destructive re-registration performed." -ForegroundColor Green
    if ($Mode -eq "service") {
        Get-Service 'actions.runner.*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Running' } | Start-Service -ErrorAction SilentlyContinue
    }
    exit 0
}

Write-Step "Resolving latest GitHub Actions Runner"
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" -Headers @{ "User-Agent" = "whichow-runner-bootstrap" }
$arch = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
    "ARM64" { "arm64" }
    default { "x64" }
}
$asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-$arch-*.zip" } | Select-Object -First 1
if (-not $asset) { throw "No Windows $arch runner asset found in $($release.tag_name)." }

$zip = Join-Path $env:TEMP $asset.name
Write-Step "Downloading $($asset.name)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $installDir -Force
Remove-Item $zip -Force -ErrorAction SilentlyContinue

Write-Step "Creating one-hour registration token"
$registration = Invoke-GitHubPost $registrationUrl $token
$registrationToken = $registration.token
if (-not $registrationToken) { throw "GitHub did not return a runner registration token." }

Push-Location $installDir
try {
    $configArgs = @(
        '--unattended',
        '--replace',
        '--url', $scopeUrl,
        '--token', $registrationToken,
        '--name', $RunnerName,
        '--work', '_work',
        '--labels', $customLabels
    )

    if ($Mode -eq "service") {
        if (-not (Test-IsAdministrator)) {
            throw "Service mode needs an elevated PowerShell. Re-run as Administrator or use -Mode user."
        }
        $configArgs += '--runasservice'
    }

    Write-Step "Registering runner"
    & .\config.cmd @configArgs
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }

    if ($Mode -eq "user") {
        Write-Step "Installing per-user startup launcher"
        $starter = Join-Path $installDir 'start-runner-hidden.ps1'
        @"
`$ErrorActionPreference = 'SilentlyContinue'
`$dir = '$($installDir.Replace("'", "''"))'
`$run = Join-Path `$dir 'run.cmd'
if (-not (Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -like "*Runner.Listener*" -and `$_.ExecutablePath -like "`$dir*" })) {
    Start-Process -FilePath `$run -WorkingDirectory `$dir -WindowStyle Hidden
}
"@ | Set-Content -Path $starter -Encoding UTF8

        $startupDir = [Environment]::GetFolderPath('Startup')
        $startupCmd = Join-Path $startupDir "GitHubRunner-$RunnerName.cmd"
        "@echo off`r`npowershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$starter`"`r`n" | Set-Content -Path $startupCmd -Encoding ASCII
        & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $starter
    }
} finally {
    Pop-Location
    $registrationToken = $null
    $token = $null
}

Write-Step "Done"
Write-Host "Runner '$RunnerName' is registered for $scopeUrl" -ForegroundColor Green
Write-Host "Custom labels: $customLabels" -ForegroundColor Green
if ($Mode -eq 'user') {
    Write-Host "Hardware/GPU mode runs in your interactive Windows session and starts at login." -ForegroundColor Yellow
} else {
    Write-Host "Runner is installed as a Windows service and starts with the machine." -ForegroundColor Green
}
Write-Host "Use runs-on labels such as: [self-hosted, Windows, $($customLabels -split ',' | Select-Object -First 1)]"
