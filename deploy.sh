#!/usr/bin/env bash
# ==============================================================================
# Campfire WSL / 本机一键部署与管理脚本
# 功能: 自动检查环境、初始化子模块、生成持久化密钥、构建并启动 Docker 容器
# ==============================================================================

set -eo pipefail

# 终端彩色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 1. 定位仓库根目录与相关路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if git -C "${SCRIPT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
else
  # 兼容从子目录执行或非 git 工作树情况
  REPO_ROOT="$(cd "${SCRIPT_DIR}" && pwd)"
  while [ "$REPO_ROOT" != "/" ] && [ ! -f "$REPO_ROOT/Dockerfile" ]; do
    REPO_ROOT="$(dirname "$REPO_ROOT")"
  done
fi

COMPOSE_FILE="${REPO_ROOT}/deploy/test-campfire/docker-compose.yml"
TARGET_ENV="${REPO_ROOT}/deploy/test-campfire/.env"
PERSISTENT_DIR="${HOME}/test_campfire"
PERSISTENT_ENV="${PERSISTENT_DIR}/.env"

# 2. 检查 Docker 环境
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    error "未检测到 docker 命令！"
    echo "提示: 如果在 WSL 中运行，请检查 Docker Desktop 是否已开启 WSL 集成 (Settings -> Resources -> WSL Integration)，"
    echo "或者在 WSL 中安装 Docker: sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    error "无法连接到 Docker 守护进程！"
    echo "提示: 请确保 Windows 上的 Docker Desktop 正在运行，"
    echo "或在 WSL 内部启动 Docker 服务: sudo service docker start"
    exit 1
  fi

  # 检测 docker compose 命令支持 (v2 plugin 或 v1 standalone)
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    error "未找到 docker compose 或 docker-compose 命令！"
    exit 1
  fi
}

# 3. 检查并拉取 Git Submodule (reference 目录)
check_submodules() {
  if [ ! -f "${REPO_ROOT}/reference/Dockerfile" ]; then
    info "检测到 reference 子模块未完整检出，正在同步子模块..."
    if command -v git >/dev/null 2>&1 && [ -d "${REPO_ROOT}/.git" ]; then
      git -C "${REPO_ROOT}" submodule update --init --recursive
      success "Submodule 同步完成。"
    else
      warn "未找到 git 命令或 .git 目录，如果构建报错缺少 reference/，请手动检出子模块。"
    fi
  fi
}

