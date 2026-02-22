# CF IP Optimizer 设计文档

## 概述

在 NAS (威联通) 上运行 Docker 容器，自动优选 Cloudflare IP，结果存储到 Cloudflare Workers KV，供多场景使用。

## 需求

- 每小时（可配置）自动优选 CF IP
- 结果持久化存储到 Workers KV
- 支持多端口测试（80, 443）
- 支持 IPv4/IPv6
- 通过 API 提供读取接口

## 架构

```
NAS (威联通) Docker
└── cf-ip-optimizer 容器
    ├── 循环脚本（动态频率）
    ├── cfst (Linux)
    └── CURL (CF API)
            │
            ▼
    Cloudflare Workers KV
    ├── config (配置)
    └── result (结果)
            │
    ┌───────┴───────┐
    ▼               ▼
Workers API    代理软件订阅
```

## 组件设计

### 1. Docker 容器

**基础镜像：** `alpine:latest`

**目录结构：**
```
/opt/cf-optimizer/
├── cfst                 # CloudflareSpeedTest 二进制
├── ip.txt               # IPv4 地址池
├── ipv6.txt             # IPv6 地址池
├── generate_ips.sh      # 生成随机 IP 脚本
├── optimizer.sh         # 主脚本（循环 + 优选 + 上传）
└── entrypoint.sh        # 入口脚本
```

**环境变量：**

| 变量名 | 说明 | 必填 |
|--------|------|------|
| `CF_API_TOKEN` | Cloudflare API Token（KV 读写权限） | 是 |
| `CF_ACCOUNT_ID` | Cloudflare 账户 ID | 是 |
| `KV_NAMESPACE_ID` | KV 命名空间 ID | 是 |
| `WORKER_URL` | Workers 地址（用于获取配置） | 是 |

**docker-compose.yml：**
```yaml
version: '3'
services:
  cf-ip-optimizer:
    image: cf-ip-optimizer:latest
    container_name: cf-ip-optimizer
    restart: unless-stopped
    environment:
      - CF_API_TOKEN=your_api_token
      - CF_ACCOUNT_ID=your_account_id
      - KV_NAMESPACE_ID=your_kv_namespace_id
      - WORKER_URL=https://your-worker.workers.dev
    volumes:
      - ./logs:/var/log/cf-optimizer
```

### 2. Workers KV 数据结构

**命名空间：** `CF_IP_OPTIMIZER`

**Key: `config`** - 优选配置

```json
{
  "interval": 3600,
  "testCount": 1000,
  "downloadCount": 50,
  "latencyMax": 200,
  "downloadMin": 5,
  "ports": [80, 443],
  "ipVersion": "both"
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `interval` | int | 3600 | 优选间隔（秒） |
| `testCount` | int | 1000 | 延迟测速数量 |
| `downloadCount` | int | 50 | 下载测速数量 |
| `latencyMax` | int | 200 | 延迟上限（ms） |
| `downloadMin` | float | 5.0 | 下载速度下限（MB/s） |
| `ports` | array | [443] | 测速端口列表 |
| `ipVersion` | string | "both" | IP版本：ipv4/ipv6/both |

**Key: `result`** - 优选结果

```json
{
  "lastUpdated": "2024-01-15T10:00:00Z",
  "ips": [
    {
      "ip": "104.16.132.229",
      "port": 443,
      "latency": 145.23,
      "downloadSpeed": 28.5
    },
    {
      "ip": "104.16.132.229",
      "port": 80,
      "latency": 142.15,
      "downloadSpeed": 30.2
    }
  ]
}
```

### 3. Workers API 接口

| 接口 | 方法 | 返回格式 | 说明 |
|------|------|----------|------|
| `/api/ips` | GET | 纯文本 | 每行 `ip:port`，供代理软件订阅 |
| `/api/ips/json` | GET | JSON | 完整结果（含延迟、速度、时间） |
| `/api/ips/conf` | GET | JSON | 获取优选配置 |

**响应示例：**

`GET /api/ips`
```
104.16.132.229:443
104.16.132.229:80
172.67.60.78:443
```

`GET /api/ips/json`
```json
{
  "lastUpdated": "2024-01-15T10:00:00Z",
  "ips": [...]
}
```

`GET /api/ips/conf`
```json
{
  "interval": 3600,
  "testCount": 1000,
  "downloadCount": 50,
  "latencyMax": 200,
  "downloadMin": 5,
  "ports": [80, 443],
  "ipVersion": "both"
}
```

### 4. 主脚本逻辑 (optimizer.sh)

```
循环开始
    │
    ▼
获取配置 (GET /api/ips/conf)
    │
    ▼
生成随机 IP (generate_ips.sh)
    │
    ▼
对每个端口运行 cfst 测速
    │
    ▼
合并结果为 JSON
    │
    ▼
写入 KV (PUT CF API)
    │
    ▼
sleep $interval
    │
    ▼
回到循环开始
```

## 实现清单

1. **Docker 镜像**
   - Dockerfile
   - entrypoint.sh
   - optimizer.sh
   - generate_ips.sh
   - cfst Linux 二进制

2. **Cloudflare 配置**
   - 创建 KV 命名空间
   - 创建 API Token
   - 初始化 config 数据

3. **Workers 代码**
   - 读取 KV 返回结果
   - 提供三个 API 接口

## 使用流程

1. 在 Cloudflare 创建 KV 命名空间和 API Token
2. 部署 Workers（提供 API 接口）
3. 初始化 KV 中的 config
4. 构建 Docker 镜像
5. 在 NAS 上运行容器
6. 通过 API 获取优选 IP
