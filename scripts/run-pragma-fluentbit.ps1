<#
.SYNOPSIS
    Lanza el fork interno de Fluent Bit (Pragma) usando el binario recien
    compilado en build/bin/Release/fluent-bit.exe.

.DESCRIPTION
    Replica la inyeccion de entorno que hace logsync.run_fluentbit cuando el
    sidecar arranca como parte del MCP, pero apuntando al .exe del fork:
      - AWS_SHARED_CREDENTIALS_FILE = $HOME/.aws/credentials
      - HOME / USERPROFILE explicitos para que el AWS C SDK encuentre el
        archivo de credenciales en Windows
      - USER_ALIAS y APP_NAME para que el conf expanda los placeholders

    Util para validar end-to-end el envio cross-account a Kinesis usando
    'stream_arn' antes de empacar el binario y publicarlo al feed.

.PARAMETER Conf
    Ruta al fluent-bit.conf. Default: el conf que ya genera logsync para
    pragma-architect-ai en %LOCALAPPDATA%\.pragma\fluentbit\<APP_NAME>\.

.PARAMETER Exe
    Ruta al fluent-bit.exe del fork. Default: build/bin/Release/fluent-bit.exe
    relativo a la raiz del repo.

.PARAMETER AppName
    APP_NAME a inyectar. Default: 'pragma-architect-ai'.

.PARAMETER UserAlias
    Alias de usuario para s3_key_format y partition keys. Default: si existe
    %LOCALAPPDATA%\.pragma\logsync\cognito_token.txt.id se usa el email del
    JWT, en caso contrario el hostname.

.PARAMETER AwsProfile
    Perfil AWS a exportar via AWS_PROFILE. Default: 'pragma-sso'.

.PARAMETER KillExisting
    Mata cualquier fluent-bit.exe en ejecucion antes de lanzar. Default: $true.

.PARAMETER Tail
    Cuantas lineas mostrar despues de iniciar antes de retornar el control.
    Default: 0 (no espera, deja FB corriendo en primer plano).

.EXAMPLE
    pwsh -File scripts/run-pragma-fluentbit.ps1

.EXAMPLE
    pwsh -File scripts/run-pragma-fluentbit.ps1 -Conf D:\path\fluent-bit.conf
#>

