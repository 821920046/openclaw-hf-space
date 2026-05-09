# Hugging Face 状态仓库清理与重建指南

本文档适用于当前这个 OpenClaw Hugging Face Space 模板，目标是解决下面这类问题：

- 免费 Hugging Face Space 重启后，本地状态丢失
- 为了保留状态，已经启用了 `OPENCLAW_HF_STATE_REPO`
- 但状态仓库体积已经很大，例如几十 GB
- 希望在尽量不丢最终状态的前提下，清理旧仓库并重新开始

## 背景说明

Hugging Face 官方文档说明：

- 免费 Spaces 默认只有 `50GB` 的本地磁盘，而且是 `not persistent`，也就是不持久。
- 任意一次 Space 配置变更，例如修改 Secrets / Variables，都会触发应用重启。
- Dataset 仓库可以用来存文件，支持私有仓库。
- 删除仓库是不可逆操作。
- 访问令牌需要有写权限，才能上传和修改私有仓库内容。

官方参考：

- [Spaces Overview](https://huggingface.co/docs/hub/spaces-overview)
- [Manage your Space](https://huggingface.co/docs/huggingface_hub/main/en/guides/manage-spaces)
- [Create and manage a repository](https://huggingface.co/docs/huggingface_hub/main/en/guides/repository)
- [Uploading datasets](https://huggingface.co/docs/hub/en/datasets-adding)
- [User access tokens](https://huggingface.co/docs/hub/security-tokens)

## 这份指南会做什么

按顺序完成下面 5 件事：

1. 暂停继续往旧状态仓库写新备份
2. 下载并保留最后一次可用状态快照
3. 删除旧的超大状态仓库
4. 创建一个新的私有 dataset 仓库
5. 让 Space 以后把状态同步到新的仓库

## 操作前你要知道

- 改 Hugging Face Space 的 `Variables and secrets` 会触发重启。
- 如果你当前 Space 里还有一些你没来得及保存的重要配置，那么最稳的是先让它完成一次最后备份，再开始清理。
- 当前模板默认每 `300` 秒同步一次；如果你没改过，表示大约每 `5` 分钟会尝试同步一次状态。

## 第 0 步：确认你现在的状态仓库名字

进入 Space 的 `Settings -> Variables and secrets`，找到：

- `OPENCLAW_HF_STATE_REPO`

记下它的值，例如：

```text
your-name/openclaw-state
```

后面所有仓库操作，都是围绕这个 repo 进行。

## 第 1 步：先停止继续写入旧状态仓库

这一步很重要。否则你边清理，Space 还在继续往旧仓库写新提交。

在 Hugging Face Space 的 `Settings -> Variables and secrets` 中：

### 推荐做法

把下面这个变量清空或删除：

- `OPENCLAW_HF_STATE_REPO`

### 备选做法

如果你不想动 repo 名，也可以临时删除：

- `HF_TOKEN`

当前模板里，只要 `OPENCLAW_HF_STATE_REPO` 存在但 `HF_TOKEN` 缺失，就会禁用状态同步。

### 做完后会发生什么

- Space 会自动重启一次
- 这是 Hugging Face 的正常行为
- 重启后，日志里不应该再出现类似：

```text
OpenClaw state sync: ENABLED (...)
```

如果仍然出现，说明变量没有改成功，先不要继续下一步。

## 第 2 步：下载最后一次状态快照

在删除旧仓库之前，先把最后一份状态导出来，防止误删后完全回不去。

打开旧的 dataset 状态仓库页面，通常 URL 类似：

```text
https://huggingface.co/datasets/<your-name>/<repo-name>
```

在 `Files and versions` 里，找到并下载：

- `openclaw-home.tgz`
- `openclaw-state.json`

如果存在将来新增的明细文件，也一起下载，例如：

- `openclaw-state-files.json`

### 这两个文件分别是什么

- `openclaw-home.tgz`
  - OpenClaw 家目录的压缩包，里面包含 `openclaw.json`、`state/`、`agents/`、配对数据等
- `openclaw-state.json`
  - 本次备份的元数据，例如时间、大小、sha256、原因

### 建议

把下载下来的文件保存在本地一个单独目录，例如：

```text
D:\hf-openclaw-backup\2026-04-05\
```

## 第 3 步：确认旧仓库大小和内容

如果你只是想先核对一下，可以在 Hugging Face 账号的 `Repositories -> Storage` 页面查看各个 repo 的体积。

你也可以进入旧 dataset repo：

- 在 `Files and versions` 看当前文件
- 在 `History` 看提交历史

注意：

- 当前文件少，不代表历史小
- 即使现在只有一个 `openclaw-home.tgz`，仓库仍然可能因为历史版本而占很多空间

如果你的仓库已经像之前那样到了几十 GB，通常最省事的办法不是“逐个删文件”，而是“删除整个旧仓库，重新建一个新的仓库”。

## 第 4 步：删除旧状态仓库

只有在你已经完成“第 2 步下载备份”之后，再做这一步。

### 网页方式

1. 打开旧的 dataset repo 页面
2. 进入 `Settings`
3. 找到删除仓库选项
4. 按提示确认删除

### 注意

- 删除仓库是不可逆的
- Hugging Face 官方文档也明确说明这是 irreversible

如果你不确定，就先不要删。

## 第 5 步：创建新的私有 dataset 仓库

推荐新建一个干净的 repo，而不是继续沿用旧仓库。

### 网页方式

1. 点击头像
2. 选择 `New Dataset`
3. 输入新的仓库名，例如：

```text
openclaw-state-v2
```

4. 可见性选择 `private`
5. 创建完成后，记下新的 repo id，例如：

```text
your-name/openclaw-state-v2
```

### 命名建议

用一个明确的新名字，避免和旧仓库混淆，例如：

- `openclaw-state-v2`
- `openclaw-state-clean`
- `openclaw-state-2026-04`

## 第 6 步：准备一个可写的 HF Token

如果你已经有一个可写 token，可以继续用；如果不确定，建议重新创建一个专用 token。

### 官方要求

用于上传私有仓库内容的 token 需要有写权限：

- `write`
- 或者能写指定资源的 `fine-grained` token

### 创建方法

1. 打开 Hugging Face `Settings -> Access Tokens`
2. 点击 `New token`
3. 给 token 起一个名字，例如：

```text
openclaw-space-state-sync
```

4. 选择：
   - `write`
   - 或 `fine-grained`，并授予新状态仓库写权限
5. 创建后立刻复制保存

注意：token 只会显示一次，后面无法再次查看原值。

## 第 7 步：把 Space 指向新的状态仓库

回到你的 Space：

`Settings -> Variables and secrets`

设置或更新下面这些值：

- `HF_TOKEN=<你的新 token>`
- `OPENCLAW_HF_STATE_REPO=<你的新 repo id>`
- `OPENCLAW_HF_STATE_REPO_TYPE=dataset`
- `OPENCLAW_HF_STATE_SYNC_INTERVAL=1800`

### 为什么建议 `1800`

当前模板默认是 `300` 秒，也就是 `5` 分钟一次。这个频率对免费环境来说偏高。

更稳的建议：

- `1800` = 每 30 分钟同步一次
- `3600` = 每 1 小时同步一次
- `0` = 不做定时同步，只在退出时同步

如果你担心仓库存储膨胀，建议先从 `1800` 开始。

## 第 8 步：是否需要恢复旧状态

这一步看你的需求。

### 场景 A：你只想从现在开始重新积累状态

那就什么都不用做。

直接让 Space 重启，等它以后自动产生新的备份即可。

### 场景 B：你想把旧状态继续接回去

当前模板默认恢复的是“新状态仓库里的最新备份”。

所以如果你想恢复旧状态，有两种方式：

#### 方式 1：手动上传旧的压缩包到新仓库

把你在第 2 步下载下来的：

- `openclaw-home.tgz`
- `openclaw-state.json`

上传到新建的 dataset repo 根目录，文件名保持不变。

之后重启 Space，模板就会从新仓库拉这两个文件来恢复。

#### 方式 2：不要恢复旧状态，干净重来

如果旧状态已经很乱，或者里面有很多无用技能、错误配置，那么直接放弃旧包，重新从零开始也是完全合理的。

## 第 9 步：重启后如何验证成功

Space 重启后，查看启动日志。

### 你应该看到

如果启用了状态同步：

```text
OpenClaw state sync: ENABLED (repo=..., type=dataset, interval=1800s)
```

如果新仓库里已经有可恢复的状态：

```text
[hf-state] restored /root/.openclaw from dataset repo ...
```

如果状态后来被成功上传：

```text
[hf-state] uploaded state backup to dataset repo ...
```

### 如果没看到这些

检查：

- `HF_TOKEN` 是否存在
- `OPENCLAW_HF_STATE_REPO` 是否写对
- `OPENCLAW_HF_STATE_REPO_TYPE` 是否是 `dataset`
- token 是否有写权限
- repo 是否真的是 private dataset repo

## 第 10 步：建议一起顺手修掉的配置

为了避免重启后又遇到别的问题，建议同时确认下面两个：

- `OPENCLAW_DEFAULT_MODEL=openrouter/free`
- `FEISHU_ALLOW_FROM=<你的 open_id>`

如果你已经在用 Feishu allowlist，这两个通常都应该是固定值。

## 常见问题

### 1. 我只是改了一个变量，为什么 Space 重启了？

因为 Hugging Face 官方行为就是这样：

- 任何 Secrets / Variables / hardware 的配置变更，都会触发应用重启

### 2. 我删除旧仓库后，Space 会不会立刻报错？

如果你已经先清掉了 `OPENCLAW_HF_STATE_REPO` 或 `HF_TOKEN`，它就不会再去访问旧仓库，所以不会因为旧仓库删除而出错。

### 3. 我能不能只删仓库里的文件，不删整个仓库？

可以，但通常不推荐。

因为你现在遇到的是“历史累积太大”的问题，不是“当前文件太多”的问题。删当前文件不一定能明显回收存储，删整个旧仓库并新建一个往往更干净。

### 4. 我想先暂停定时备份，只保留退出时备份，可以吗？

可以，把：

- `OPENCLAW_HF_STATE_SYNC_INTERVAL=0`

即可。

### 5. 我怎么确认现在的状态仓库里到底有什么？

当前实现默认保存：

- `openclaw-home.tgz`
- `openclaw-state.json`

其中：

- `openclaw-home.tgz` 是完整压缩包
- `openclaw-state.json` 是元数据

如果你需要更细粒度的文件清单，后续可以再给模板加一个额外的明细导出文件。

## 推荐的最小安全操作顺序

如果你只想照着做，不想看上面全部细节，就按这个顺序：

1. 到 Space 里删除 `OPENCLAW_HF_STATE_REPO`
2. 等 Space 重启完成
3. 到旧 dataset repo 下载 `openclaw-home.tgz` 和 `openclaw-state.json`
4. 删除旧 dataset repo
5. 新建一个新的 private dataset repo
6. 新建或准备一个 `write` 权限的 `HF_TOKEN`
7. 回到 Space，设置：
   - `HF_TOKEN`
   - `OPENCLAW_HF_STATE_REPO=<新 repo>`
   - `OPENCLAW_HF_STATE_REPO_TYPE=dataset`
   - `OPENCLAW_HF_STATE_SYNC_INTERVAL=1800`
8. 重启后看日志，确认出现 `OpenClaw state sync: ENABLED`
9. 如果你想保留旧状态，再把旧的 `openclaw-home.tgz` 和 `openclaw-state.json` 上传到新 repo

## 当前模板相关文件

如果你想对照代码，核心逻辑在这里：

- [docker/start.sh](/E:/新建文件夹/openclaw-hf-space/docker/start.sh)
- [docker/hf-state-store.py](/E:/新建文件夹/openclaw-hf-space/docker/hf-state-store.py)
- [Dockerfile](/E:/新建文件夹/openclaw-hf-space/Dockerfile)
- [README.md](/E:/新建文件夹/openclaw-hf-space/README.md)