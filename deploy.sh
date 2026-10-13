#!/usr/bin/env bash
# ==============================================================================
# Campfire 一键独立部署脚本 (Self-Contained Deployment Script)
#
# 功能:
# 1. 交互式/命令行快速创建独立服务实例，支持多实例完全隔离
# 2. 实时检测容器名称与数据卷冲突，避免数据与服务覆盖
# 3. 自动检测并随机分配可用宿主机端口，防止端口占用
# 4. 自动生成 .env（包含高强度 SECRET_KEY_BASE 与 VAPID WebPush 密钥对）
# 5. 支持直接拉取远程镜像，亦支持通过 --build 从本地源码构建
# 6. 支持单行 URL 远程下载直接执行：
#    curl -fsSL <URL>/deploy.sh | bash
# ==============================================================================

set -eo pipefail

# 终端彩色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# 交互输入读取函数（兼容终端执行、远程 curl ... | bash 管道以及自动化管道传参）
prompt_user() {
  local prompt_text="$1"
  local default_val="$2"
  local var_ref="$3"
  local input=""

  printf "${prompt_text}" >&2

  if [ -t 0 ]; then
    read -r input || input=""
  elif [ -p /dev/stdin ]; then
    # stdin 是管道流
    if [[ "${0}" =~ \.sh$ ]] || [ -f "${0}" ]; then
      read -r input || input=""
    elif [ -r /dev/tty ]; then
      # 脚本本身由管道送入 bash (例如 curl ... | bash)，从控制终端读取用户按键
      read -r input </dev/tty || input=""
    else
      read -r input || input=""
    fi
  elif [ -r /dev/tty ]; then
    read -r input </dev/tty || input=""
  else
    input="$default_val"
  fi

  if [ -z "$input" ]; then
    input="$default_val"
  fi

  eval "$var_ref=\"\$input\""
}

DOCKER_BIN="docker"

# 检查 Docker 运行环境与 Compose 支持 (自动适配 Linux, macOS 与 Windows WSL)
check_docker() {
  if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1 || ! "${DOCKER_BIN}" info >/dev/null 2>&1; then
    if command -v docker.exe >/dev/null 2>&1 && docker.exe info >/dev/null 2>&1; then
      DOCKER_BIN="docker.exe"
    fi
  fi

  if ! command -v "${DOCKER_BIN}" >/dev/null 2>&1; then
    error "未检测到 docker 命令，请先安装 Docker！"
    echo "官方安装指引: https://docs.docker.com/engine/install/"
    exit 1
  fi

  if ! "${DOCKER_BIN}" info >/dev/null 2>&1; then
    error "无法连接到 Docker 守护进程，请确认 Docker 服务正在运行！"
    echo "Linux / WSL 启动命令示例: sudo systemctl start docker 或 sudo service docker start"
    exit 1
  fi

  if "${DOCKER_BIN}" compose version >/dev/null 2>&1; then
    COMPOSE_CMD="${DOCKER_BIN} compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  elif command -v docker-compose.exe >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose.exe"
  else
    error "未找到 docker compose 或 docker-compose 命令！"
    exit 1
  fi
}

# 检测仓库源码根目录 (用于 --build 模式)
detect_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${script_dir}/Dockerfile" ]; then
    echo "${script_dir}"
    return 0
  fi
  if [ -f "${PWD}/Dockerfile" ]; then
    echo "${PWD}"
    return 0
  fi
  if command -v git >/dev/null 2>&1 && git -C "${PWD}" rev-parse --show-toplevel >/dev/null 2>&1; then
    local git_root
    git_root="$(git -C "${PWD}" rev-parse --show-toplevel)"
    if [ -f "${git_root}/Dockerfile" ]; then
      echo "${git_root}"
      return 0
    fi
  fi
  echo ""
}

