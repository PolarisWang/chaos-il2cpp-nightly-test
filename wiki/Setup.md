# 环境搭建与启动指南

## 前置要求

- Docker Engine 24+ & Docker Compose v2
- 至少 4 核 CPU、16GB 内存、50GB 磁盘空间
- `git` 已安装
- booming-il2cpp 源码仓库（通过 Docker volume 挂载）

## 目录结构

建议两个仓库放在同一父目录下：

```
/home/debian/agent/
    ├── chaos-il2cpp-nightly-test/   # 本仓库 (CI/CD 配置)
    └── booming-il2cpp/              # 源码仓库 (被挂载到容器)
```

## 一步启动

```bash
# 1. 克隆本仓库
git clone <repo-url> chaos-il2cpp-nightly-test
cd chaos-il2cpp-nightly-test

# 2. 确保 booming-il2cpp 仓库存在
ls /home/debian/agent/booming-il2cpp/testing/foundation-dll/

# 3. 一键启动所有服务
bash scripts/startup.sh

# 4. 如果需要重建镜像
bash scripts/startup.sh --build
```

## 分步启动

```bash
# 1. 初始化数据目录
sudo mkdir -p /var/lib/report-server/{daily,db,archive}

# 2. 配置环境变量（可选）
# 编辑 docker-compose.yml 中的 x-external-urls 段
# 修改 JENKINS_URL 和 REPORT_URL 为实际的 IP 地址

# 3. 启动 SonarQube（可选）
docker compose -f sonarqube/docker-compose.yml up -d

# 4. 等待 SonarQube 就绪（约 1-2 分钟）
# 访问 http://<host>:9000 确认

# 5. 启动 Jenkins + Agents + Report + MinIO
docker compose up -d --build

# 6. 等待 Jenkins 初始化（约 30 秒）
# init.groovy 会自动创建 Agent 节点和凭证

# 7. 验证
curl -s http://10.10.1.173:8081/api/health
```

## 首次访问

| 服务 | 地址 | 用户 / 密码 |
|------|------|-------------|
| Jenkins | http://10.10.1.173:8080 | `qa004` / `abcd@1234` |
| SonarQube | http://10.10.1.173:9000 | `admin` / `admin` |
| Report Server | http://10.10.1.173:8081 | — |

## 外部 URL 配置

在 `docker-compose.yml` 中使用 YAML anchor 统一管理：

```yaml
x-external-urls: &external-urls
  JENKINS_URL: http://10.10.1.173:8080
  REPORT_URL: http://10.10.1.173:8081
  FEISHU_WEBHOOK_URL: https://open.feishu.cn/open-apis/bot/v2/hook/...
```

这些变量会被自动注入到 master 和 linux-x64-agent 两个容器中。
如果 IP 地址变更，修改此处并重启容器：

```bash
docker compose up -d --no-deps master linux-x64-agent
```

## 环境变量

| 变量 | 默认值 | 必填 | 说明 |
|------|--------|------|------|
| `JENKINS_URL` | `http://10.10.1.173:8080` | 否 | Jenkins 外部访问地址（通知链接用） |
| `REPORT_URL` | `http://10.10.1.173:8081` | 否 | 报告服务器外部地址（通知链接用） |
| `FEISHU_WEBHOOK_URL` | — | 否 | 飞书机器人 Webhook 地址 |
| `SONAR_TOKEN` | — | 是 | SonarQube 认证 Token |
| `JENKINS_ADMIN_ID` | `qa004` | 否 | Jenkins 管理员账号 |
| `JENKINS_ADMIN_PASSWORD` | `abcd@1234` | 否 | Jenkins 管理员密码 |
| `MINIO_ACCESS_KEY` | `minioadmin` | 否 | MinIO S3 访问密钥 |
| `MINIO_SECRET_KEY` | `minioadmin` | 否 | MinIO S3 密钥 |

## 验证安装

```bash
# 1. 检查所有容器运行中
docker ps --format "table {{.Names}}\t{{.Status}}"

# 2. Jenkins 可访问
curl -s -o /dev/null -w "%{http_code}" http://10.10.1.173:8080/login
# 预期: 200

# 3. Report API 正常
curl -s http://10.10.1.173:8081/api/health | python3 -m json.tool
# 预期: {"status": "ok", ...}

# 4. Agent 已连接（Jenkins 就绪后执行）
curl -s http://10.10.1.173:8080/computer/linux-x64/api/json \
    --user qa004:abcd@1234 | python3 -c "import json,sys; d=json.load(sys.stdin); print('offline' if d.get('offline') else 'online')"

# 5. 手动触发一次 Nightly Build
curl -X POST http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters \
    --user qa004:abcd@1234
```

## booming-il2cpp 仓库

本系统不通过 git clone 拉取源码，而是通过 Docker volume 直接挂载宿主机目录：

```yaml
volumes:
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:ro   # master
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:rw   # agent
```

如需更新源码：

```bash
cd /home/debian/agent/booming-il2cpp
git pull
# 无需重启容器，下一次 build 自动使用新代码
```

## 常见问题

### 端口冲突

如果 8080/9000/8081 被占用，修改 `docker-compose.yml` 和 `sonarqube/docker-compose.yml` 中的端口映射，同时更新 `x-external-urls` 中的 `JENKINS_URL` 和 `REPORT_URL`。

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

### Agent 连不上 Master

Agent 容器重启后会自动重新连接 Jenkins。如果仍然连不上：

```bash
# 检查 Agent 日志
docker logs chaos-agent-x64 --tail 20

# 确认 JENKINS_MASTER_URL 正确
docker inspect chaos-agent-x64 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep JENKINS_MASTER

# 重启 Agent
docker compose restart linux-x64-agent
```

### 飞书通知不发

**重要**: `FEISHU_WEBHOOK_URL` 必须同时配置在 master 和 linux-x64-agent 两个容器中。通知脚本运行在 agent 上。
使用 `<<: *external-urls` 可确保两个容器都获取该变量。验证方法：

```bash
docker inspect chaos-agent-x64 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep FEISHU
```

---

*Last updated: 2026-06-16*
