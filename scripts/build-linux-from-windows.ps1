<#
.SYNOPSIS
    Compila Fluent Bit desde Windows usando WSL (Ubuntu) para evitar los
    problemas de la build nativa de Windows (libevent, MSI, DNS resolver, etc.).

.DESCRIPTION
    Pipeline que asegura WSL listo, asegura que el script bash este sin CRLF,
    y delega a build-linux.sh, que a su vez:
      1. Detecta que estamos en /mnt/<drv>/ y se auto-sincroniza a ~/fluent-bit-pragma-build
      2. Normaliza line endings y permisos de los scripts vendorizados
      3. Ejecuta cmake configure + build con todas las dependencias

    El binario resultante queda en:
        \\wsl.localhost\Ubuntu-22.04\home\<usuario>\fluent-bit-pragma-build\build-linux\bin\fluent-bit

    Tambien lo copia a build-linux/fluent-bit (en el repo Windows) para
    facilitar el acceso desde scripts de Windows.

.PARAMETER Distro
    Distribucion WSL a usar. Default: 'Ubuntu-22.04'.

.PARAMETER Clean
    Pasa --clean al script de build (recompilacion limpia).

.EXAMPLE
    pwsh -File scripts/build-linux-from-windows.ps1 -Clean
#>

[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu-22.04",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
Write-Host "==> Repo Windows: $RepoRoot"
Write-Host "==> WSL distro: $Distro"

# 1. Verificar WSL. wsl.exe en Windows emite el listado en UTF-16LE,
# por lo que Out-String simple puede contener caracteres NUL (0x00). Hacemos
# matching tolerante reemplazando los NUL antes de comparar.
$wslListRaw = (wsl --list --quiet 2>$null | Out-String)
if ($LASTEXITCODE -ne 0) {
    throw "wsl --list --quiet fallo (exit=$LASTEXITCODE). WSL no disponible o no instalado."
}
$wslListClean = ($wslListRaw -replace "`0", "")
$distros = $wslListClean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not ($distros -contains $Distro)) {
    throw "La distribucion '$Distro' no esta disponible. Distros: $($distros -join ', ')"
}

# 2. Convertir path Windows a path WSL (D:\foo\bar -> /mnt/d/foo/bar)
function ConvertTo-WslPath {
    param([string]$WinPath)
    $p = $WinPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest  = $Matches[2]
        return "/mnt/$drive/$rest"
    }
    return $p
}

$wslRepo = ConvertTo-WslPath $RepoRoot
$logWin = Join-Path (Split-Path $RepoRoot -Parent) "fluent-bit-linux-build.log"
$wslLog = ConvertTo-WslPath $logWin

Write-Host "==> WSL repo path: $wslRepo"
Write-Host "==> Log: $logWin"

# 3. Asegurar el script bash sin CRLF (si lo edito alguien en Windows)
$buildScript = Join-Path $RepoRoot 'scripts\build-linux.sh'
if (Test-Path $buildScript) {
    # Reescribir el archivo con LF puros
    $content = Get-Content -Path $buildScript -Raw
    if ($content -match "`r`n") {
        Write-Host "==> Normalizando build-linux.sh a LF"
        $content = $content -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($buildScript, $content)
    }
}

# 4. Construir argumentos
$bashArgs = @()
if ($Clean) { $bashArgs += '--clean' }
$argString = ($bashArgs -join ' ')

# 5. Construir el script bash a ejecutar. Lo escribimos en un .sh temporal
#    con line endings LF (sin CRLF) en lugar de pasarlo via -c, porque las
#    here-strings de PowerShell se persisten con \r\n y bash interpreta el
#    \r como caracter literal, rompiendo 'cd', 'set -e' y demas.
$tempBash = New-TemporaryFile
$tempBashPath = $tempBash.FullName + '.sh'
Move-Item $tempBash.FullName $tempBashPath -Force

$scriptLines = @(
    'set -e'
    "cd '$wslRepo'"
    'chmod +x scripts/build-linux.sh 2>/dev/null || true'
    '# Asegurar que el script bash este sin CRLF (defensivo, idempotente)'
    'if command -v dos2unix >/dev/null 2>&1; then'
    '    dos2unix --quiet scripts/build-linux.sh 2>/dev/null || true'
    'else'
    "    sed -i 's/\r$//' scripts/build-linux.sh 2>/dev/null || true"
    'fi'
    "./scripts/build-linux.sh $argString 2>&1 | tee '$wslLog'"
)
# Escribir con LF puros (UTF-8 sin BOM)
[System.IO.File]::WriteAllText($tempBashPath, ($scriptLines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))

$tempBashWsl = ConvertTo-WslPath $tempBashPath

Write-Host "==> Ejecutando build dentro de WSL..."
Write-Host ""
try {
    wsl --distribution $Distro -- bash "$tempBashWsl"
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item $tempBashPath -ErrorAction SilentlyContinue
}

if ($exitCode -ne 0) {
    Write-Error "Build fallo (exit=$exitCode). Revisa $logWin"
    exit $exitCode
}

# 6. Copiar binario al repo Windows para que run-pragma-fluentbit pueda
#    encontrarlo sin necesidad de entrar a WSL manualmente.
$wslHome = wsl --distribution $Distro -- bash -c 'echo $HOME' | ForEach-Object { $_.Trim() }
$linuxBinaryWsl = "$wslHome/fluent-bit-pragma-build/build-linux/bin/fluent-bit"
$linuxBinaryUnc = "\\wsl.localhost\$Distro$($linuxBinaryWsl -replace '/', '\')"

if (Test-Path $linuxBinaryUnc) {
    $destDir = Join-Path $RepoRoot 'build-linux\bin'
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    $destBin = Join-Path $destDir 'fluent-bit'
    Copy-Item $linuxBinaryUnc $destBin -Force
    Write-Host ""
    Write-Host "==> Binario copiado a $destBin"
    Write-Host "    (tambien disponible directamente en WSL como $linuxBinaryWsl)"
} else {
    Write-Warning "No encuentro el binario en $linuxBinaryUnc"
}

Write-Host ""
Write-Host "==> Listo. Para ejecutarlo desde WSL contra Kinesis:"
Write-Host "    wsl -d $Distro -- $linuxBinaryWsl --version"