# 4. 自动生成或同步持久化环境密钥 (.env)
setup_env() {
  mkdir -p "${PERSISTENT_DIR}"
  mkdir -p "$(dirname "${TARGET_ENV}")"

  local need_generate=false

  # 检查目标配置与持久化配置中是否已有有效密钥
  if [ -f "${TARGET_ENV}" ] && grep -q '^SECRET_KEY_BASE=' "${TARGET_ENV}" 2>/dev/null && [ -n "$(grep '^SECRET_KEY_BASE=' "${TARGET_ENV}" | cut -d= -f2-)" ]; then
    info "使用现有的 deploy/test-campfire/.env 配置..."
    cp "${TARGET_ENV}" "${PERSISTENT_ENV}"
  elif [ -f "${PERSISTENT_ENV}" ] && grep -q '^SECRET_KEY_BASE=' "${PERSISTENT_ENV}" 2>/dev/null && [ -n "$(grep '^SECRET_KEY_BASE=' "${PERSISTENT_ENV}" | cut -d= -f2-)" ]; then
    info "复用持久化目录 (${PERSISTENT_DIR}) 中的已有密钥配置..."
    cp "${PERSISTENT_ENV}" "${TARGET_ENV}"
  else
    need_generate=true
  fi

  if [ "$need_generate" = true ]; then
    info "未检测到有效密钥，正在自动生成新的 SECRET_KEY_BASE 与 VAPID 密钥对..."
    if ! command -v openssl >/dev/null 2>&1; then
      error "未检测到 openssl 工具，无法自动生成安全密钥，请先安装 openssl！"
      exit 1
    fi

    local secret_key_base
    secret_key_base=$(openssl rand -hex 64)

    local vapid_tmp="/tmp/vapid_$$.key"
    openssl ecparam -name prime256v1 -genkey -noout -out "${vapid_tmp}" 2>/dev/null
    local vapid_public_key
    local vapid_private_key
    vapid_public_key=$(openssl ec -in "${vapid_tmp}" -pubout -outform DER 2>/dev/null | tail -c 65 | openssl base64 -e | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    vapid_private_key=$(openssl ec -in "${vapid_tmp}" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | openssl base64 -e | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    rm -f "${vapid_tmp}"

    {
      echo "# Campfire 环境变量配置 (本地部署脚本自动生成)"
      echo "SECRET_KEY_BASE=${secret_key_base}"
      echo "DISABLE_SSL=true"
      echo "VAPID_PRIVATE_KEY=${vapid_private_key}"
      echo "VAPID_PUBLIC_KEY=${vapid_public_key}"
    } > "${PERSISTENT_ENV}"

    cp "${PERSISTENT_ENV}" "${TARGET_ENV}"
    success "已成功生成并保存密钥至 ${TARGET_ENV} 与 ${PERSISTENT_ENV}"
  fi

  # 备份 compose 模板至持久化目录
  cp "${COMPOSE_FILE}" "${PERSISTENT_DIR}/" 2>/dev/null || true
}

# 5. 执行部署构建并启动
deploy_up() {
  local rebuild_flag=""
  if [ "$1" = "--rebuild" ] || [ "$1" = "-b" ]; then
    rebuild_flag="--no-cache"
    info "指定强制重新构建（--no-cache）..."
  fi

  check_docker
  check_submodules
  setup_env

  info "正在本地构建 Docker 镜像 (test_campfire:latest)..."
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" build ${rebuild_flag}

  info "正在停止旧容器实例..."
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" down 2>/dev/null || true

  info "正在启动新容器实例..."
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" up -d --remove-orphans

  echo ""
  info "等待服务就绪检查..."
  sleep 2

  if ${COMPOSE_CMD} -f "${COMPOSE_FILE}" ps | grep -q "test_campfire"; then
    success "============================================================"
    success "   Campfire 服务已成功部署并运行！"
    success "============================================================"
    echo -e "   🌐 本机访问地址: ${CYAN}http://localhost:3002${NC}"
    echo -e "   📦 容器名称:     ${YELLOW}test_campfire${NC}"
    echo -e "   💾 持久化数据卷: ${YELLOW}test-campfire_test_campfire_storage${NC}"
    echo -e "   ⚙️ 配置文件路径: ${YELLOW}${TARGET_ENV}${NC}"
    echo -e "------------------------------------------------------------"
    echo -e "   常用管理命令:"
    echo -e "     查看实时日志:   ${CYAN}./deploy.sh logs${NC}"
    echo -e "     查看容器状态:   ${CYAN}./deploy.sh status${NC}"
    echo -e "     重启服务容器:   ${CYAN}./deploy.sh restart${NC}"
    echo -e "     停止服务容器:   ${CYAN}./deploy.sh down${NC}"
    echo -e "     强制重新编译:   ${CYAN}./deploy.sh --rebuild${NC}"
    success "============================================================"
  else
    error "容器未能成功启动，请查看最新日志输出:"
    ${COMPOSE_CMD} -f "${COMPOSE_FILE}" logs --tail 50
    exit 1
  fi
}

# 6. 其他常用管理子命令
deploy_down() {
  check_docker
  info "正在停止并移除 Campfire 容器..."
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" down
  success "服务已停止。"
}

deploy_restart() {
  check_docker
  info "正在重启 Campfire 容器..."
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" restart
  success "服务已重启。"
}

deploy_logs() {
  check_docker
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" logs -f --tail 100
}

deploy_status() {
  check_docker
  ${COMPOSE_CMD} -f "${COMPOSE_FILE}" ps
}

# 7. 帮助手册
show_help() {
  echo "用法: $0 [命令|选项]"
  echo ""
  echo "命令:"
  echo "  up [选项]      构建并部署启动服务 (默认行为)"
  echo "  down | stop    停止并移除运行中的容器"
  echo "  restart        重启服务容器"
  echo "  logs           查看实时服务运行日志"
  echo "  status | ps    查看容器运行状态"
  echo "  help           查看本帮助文档"
  echo ""
  echo "选项:"
  echo "  --rebuild, -b  强制重新编译镜像 (使用 --no-cache)"
  echo ""
  echo "示例:"
  echo "  $0             # 一键自动部署启动"
  echo "  $0 --rebuild   # 忽略缓存强制重编并启动"
  echo "  $0 logs        # 查看实时日志"
  echo "  $0 down        # 停止服务"
}

# 8. 入口解析
case "${1:-}" in
  "")
    deploy_up
    ;;
  "up")
    deploy_up "${2:-}"
    ;;
  "--rebuild"|"-b")
    deploy_up "--rebuild"
    ;;
  "down"|"stop")
    deploy_down
    ;;
  "restart")
    deploy_restart
    ;;
  "logs")
    deploy_logs
    ;;
  "status"|"ps")
    deploy_status
    ;;
  "help"|"--help"|"-h")
    show_help
    ;;
  *)
    error "未知命令: $1"
    show_help
    exit 1
    ;;
esac
