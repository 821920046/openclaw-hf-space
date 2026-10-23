# **OpenClaw Hugging Face Space 深度优化方案**

针对 OpenClaw 部署在 Hugging Face 免费 CPU Space 实例（通常仅 16GB 内存且受配额限制）时暴露出的**内存超限 (OOM)**、**僵尸网络扫描**以及**队列积压**等核心问题，特制定以下深度优化方案。本方案旨在对项目结构进行裁剪与加固，确保其在免费微型服务器上长期稳定、安全地运行。

## **一、 核心优化策略**

| 优化维度 | 发现问题 | 具体解决措施 | 预期效果   |
| :---- | :---- | :---- | :---- |
| **插件裁剪** | 加载 9 个插件，RSS 内存暴涨至 1.22 GiB，远超微型容器轻量运行预期。 | 在配置文件中移除 browser, canvas, phone-control 等高内存消耗组件。 | 静态常驻内存可降低 50% 以上，彻底杜绝因 OOM 被 HF 强杀。 |
| **安全与反扫描** | Nginx 遭遇大量境外僵尸网络盲猜 .env、.git 等敏感路径，消耗 CPU 算力。 | 1\. 建议在 HF 设置中将 Space 设为 **Private**。 2\. 调整 Nginx 配置直接丢弃非法探测。 | 屏蔽 100% 的外部恶意垃圾流量，将微弱的 CPU 算力留给飞书业务本身。 |
| **队列防积压** | 用户请求排队超过 120 秒，大模型响应极慢。 | 将 openrouter/free 免费渠道替换为国内高并发低延迟的 API（如硅基流动或 DeepSeek）。 | 消息首字响应提升至秒级，消除任务排队警告。 |

## **二、 针对仓库源码的具体优化修改**

建议对您在 GitHub 仓库中相关的配置文件、脚本和 Dockerfile 进行如下调整：

### **1\. 优化 openclaw.json 模板（精简插件与加固安全）**

在项目中动态生成或合并 openclaw.json 的逻辑中（或直接在挂载的持久化 Dataset 中），限制启动的插件列表。推荐的精简版插件配置如下：

{  
  "plugins": \[  
    "feishu",  
    "file-transfer",  
    "memory-core",  
    "talk-voice"  
  \],  
  "gateway": {  
    "controlUi": {  
      "dangerouslyDisableDeviceAuth": false  
    }  
  }  
}

*注：移除了 **browser**（ puppeteer/chromium 实例是绝对的内存杀手）和 **canvas**、**phone-control**，仅保留飞书核心对接能力。同时将危险的 dangerouslyDisableDeviceAuth 设为 false 以开启设备鉴权。*

### **2\. 优化 Nginx 配置（直接拒绝恶意探测）**

如果您在仓库中集成了 Nginx 配置文件，可以通过配置路由规则，对盲猜敏感路径的请求直接返回 444（Nginx 特有状态码：直接关闭连接，不返回任何响应头，最大化节省带宽和算力）：

\# 在 server 块中加入敏感路径阻断  
location \~\* \\.(env|git|yaml|yml|log|bak|config)$ {  
    return 444;  
}

location \~\* /(ADMIN|admin|wp-admin|setup|config|manifest) {  
    return 444;  
}

### **3\. 优化 Dockerfile（保持轻量与时效性）**

确保基础镜像构建时不会带入无用的系统守护进程，并在启动脚本中加入自动清理临时文件的逻辑：

* 在启动命令（如 entrypoint.sh）的开头，加入 rm \-rf /tmp/\*，定期清理运行过程中产生的富媒体、语音及临时文件缓存。  
* 将 OpenClaw 的更新机制改为通过 Docker 构建时拉取最新 Release，避免容器运行时在线升级导致的瞬时 CPU 飙升。

## **三、 部署在 Hugging Face 时的最佳操作建议**

1. **切换 Space 属性为 Private**：因为飞书机器人使用的是**长连接（WebSocket）**模式与 OpenClaw 通信，网关不需要对外暴露公网 Webhook 回调。将 Space 改为 Private 既不会破坏飞书的功能，又能让外部扫描脚本完全无法访问您的实例。  
2. **绑定稳定的 API Key**：尽量避开 OpenRouter 的免费通道，配置带有企业级 SLA 保证或国内响应快速的 API，这能有效防止任务在微型 CPU 队列里因网络挂起而发生死锁。