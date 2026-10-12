# ==============================================================================
# Campfire Windows PowerShell 一键独立部署脚本 (Standalone Deploy)
# ==============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "new", "up", "down", "stop", "restart", "logs", "status", "ps", "help", "")]
    [string]$Command = "",

    [string]$Name = "",
    [int]$Port = 0,
    [string]$Image = "dogming/once-campfire-rust:latest",

    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

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

function Test-PortInUse([int]$testPort) {
    # 检查 Docker 容器映射
    $dockerPorts = docker ps --format '{{.Ports}}' 2>$null
    if ($dockerPorts -match "(0\.0\.0\.0:|:::|:)$testPort(->|/)") {
        return $true
    }
    # 检查 Windows TCP 监听
    $tcp = Get-NetTCPConnection -LocalPort $testPort -ErrorAction SilentlyContinue
    if ($tcp) {
        return $true
    }
    return $false
}

function Get-AvailablePort {
    for ($i = 0; $i -lt 100; $i++) {
        $p = Get-Random -Minimum 3100 -Maximum 8999
        if ($p -in @(3306, 5000, 5432, 6379, 8000, 8080, 8443, 8888)) { continue }
        if (-not (Test-PortInUse $p)) { return $p }
    }
    for ($p = 3001; $p -le 9999; $p++) {
        if (-not (Test-PortInUse $p)) { return $p }
    }
    return 3000
}

function Check-ServiceConflict([string]$svcName) {
    $containers = docker ps -a --format '{{.Names}}' 2>$null
    if ($containers -split "`r?`n" -contains $svcName) {
        return "存在同名容器 '$svcName'"
    }
    $volumes = docker volume ls --format '{{.Name}}' 2>$null
    if ($volumes -split "`r?`n" -contains "${svcName}_storage") {
        return "存在同名数据卷 '${svcName}_storage'"
    }
    return $null
}

function Generate-Keys {
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

    return @{
        SecretKeyBase = $secretKeyBase
        VapidPrivate = $vapidPriv
        VapidPublic = $vapidPub
    }
}

function Deploy-Init {
    Test-DockerRunning

    $deployDir = (Get-Location).Path
    $envFile = Join-Path $deployDir ".env"
    $composeFile = Join-Path $deployDir "docker-compose.yml"

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "       🏕️  Campfire 一键独立部署向导 (PowerShell)" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "部署工作目录: $deployDir" -ForegroundColor Yellow
    Write-Host ""

    # 1. 服务名称
    $defaultSvc = "campfire"
    if (Check-ServiceConflict $defaultSvc) {
        $defaultSvc = "campfire-$(Get-Random -Minimum 100 -Maximum 999)"
    }
    $svcName = $Name
    while (-not $svcName) {
        $inputVal = Read-Host "👉 请输入服务名称 (用于容器名与数据卷隔离) [默认: $defaultSvc]"
        if (-not $inputVal) { $inputVal = $defaultSvc }
        if ($inputVal -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
            Write-Err "服务名称不合法！仅支持以字母/数字开头的字母、数字、点、下划线或中划线。"
            continue
        }
        $conflict = Check-ServiceConflict $inputVal
        if ($conflict) {
            Write-Warn "⚠️ 服务名称 '$inputVal' 与机器现有资源冲突 ($conflict)！"
            Write-Host "   为了确保本服务数据完全隔离，请重新输入服务名称。"
            $defaultSvc = "$inputVal-$(Get-Random -Minimum 100 -Maximum 999)"
            continue
        }
        $svcName = $inputVal
    }
    Write-Success "服务名称已确定: $svcName (隔离数据卷: ${svcName}_storage)"
    Write-Host ""

    # 2. 端口分配
    $defaultPort = Get-AvailablePort
    $hostPort = $Port
    while (-not $hostPort) {
        $portInput = Read-Host "👉 请输入宿主机映射端口 [默认推荐可用端口: $defaultPort]"
        if (-not $portInput) { $portInput = $defaultPort }
        [int]$parsedPort = 0
        if (-not [int]::TryParse($portInput, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
            Write-Err "端口号无效，请输入 1 到 65535 之间的合法整数！"
            continue
        }
        if (Test-PortInUse $parsedPort) {
            Write-Warn "⚠️ 端口 $parsedPort 当前已被占用，请更换其他端口！"
            $defaultPort = Get-AvailablePort
            continue
        }
        $hostPort = $parsedPort
    }
    Write-Success "宿主机端口已确定: $hostPort"
    Write-Host ""

    # 3. 镜像标签
    $imageTag = $Image
    $imgInput = Read-Host "👉 Docker 镜像标签 [默认: $imageTag]"
    if ($imgInput) { $imageTag = $imgInput }
    Write-Success "镜像标签已确定: $imageTag"
    Write-Host ""

    # 4. 生成 .env
    $reuseEnv = $false
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        if ($content -match "(?m)^SECRET_KEY_BASE=(.+)$") {
            Write-Warn "检测到当前目录已存在 .env 且包含密钥。"
            $choice = Read-Host "是否保留并复用现有 .env 密钥？[Y/n]"
            if ($choice -match '^[Yy]?$') { $reuseEnv = $true }
        }
    }

    if (-not $reuseEnv) {
        Write-Info "正在生成高强度加密密钥 (SECRET_KEY_BASE & VAPID WebPush 密钥对)..."
        $keys = Generate-Keys
        $envContent = @"
# ==============================================================================
# Campfire 环境变量配置
# 服务实例名称: $svcName
# 自动生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# ==============================================================================
SECRET_KEY_BASE=$($keys.SecretKeyBase)
DISABLE_SSL=true
VAPID_PRIVATE_KEY=$($keys.VapidPrivate)
VAPID_PUBLIC_KEY=$($keys.VapidPublic)
RAILS_ENV=production
"@
        Set-Content -Path $envFile -Value $envContent -Encoding utf8
        Write-Success "已成功生成 .env 配置文件: $envFile"
    } else {
        Write-Success "已保留现有 .env 配置文件: $envFile"
    }
    Write-Host ""

    # 5. 生成 docker-compose.yml
    Write-Info "正在生成 docker-compose.yml..."
    $composeContent = @"
# ==============================================================================
# Campfire 独立部署 Docker Compose 配置
# 实例名称: $svcName
# 宿主端口: $hostPort
# 存储隔离: ${svcName}_storage
# 自动生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# ==============================================================================
services:
  ${svcName}:
    image: $imageTag
    container_name: $svcName
    restart: unless-stopped
    ports:
      - "${hostPort}:80"
    env_file:
      - .env
    volumes:
      - ${svcName}_storage:/rails/storage

volumes:
  ${svcName}_storage:
    name: ${svcName}_storage
"@
    Set-Content -Path $composeFile -Value $composeContent -Encoding utf8
    Write-Success "已成功生成 docker-compose.yml: $composeFile"
    Write-Host ""

    # 6. 启动容器
    $startNow = Read-Host "🚀 配置文件已就绪，是否立即启动服务？[Y/n]"
    if ($startNow -match '^[Yy]?$') {
        Write-Info "正在拉取镜像并启动容器 ($svcName)..."
        docker compose up -d --remove-orphans

        Start-Sleep -Seconds 2

        Write-Host ""
        Write-Success "============================================================"
        Write-Success "   🎉 Campfire 服务实例已成功启动！"
        Write-Success "============================================================"
        Write-Host "   📦 实例名称:     $svcName" -ForegroundColor Yellow
        Write-Host "   🔌 宿主端口:     $hostPort" -ForegroundColor Yellow
        Write-Host "   💾 隔离存储卷:   ${svcName}_storage" -ForegroundColor Yellow
        Write-Host "   🌐 本地访问地址: http://localhost:$hostPort" -ForegroundColor Cyan
        Write-Host "------------------------------------------------------------"
        Write-Host "   常用管理命令 (在当前目录下运行):"
        Write-Host "     查看实时日志:   docker compose logs -f" -ForegroundColor Cyan
        Write-Host "     查看服务状态:   docker compose ps" -ForegroundColor Cyan
        Write-Host "     重启服务容器:   docker compose restart" -ForegroundColor Cyan
        Write-Host "     停止服务容器:   docker compose down" -ForegroundColor Cyan
        Write-Success "============================================================"
    } else {
        Write-Info "配置文件已就绪，您可随时在当前目录下运行以下命令启动服务："
        Write-Host "   docker compose up -d" -ForegroundColor Cyan
    }
}

