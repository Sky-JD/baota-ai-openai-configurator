# 宝塔 AI OpenAI 兼容接口配置器

`configure_bt_ai_openai_api.sh` 用于把宝塔面板 AI 模块切换到自定义 OpenAI-compatible API，避免继续使用宝塔官方默认接口。

脚本会同时处理两个关键位置：

- 写入宝塔 AI 全局配置：`/www/server/panel/data/agent/config.json`
- 修正宝塔内置 Prompt/SkillAgent 模板里的官方接口覆盖项，避免页面仍被模板里的 `base_url` / `api_key` 拉回官方接口

## 适用系统

支持常见 Linux 宝塔环境：

- CentOS / RHEL / AlmaLinux / Rocky Linux
- Ubuntu / Debian

不支持 Windows/PowerShell。请在宝塔面板所在 Linux 服务器上执行。

## API 要求

你的 API 提供商必须兼容 OpenAI API 格式。

至少需要支持：

```text
/v1/chat/completions
```

建议支持：

```text
/v1/models
```

如果需要 RAG、知识库、语义检索或长历史召回，再考虑支持：

```text
/v1/embeddings
```

普通聊天不强制需要 Embedding。

## 快速使用

把脚本上传到服务器后执行：

```bash
bash configure_bt_ai_openai_api.sh
```

脚本会逐步提示输入：

```text
请输入 API Base URL，例如 https://api.example.com/v1
>
请输入 API Key
>
```

如果 URL 没有 `/v1`，脚本会自动补齐：

```text
https://api.example.com    -> https://api.example.com/v1
https://api.example.com/   -> https://api.example.com/v1
```

如果误填了完整聊天接口，也会自动规整：

```text
https://api.example.com/v1/chat/completions -> https://api.example.com/v1
```

## 非交互式使用

适合批量部署或远程执行：

```bash
bash configure_bt_ai_openai_api.sh \
  --base-url https://api.example.com/v1 \
  --api-key sk-xxxx \
  --models mimo-v2.5-pro \
  --yes
```

如果不传 `--models`，脚本会尝试请求：

```text
{base_url}/models
```

自动获取模型列表。

在交互模式下，多个模型会让你选择；在 `--yes` 模式下会默认选择第一个模型。如果自动获取失败，脚本会解析 OpenAI/New API 风格错误，例如：

```json
{"error":{"message":"无效的令牌","type":"new_api_error"}}
```

并输出具体原因。

## 常用参数

```text
--base-url URL              自定义 API Base URL，例如 https://api.example.com/v1
--api-key KEY               自定义 API Key
--models LIST               模型列表，逗号分隔；不填时会尝试自动获取
--embedding-base-url URL    Embedding API Base URL，默认跟随 --base-url
--embedding-api-key KEY     Embedding API Key，默认跟随 --api-key
--embedding-model NAME      Embedding 模型名，默认 text-embedding-3-small
--panel-path PATH           宝塔面板路径，默认 /www/server/panel 或环境变量 BT_PANEL
--config PATH               直接指定 config.json 路径
--yes                       非交互确认
--no-restart                写入后不重启宝塔面板
--dry-run                   只打印将写入的配置，不落盘
--show                      显示当前配置摘要，不显示密钥原文
--restore BACKUP_PATH       从备份文件恢复
```

## 查看当前配置

```bash
bash configure_bt_ai_openai_api.sh --show
```

输出会隐藏密钥原文，并显示是否还有模板覆盖项：

```json
{
  "api_base_url": "https://api.example.com/v1",
  "api_key": "sk-x...xxxx",
  "models": ["mimo-v2.5-pro"],
  "template_overrides": []
}
```

如果 `template_overrides` 不是空数组，说明宝塔内置模板里仍有 `base_url`、`api_key` 或不一致的 `model_name`，页面可能继续走旧接口。重新运行脚本即可修正。

## 为什么要修正模板

宝塔 AI 的部分页面会使用内置 Prompt 模板，例如：

```text
/www/server/panel/mod/project/agent/prompts/agent_aics.md
```

这些模板可能硬编码：

```yaml
base_url: https://www.bt.cn/plugin_api/chat/openai/v1
api_key: sk-xxxx
model_name: qwen3.5-plus
```

宝塔聊天接口的优先级是：

```text
请求参数 > Prompt 模板配置 > 全局 config.json
```

所以只改 `config.json` 可能还不够。脚本会自动：

- 删除模板 frontmatter 里的 `base_url`
- 删除模板 frontmatter 里的 `api_key`
- 把 `model_name` 同步成当前配置的第一个模型
- 修改前创建 `.bak.YYYYMMDD-HHMMSS` 备份

## Embedding 是否必须填写

普通聊天不需要单独配置 Embedding。

如果你只是想让宝塔 AI 正常对话，Embedding 相关提示可以直接回车，默认继承主 API URL 和 Key。

只有这些功能才可能依赖 Embedding：

- RAG / 知识库检索
- 语义相似搜索
- 长对话历史召回
- 向量检索

如果你的 API 提供商不支持 `/v1/embeddings`，不影响基础聊天。

## 测试写入但不落盘

```bash
bash configure_bt_ai_openai_api.sh \
  --base-url https://api.example.com \
  --api-key sk-xxxx \
  --models mimo-v2.5-pro \
  --dry-run \
  --yes
```

`--dry-run` 会显示将写入的配置和将修正的模板，但不会修改文件。

## 回滚配置

脚本修改 `config.json` 前会自动备份，例如：

```text
/www/server/panel/data/agent/config.json.bak.20260531-034737
```

使用备份恢复：

```bash
bash configure_bt_ai_openai_api.sh \
  --restore /www/server/panel/data/agent/config.json.bak.20260531-034737
```

模板文件也会生成类似备份：

```text
/www/server/panel/mod/project/agent/prompts/agent_aics.md.bak.20260531-035514
```

如需恢复模板，可手动把对应 `.bak.*` 文件复制回原文件名。

## 常见问题

### 页面仍提示 401 Unauthorized

先查看配置：

```bash
bash configure_bt_ai_openai_api.sh --show
```

重点看：

- `api_base_url` 是否正确
- `api_key` 是否是当前有效 Key
- `models` 是否是当前 token 可用的模型
- `template_overrides` 是否为空数组

如果 `template_overrides` 不为空，重新运行脚本修正模板。

### 已写入配置但页面还是旧模型或旧接口

宝塔面板进程可能缓存了配置。脚本默认会重启宝塔面板；如果使用了 `--no-restart`，需要手动重启：

```bash
bt restart
```

然后浏览器执行 `Ctrl + F5` 强制刷新，并新建聊天会话测试。

### 自动获取模型失败

可能原因：

- API Key 错误
- API 提供商不支持 `/v1/models`
- 当前 Key 没有模型列表权限
- Base URL 填错

可以手动传入模型：

```bash
bash configure_bt_ai_openai_api.sh \
  --base-url https://api.example.com/v1 \
  --api-key sk-xxxx \
  --models your-model-name \
  --yes
```

## 文件说明

```text
configure_bt_ai_openai_api.sh  主脚本
README.md                     使用说明
```

