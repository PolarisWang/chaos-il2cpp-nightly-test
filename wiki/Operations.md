# 运维手册

## 服务管理

### 启动与停止

```bash
# 推荐方式
bash scripts/startup.sh           # 启动所有服务
bash scripts/startup.sh --stop    # 停止所有服务
bash scripts/startup.sh --status  # 查看状态

# Docker Compose 直接操作
docker compose up -d              # 启动 Jenkins + Agents + Report
docker compose -f sonarqube/docker-compose.yml up -d  # 启动 SonarQube
docker compose logs -f master     # 查看 Jenkins 日志
docker compose logs -f report-api # 查看 Report API 日志
```

### 重建单个服务

```bash
docker compose up -d --build report-api     # 重建 Report API
docker compose up -d --build report-server  # 重建 Report Server
docker compose up -d --build master          # 重建 Jenkins Master
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

# 清空并重新导入（需先停止 report-api）
sqlite3 /var/lib/report-server/db/report.db "DELETE FROM dll_results; DELETE FROM reports;"
# 然后重新运行 collect-all-results.sh 或逐个调用 /api/ingest
```

### Docker 数据卷

```bash
# 查看数据卷占用
docker system df

# 清理构建缓存（可释放 ~12GB）
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
# 检查 Master 日志
docker compose logs master | grep -i agent

# 重启 Agent
docker compose restart linux-x64-agent

# 手动注册（如果自动注册失败）
docker exec chaos-master \
    java -jar /usr/share/jenkins/jenkins.war \
    -httpPort=-1 &
```

### SonarQube 初始化慢

首次启动 Elasticsearch 需要下载插件和分析器，通常需要 1-2 分钟。

```bash
# 查看进度
docker compose -f sonarqube/docker-compose.yml logs -f sonarqube

# 检查数据库连接
docker compose -f sonarqube/docker-compose.yml exec postgresql \
    pg_isready -U sonar
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

### Nightly 报告未生成

```bash
# 检查 Jenkins 构建历史
# 或在 agent 上手动运行 orchestrator
bash scripts/nightly-orchestrator.sh --dry-run

# 检查数据文件
ls -la /var/lib/report-server/daily/nightly-data-*.json

# 手动导入数据
curl -X POST 'http://localhost:8081/api/ingest?date_tag=20260614'
```

## 备份策略

| 数据 | 备份频率 | 方式 |
|------|---------|------|
| Jenkins 配置 | 每周 | Docker volume 备份 |
| SonarQube 数据 | 每周 | PostgreSQL dump |
| 报告文件 | 每月 | tar.gz 归档到 archive/ |
| SQLite 趋势库 | 每次 nightly 后 | 自动更新，可单独 cp |

## 监控检查清单

每次 Nightly Build 后确认：

- [ ] Jenkins 构建状态（全部平台通过）
- [ ] SonarQube 质量门禁（覆盖率 > 60%, 重复率 < 5%）
- [ ] 报告文件已生成：`nightly-report-<date>.html`
- [ ] 趋势数据已写入 SQLite：`/api/trends`
- [ ] 飞书通知已推送
- [ ] nightly-latest.html 软链接已更新

---

*Last updated: 2026-06-14*