function Manage-Compose([string]$action) {
    Test-DockerRunning
    if (-not (Test-Path "docker-compose.yml")) {
        Write-Warn "当前目录下未检测到 docker-compose.yml，正在启动部署向导..."
        Deploy-Init
        return
    }

    switch ($action) {
        "up" {
            docker compose up -d --remove-orphans
            Write-Success "服务已启动。"
        }
        { $_ -in "down", "stop" } {
            docker compose down
            Write-Success "服务已停止。"
        }
        "restart" {
            docker compose restart
            Write-Success "服务已重启。"
        }
        "logs" {
            docker compose logs -f --tail 100
        }
        { $_ -in "status", "ps" } {
            docker compose ps
        }
    }
}

if ($Help -or $Command -eq "help") {
    Write-Host @"
用法: .\deploy.ps1 [init|up|down|restart|logs|status|help]

核心命令:
  (无参数)   交互式向导：检查冲突、分配随机端口、生成 .env 与 docker-compose.yml 并启动
  init       强制启动配置向导生成新实例
  up         启动当前目录下的服务容器 (docker compose up -d)
  down|stop  停止并清理当前目录下的容器 (docker compose down)
  restart    重启当前服务容器
  logs       查看当前服务实时运行日志 (docker compose logs -f)
  status|ps  查看当前容器运行状态
  help       查看本帮助
"@
    exit 0
}

switch ($Command) {
    "" {
        if ((Test-Path "docker-compose.yml") -and (Test-Path ".env")) {
            Write-Warn "检测到当前目录下已存在配置文件 (docker-compose.yml 与 .env)。"
            $c = Read-Host "请选择操作 [1: 启动已有服务, 2: 重新配置新实例, 3: 退出] (默认: 1)"
            switch ($c) {
                "2" { Deploy-Init }
                "3" { Write-Info "已退出。"; exit 0 }
                default { Manage-Compose "up" }
            }
        } else {
            Deploy-Init
        }
    }
    { $_ -in "init", "new" } { Deploy-Init }
    { $_ -in "up", "down", "stop", "restart", "logs", "status", "ps" } { Manage-Compose $Command }
    default {
        Write-Err "未知命令: $Command"
        exit 1
    }
}