# 检查指定端口是否在宿主机或 Docker 容器中已被占用
is_port_in_use() {
  local port="$1"

  # 1. 检查 Docker 容器已映射的端口
  if "${DOCKER_BIN}" ps --format '{{.Ports}}' 2>/dev/null | grep -Eq "(0\.0\.0\.0:|:::|:)${port}(->|/)"; then
    return 0
  fi

  # 2. 检查系统 ss 监听状态
  if command -v ss >/dev/null 2>&1; then
    if ss -tuln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
      return 0
    fi
  # 3. 检查系统 netstat 监听状态
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -tuln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
      return 0
    fi
  # 4. 检查系统 lsof
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"${port}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 5. Socket 绑定探测 (python3 / nc / /dev/tcp)
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "import socket; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('', ${port})); s.close()" 2>/dev/null; then
      return 0
    fi
  elif command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
      return 0
    fi
  elif (echo >/dev/tcp/127.0.0.1/"${port}") 2>/dev/null; then
    return 0
  fi

  return 1 # 未被占用
}

# 随机寻找一个未被占用的端口 (默认范围 3100 ~ 8999)
find_available_port() {
  local candidate
  local attempts=0
  while [ $attempts -lt 100 ]; do
    if command -v shuf >/dev/null 2>&1; then
      candidate=$(shuf -i 3100-8999 -n 1)
    else
      candidate=$(( (RANDOM % 5900) + 3100 ))
    fi

    # 避开常用知名中间件端口
    case "$candidate" in
      3306|5000|5432|6379|8000|8080|8443|8888)
        attempts=$((attempts + 1))
        continue
        ;;
    esac

    if ! is_port_in_use "$candidate"; then
      echo "$candidate"
      return 0
    fi
    attempts=$((attempts + 1))
  done

  # 备用线性向上扫描
  for p in $(seq 3001 9999); do
    if ! is_port_in_use "$p"; then
      echo "$p"
      return 0
    fi
  done
  echo "3000"
}

# 检查服务名称是否与已有容器或 Volume 冲突
# 返回 0 表示冲突并输出原因，返回 1 表示不冲突
check_service_conflict() {
  local name="$1"
  local target_dir="${2:-$PWD}"

  # 如果当前部署目录的 docker-compose.yml 已经定义了本服务，说明是重构/升级同一实例，不算跨实例冲突
  if [ -f "${target_dir}/docker-compose.yml" ] && grep -Eq "container_name:[[:space:]]*[\"']?${name}[\"']?" "${target_dir}/docker-compose.yml" 2>/dev/null; then
    return 1
  fi

  # 检查同名 Docker 容器
  local container_match
  container_match=$("${DOCKER_BIN}" ps -a --format '{{.Names}}' 2>/dev/null | grep -Fx "${name}" || true)
  if [ -n "$container_match" ]; then
    echo "存在同名容器 '${name}'"
    return 0
  fi

  # 检查同名 Docker Volume 隔离卷 (${name}_storage)
  local volume_match
  volume_match=$("${DOCKER_BIN}" volume ls --format '{{.Name}}' 2>/dev/null | grep -Fx "${name}_storage" || true)
  if [ -n "$volume_match" ]; then
    echo "存在同名数据卷 '${name}_storage'"
    return 0
  fi

  return 1
}

# 自动生成所需高强度加密密钥 (SECRET_KEY_BASE 与 VAPID 密钥对)
generate_keys() {
  if ! command -v openssl >/dev/null 2>&1; then
    error "未找到 openssl 工具，无法自动生成安全密钥！请先安装 openssl。"
    exit 1
  fi

  local secret_key_base
  secret_key_base=$(openssl rand -hex 64)

  local vapid_tmp
  vapid_tmp="$(mktemp 2>/dev/null || echo "/tmp/vapid_$$.key")"
  openssl ecparam -name prime256v1 -genkey -noout -out "${vapid_tmp}" 2>/dev/null
  local vapid_public_key
  local vapid_private_key
  vapid_public_key=$(openssl ec -in "${vapid_tmp}" -pubout -outform DER 2>/dev/null | tail -c 65 | openssl base64 -e | tr -d '\n' | tr '/+' '_-' | tr -d '=')
  vapid_private_key=$(openssl ec -in "${vapid_tmp}" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | openssl base64 -e | tr -d '\n' | tr '/+' '_-' | tr -d '=')
  rm -f "${vapid_tmp}"

  echo "${secret_key_base}|${vapid_private_key}|${vapid_public_key}"
}

