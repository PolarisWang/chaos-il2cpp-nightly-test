# 运维手册

## 服务管理

### 启动与停止

```bash
# 推荐方式
bash scripts/startup.sh           # 启动所有服务
bash scripts/startup.sh --stop    # 停止所有服务
bash scripts/startup.sh --status  # 查看状态

# Docker Compose 直接操作
docker compose up -d              # 启动 Jenkins + Agents + Report + MinIO
docker compose -f sonarqube/docker-compose.yml up -d  # 启动 SonarQube
docker compose logs -f master     # 查看 Jenkins 日志
docker compose logs -f report-api # 查看 Report API 日志
```

### 重建单个服务

```bash
docker compose up -d --build report-api     # 重建 Report API
docker compose up -d --build report-server  # 重建 Report Server
docker compose up -d --build master          # 重建 Jenkins Master

# 不重建镜像，仅重启
docker compose up -d --no-deps master linux-x64-agent  # 重启后使环境变量生效
```

### 启动后检查清单

```bash
# 1. 所有容器运行中
docker ps --format "table {{.Names}}\t{{.Status}}"

# 2. Jenkins 可访问
curl -s -o /dev/null -w "%{http_code}" http://10.10.1.173:8080/login
# 预期: 200

# 3. 验证 Agent 已连接（需 Jenkins 初始化完成）
curl -s http://10.10.1.173:8080/computer/linux-x64/api/json \
    --user qa004:abcd@1234 | python3 -c "import json,sys; d=json.load(sys.stdin); print('online' if not d.get('offline') else 'offline')"

# 4. Report API 正常
curl -s http://10.10.1.173:8081/api/health | python3 -m json.tool
```

## 数据维护

### 报告目录

```bash
# 查看报告占用空间
du -sh /var/lib/report-server/

# 手动清理旧报告（保留最近 30 天）
find /var/lib/report-server/daily/ -name "nightly-*-*.html" -mtime +30 -delete
find /var/lib/report-server/daily/ -name "nightly-data-*.json" -mtime +30 -delete

# 归档旧报告
tar czf /var/lib/report-server/archive/reports-2026-05.tar.gz \
    /var/lib/report-server/daily/nightly-*-202605*.html
```

### SQLite 数据库

```bash
# 数据库位置
/var/lib/report-server/db/report.db

# 查看数据量
sqlite3 /var/lib/report-server/db/report.db "SELECT COUNT(*) FROM reports;"
sqlite3 /var/lib/report-server/db/report.db "SELECT COUNT(*) FROM dll_results;"

# 导出备份
cp /var/lib/report-server/db/report.db /backup/report-$(date +%Y%m%d).db

# 清空并重新导入
sqlite3 /var/lib/report-server/db/report.db "DELETE FROM dll_results; DELETE FROM reports;"
# 然后重新运行 collect-all-results.sh 或逐个调用 /api/ingest
```

### Docker 数据卷

```bash
# 查看数据卷占用
docker system df

# 清理构建缓存（可释放大量空间）
docker builder prune -f

# 备份 Jenkins 数据
docker run --rm -v jenkins-home:/data -v /backup:/backup alpine \
    tar czf /backup/jenkins-$(date +%Y%m%d).tar.gz -C /data .
```

## 故障排查

### Jenkins 无法启动

```bash
# 查看日志
docker compose logs master

# 检查 JCasC 配置
docker exec chaos-master cat /usr/share/jenkins/ref/jenkins.yaml

# 重建
docker compose up -d --build master
```

### Agent 无法连接到 Master

```bash
# 检查 Agent 日志
docker logs chaos-agent-x64 --tail 20

# 检查 Master 日志中的 Agent 注册信息
docker compose logs master | grep -i agent

# 重启 Agent
docker compose restart linux-x64-agent

# 如果 agent 容器反复重启，检查 JENKINS_AGENT_SECRET
docker inspect chaos-agent-x64 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep AGENT
```

