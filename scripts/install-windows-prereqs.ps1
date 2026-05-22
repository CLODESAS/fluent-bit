<#
.SYNOPSIS
    Instala los pre-requisitos para compilar Fluent Bit en Windows x64.

.DESCRIPTION
    Asegura, de forma idempotente, las herramientas necesarias para que
    scripts/build-windows-package.ps1 corra sin intervencion manual:

      1. Visual Studio 2022 Build Tools con el workload C++
         (Microsoft.VisualStudio.Component.VC.Tools.x86.x64) y el SDK
         de Windows 10/11.
      2. CMake 3.x o superior.
      3. Git para Windows (necesario para clonar vcpkg).
      4. WIX Toolset 3.x (opcional, requerido para empaquetar MSI).

    Las dependencias de build (WinFlexBison, vcpkg + OpenSSL static) las
    gestiona build-windows-package.ps1 en el LOCALAPPDATA del usuario, asi
    no requieren elevacion ni cambian la maquina globalmente.

.PARAMETER InstallVisualStudio
    Instala VS Build Tools 2022 con C++ si no esta presente. Default: $true.

.PARAMETER InstallCMake
    Instala CMake si no esta presente. Default: $true.

.PARAMETER InstallGit
    Instala Git para Windows si no esta presente. Default: $true.

.PARAMETER InstallWix
    Instala WIX Toolset (necesario para CPack -G WIX). Default: $false.
    Sin WIX el script de build solo genera ZIP; con WIX genera MSI + ZIP.

.PARAMETER Force
    Reinstala los componentes aunque ya esten presentes.

.EXAMPLE
    pwsh -File scripts/install-windows-prereqs.ps1

.EXAMPLE
    # Instalacion completa incluyendo WIX para generar el MSI
    pwsh -File scripts/install-windows-prereqs.ps1 -InstallWix

.NOTES
    Requiere PowerShell 5.1+ ejecutandose con permisos de administrador
    (winget escala las instalaciones via UAC). En CI usa la imagen
    'windows-2022' que ya trae VS Build Tools y CMake; este script es
    idempotente y completa lo que falte.
#>

[CmdletBinding()]
param(
    [bool]$InstallVisualStudio = $true,
    [bool]$InstallCMake        = $true,
    [bool]$InstallGit          = $true,
    [bool]$InstallWix          = $false,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-WingetAvailable {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Invoke-Winget {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string[]]$ExtraArgs = @()
    )
    $args = @(
        'install',
        '--id', $Id,
        '--silent',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity'
    ) + $ExtraArgs
    Write-Host "==> winget $($args -join ' ')"
    & winget @args
    # winget retorna 0 si instalo, -1978335189 si ya estaba presente
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        throw "winget install $Id fallo (exit=$LASTEXITCODE)"
    }
}

function Test-CMakeInstalled {
    if (Get-Command cmake -ErrorAction SilentlyContinue) { return $true }
    return (Test-Path "C:\Program Files\CMake\bin\cmake.exe") -or `
           (Test-Path "$env:LOCALAPPDATA\Programs\CMake\bin\cmake.exe")
}

function Test-VisualStudioCpp {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $false }
    $path = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    return -not [string]::IsNullOrWhiteSpace($path)
}

function Test-WixInstalled {
    if (Get-Command candle -ErrorAction SilentlyContinue) { return $true }
    if (Test-Path "$env:WIX\bin\candle.exe") { return $true }
    foreach ($p in @(
        "C:\Program Files (x86)\WiX Toolset v3.14\bin\candle.exe",
        "C:\Program Files (x86)\WiX Toolset v3.11\bin\candle.exe"
    )) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
if (-not (Test-WingetAvailable)) {
    throw "winget no esta disponible. Instala App Installer desde la Microsoft Store o usa Windows 10 1809+."
}
Write-Host "==> winget version: $((winget --version) -replace '^v','')"

# -----------------------------------------------------------------------------
# 1. Visual Studio 2022 Build Tools + workload C++
# -----------------------------------------------------------------------------
if ($InstallVisualStudio) {
    if ($Force -or -not (Test-VisualStudioCpp)) {
        Write-Host "==> Instalando VS 2022 Build Tools con workload C++"
        # winget pasa los argumentos al installer via --override
        $override = @(
            '--quiet --wait --norestart --nocache',
            '--add Microsoft.VisualStudio.Workload.VCTools',
            '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
            '--add Microsoft.VisualStudio.Component.Windows10SDK.19041',
            '--add Microsoft.VisualStudio.Component.VC.CMake.Project',
            '--add Microsoft.VisualStudio.Component.VC.ATL'
        ) -join ' '
        Invoke-Winget -Id 'Microsoft.VisualStudio.2022.BuildTools' `
                      -ExtraArgs @('--override', $override)
    } else {
        Write-Host "==> VS Build Tools con C++ ya instalado, omitiendo"
    }
}