# 获取本机局域网 IP
get_host_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
  fi
  echo "$ip"
}

# 核心：配置向导与部署执行
deploy_init() {
  check_docker

  local opt_dir="${PWD}"
  local opt_name=""
  local opt_port=""
  local opt_image="dogming/once-campfire-rust:latest"
  local opt_volume=""
  local opt_build=false
  local opt_rebuild=false
  local opt_yes=false
  local opt_no_start=false
  local opt_force=false

  # 命令行参数解析
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        opt_dir="$2"
        shift 2
        ;;
      --name|-n)
        opt_name="$2"
        shift 2
        ;;
      --port|-p)
        opt_port="$2"
        shift 2
        ;;
      --volume|-v)
        opt_volume="$2"
        shift 2
        ;;
      --image|-i)
        opt_image="$2"
        shift 2
        ;;
      --build|-b)
        opt_build=true
        shift
        ;;
      --rebuild)
        opt_build=true
        opt_rebuild=true
        shift
        ;;
      --yes|-y)
        opt_yes=true
        shift
        ;;
      --no-start)
        opt_no_start=true
        shift
        ;;
      --force|-f)
        opt_force=true
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  mkdir -p "${opt_dir}"
  local deploy_dir
  deploy_dir="$(cd "${opt_dir}" && pwd)"
  local env_file="${deploy_dir}/.env"
  local compose_file="${deploy_dir}/docker-compose.yml"

  echo ""
  echo -e "${CYAN}============================================================${NC}"
  echo -e "${BOLD}       🏕️  Campfire 一键独立部署向导 (Standalone Deploy)${NC}"
  echo -e "${CYAN}============================================================${NC}"
  echo -e "部署工作目录: ${YELLOW}${deploy_dir}${NC}"
  echo ""

  # 1. 服务名称确定
  local service_name="${opt_name}"
  if [ -z "${service_name}" ]; then
    local default_svc_name="campfire"
    if check_service_conflict "${default_svc_name}" "${deploy_dir}" >/dev/null 2>&1; then
      local rand_suffix
      rand_suffix=$(( (RANDOM % 900) + 100 ))
      default_svc_name="campfire-${rand_suffix}"
    fi

    while true; do
      prompt_user "👉 请输入服务名称 (用于容器名与数据卷隔离) [默认: ${default_svc_name}]: " "${default_svc_name}" service_name

      if [[ ! "${service_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        error "服务名称不合法！仅支持以字母/数字开头的字母、数字、点、下划线或中划线。"
        continue
      fi

      local conflict_reason
      conflict_reason=$(check_service_conflict "${service_name}" "${deploy_dir}" || true)
      if [ -n "${conflict_reason}" ] && [ "$opt_force" = false ]; then
        warn "⚠️ 服务名称 '${service_name}' 与机器现有资源冲突 (${conflict_reason})！"
        echo -e "   为了确保本服务数据与其它实例${BOLD}完全隔离${NC}，请输入一个新的服务名称。"
        default_svc_name="${service_name}-$(( (RANDOM % 900) + 100 ))"
        continue
      fi

      break
    done
  else
    if [[ ! "${service_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      error "指定的 --name '${service_name}' 格式不合法！"
      exit 1
    fi
    local conflict_reason
    conflict_reason=$(check_service_conflict "${service_name}" "${deploy_dir}" || true)
    if [ -n "${conflict_reason}" ] && [ "$opt_yes" = false ] && [ "$opt_force" = false ]; then
      warn "⚠️ 指定的服务名称 '${service_name}' 与已有资源冲突 (${conflict_reason})！"
      echo "提示: 如需强制覆盖此服务实例，请添加 --force 参数。"
      exit 1
    fi
  fi
  success "服务名称已确定: ${BOLD}${service_name}${NC}"
  echo ""

  # 2. 宿主机端口确定
  local host_port="${opt_port}"
  if [ -z "${host_port}" ]; then
    local default_port
    default_port=$(find_available_port)
    if [ "$opt_yes" = true ]; then
      host_port="${default_port}"
    else
      while true; do
        prompt_user "👉 请输入宿主机映射端口 [默认推荐可用端口: ${default_port}]: " "${default_port}" host_port

        if [[ ! "${host_port}" =~ ^[0-9]+$ ]] || [ "${host_port}" -lt 1 ] || [ "${host_port}" -gt 65535 ]; then
          error "端口号无效，请输入 1 到 65535 之间的合法整数！"
          continue
        fi

        if is_port_in_use "${host_port}"; then
          warn "⚠️ 端口 ${host_port} 当前已被占用，请更换其他端口！"
          default_port=$(find_available_port)
          continue
        fi

        break
      done
    fi
  else
    if [[ ! "${host_port}" =~ ^[0-9]+$ ]] || [ "${host_port}" -lt 1 ] || [ "${host_port}" -gt 65535 ]; then
      error "指定的 --port '${host_port}' 无效，请输入 1 到 65535 之间的整数！"
      exit 1
    fi
  fi
  success "宿主机端口已确定: ${BOLD}${host_port}${NC}"
  echo ""

  # 3. 镜像标签确定
  local image_tag="${opt_image}"
  if [ -z "${opt_name}" ] && [ "$opt_yes" = false ] && [ "$opt_build" = false ]; then
    prompt_user "👉 Docker 镜像标签 [默认: ${image_tag}]: " "${image_tag}" image_tag
  fi
  success "镜像标签已确定: ${BOLD}${image_tag}${NC}"
  echo ""

  # 4. 专属数据卷名称确定
  local volume_name="${opt_volume}"
  if [ -z "${volume_name}" ]; then
    volume_name="${service_name}_storage"
  fi
  success "隔离数据卷已确定: ${BOLD}${volume_name}${NC}"
  echo ""

  # 5. 生成或复用 .env 密钥配置
  local reuse_env=false
  if [ -f "${env_file}" ] && grep -q '^SECRET_KEY_BASE=' "${env_file}" 2>/dev/null && [ -n "$(grep '^SECRET_KEY_BASE=' "${env_file}" | cut -d= -f2-)" ]; then
    if [ "$opt_yes" = true ] || [ "$opt_force" = false ]; then
      reuse_env=true
    else
      warn "检测到当前目录已存在 .env 且包含密钥。"
      local reuse_choice=""
      prompt_user "是否保留并复用现有 .env 密钥？[Y/n]: " "Y" reuse_choice
      if [[ "$reuse_choice" =~ ^[Yy]$ ]]; then
        reuse_env=true
      fi
    fi
  fi

  if [ "$reuse_env" = false ]; then
    info "正在生成高强度加密密钥 (SECRET_KEY_BASE & VAPID WebPush 密钥对)..."
    local keys_raw
    keys_raw=$(generate_keys)
    local skb vpriv vpub
    skb=$(echo "${keys_raw}" | cut -d'|' -f1)
    vpriv=$(echo "${keys_raw}" | cut -d'|' -f2)
    vpub=$(echo "${keys_raw}" | cut -d'|' -f3)

    cat > "${env_file}" <<EOF
# ==============================================================================
# Campfire 环境变量配置
# 服务实例名称: ${service_name}
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================
SECRET_KEY_BASE=${skb}
DISABLE_SSL=true
VAPID_PRIVATE_KEY=${vpriv}
VAPID_PUBLIC_KEY=${vpub}
RAILS_ENV=production
EOF
    chmod 600 "${env_file}" 2>/dev/null || true
    success "已成功生成 .env 密钥配置文件: ${env_file}"
  else
    success "已保留现有 .env 密钥配置文件: ${env_file}"
  fi
  echo ""

  # 6. 生成 docker-compose.yml (支持从本地源码 build 或直接 pull 镜像)
  info "正在生成 docker-compose.yml..."
  local repo_root=""
  if [ "$opt_build" = true ]; then
    repo_root="$(detect_repo_root)"
    if [ -z "${repo_root}" ]; then
      error "指定了 --build 编译模式，但未在当前目录或父目录找到 Dockerfile！"
      exit 1
    fi
    info "检测到本地源码构建上下文: ${repo_root}"

    cat > "${compose_file}" <<EOF
# ==============================================================================
# Campfire 独立部署 Docker Compose 配置 (本地源码构建模式)
# 实例名称: ${service_name}
# 宿主端口: ${host_port}
# 存储隔离: ${volume_name}
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================
services:
  ${service_name}:
    build:
      context: ${repo_root}
      dockerfile: Dockerfile
    image: ${image_tag}
    container_name: ${service_name}
    restart: unless-stopped
    ports:
      - "${host_port}:80"
    env_file:
      - .env
    volumes:
      - ${service_name}_storage:/rails/storage

volumes:
  ${service_name}_storage:
    name: ${volume_name}
EOF
  else
    cat > "${compose_file}" <<EOF
# ==============================================================================
# Campfire 独立部署 Docker Compose 配置
# 实例名称: ${service_name}
# 宿主端口: ${host_port}
# 存储隔离: ${volume_name}
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================
services:
  ${service_name}:
    image: ${image_tag}
    container_name: ${service_name}
    restart: unless-stopped
    ports:
      - "${host_port}:80"
    env_file:
      - .env
    volumes:
      - ${service_name}_storage:/rails/storage

volumes:
  ${service_name}_storage:
    name: ${volume_name}
EOF
  fi
  success "已成功生成 docker-compose.yml: ${compose_file}"
  echo ""

  # 7. 启动容器处理
  local start_now=""
  if [ "$opt_yes" = true ]; then
    if [ "$opt_no_start" = true ]; then
      start_now="n"
    else
      start_now="y"
    fi
  else
    prompt_user "🚀 配置文件已就绪，是否立即启动服务？[Y/n]: " "Y" start_now
  fi

  if [[ "$start_now" =~ ^[Yy]$ ]]; then
    echo ""
    if [ "$opt_build" = true ]; then
      local build_args=""
      if [ "$opt_rebuild" = true ]; then
        build_args="--no-cache"
        info "正在重新构建本地镜像 (--no-cache)..."
      else
        info "正在本地构建 Docker 镜像..."
      fi
      (cd "${deploy_dir}" && ${COMPOSE_CMD} build ${build_args})
      info "正在停止旧容器实例..."
      (cd "${deploy_dir}" && ${COMPOSE_CMD} down 2>/dev/null || true)
    fi

    info "正在启动容器 (${service_name})..."
    (cd "${deploy_dir}" && ${COMPOSE_CMD} up -d --remove-orphans)

    echo ""
    info "等待服务状态自检..."
    sleep 2

    local lan_ip
    lan_ip=$(get_host_ip)

    echo ""
    success "============================================================"
    success "   🎉 Campfire 服务实例已成功启动！"
    success "============================================================"
    echo -e "   📦 实例名称:     ${YELLOW}${service_name}${NC}"
    echo -e "   🔌 宿主端口:     ${YELLOW}${host_port}${NC}"
    echo -e "   💾 隔离存储卷:   ${YELLOW}${volume_name}${NC}"
    echo -e "   📁 部署路径:     ${YELLOW}${deploy_dir}${NC}"
    echo -e "   🌐 本地访问地址: ${CYAN}http://localhost:${host_port}${NC}"
    if [ -n "$lan_ip" ] && [ "$lan_ip" != "127.0.0.1" ]; then
      echo -e "   🌐 局域网访问:   ${CYAN}http://${lan_ip}:${host_port}${NC}"
    fi
    echo -e "------------------------------------------------------------"
    echo -e "   常用管理命令 (在部署目录下运行):"
    echo -e "     查看实时日志:   ${CYAN}${COMPOSE_CMD} logs -f${NC}"
    echo -e "     查看服务状态:   ${CYAN}${COMPOSE_CMD} ps${NC}"
    echo -e "     重启服务容器:   ${CYAN}${COMPOSE_CMD} restart${NC}"
    echo -e "     停止服务容器:   ${CYAN}${COMPOSE_CMD} down${NC}"
    success "============================================================"
  else
    echo ""
    info "配置文件已就绪，您可随时在部署目录下运行以下命令启动服务："
    echo -e "   ${CYAN}cd ${deploy_dir} && ${COMPOSE_CMD} up -d${NC}"
  fi
}

# 快捷管理子命令分发
manage_compose() {
  local action="$1"
  shift || true
  check_docker

  local compose_file="docker-compose.yml"
  if [ ! -f "${compose_file}" ]; then
    warn "当前目录下未检测到 docker-compose.yml，正在为您启动部署向导..."
    deploy_init "$@"
    return
  fi

  case "$action" in
    up)
      info "正在启动服务..."
      ${COMPOSE_CMD} up -d --remove-orphans "$@"
      success "服务已启动。"
      ;;
    down|stop)
      info "正在停止服务..."
      ${COMPOSE_CMD} down "$@"
      success "服务已停止。"
      ;;
    restart)
      info "正在重启服务..."
      ${COMPOSE_CMD} restart "$@"
      success "服务已重启。"
      ;;
    logs)
      ${COMPOSE_CMD} logs -f --tail 100 "$@"
      ;;
    status|ps)
      ${COMPOSE_CMD} ps "$@"
      ;;
    *)
      error "未知操作: $action"
      show_help
      exit 1
      ;;
  esac
}