### Build 卡住（Pipeline 不前进）

```bash
# 检查 Agent 上运行的进程
docker exec chaos-agent-x64 ps aux | grep -E "entry|python"

# 如果 entry.exe 长时间 ( > 30 分钟) 占用 100% CPU:
# 1. 记录当前 PID
# 2. 在 Jenkins UI 中止构建
# 3. 如果需要，Kill 卡住的进程
docker exec chaos-agent-x64 kill <pid>

# 重新触发 build 并考虑切换 BUILD_CONFIG 避免卡住的阶段
```

### Report API 返回 502

```bash
# 检查 API 容器是否运行
docker ps | grep report-api

# 查看日志
docker compose logs report-api

# 检查 Nginx proxy 配置
docker exec chaos-report-server cat /etc/nginx/nginx.conf
```

### 飞书通知未收到

首先确认问题原因：

```bash
# 1. 检查 FEISHU_WEBHOOK_URL 是否在 agent 容器中
docker inspect chaos-agent-x64 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep FEISHU

# 2. 从 agent 直接测试 webhook
docker exec chaos-agent-x64 sh -c '
curl -s -o /dev/null -w "%{http_code}" -X POST "$FEISHU_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"test\"}}"
'
# 预期: 200

# 3. 检查 Jenkins build 日志中有无通知脚本调用
# （通知输出在 post-build 阶段，可能在压缩二进制日志中不可见）

# 4. 确认 docker-compose.yml 中 FEISHU_WEBHOOK_URL 在 x-external-urls 段
```

**已知坑**: `FEISHU_WEBHOOK_URL` 必须同时配置在 **master 和 linux-x64-agent** 两个容器中。通知脚本运行在 agent 上，如果只有 master 有该变量，脚本会静默跳过。

### Nightly 报告未生成

```bash
# 检查 data JSON 是否存在
ls -la /var/lib/report-server/daily/nightly-data-*.json

# 手动导入数据
curl -X POST 'http://10.10.1.173:8081/api/ingest?date_tag=20260615'

# 检查 Jenkins build 日志中 collect-all-results.sh 是否执行成功
```

## 配置管理

### 外部 URL 配置

所有外部访问地址统一在 `docker-compose.yml` 的 `x-external-urls` anchor 中定义：

```yaml
x-external-urls: &external-urls
  JENKINS_URL: http://10.10.1.173:8080
  REPORT_URL: http://10.10.1.173:8081
  FEISHU_WEBHOOK_URL: https://open.feishu.cn/open-apis/bot/v2/hook/...
```

通过 `<<: *external-urls` 应用到 master 和 linux-x64-agent。修改后需重启两个容器：

```bash
docker compose up -d --no-deps master linux-x64-agent
```

### booming-il2cpp 仓库更新

源码仓库通过 Docker volume 挂载，更新后无需重启容器：

```bash
cd /home/debian/agent/booming-il2cpp
git pull
# 变更立即对下一次 build 生效
```

## Nightly Build 后检查清单

- [ ] Jenkins 构建状态（三个平台全部通过）
- [ ] Report Server 可访问: `curl -s http://10.10.1.173:8081/`
- [ ] 报告文件已生成: `nightly-report-<date>.html`
- [ ] 趋势数据已写入 SQLite: `http://10.10.1.173:8081/api/trends`
- [ ] 飞书通知已推送（检查群聊）
- [ ] nightly-latest.html 软链接已更新

## 备份策略

| 数据 | 备份频率 | 方式 |
|------|---------|------|
| Jenkins 配置 | 每周 | Docker volume 备份 |
| SonarQube 数据 | 每周 | PostgreSQL dump |
| 报告文件 | 每月 | tar.gz 归档到 archive/ |
| SQLite 趋势库 | 每次 nightly 后 | 自动更新，可单独 cp |

---

*Last updated: 2026-06-16*
