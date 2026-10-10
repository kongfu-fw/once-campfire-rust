# ==============================================================================
# Campfire Windows PowerShell 本机一键部署与管理脚本
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "down", "stop", "restart", "logs", "status", "ps", "help", "")]
    [string]$Command = "up",

    [Alias("b")]
    [switch]$Rebuild,

    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$RepoRoot = $PSScriptRoot
$ComposeFile = Join-Path $RepoRoot "deploy\test-campfire\docker-compose.yml"
$TargetEnv = Join-Path $RepoRoot "deploy\test-campfire\.env"
$PersistentDir = Join-Path $env:USERPROFILE "test_campfire"
$PersistentEnv = Join-Path $PersistentDir ".env"

function Test-DockerRunning {
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Err "未检测到 docker 命令，请先安装 Docker Desktop。"
        exit 1
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "无法连接到 Docker 守护进程，请确保 Docker Desktop 正在运行。"
        exit 1
    }
}

function Ensure-Submodules {
    $refDockerfile = Join-Path $RepoRoot "reference\Dockerfile"
    if (-not (Test-Path $refDockerfile)) {
        Write-Info "检测到 reference 子模块未完整检出，正在同步子模块..."
        git -C $RepoRoot submodule update --init --recursive
        Write-Success "Submodule 同步完成。"
    }
}

function Ensure-EnvSecrets {
    if (-not (Test-Path $PersistentDir)) {
        New-Item -ItemType Directory -Path $PersistentDir -Force | Out-Null
    }

    $needGen = $true

    if (Test-Path $TargetEnv) {
        $content = Get-Content $TargetEnv -Raw
        if ($content -match "(?m)^SECRET_KEY_BASE=(.+)$" -and $matches[1].Trim()) {
            Write-Info "使用现有的 deploy\test-campfire\.env 配置..."
            Copy-Item $TargetEnv $PersistentEnv -Force
            $needGen = $false
        }
    }
    
    if ($needGen -and (Test-Path $PersistentEnv)) {
        $content = Get-Content $PersistentEnv -Raw
        if ($content -match "(?m)^SECRET_KEY_BASE=(.+)$" -and $matches[1].Trim()) {
            Write-Info "复用持久化目录 ($PersistentDir) 中的已有密钥配置..."
            Copy-Item $PersistentEnv $TargetEnv -Force
            $needGen = $false
        }
    }

    if ($needGen) {
        Write-Info "正在自动生成 SECRET_KEY_BASE 与 VAPID 密钥对..."
        
        # 64 字节随机 Hex
        $bytes = New-Object byte[] 64
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secretKeyBase = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""

        # 生成 P-256 EC VAPID 密钥
        $ecdsa = [System.Security.Cryptography.ECDsa]::Create([System.Security.Cryptography.ECCurve]::NamedCurves.nistP256)
        $ecParams = $ecdsa.ExportParameters($true)
        
        # Public key: 0x04 + X (32 bytes) + Y (32 bytes)
        $rawPub = [byte[]](,4 + $ecParams.Q.X + $ecParams.Q.Y)
        $vapidPub = [System.Convert]::ToBase64String($rawPub).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        
        # Private key: D (32 bytes)
        $vapidPriv = [System.Convert]::ToBase64String($ecParams.D).TrimEnd('=').Replace('+', '-').Replace('/', '_')

        $envText = @"
# Campfire 环境变量配置 (Windows 部署脚本自动生成)
SECRET_KEY_BASE=$secretKeyBase
DISABLE_SSL=true
VAPID_PRIVATE_KEY=$vapidPriv
VAPID_PUBLIC_KEY=$vapidPub
"@
        Set-Content -Path $PersistentEnv -Value $envText -Encoding utf8
        Copy-Item $PersistentEnv $TargetEnv -Force
        Write-Success "密钥已保存至 $TargetEnv 与 $PersistentEnv"
    }
}

function Deploy-Up {
    Test-DockerRunning
    Ensure-Submodules
    Ensure-EnvSecrets

    Write-Info "正在本地构建 Docker 镜像 (test_campfire:latest)..."
    if ($Rebuild) {
        docker compose -f $ComposeFile build --no-cache
    } else {
        docker compose -f $ComposeFile build
    }

    Write-Info "正在停止旧容器..."
    docker compose -f $ComposeFile down 2>$null

    Write-Info "正在启动新容器..."
    docker compose -f $ComposeFile up -d --remove-orphans

    Start-Sleep -Seconds 2

    $ps = docker compose -f $ComposeFile ps
    if ($ps -match "test_campfire") {
        Write-Success "============================================================"
        Write-Success "   Campfire 服务已成功部署并运行！"
        Write-Success "============================================================"
        Write-Host "   🌐 本机访问地址: http://localhost:3002" -ForegroundColor Cyan
        Write-Host "   📦 容器名称:     test_campfire" -ForegroundColor Yellow
        Write-Host "   💾 持久化数据卷: test-campfire_test_campfire_storage" -ForegroundColor Yellow
        Write-Host "   ⚙️ 配置文件路径: $TargetEnv" -ForegroundColor Yellow
        Write-Host "------------------------------------------------------------"
        Write-Host "   常用管理命令:"
        Write-Host "     查看实时日志:   .\deploy.ps1 logs" -ForegroundColor Cyan
        Write-Host "     查看容器状态:   .\deploy.ps1 status" -ForegroundColor Cyan
        Write-Host "     重启服务容器:   .\deploy.ps1 restart" -ForegroundColor Cyan
        Write-Host "     停止服务容器:   .\deploy.ps1 down" -ForegroundColor Cyan
        Write-Host "     强制重新编译:   .\deploy.ps1 -Rebuild" -ForegroundColor Cyan
        Write-Success "============================================================"
    } else {
        Write-Err "容器未能成功启动，请查看最新日志:"
        docker compose -f $ComposeFile logs --tail 50
    }
}

if ($Help -or $Command -eq "help") {
    Write-Host @"
用法: .\deploy.ps1 [up|down|restart|logs|status|help] [-Rebuild]

命令:
  up         构建并部署启动服务 (默认行为)
  down|stop  停止并移除容器
  restart    重启服务容器
  logs       查看实时日志 (docker compose logs -f)
  status|ps  查看容器运行状态
  help       查看本帮助

选项:
  -Rebuild   强制重新编译 Docker 镜像 (使用 --no-cache)
"@
    exit 0
}

switch ($Command) {
    { $_ -in "up", "" } { Deploy-Up }
    { $_ -in "down", "stop" } { Test-DockerRunning; docker compose -f $ComposeFile down; Write-Success "服务已停止。" }
    "restart" { Test-DockerRunning; docker compose -f $ComposeFile restart; Write-Success "服务已重启。" }
    "logs" { Test-DockerRunning; docker compose -f $ComposeFile logs -f --tail 100 }
    { $_ -in "status", "ps" } { Test-DockerRunning; docker compose -f $ComposeFile ps }
}
