# chaos-il2cpp CI/CD Wiki

欢迎来到 chaos-il2cpp 持续集成/持续交付系统 Wiki。

## 快速导航

| 文档 | 说明 |
|------|------|
| [Home](Home) | Wiki 入口 |
| [Architecture](Architecture) | 系统架构与服务拓扑 |
| [Setup](Setup) | 环境搭建与启动指南 |
| [Nightly-Pipeline](Nightly-Pipeline) | Nightly Build 管线详解 |
| [Report-Server](Report-Server) | 报告服务器、API 与趋势分析 |
| [Dashboard](Dashboard) | 质量看板说明 |
| [Operations](Operations) | 运维手册与故障排查 |
| [Agent-Setup](Agent-Setup) | Agent 注册与平台支持 |

## 系统概览

| 维度 | 内容 |
|------|------|
| 用途 | IL2CPP 多平台编译验证 + 全量测试 + 质量报告 |
| 核心工具 | Jenkins + SonarQube + Allure + FastAPI + Nginx |
| 测试平台 | Linux x64, Linux ARM64, Android ARM64 |
| 测试维度 | Fact(正确性), Benchmark(性能), HotUpdate(热更新), Memory(内存) |
| 触发方式 | 每日 03:00 cron / GitHub Webhook / 手动 |
| 通知渠道 | 飞书卡片 + 邮件 |

## 快速链接

- Jenkins: http://host:8080
- SonarQube: http://host:9000
- Report Server: http://host:8081
- Report API: http://host:8081/api/reports

---

*Last updated: 2026-06-14*
