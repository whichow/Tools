[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Target,
    [ValidateSet('repo','org')][string]$Scope = 'repo',
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [switch]$KeepFiles
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    return Get-PlainText (Read-Host 'GitHub token' -AsSecureString)
}
function Post([string]$Url,[string]$Token) {
    Invoke-RestMethod -Method Post -Uri $Url -Headers @{
        Accept='application/vnd.github+json'; Authorization="Bearer $Token";
        'X-GitHub-Api-Version'='2026-03-10'; 'User-Agent'='whichow-runner-bootstrap'
    }
}

$InstallDir = (Resolve-Path $InstallDir).Path
if (-not (Test-Path (Join-Path $InstallDir '.runner'))) { throw "No configured runner found at $InstallDir" }
$token = Get-GitHubToken
$removeUrl = if ($Scope -eq 'repo') {
    "https://api.github.com/repos/$Target/actions/runners/remove-token"
} else {
    "https://api.github.com/orgs/$Target/actions/runners/remove-token"
}
$remove = Post $removeUrl $token
$removeToken = $remove.token

# Stop any interactive runner process whose executable lives in this install directory.
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like '*Runner.Listener*' -and $_.ExecutablePath -like "$InstallDir*"
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Push-Location $InstallDir
try {
    & .\config.cmd remove --unattended --token $removeToken
    if ($LASTEXITCODE -ne 0) { throw "config.cmd remove failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }

# Remove per-user startup launchers created by install-runner.ps1.
$startupDir = [Environment]::GetFolderPath('Startup')
Get-ChildItem $startupDir -Filter 'GitHubRunner-*.cmd' -ErrorAction SilentlyContinue | ForEach-Object {
    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -like "*$InstallDir*") { Remove-Item $_.FullName -Force }
}

if (-not $KeepFiles) { Remove-Item $InstallDir -Recurse -Force }
Write-Host "Runner removed from $Target" -ForegroundColor Green
