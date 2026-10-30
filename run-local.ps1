# Run both demo servers from the project root on Windows.
# Stop with Ctrl+C; the backend is stopped when the frontend exits.
$ErrorActionPreference = 'Stop'

$backendDir = Join-Path $PSScriptRoot 'bankProductCreation'
$frontendDir = Join-Path $PSScriptRoot 'bankProductFront'
$envFile = Join-Path $backendDir '.env.local'
$backendProcess = $null
$runFailed = $false

function Require-Program([string] $name, [string] $help) {
    $program = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $program) { throw "$name was not found. $help" }
    return $program.Source
}

function Read-Default([string] $label, [string] $default) {
    $answer = Read-Host "$label [$default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer
}

function Load-LocalEnvironment([string] $path) {
    $allowed = @('DB_URL', 'DB_USERNAME', 'DB_PASSWORD', 'APP_DATA_DIR',
        'APP_PUBLIC_BASE_URL', 'APP_DOCUMENT_MODE', 'APP_IMPORT_LEGACY_STATE',
        'SESSION_COOKIE_SECURE')
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim()
        } else { continue }
        if ($allowed -notcontains $name) { continue }
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Get-LanAddresses {
    $addresses = @()
    foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne 'Up') { continue }
        if ($adapter.NetworkInterfaceType -notin @('Ethernet', 'Wireless80211')) { continue }
        foreach ($entry in $adapter.GetIPProperties().UnicastAddresses) {
            $ip = $entry.Address
            if ($ip.AddressFamily -ne 'InterNetwork') { continue }
            if ([System.Net.IPAddress]::IsLoopback($ip) -or $ip.ToString().StartsWith('169.254.')) { continue }
            $addresses += $ip.ToString()
        }
    }
    return @($addresses | Select-Object -Unique)
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $backendDir 'mvnw.cmd')) -or
        -not (Test-Path -LiteralPath (Join-Path $frontendDir 'package-lock.json'))) {
        throw 'Run this launcher from a complete copy of the project (both bankProductCreation and bankProductFront folders).'
    }

    $java = Require-Program 'java.exe' 'Install JDK 21 or newer (JDK 25 is supported) and put it on PATH.'
    $null = Require-Program 'javac.exe' 'Install a JDK, not only a Java runtime.'
    $null = Require-Program 'node.exe' 'Install Node.js 20.19+ or 22.12+.'
    $npm = Require-Program 'npm.cmd' 'Install Node.js with npm.'
    $javaVersion = (& $java --version | Out-String)
    if ($javaVersion -match '^(?:openjdk|java)\s+(\d+)') {
        $javaMajor = [int]$Matches[1]
    } else {
        throw "Could not read Java version: $javaVersion"
    }
    if ($javaMajor -lt 21) { throw 'This project needs JDK 21 or newer.' }

    if (Test-Path -LiteralPath $envFile) {
        Load-LocalEnvironment $envFile
    } elseif (-not $env:DB_PASSWORD) {
        Write-Host 'First run: enter the credentials for an existing PostgreSQL database.'
        $dbUrl = Read-Default 'PostgreSQL JDBC URL' 'jdbc:postgresql://localhost:5432/bank_product'
        $dbUser = Read-Default 'PostgreSQL username' 'bank_product_owner'
        $securePassword = Read-Host 'PostgreSQL password' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        try { $dbPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        if (@($dbUrl, $dbUser, $dbPassword) | Where-Object { $_ -match '[\r\n]' }) {
            throw 'Database settings must each fit on one line.'
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllLines($envFile,
            @("DB_URL=$dbUrl", "DB_USERNAME=$dbUser", "DB_PASSWORD=$dbPassword"), $utf8)
        Load-LocalEnvironment $envFile
        Write-Host "Saved database settings in $envFile"
    }

    $lanAddresses = @(Get-LanAddresses)
    if (-not $env:APP_PUBLIC_BASE_URL -and $lanAddresses.Count -eq 1) {
        $env:APP_PUBLIC_BASE_URL = "http://$($lanAddresses[0]):5173"
    }
    $env:SERVER_ADDRESS = '127.0.0.1'

    $lockFile = Join-Path $frontendDir 'package-lock.json'
    $lockHash = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash
    $stamp = Join-Path $frontendDir 'node_modules\.run-local-lock.sha256'
    $viteBin = Join-Path $frontendDir 'node_modules\vite\bin\vite.js'
    $installedHash = if (Test-Path -LiteralPath $stamp) { (Get-Content -LiteralPath $stamp -Raw).Trim() } else { '' }
    if ($installedHash -ne $lockHash -or -not (Test-Path -LiteralPath $viteBin)) {
        Write-Host 'Installing frontend packages...'
        Push-Location $frontendDir
        try {
            & $npm ci
            if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
            Set-Content -LiteralPath $stamp -Value $lockHash -NoNewline
        } finally { Pop-Location }
    }

    Write-Host 'Building backend...'
    Push-Location $backendDir
    try {
        & (Join-Path $backendDir 'mvnw.cmd') -q -DskipTests package
        if ($LASTEXITCODE -ne 0) { throw 'Maven build failed.' }
    } finally { Pop-Location }

    Write-Host 'Starting backend on http://localhost:8080 ...'
    $backendProcess = Start-Process -FilePath $java -ArgumentList @('-jar', 'target\bankProductCreation-0.0.1-SNAPSHOT.jar') `
        -WorkingDirectory $backendDir -NoNewWindow -PassThru
    $ready = $false
    $startupTimer = [Diagnostics.Stopwatch]::StartNew()
    while ($startupTimer.Elapsed.TotalSeconds -lt 60) {
        $backendProcess.Refresh()
        if ($backendProcess.HasExited) {
            throw 'Backend stopped during startup. Check the error above and confirm PostgreSQL is running with the configured database and user.'
        }
        try {
            $null = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/api/auth/csrf' -UseBasicParsing -TimeoutSec 2
            $ready = $true
            break
        } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ready) { throw 'Backend did not become ready on port 8080 within 60 seconds.' }

    Write-Host 'Frontend: http://localhost:5173'
    foreach ($address in $lanAddresses) { Write-Host "Other computers on this network: http://$($address):5173" }
    Write-Host 'Allow port 5173 through Windows Firewall if another computer cannot connect.'
    Write-Host 'Press Ctrl+C to stop both servers.'
    Push-Location $frontendDir
    try {
        & $npm run dev -- --host 0.0.0.0 --port 5173 --strictPort
        if ($LASTEXITCODE -ne 0) { throw 'Frontend server stopped with an error.' }
    } finally { Pop-Location }
} catch {
    $runFailed = $true
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($backendProcess) {
        $backendProcess.Refresh()
        if (-not $backendProcess.HasExited) {
            Stop-Process -Id $backendProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
if ($runFailed) { exit 1 }
