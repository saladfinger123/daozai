param(
    [switch]$SkipBuild,
    [string]$Executable,
    [string]$NsisCompiler,
    [string]$OutputDirectory,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Push-Location $projectRoot
try {
    $version = [regex]::Match((Get-Content Cargo.toml -Raw), '(?m)^version = "([^"]+)"').Groups[1].Value
    # 发布版不嵌入构建机器的用户目录和项目路径：依赖源码路径换成中性前缀，PDB 只记文件名。
    # 用 CARGO_ENCODED_RUSTFLAGS（\x1f 分隔）避免路径里的空格被拆开；它会覆盖 .cargo/config.toml 的 rustflags，所以带上 crt-static。
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    $env:CARGO_ENCODED_RUSTFLAGS = @('-C', 'target-feature=+crt-static', "--remap-path-prefix=$cargoHome=cargo", "--remap-path-prefix=$projectRoot=daozai", '-C', 'link-arg=/PDBALTPATH:%_PDB%') -join [char]0x1f
    $triple = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    # x64 继续使用原来的工具链名。ARM64 运行器上的 stable 就是 aarch64-pc-windows-msvc。
    $toolchain = if ($Architecture -eq 'arm64') { 'stable' } else { 'stable-x86_64-pc-windows-msvc' }
    if (-not $SkipBuild) {
        $env:CARGO_BUILD_JOBS = '1'
        cargo "+$toolchain" build --locked --release --bin daozai --target $triple
        if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }
    }
    if (-not $Executable) {
        $targetDirectory = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $projectRoot 'target' }
        $Executable = Join-Path $targetDirectory "$triple\release\daozai.exe"
    }
    $binary = Get-Item -LiteralPath $Executable
    $audit = @(& (Join-Path $PSScriptRoot 'check-runtime.ps1') -Executable $binary.FullName -Architecture $Architecture)
    $audit | Write-Output
    if ($binary.VersionInfo.FileVersion -ne $version -and $binary.VersionInfo.FileVersion -ne "$version.0") { throw 'Executable version mismatch' }
    $content = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($binary.FullName))
    foreach ($private in @($env:USERPROFILE, $projectRoot)) {
        if ($private -and $content.Contains($private)) { throw "Executable embeds a build-machine path: $private" }
    }
    $packageName = "Daozai-v$version-windows-$Architecture"
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
    $outputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $stagingDirectory = Join-Path $outputDirectory $packageName
    if (Test-Path -LiteralPath $stagingDirectory) { throw 'Package directory already exists' }
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    Copy-Item -LiteralPath $binary.FullName -Destination (Join-Path $stagingDirectory 'daozai.exe')
    # ZIP 保留给免安装使用和应用内更新。x64 另外做 NSIS 安装器；ARM64 不做。
    # NSIS 3.13 的安装器本体是 32 位 PE（机器类型 0x14C），在 ARM64 上要靠模拟运行。
    @('LICENSE','THIRD_PARTY_NOTICES.txt') | ForEach-Object {
        Copy-Item -LiteralPath (Join-Path $projectRoot $_) -Destination $stagingDirectory -Recurse
    }
    $hashed = @()
    if ($Architecture -eq 'x64') {
        if (-not $NsisCompiler) {
            $compiler = Get-Command makensis.exe -ErrorAction SilentlyContinue
            if ($compiler) { $NsisCompiler = $compiler.Source }
            elseif ($env:NSIS_HOME) { $NsisCompiler = Join-Path $env:NSIS_HOME 'makensis.exe' }
            else { $NsisCompiler = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe' }
        }
        if (-not (Test-Path -LiteralPath $NsisCompiler)) { throw 'NSIS compiler not found; install NSIS or pass -NsisCompiler' }
        $setup = Join-Path $outputDirectory "Daozai-Setup-v$version-x64.exe"
        & $NsisCompiler /V2 /WX "/DAPP_VERSION=$version" "/DPROJECT_DIR=$projectRoot" "/DSOURCE_EXE=$($binary.FullName)" "/DOUTPUT_FILE=$setup" (Join-Path $projectRoot 'installer\setup.nsi')
        if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
        $hashed += $setup
        Write-Output $setup
    } else {
        @'
岛仔 Windows ARM64 便携包。
daozai.exe 的构建目标是 aarch64-pc-windows-msvc，应为 PE32+、机器类型 0xAA64，并静态链接 C 运行库。
本包不含安装程序。NSIS 3.13 生成的安装器本体是 32 位（机器类型 0x14C），在 ARM64 Windows 上需要模拟执行。
应用内更新只接受本仓库 saladfinger123/daozai 的 Daozai-v<版本>-windows-arm64.zip，不会改用上游 x64 包。
打包机上的 PE 检查不能代替在具体 ARM 设备上的运行测试。
'@ | Set-Content -LiteralPath (Join-Path $stagingDirectory 'ARM64.txt') -Encoding utf8
    }
    $archive = Join-Path $outputDirectory "$packageName.zip"
    Compress-Archive -LiteralPath $stagingDirectory -DestinationPath $archive
    $hashed += $archive
    $hashed | ForEach-Object {
        $checksum = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        "$checksum  $([IO.Path]::GetFileName($_))"
    } | Set-Content -LiteralPath (Join-Path $outputDirectory 'SHA256SUMS.txt') -Encoding ascii
    $audit | Set-Content -LiteralPath (Join-Path $outputDirectory 'runtime-audit.txt') -Encoding utf8
    Write-Output $archive
} finally { Pop-Location }