# -----------------------------------------------------------------------------
# 2. CMake
# -----------------------------------------------------------------------------
if ($InstallCMake) {
    if ($Force -or -not (Test-CMakeInstalled)) {
        Write-Host "==> Instalando CMake"
        Invoke-Winget -Id 'Kitware.CMake'
    } else {
        Write-Host "==> CMake ya instalado, omitiendo"
    }
    # Asegurar que esta en PATH para esta sesion
    $cmakeBin = "C:\Program Files\CMake\bin"
    if ((Test-Path "$cmakeBin\cmake.exe") -and -not ($env:PATH -split ";" | Where-Object { $_ -eq $cmakeBin })) {
        $env:PATH = "$cmakeBin;$env:PATH"
    }
}

# -----------------------------------------------------------------------------
# 3. Git para Windows
# -----------------------------------------------------------------------------
if ($InstallGit) {
    if ($Force -or -not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "==> Instalando Git for Windows"
        Invoke-Winget -Id 'Git.Git'
    } else {
        Write-Host "==> Git ya instalado, omitiendo"
    }
}

# -----------------------------------------------------------------------------
# 4. WIX Toolset (opcional, para empaquetar MSI con CPack)
# -----------------------------------------------------------------------------
if ($InstallWix) {
    if ($Force -or -not (Test-WixInstalled)) {
        Write-Host "==> Instalando WIX Toolset"
        # WIX 3.x es el que CPack -G WIX usa por defecto en CMake actual
        Invoke-Winget -Id 'WiXToolset.WiXToolset'
    } else {
        Write-Host "==> WIX Toolset ya instalado, omitiendo"
    }
}

# -----------------------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "==> Verificacion final:"
$rows = @()

if (Test-VisualStudioCpp) {
    $vsPath = & "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" `
        -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    $rows += [pscustomobject]@{ Tool = 'VS BuildTools (C++)'; Status = 'OK';      Detail = $vsPath }
} else {
    $rows += [pscustomobject]@{ Tool = 'VS BuildTools (C++)'; Status = 'MISSING'; Detail = 'reinicia la sesion y vuelve a correr el script' }
}

if (Test-CMakeInstalled) {
    $cmakeExe = (Get-Command cmake -ErrorAction SilentlyContinue).Source
    if (-not $cmakeExe) { $cmakeExe = "C:\Program Files\CMake\bin\cmake.exe" }
    $ver = (& $cmakeExe --version | Select-Object -First 1)
    $rows += [pscustomobject]@{ Tool = 'CMake'; Status = 'OK'; Detail = $ver }
} else {
    $rows += [pscustomobject]@{ Tool = 'CMake'; Status = 'MISSING'; Detail = '' }
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    $rows += [pscustomobject]@{ Tool = 'Git'; Status = 'OK'; Detail = (git --version) }
} else {
    $rows += [pscustomobject]@{ Tool = 'Git'; Status = 'MISSING'; Detail = '' }
}

if (Test-WixInstalled) {
    $rows += [pscustomobject]@{ Tool = 'WIX Toolset'; Status = 'OK';       Detail = 'CPack puede generar MSI' }
} else {
    $rows += [pscustomobject]@{ Tool = 'WIX Toolset'; Status = 'OPTIONAL'; Detail = 'sin MSI; ZIP funciona igual' }
}

$rows | Format-Table -AutoSize | Out-String | Write-Host

if ($rows | Where-Object { $_.Status -eq 'MISSING' -and $_.Tool -ne 'WIX Toolset' }) {
    Write-Warning "Faltan pre-requisitos. Si acabas de instalar VS Build Tools, abre una nueva consola para que el PATH se actualice."
    exit 1
}

Write-Host "==> Listo. Ejecuta: pwsh -File scripts/build-windows-package.ps1 -Clean"
