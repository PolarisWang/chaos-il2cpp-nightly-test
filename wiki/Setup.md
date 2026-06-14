# 环境搭建与启动指南

## 前置要求

- Docker Engine 24+ & Docker Compose v2
- 至少 4 核 CPU、16GB 内存、50GB 磁盘空间
- `git` 已安装
- 可选: SonarQube Token、飞书 Webhook URL

## 一步启动

```bash
# 克隆仓库
git clone <repo-url> chaos-il2cpp-nightly-test
cd chaos-il2cpp-nightly-test

# 一键启动所有服务（推荐）
bash scripts/startup.sh

# 如果需要重建镜像
bash scripts/startup.sh --build
```

## 分步启动

```bash
# 1. 初始化数据目录
sudo mkdir -p /var/lib/report-server/{daily,db,archive}

# 2. 配置环境变量
cp .env.example .env
# 编辑 .env 填入 SONAR_TOKEN 和 FEISHU_WEBHOOK_URL

# 3. 启动 SonarQube
docker compose -f sonarqube/docker-compose.yml up -d

# 4. 等待 SonarQube 就绪（约 1-2 分钟）
# 访问 http://localhost:9000 确认

# 5. 启动 Jenkins + Agents + Report
docker compose up -d --build

# 6. 验证
curl http://localhost:8081/api/health
```

## 启动脚本选项

```bash
bash scripts/startup.sh           # 完整启动
bash scripts/startup.sh --status  # 查看服务状态
bash scripts/startup.sh --stop    # 停止所有服务
bash scripts/startup.sh --restart # 重启
bash scripts/startup.sh --build   # 重建镜像后启动
bash scripts/startup.sh --init    # 仅初始化目录
bash scripts/startup.sh --jenkins-only  # 仅 Jenkins
bash scripts/startup.sh --sonar-only    # 仅 SonarQube
bash scripts/startup.sh --report-only   # 仅 Report Server
```

## 首次访问

| 服务 | 地址 | 用户 / 密码 |
|------|------|-------------|
| Jenkins | http://localhost:8080 | `admin` / `abcd@1234` |
| SonarQube | http://localhost:9000 | `admin` / `admin` |
| Report Server | http://localhost:8081 | — |

## 环境变量

| 变量 | 默认值 | 必填 | 说明 |
|------|--------|------|------|
| `SONAR_TOKEN` | — | 是 | SonarQube 认证 Token（Jenkins init.groovy 自动创建凭证） |
| `FEISHU_WEBHOOK_URL` | — | 否 | 飞书机器人 Webhook 地址 |
| `JENKINS_ADMIN_ID` | `qa004` | 否 | Jenkins 管理员账号 |
| `JENKINS_ADMIN_PASSWORD` | `abcd@1234` | 否 | Jenkins 管理员密码 |

## 验证安装

```bash
# 1. 检查所有容器运行中
docker ps --format "table {{.Names}}\t{{.Status}}"

# 2. Jenkins 可访问
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/login
# 预期: 200 或 403

# 3. Report API 正常
curl -s http://localhost:8081/api/health | python3 -m json.tool
# 预期: {"status": "ok", ...}

# 4. 手动触发一次 Nightly Pipeline
curl -X POST http://localhost:8080/job/NightlyPipeline/build \
    --user admin:abcd@1234
```

## 常见问题

### 端口冲突

如果 8080/9000/8081 被占用，修改 `docker-compose.yml` 中的端口映射。

### Docker 权限

确保当前用户在 docker 组：
```bash
sudo usermod -aG docker $USER
# 重新登录生效
```

### SonarQube 内存不足

Elasticsearch 需要至少 2GB 可用内存。如果内存不足，在 `sonarqube/docker-compose.yml` 中限制 ES 堆内存：
```yaml
environment:
  - SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true
  - ES_JAVA_OPTS=-Xms512m -Xmx512m
```

---

*Last updated: 2026-06-14*
