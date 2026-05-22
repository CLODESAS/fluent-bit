<#
.SYNOPSIS
    Compila Fluent Bit para Windows x64 y genera el mismo paquete que el
    pipeline upstream (MSI + ZIP) usando CPack.

.DESCRIPTION
    Reproduce localmente la logica de packaging que appveyor.yml ejecuta en CI:
      - Asegura WinFlexBison
      - Asegura vcpkg con OpenSSL static (x64)
      - Configura el build con CMake (Visual Studio 2022 / 2019)
      - Compila con MSBuild en Release
      - Genera MSI (WIX, opcional) y ZIP con CPack

    El binario y los paquetes resultantes quedan en build/bin/Release y build/.

    Workarounds aplicados (ver flb_info.h.in y CMakeLists.txt del fork):
      - -DCMAKE_POLICY_VERSION_MINIMUM=3.5: CMake 4.x removio compatibilidad
        con cmake_minimum_required <3.5 y algunos sub-proyectos vendorizados
        (lib/monkey/.../libevent) la siguen declarando.
      - __FLB_FILENAME__ con fallback en flb_info.h.in: MSBuild en Windows
        pierde el define cuando se inyecta solo via CMAKE_C_FLAGS para algunos
        sub-vcxproj (filter_nest, etc.). El header lo resuelve a __FILE__ si
        la flag no llego.

.PARAMETER BuildDir
    Carpeta de build. Default: ./build

.PARAMETER Clean
    Borra build/ antes de configurar.

.PARAMETER SkipTests
    Omite FLB_TESTS_*. Default: $true.

.PARAMETER VsVersion
    "2022" (default) o "2019". Selecciona el generador de Visual Studio.

.EXAMPLE
    pwsh -File scripts/build-windows-package.ps1 -Clean

.NOTES
    Pre-requisitos:
      - Visual Studio Build Tools (workload "Desktop development with C++")
      - CMake 3.12 o superior, recomendado 3.x. Con CMake 4.x el script aplica
        el workaround CMAKE_POLICY_VERSION_MINIMUM=3.5 automaticamente.
      - Git en PATH
      - Conexion a internet (descarga vcpkg + winflexbison la primera vez)
      - WIX Toolset 3.x (opcional). Sin WIX el script genera solo ZIP.
        Instalalo con: winget install WiXToolset.WiXToolset
#>

