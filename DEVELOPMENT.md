# 开发注意事项与工作流指南 (DEVELOPMENT.md)

本文档整理了本项目在本地开发、Docker 运行、代码修改及镜像构建时的关键注意事项，避免在新 Session 或切换环境时遇到常见问题。

---

## 1. 镜像构建与推送策略（重要）

- **日常功能开发**：
  - **严禁在每次开发完成后自动推送到 Docker Hub！**
  - 本地仅执行构建并在本地 Docker 运行验证：
    ```powershell
    docker compose up -d --build
    ```
- **镜像推送时机**：
  - **仅在准备合并到 `main` 主分支、或者用户明确发出推送指令时，才处理镜像构建与推送。**
  - **推送仓库与标签规范**：
    - 仓库：`dogming/once-campfire-rust`
    - 标签：`latest`、版本号（如 `0.1.0`）、日期（如 `YYYYMMDD`，例如 `20261001`）。
    - 示例命令：
      ```powershell
      docker push dogming/once-campfire-rust:latest
      docker push dogming/once-campfire-rust:0.1.0
      docker push dogming/once-campfire-rust:20261001
      ```

---

## 2. Git 换行符（CRLF vs LF - 致命陷阱）

- **核心背景**：
  - 项目在编译阶段使用 Propshaft 机制计算静态资源哈希（`SHA1`），直接计算文件字节。
  - Windows 环境下 Git 默认 `core.autocrlf=true` 会将文本文件转为 `CRLF`（`\r\n`）。
  - 若 `reference/` 或 `crates/assets/` 下的文件被转为 CRLF，会导致静态资源指纹哈希改变，CI 及 golden-vector 测试会直接失败，且 Linux 容器内的 shell 脚本（如 `post-restore`）会报错 `\r: command not found`。
- **环境配置要求**：
  - 本仓库与 `reference/` 子模块必须保持 **`core.autocrlf=false`**：
    ```powershell
    git config core.autocrlf false
    git -C reference config core.autocrlf false
    ```
  - 如果文件不慎被转为 CRLF，使用以下命令强制重置为仓库本身的 LF：
    ```powershell
    git rm --cached -r .
    git reset --hard
    git -C reference rm --cached -r .
    git -C reference reset --hard
    ```

---

## 3. 前端修改规范（Overrides）

- **严禁直接修改 `reference/`**：
  - `reference/` 为 Git 子模块，必须保持与上游提交完全一致。
- **覆盖机制**：
  - 所有属于本移植工程的前端改动，全部放在 **`crates/assets/overrides/`** 目录下。
  - 文件相对路径必须与被覆盖文件的逻辑路径一致（例如 `crates/assets/overrides/controllers/lightbox_controller.js` 覆盖 `reference/app/javascript/controllers/lightbox_controller.js`）。
  - 编译工具 `crates/assets/build.rs` 会优先加载 `overrides/` 下的文件。
- **文档同步**：
  - 任何新增或修改的覆盖文件，必须在 **`crates/assets/OVERRIDES.md`** 的表格中添加记录，说明修改原因与差异。

---

## 4. 本地 Docker 环境与运行配置

- **Docker Desktop 启动**：
  - 若 Windows 下 Docker 守护进程未启动，可执行：
    ```powershell
    Start-Process -FilePath "C:\Program Files\Docker\Docker\resources\com.docker.backend.exe" -WindowStyle Hidden
    ```
  - 确认 `docker version` 能正常响应后再执行容器命令。
- **端口映射**：
  - 默认映射端口为 **`3000:80`**。
  - 本地访问地址：**`http://localhost:3000`**。
  - 注意：不要默认使用 `8080`，本地可能已有其他服务（如 `realtime-chopper`）占用 8080。
- **Docker Compose 日常操作**：
  ```powershell
  # 启动/重新编译启动
  docker compose up -d --build

  # 查看运行状态
  docker compose ps

  # 查看实时日志
  docker compose logs -f

  # 停止并移除容器
  docker compose down
  ```
- **数据持久化存储**：
  - `compose.yaml` 中默认使用命名卷 `campfire_rust_storage`。
  - 若需要挂载旧版 Rails 遗留的数据卷，可在 `compose.yaml` 中将卷配置修改为：
    ```yaml
    volumes:
      campfire_storage:
        external: true
        name: once-campfire_campfire_data
    ```

---

## 5. 更新日志管理 (CHANGELOG.md)

- 任何新功能、交互改进或 Bug 修复，应及时在根目录的 **`CHANGELOG.md`** 中追加记录：
  - 包含发布日期、改动概述。
  - 提供详细的操作指引（如桌面端鼠标、移动端触控手势说明）。
  - 记录技术实现细节与涉及的文件路径。