show_help() {
  echo "用法: $0 [命令] [选项]"
  echo ""
  echo "命令:"
  echo "  (无参数)       交互式向导：检查冲突、分配随机端口、生成 .env 与 docker-compose.yml 并启动"
  echo "  init           初始化并配置部署实例"
  echo "  up             启动当前目录下的服务容器 (docker compose up -d)"
  echo "  down | stop    停止并清理当前目录下的容器 (docker compose down)"
  echo "  restart        重启当前服务容器"
  echo "  logs           查看当前服务实时运行日志"
  echo "  status | ps    查看当前容器运行状态"
  echo "  help           查看本帮助手册"
  echo ""
  echo "init 命令选项:"
  echo "  --dir <路径>      指定部署工作目录 (默认: 当前目录)"
  echo "  --name, -n <名称> 指定服务容器名称"
  echo "  --port, -p <端口> 指定宿主机绑定端口"
  echo "  --volume, -v <卷> 指定隔离数据卷名称 (默认: \${name}_storage)"
  echo "  --image, -i <镜像>指定 Docker 镜像标签 (默认: dogming/once-campfire-rust:latest)"
  echo "  --build, -b       启用本地源码构建模式 (使用仓库 Dockerfile)"
  echo "  --rebuild         本地构建并忽略缓存 (--no-cache)"
  echo "  --yes, -y         非交互式静默执行"
  echo "  --no-start        仅生成配置文件，不自动启动容器"
  echo "  --force, -f       强制覆盖已有冲突配置"
  echo ""
  echo "示例:"
  echo "  $0                                      # 交互式向导"
  echo "  $0 init --name team-chat --port 3200 -y # 脚本化一键创建"
  echo "  curl -fsSL https://.../deploy.sh | bash # 远程单行执行"
}

# 脚本入口处理
case "${1:-}" in
  "")
    if [ -f "${PWD}/docker-compose.yml" ] && [ -f "${PWD}/.env" ]; then
      echo -e "${YELLOW}检测到当前目录下已存在配置文件 (docker-compose.yml 与 .env)。${NC}"
      prompt_user "请选择操作 [1: 启动已有服务, 2: 重新配置新实例, 3: 退出] (默认: 1): " "1" exist_choice
      case "$exist_choice" in
        1)
          manage_compose "up"
          ;;
        2)
          deploy_init
          ;;
        *)
          info "已退出。"
          exit 0
          ;;
      esac
    else
      deploy_init
    fi
    ;;
  "init"|"setup"|"new")
    shift
    deploy_init "$@"
    ;;
  --*)
    # 如果直接以选项开头（例如 ./deploy.sh --name ...），作为 init 处理
    deploy_init "$@"
    ;;
  "up"|"down"|"stop"|"restart"|"logs"|"status"|"ps")
    manage_compose "$@"
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