[CmdletBinding()]
param(
    [string]$Conf,
    [string]$Exe,
    [string]$AppName    = "pragma-architect-ai",
    [string]$UserAlias,
    [string]$AwsProfile = "pragma-sso",
    [bool]$KillExisting = $true,
    [int]$Tail          = 0
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoRoot = Split-Path -Parent $PSScriptRoot

# -----------------------------------------------------------------------------
# 1. Resolver fluent-bit.exe del fork
# -----------------------------------------------------------------------------
if (-not $Exe) {
    $candidates = @(
        (Join-Path $RepoRoot 'build\bin\Release\fluent-bit.exe'),
        (Join-Path $RepoRoot 'build\bin\fluent-bit.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $Exe = $c; break }
    }
    if (-not $Exe) {
        throw "No encuentro fluent-bit.exe del fork. Compilalo primero con scripts/build-windows-package.ps1 o pasa -Exe."
    }
}
Write-Host "==> Exe: $Exe"
$ver = & $Exe --version 2>&1 | Select-Object -First 1
Write-Host "==> $ver"
if ($ver -notmatch 'pragma') {
    Write-Warning "El exe no parece ser el fork de Pragma (no contiene 'pragma' en --version). Continuo de todos modos."
}

# -----------------------------------------------------------------------------
# 2. Resolver USER_ALIAS (mismo algoritmo que run_fluentbit.py)
# -----------------------------------------------------------------------------
function Resolve-UserAlias {
    $idTokenPath = Join-Path $env:LOCALAPPDATA '.pragma\logsync\cognito_token.txt.id'
    if (Test-Path $idTokenPath) {
        try {
            $token = (Get-Content $idTokenPath -Raw).Trim()
            $parts = $token.Split('.')
            if ($parts.Count -ge 2) {
                $payloadB64 = $parts[1]
                $padding = (4 - ($payloadB64.Length % 4)) % 4
                $payloadB64 = $payloadB64 + ('=' * $padding)
                $payloadB64 = $payloadB64.Replace('-', '+').Replace('_', '/')
                $bytes = [System.Convert]::FromBase64String($payloadB64)
                $json = [System.Text.Encoding]::UTF8.GetString($bytes)
                $claims = $json | ConvertFrom-Json
                $email = if ($claims.email) { $claims.email } else { $claims.'cognito:username' }
                if ($email -and $email.Contains('@')) {
                    $alias = $email.Split('@', 2)[0]
                    $alias = ($alias -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.').ToLower()
                    if ($alias) { return $alias }
                }
            }
        } catch {
            Write-Verbose "No se pudo leer id_token: $_"
        }
    }
    # Fallback: hostname sanitizado
    $h = [System.Net.Dns]::GetHostName()
    $h = ($h -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.').ToLower()
    if ($h) { return $h } else { return 'unknown-host' }
}

if (-not $UserAlias) {
    $UserAlias = Resolve-UserAlias
}
Write-Host "==> USER_ALIAS=$UserAlias"

# -----------------------------------------------------------------------------
# 3. Resolver Conf (default: el que genera logsync)
# -----------------------------------------------------------------------------
if (-not $Conf) {
    $Conf = Join-Path $env:LOCALAPPDATA ".pragma\fluentbit\$AppName\fluent-bit.conf"
}
if (-not (Test-Path $Conf)) {
    throw "No existe el conf: $Conf. Genera uno con `python -m logsync.generate` o pasa -Conf."
}
Write-Host "==> Conf: $Conf"

# -----------------------------------------------------------------------------
# 4. Matar fluent-bit existente
# -----------------------------------------------------------------------------
if ($KillExisting) {
    $procs = Get-Process -Name 'fluent-bit' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "==> Matando $($procs.Count) proceso(s) fluent-bit previos..."
        $procs | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                Write-Host "    PID $($_.Id) terminado ($($_.Path))"
            } catch {
                Write-Warning "No se pudo matar PID $($_.Id): $_"
            }
        }
        Start-Sleep -Seconds 1
    }
}

# -----------------------------------------------------------------------------
# 5. Inyectar entorno AWS y lanzar
# -----------------------------------------------------------------------------
$home_dir = $env:USERPROFILE
$creds = Join-Path $home_dir '.aws\credentials'
if (-not (Test-Path $creds)) {
    Write-Warning "No existe $creds. Sin esto el plugin de Kinesis no podra autenticar."
}

$env:AWS_SHARED_CREDENTIALS_FILE = $creds
$env:HOME                        = $home_dir
$env:USERPROFILE                 = $home_dir
$env:USER_ALIAS                  = $UserAlias
$env:APP_NAME                    = $AppName
$env:AWS_PROFILE                 = $AwsProfile
if (-not $env:HOSTNAME) { $env:HOSTNAME = [System.Net.Dns]::GetHostName() }

Write-Host "==> Entorno inyectado:"
Write-Host "    AWS_SHARED_CREDENTIALS_FILE = $env:AWS_SHARED_CREDENTIALS_FILE"
Write-Host "    AWS_PROFILE                 = $env:AWS_PROFILE"
Write-Host "    APP_NAME                    = $env:APP_NAME"
Write-Host "    USER_ALIAS                  = $env:USER_ALIAS"
Write-Host ""

# -----------------------------------------------------------------------------
# 6. Ejecutar
# -----------------------------------------------------------------------------
if ($Tail -gt 0) {
    # Modo background con captura para inspeccion rapida
    $logFile = Join-Path $env:TEMP "pragma-fluent-bit-$PID.log"
    Write-Host "==> Lanzando en background, log: $logFile"
    $proc = Start-Process -FilePath $Exe -ArgumentList @('-c', $Conf) `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError "$logFile.err" `
        -PassThru -NoNewWindow
    Write-Host "==> PID: $($proc.Id)"
    Start-Sleep -Seconds 5
    Write-Host "--- log (ultimas $Tail lineas) ---"
    Get-Content $logFile -Tail $Tail -ErrorAction SilentlyContinue
    Write-Host "--- stderr (ultimas $Tail lineas) ---"
    Get-Content "$logFile.err" -Tail $Tail -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "FB sigue corriendo (PID $($proc.Id)). Para detenerlo: Stop-Process -Id $($proc.Id)"
} else {
    # Modo foreground: bloquea hasta Ctrl+C
    Write-Host "==> Lanzando en primer plano (Ctrl+C para detener)..."
    & $Exe -c $Conf
}