[CmdletBinding()]
param(
    [string]$BuildDir = "build",
    [switch]$Clean,
    [bool]$SkipTests = $true,
    [ValidateSet("2022", "2019")][string]$VsVersion = "2022"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Ubicacion del repo (raiz: directorio padre de scripts/)
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    Write-Host "==> Repo root: $RepoRoot"

    # ----------------------------------------------------------------------
    # 1. WinFlexBison
    # ----------------------------------------------------------------------
    $WinFlexDir = Join-Path $env:LOCALAPPDATA "WinFlexBison"
    if (-not (Test-Path "$WinFlexDir\bison.exe")) {
        Write-Host "==> Instalando WinFlexBison en $WinFlexDir"
        $zip = Join-Path $env:TEMP "winflexbison.zip"
        $url = "https://github.com/lexxmark/winflexbison/releases/download/v2.5.22/win_flex_bison-2.5.22.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip
        if (Test-Path $WinFlexDir) { Remove-Item $WinFlexDir -Recurse -Force }
        Expand-Archive $zip -DestinationPath $WinFlexDir
        Copy-Item "$WinFlexDir\win_bison.exe" "$WinFlexDir\bison.exe"
        Copy-Item "$WinFlexDir\win_flex.exe"  "$WinFlexDir\flex.exe"
    }
    if (-not ($env:PATH -split ";" | Where-Object { $_ -eq $WinFlexDir })) {
        $env:PATH = "$WinFlexDir;$env:PATH"
    }
    Write-Host "==> bison: $((Get-Command bison.exe).Source)"

    # ----------------------------------------------------------------------
    # 2. vcpkg + OpenSSL static
    # ----------------------------------------------------------------------
    $VcpkgRoot = $env:VCPKG_ROOT
    if (-not $VcpkgRoot -or -not (Test-Path $VcpkgRoot)) {
        $VcpkgRoot = Join-Path $env:LOCALAPPDATA "vcpkg"
    }
    if (-not (Test-Path "$VcpkgRoot\vcpkg.exe")) {
        Write-Host "==> Clonando vcpkg en $VcpkgRoot"
        if (-not (Test-Path $VcpkgRoot)) {
            git clone --depth 1 https://github.com/microsoft/vcpkg.git $VcpkgRoot
        }
        & "$VcpkgRoot\bootstrap-vcpkg.bat" -disableMetrics
    }
    Write-Host "==> Asegurando openssl:x64-windows-static"
    & "$VcpkgRoot\vcpkg.exe" install openssl --triplet x64-windows-static --recurse
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install openssl fallo" }

    $OpenSslRoot = Join-Path $VcpkgRoot "packages\openssl_x64-windows-static"
    if (-not (Test-Path $OpenSslRoot)) {
        # vcpkg moderno usa instalacion en installed/
        $OpenSslRoot = Join-Path $VcpkgRoot "installed\x64-windows-static"
    }
    Write-Host "==> OPENSSL_ROOT_DIR=$OpenSslRoot"

    # ----------------------------------------------------------------------
    # 3. Build dir
    # ----------------------------------------------------------------------
    $BuildPath = Join-Path $RepoRoot $BuildDir
    if ($Clean -and (Test-Path $BuildPath)) {
        Write-Host "==> Limpiando $BuildPath"
        Remove-Item $BuildPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $BuildPath -Force | Out-Null

    # ----------------------------------------------------------------------
    # 4. CMake configure (Visual Studio generator)
    # ----------------------------------------------------------------------
    $cmakeGen = if ($VsVersion -eq "2019") { "Visual Studio 16 2019" } else { "Visual Studio 17 2022" }
    Write-Host "==> CMake configure ($cmakeGen, x64)"

    $cmakeArgs = @(
        "-S", $RepoRoot,
        "-B", $BuildPath,
        "-G", $cmakeGen,
        "-A", "x64",
        "-DOPENSSL_ROOT_DIR=$OpenSslRoot",
        # CMake 4.x removio compatibilidad con cmake_minimum_required <3.5;
        # algunos subproyectos vendorizados (lib/monkey/.../libevent) aun la
        # declaran. Esta politica les permite seguir configurando.
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        # libbacktrace es opcional (stacktraces en errores fatales) y su
        # ./configure detecta mal BACKTRACE_ELF_SIZE en algunos hosts. No
        # afecta el flujo Kinesis/S3/CloudWatch que necesitamos.
        "-DFLB_BACKTRACE=Off",
        "-DFLB_RELEASE=On",
        "-DFLB_DEBUG=Off",
        "-DFLB_OUT_KINESIS_STREAMS=On",
        "-DFLB_OUT_S3=On",
        "-DFLB_OUT_CLOUDWATCH_LOGS=On"
    )
    if ($SkipTests) {
        $cmakeArgs += @(
            "-DFLB_TESTS_INTERNAL=Off",
            "-DFLB_TESTS_RUNTIME=Off"
        )
    }
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure fallo" }

    # ----------------------------------------------------------------------
    # 5. Build (MSBuild Release)
    # ----------------------------------------------------------------------
    Write-Host "==> Compilando (Release)"
    & cmake --build $BuildPath --config Release -j 4
    if ($LASTEXITCODE -ne 0) { throw "cmake build fallo" }

    $exe = Join-Path $BuildPath "bin\Release\fluent-bit.exe"
    if (-not (Test-Path $exe)) {
        throw "No se genero $exe"
    }
    Write-Host "==> fluent-bit.exe generado"
    & $exe --version | Write-Host

    # ----------------------------------------------------------------------
    # 6. CPack: MSI (WIX) y ZIP
    # ----------------------------------------------------------------------
    Push-Location $BuildPath
    try {
        Write-Host "==> CPack: MSI (WIX)"
        # WIX requiere candle.exe + light.exe; CPack los detecta si estan en PATH
        $wixOk = $true
        try {
            & cpack -G WIX -C Release
            if ($LASTEXITCODE -ne 0) { $wixOk = $false }
        } catch {
            $wixOk = $false
        }
        if (-not $wixOk) {
            Write-Warning "CPack WIX fallo (probablemente WIX Toolset no instalado). Continuo con ZIP."
        }

        Write-Host "==> CPack: ZIP"
        & cpack -G ZIP -C Release
        if ($LASTEXITCODE -ne 0) { throw "cpack ZIP fallo" }
    } finally {
        Pop-Location
    }

    # ----------------------------------------------------------------------
    # 7. Resumen
    # ----------------------------------------------------------------------
    Write-Host ""
    Write-Host "==> Artefactos generados:"
    Get-ChildItem $BuildPath -Filter "fluent-bit-*" -File |
        Select-Object Name, @{n='SizeMB';e={[math]::Round($_.Length/1MB,2)}}, LastWriteTime |
        Format-Table -AutoSize | Out-String | Write-Host
} finally {
    Pop-Location
}
