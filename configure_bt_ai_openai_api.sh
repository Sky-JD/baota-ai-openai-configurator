#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.1"
SUPPORTED_DISTROS="CentOS/RHEL/AlmaLinux/Rocky Linux/Ubuntu/Debian"

PANEL_PATH="${BT_PANEL:-/www/server/panel}"
CONFIG_PATH=""
BASE_URL="${BT_AI_API_BASE_URL:-}"
API_KEY="${BT_AI_API_KEY:-}"
MODELS="${BT_AI_MODELS:-}"
EMBEDDING_BASE_URL="${BT_AI_EMBEDDING_BASE_URL:-}"
EMBEDDING_API_KEY="${BT_AI_EMBEDDING_API_KEY:-}"
EMBEDDING_MODEL="${BT_AI_EMBEDDING_MODEL:-}"
YES=0
NO_RESTART=0
DRY_RUN=0
SHOW_CONFIG=0
RESTORE_BACKUP=""

usage() {
  cat <<'EOF'
用法:
  configure_bt_ai_openai_api.sh [选项]

作用:
  配置宝塔面板 AI 模块使用自定义 OpenAI-compatible API，而不是默认宝塔官方接口。
  同时修正内置 Prompt/SkillAgent 模板里的官方 base_url/api_key 覆盖项。

兼容范围:
  支持 CentOS/RHEL/AlmaLinux/Rocky Linux 和 Ubuntu/Debian 系 Linux。
  不兼容 Windows/PowerShell，请在宝塔所在 Linux 服务器上执行。

重要提示:
  你的 API 提供商必须兼容 OpenAI API 格式。
  至少需要支持 /v1/chat/completions。
  如果要自动获取模型列表，需要支持 /v1/models。
  如果启用 RAG/向量检索，需要支持 /v1/embeddings。

常用选项:
  --base-url URL              自定义 API Base URL，例如 https://api.example.com/v1
  --api-key KEY               自定义 API Key
  --models LIST               模型列表，逗号分隔；不填时会尝试自动获取并引导选择
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
  -h, --help                  显示帮助

环境变量:
  BT_AI_API_BASE_URL
  BT_AI_API_KEY
  BT_AI_MODELS
  BT_AI_EMBEDDING_BASE_URL
  BT_AI_EMBEDDING_API_KEY
  BT_AI_EMBEDDING_MODEL

示例:
  bash configure_bt_ai_openai_api.sh \
    --base-url https://api.example.com/v1 \
    --api-key sk-xxxx \
    --yes
EOF
}

log() {
  printf '[bt-ai-config] %s\n' "$*"
}

die() {
  printf '[bt-ai-config] 错误: %s\n' "$*" >&2
  exit 1
}

detect_linux() {
  local kernel
  kernel="$(uname -s 2>/dev/null || true)"
  if [[ "$kernel" != "Linux" ]]; then
    die "当前系统不是 Linux。本脚本只支持 CentOS/Ubuntu 等 Linux 服务器，不支持 Windows。"
  fi

  local id=""
  local name=""
  if [[ -r /etc/os-release ]]; then
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-}}")"
  fi

  case "$id" in
    centos|rhel|almalinux|rocky|ubuntu|debian)
      log "检测到系统: ${name:-$id}"
      ;;
    "")
      log "未检测到 /etc/os-release，将按通用 Linux 方式继续。"
      ;;
    *)
      log "检测到系统: ${name:-$id}。该发行版未专项验证，但会按通用 Linux 方式继续。"
      ;;
  esac
}

require_arg() {
  local opt="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$opt 缺少参数值"
}

mask_secret() {
  local value="${1:-}"
  local len=${#value}
  if [[ -z "$value" ]]; then
    printf ''
  elif [[ "$value" == "--" ]]; then
    printf -- '--'
  elif (( len <= 8 )); then
    printf '****'
  else
    printf '%s...%s' "${value:0:4}" "${value: -4}"
  fi
}

find_python3() {
  local candidate=""
  local candidates=()

  if command -v python3 >/dev/null 2>&1; then
    candidates+=("$(command -v python3)")
  fi
  candidates+=(
    "$PANEL_PATH/pyenv/bin/python3"
    "$PANEL_PATH/pyenv/bin/python"
  )

  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    "$candidate" - <<'PY' >/dev/null 2>&1 && {
import sys
raise SystemExit(0 if sys.version_info >= (3, 5) else 1)
PY
      printf '%s\n' "$candidate"
      return
    }
  done

  die "未找到 Python 3.5 或更高版本。请先安装 python3，或确认宝塔面板 pyenv 存在。"
}

normalize_base_url() {
  local url="$1"
  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  local raw="$url"
  local endpoint_check="${url%/}"
  case "$endpoint_check" in
    */chat/completions)
      url="${endpoint_check%/chat/completions}"
      ;;
    */completions)
      url="${endpoint_check%/completions}"
      ;;
  esac
  local v1_check="${url%/}"
  if [[ "$v1_check" == */v1 ]]; then
    url="$v1_check"
  else
    if [[ "$raw" == */ ]]; then
      url="${url}v1"
    else
      url="${url}/v1"
    fi
  fi
  printf '%s\n' "$url"
}

validate_base_url() {
  local py="$1"
  local url="$2"
  local label="$3"
  local err=""

  if ! err="$(VALIDATE_URL="$url" VALIDATE_LABEL="$label" "$py" - <<'PY'
import os
from urllib.parse import urlsplit

label = os.environ["VALIDATE_LABEL"]
value = os.environ["VALIDATE_URL"].strip()

if not value:
    print("{} 不能为空".format(label))
    raise SystemExit(1)

if any(ord(ch) < 32 for ch in value):
    print("{} 包含不可见控制字符，请重新输入".format(label))
    raise SystemExit(1)

if any(ch.isspace() for ch in value):
    print("{} 不能包含空格或换行: {!r}".format(label, value))
    raise SystemExit(1)

parsed = urlsplit(value)
if parsed.scheme not in ("http", "https") or not parsed.netloc:
    print("{} 必须是完整的 http(s) URL，例如 https://api.example.com/v1；当前值: {}".format(label, value))
    raise SystemExit(1)

if parsed.username is not None or parsed.password is not None:
    print("{} 不能在 URL 中包含用户名或密码".format(label))
    raise SystemExit(1)

if parsed.query or parsed.fragment:
    print("{} 不能包含查询参数或片段: {}".format(label, value))
    raise SystemExit(1)
PY
)"; then
    die "$err"
  fi
}

auto_select_models() {
  local py="$1"
  [[ -z "$MODELS" ]] || return 0

  log "未填写模型名，正在尝试从 ${BASE_URL}/models 自动获取模型列表。"

  local tmp
  local fetch_error=""
  tmp="$(mktemp -t bt-ai-models.XXXXXX)"
  if BASE_URL="$BASE_URL" API_KEY="$API_KEY" "$py" - <<'PY' >"$tmp" 2>&1; then
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

def parse_error_body(raw):
    text = raw.decode("utf-8", "replace").strip()
    if not text:
        return ""
    try:
        payload = json.loads(text)
    except Exception:
        return text[:500]

    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            parts = []
            message = error.get("message")
            code = error.get("code")
            error_type = error.get("type")
            if message:
                parts.append(str(message))
            if code:
                parts.append("code=" + str(code))
            if error_type:
                parts.append("type=" + str(error_type))
            if parts:
                return "; ".join(parts)
            return json.dumps(error, ensure_ascii=False)[:500]

        for key in ("message", "msg", "detail", "error_description"):
            if payload.get(key):
                return str(payload[key])[:500]
        return json.dumps(payload, ensure_ascii=False)[:500]

    return text[:500]

base_url = os.environ["BASE_URL"].rstrip("/")
api_key = os.environ["API_KEY"]
if any(ord(ch) < 32 for ch in api_key):
    print("ERROR: API Key 包含不可见控制字符，请重新输入")
    raise SystemExit(2)
request = urllib.request.Request(
    base_url + "/models",
    headers={
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
    },
)

class CurlTransportError(Exception):
    pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def decode_curl_output(output):
    marker = b"\nBT_AI_HTTP_STATUS:"
    if marker not in output:
        return output, "000"
    body, status_raw = output.rsplit(marker, 1)
    return body, status_raw.strip().decode("ascii", "replace")


def curl_config_escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')


def load_payload_with_curl():
    curl = shutil.which("curl")
    if not curl:
        return None

    url = base_url + "/models"
    command = [
        curl,
        "--disable",
        "--silent",
        "--show-error",
        "--connect-timeout",
        "10",
        "--max-time",
        "20",
        "--config",
        "-",
        "--write-out",
        "\nBT_AI_HTTP_STATUS:%{http_code}",
        url,
    ]
    request_config = (
        'header = "Authorization: Bearer {}"\n'.format(curl_config_escape(api_key))
        + 'header = "Accept: application/json"\n'
    ).encode("utf-8")

    result = subprocess.run(
        command,
        input=request_config,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    body, status = decode_curl_output(result.stdout)

    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise CurlTransportError("curl 请求失败" + (": " + detail[:500] if detail else ""))

    if not status.isdigit() or not 200 <= int(status) < 300:
        detail = parse_error_body(body)
        message = "HTTP " + status
        if detail:
            message += ": " + detail
        raise RuntimeError(message)

    return json.loads(body.decode("utf-8"))

def load_payload_with_urllib():
    opener = urllib.request.build_opener(NoRedirectHandler())
    with opener.open(request, timeout=20) as response:
        raw = response.read()
    return json.loads(raw.decode("utf-8"))


def load_payload():
    curl_error = ""
    try:
        curl_payload = load_payload_with_curl()
        if curl_payload is not None:
            return curl_payload
    except CurlTransportError as exc:
        curl_error = str(exc)

    try:
        return load_payload_with_urllib()
    except urllib.error.HTTPError:
        raise
    except urllib.error.URLError as exc:
        if curl_error:
            reason = str(getattr(exc, "reason", exc))
            raise RuntimeError("{}；Python 回退也失败: {}".format(curl_error, reason))
        raise

try:
    payload = load_payload()
except urllib.error.HTTPError as e:
    detail = parse_error_body(e.read())
    msg = "HTTP {}".format(e.code)
    if detail:
        msg += ": " + detail
    print("ERROR: " + msg)
    raise SystemExit(2)
except urllib.error.URLError as e:
    reason = str(getattr(e, "reason", e))
    if "unknown url type: https" in reason.lower():
        print("ERROR: 当前 Python 不支持 HTTPS，且系统未找到 curl；请安装 curl 后重试")
    else:
        print("ERROR: 网络连接失败: " + reason)
    raise SystemExit(2)
except json.JSONDecodeError:
    print("ERROR: /models 响应不是有效 JSON")
    raise SystemExit(2)
except Exception as e:
    print("ERROR: " + str(e))
    raise SystemExit(2)

items = payload.get("data", payload)
if not isinstance(items, list):
    print("ERROR: /models 响应中没有可识别的 data 模型列表")
    raise SystemExit(2)

models = []
for item in items:
    if isinstance(item, dict):
        model_id = item.get("id") or item.get("name") or item.get("model")
    else:
        model_id = str(item)
    if model_id and model_id not in models:
        models.append(model_id)

if not models:
    print("ERROR: /models 返回的模型列表为空")
    raise SystemExit(2)

for model in models:
    print(model)
PY
    mapfile -t available_models <"$tmp"
  else
    available_models=()
    fetch_error="$(sed -n 's/^ERROR: //p' "$tmp" | head -n 1)"
    if [[ -z "$fetch_error" ]]; then
      fetch_error="$(tr '\n' ' ' <"$tmp" | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c 1-240)"
    fi
  fi
  rm -f "$tmp"

  if [[ "${#available_models[@]}" -eq 0 ]]; then
    if [[ -n "$fetch_error" ]]; then
      log "自动获取模型失败: $fetch_error"
    fi
    log "未能自动获取模型列表。请确认 API 提供商是否支持 OpenAI 格式的 /v1/models，并检查 API Key 是否正确。"
    if [[ "$YES" -eq 1 ]]; then
      die "非交互模式未提供 --models，且自动获取模型失败"
    fi
    prompt_if_empty MODELS "请输入模型名，多个用逗号分隔，例如 gpt-4o-mini,deepseek-chat"
    return 0
  fi

  if [[ "${#available_models[@]}" -eq 1 ]]; then
    MODELS="${available_models[0]}"
    log "已自动选择唯一模型: $MODELS"
    return 0
  fi

  if [[ "$YES" -eq 1 ]]; then
    MODELS="${available_models[0]}"
    log "非交互模式下已自动选择第一个模型: $MODELS"
    return 0
  fi

  printf '\n可用模型列表:\n' >&2
  local idx
  for idx in "${!available_models[@]}"; do
    printf '  %d) %s\n' "$((idx + 1))" "${available_models[$idx]}" >&2
  done
  printf '请选择模型编号，或直接输入模型名；留空默认选择 1\n> ' >&2

  local answer
  IFS= read -r answer
  if [[ -z "$answer" ]]; then
    MODELS="${available_models[0]}"
  elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#available_models[@]} )); then
    MODELS="${available_models[$((answer - 1))]}"
  else
    MODELS="$answer"
  fi
  log "已选择模型: $MODELS"
}

prompt_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local value="${!var_name:-}"

  if [[ -n "$value" ]]; then
    return
  fi

  if [[ "$YES" -eq 1 ]]; then
    [[ -n "$default_value" ]] || die "非交互模式缺少必要参数: $var_name"
    printf -v "$var_name" '%s' "$default_value"
    return
  fi

  local prompt_text="$prompt"
  if [[ -n "$default_value" ]]; then
    prompt_text="$prompt [$default_value]"
  fi

  while true; do
    if [[ "$secret" -eq 1 ]]; then
      printf '%s\n> ' "$prompt_text" >&2
      IFS= read -r -s value
      printf '\n' >&2
    else
      printf '%s\n> ' "$prompt_text" >&2
      IFS= read -r value
    fi

    if [[ -z "$value" && -n "$default_value" ]]; then
      value="$default_value"
    fi

    if [[ -n "$value" ]]; then
      break
    fi

    log "$var_name 不能为空，请重新输入。"
  done

  printf -v "$var_name" '%s' "$value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url)
        require_arg "$1" "${2:-}"
        BASE_URL="${2:-}"; shift 2 ;;
      --api-key)
        require_arg "$1" "${2:-}"
        API_KEY="${2:-}"; shift 2 ;;
      --models)
        require_arg "$1" "${2:-}"
        MODELS="${2:-}"; shift 2 ;;
      --embedding-base-url)
        require_arg "$1" "${2:-}"
        EMBEDDING_BASE_URL="${2:-}"; shift 2 ;;
      --embedding-api-key)
        require_arg "$1" "${2:-}"
        EMBEDDING_API_KEY="${2:-}"; shift 2 ;;
      --embedding-model)
        require_arg "$1" "${2:-}"
        EMBEDDING_MODEL="${2:-}"; shift 2 ;;
      --panel-path)
        require_arg "$1" "${2:-}"
        PANEL_PATH="${2:-}"; shift 2 ;;
      --config)
        require_arg "$1" "${2:-}"
        CONFIG_PATH="${2:-}"; shift 2 ;;
      --restore)
        require_arg "$1" "${2:-}"
        RESTORE_BACKUP="${2:-}"; shift 2 ;;
      --yes|-y)
        YES=1; shift ;;
      --no-restart)
        NO_RESTART=1; shift ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      --show)
        SHOW_CONFIG=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      --version)
        printf '%s\n' "$VERSION"; exit 0 ;;
      *)
        die "未知参数: $1" ;;
    esac
  done
}

ensure_paths() {
  PANEL_PATH="${PANEL_PATH%/}"
  if [[ -z "$CONFIG_PATH" ]]; then
    CONFIG_PATH="$PANEL_PATH/data/agent/config.json"
  fi
  CONFIG_DIR="$(dirname "$CONFIG_PATH")"
}

show_config() {
  local py="$1"
  CONFIG_PATH="$CONFIG_PATH" PANEL_PATH="$PANEL_PATH" "$py" - <<'PY'
import json
import os
import re

path = os.environ["CONFIG_PATH"]
panel_path = os.environ["PANEL_PATH"].rstrip("/")
print("config_path:", path)
if not os.path.exists(path):
    print("status: config file does not exist; panel is using built-in defaults")
    raise SystemExit(0)

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

def mask(value):
    if not value:
        return ""
    if value == "--":
        return "--"
    return value[:4] + "..." + value[-4:] if len(value) > 8 else "****"

summary = {
    "api_base_url": data.get("api_base_url", ""),
    "api_key": mask(data.get("api_key", "")),
    "models": data.get("models", []),
    "embedding": {
        "embedding_base_url": data.get("embedding", {}).get("embedding_base_url", ""),
        "embedding_api_key": mask(data.get("embedding", {}).get("embedding_api_key", "")),
        "embedding_model_name": data.get("embedding", {}).get("embedding_model_name", ""),
    },
}

model = (data.get("models") or [""])[0]
template_overrides = []
for rel_root in ("mod/project/agent/prompts", "mod/project/agent/skill_agents"):
    root = os.path.join(panel_path, rel_root)
    if not os.path.isdir(root):
        continue
    for name in sorted(os.listdir(root)):
        if not name.endswith((".md", ".txt")):
            continue
        file_path = os.path.join(root, name)
        try:
            text = open(file_path, "r", encoding="utf-8").read()
        except Exception:
            continue
        if not text.startswith("---"):
            continue
        match = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.S)
        if not match:
            continue
        frontmatter = match.group(1)
        reasons = []
        if re.search(r"^\s*base_url\s*:", frontmatter, re.M):
            reasons.append("base_url")
        if re.search(r"^\s*api_key\s*:", frontmatter, re.M):
            reasons.append("api_key")
        model_match = re.search(r"^\s*model_name\s*:\s*(.+?)\s*$", frontmatter, re.M)
        if model and model_match:
            current_model = model_match.group(1).strip().strip("\"'")
            if current_model != model:
                reasons.append("model_name:" + current_model)
        if reasons:
            template_overrides.append({
                "path": file_path,
                "reasons": reasons,
            })

summary["template_overrides"] = template_overrides
print(json.dumps(summary, ensure_ascii=False, indent=2))
PY
}

restore_config() {
  [[ -n "$RESTORE_BACKUP" ]] || return 0
  [[ -f "$RESTORE_BACKUP" ]] || die "备份文件不存在: $RESTORE_BACKUP"
  mkdir -p "$CONFIG_DIR"
  cp -a "$RESTORE_BACKUP" "$CONFIG_PATH"
  chmod 600 "$CONFIG_PATH" 2>/dev/null || true
  log "已恢复配置: $RESTORE_BACKUP -> $CONFIG_PATH"
  restart_panel
  exit 0
}

confirm_write() {
  log "将写入宝塔 AI 配置:"
  log "  config: $CONFIG_PATH"
  log "  api_base_url: $BASE_URL"
  log "  api_key: $(mask_secret "$API_KEY")"
  log "  models: $MODELS"
  log "  embedding_base_url: $EMBEDDING_BASE_URL"
  log "  embedding_api_key: $(mask_secret "$EMBEDDING_API_KEY")"
  log "  embedding_model: $EMBEDDING_MODEL"

  if [[ "$YES" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  printf '确认写入以上配置吗？[y/N]\n> ' >&2
  local answer
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) die "已取消" ;;
  esac
}

write_config() {
  local py="$1"
  local backup_path=""

  mkdir -p "$CONFIG_DIR"
  if [[ -f "$CONFIG_PATH" ]]; then
    backup_path="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_PATH" "$backup_path"
    log "已备份原配置: $backup_path"
  fi

  CONFIG_PATH="$CONFIG_PATH" \
  PANEL_PATH="$PANEL_PATH" \
  BASE_URL="$BASE_URL" \
  API_KEY="$API_KEY" \
  MODELS="$MODELS" \
  EMBEDDING_BASE_URL="$EMBEDDING_BASE_URL" \
  EMBEDDING_API_KEY="$EMBEDDING_API_KEY" \
  EMBEDDING_MODEL="$EMBEDDING_MODEL" \
  DRY_RUN="$DRY_RUN" \
  "$py" - <<'PY'
import json
import os
import re
import shutil
import sys
import time
from urllib.parse import urlsplit

path = os.environ["CONFIG_PATH"]
panel_path = os.environ["PANEL_PATH"].rstrip("/")
base_url = os.environ["BASE_URL"].strip()
api_key = os.environ["API_KEY"].strip()
models_raw = os.environ["MODELS"].strip()
embedding_base_url = os.environ["EMBEDDING_BASE_URL"].strip()
embedding_api_key = os.environ["EMBEDDING_API_KEY"].strip()
embedding_model = os.environ["EMBEDDING_MODEL"].strip()
dry_run = os.environ.get("DRY_RUN") == "1"

def has_control_chars(value):
    return any(ord(ch) < 32 for ch in value)

def validate_http_url(name, value):
    value = value.strip()
    if not value:
        raise SystemExit("missing {}".format(name))
    if has_control_chars(value):
        raise SystemExit("{} contains invisible control characters; please re-enter it".format(name))
    if any(ch.isspace() for ch in value):
        raise SystemExit("{} contains whitespace; please re-enter it".format(name))

    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise SystemExit(
            "{} must be a full http(s) URL such as https://api.example.com/v1; got: {}".format(name, value)
        )
    if parsed.username is not None or parsed.password is not None:
        raise SystemExit("{} must not contain username or password in the URL".format(name))
    if parsed.query or parsed.fragment:
        raise SystemExit("{} must not contain query string or fragment; got: {}".format(name, value))
    return value

def yaml_scalar(value):
    return json.dumps(value, ensure_ascii=False)

def collect_template_changes(panel_path, model):
    roots = [
        os.path.join(panel_path, "mod/project/agent/prompts"),
        os.path.join(panel_path, "mod/project/agent/skill_agents"),
    ]
    changes = []

    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            if not name.endswith((".md", ".txt")):
                continue
            file_path = os.path.join(root, name)
            try:
                with open(file_path, "r", encoding="utf-8") as f:
                    text = f.read()
            except Exception:
                continue
            if not text.startswith("---"):
                continue

            match = re.match(r"^(---\s*\n)(.*?)(\n---\s*\n)(.*)$", text, re.S)
            if not match:
                continue

            head, frontmatter, sep, body = match.groups()
            lines = []
            reasons = []
            touched = False
            for line in frontmatter.splitlines():
                if re.match(r"^\s*base_url\s*:", line):
                    reasons.append("remove base_url")
                    touched = True
                    continue
                if re.match(r"^\s*api_key\s*:", line):
                    reasons.append("remove api_key")
                    touched = True
                    continue
                if re.match(r"^\s*model_name\s*:", line):
                    new_line = "model_name: {}".format(yaml_scalar(model))
                    lines.append(new_line)
                    if line.strip() != new_line:
                        reasons.append("set model_name")
                        touched = True
                    continue
                lines.append(line)

            if not touched:
                continue

            changes.append({
                "path": file_path,
                "content": head + "\n".join(lines) + sep + body,
                "reasons": reasons,
            })

    return changes

if not base_url:
    raise SystemExit("missing base_url")
if not api_key:
    raise SystemExit("missing api_key")
base_url = validate_http_url("base_url", base_url)
if has_control_chars(api_key):
    raise SystemExit("api_key contains invisible control characters; please re-enter it")
if "bt.cn" in base_url:
    raise SystemExit("base_url contains bt.cn; this script is for custom APIs")

effective_embedding_base_url = validate_http_url(
    "embedding_base_url",
    embedding_base_url or base_url,
)

models = [item.strip() for item in models_raw.split(",") if item.strip()]
if not models:
    raise SystemExit("missing models")

if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        try:
            config = json.load(f)
        except Exception:
            config = {}
else:
    config = {}

if not isinstance(config, dict):
    config = {}

embedding = config.get("embedding")
if not isinstance(embedding, dict):
    embedding = {}

config["api_base_url"] = base_url
config["api_key"] = api_key
config["models"] = models

embedding["embedding_base_url"] = effective_embedding_base_url
if (not embedding_api_key) or has_control_chars(embedding_api_key):
    embedding_api_key = api_key
embedding["embedding_api_key"] = embedding_api_key
embedding["embedding_model_name"] = embedding_model or "text-embedding-3-small"
config["embedding"] = embedding

if "model_config" not in config or not isinstance(config["model_config"], dict):
    config["model_config"] = {}

for model in models:
    config["model_config"].setdefault(model, {})

template_changes = collect_template_changes(panel_path, models[0])

if dry_run:
    safe = json.loads(json.dumps(config, ensure_ascii=False))
    if safe.get("api_key"):
        safe["api_key"] = "<redacted>"
    if safe.get("embedding", {}).get("embedding_api_key"):
        safe["embedding"]["embedding_api_key"] = "<redacted>"
    print(json.dumps(safe, ensure_ascii=False, indent=2))
    print("template_overrides_to_patch:", len(template_changes))
    for item in template_changes:
        print("template_override:", item["path"], "|", ", ".join(item["reasons"]))
    raise SystemExit(0)

tmp_path = path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=4)
    f.write("\n")
os.replace(tmp_path, path)
print("saved:", path)

def patch_template_overrides():
    timestamp = time.strftime("%Y%m%d-%H%M%S")
    changed = []

    for item in template_changes:
        file_path = item["path"]
        backup_path = file_path + ".bak." + timestamp
        shutil.copy2(file_path, backup_path)
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(item["content"])
        changed.append((file_path, item["reasons"]))

    return changed

patched = patch_template_overrides()
print("patched_template_count:", len(patched))
for file_path, reasons in patched:
    print("patched_template:", file_path, "|", ", ".join(reasons))
PY

  if [[ "$DRY_RUN" -eq 0 ]]; then
    chmod 600 "$CONFIG_PATH" 2>/dev/null || true
  fi
}

restart_panel() {
  if [[ "$NO_RESTART" -eq 1 ]]; then
    log "已跳过重启宝塔面板。需要手动重启后新配置才会稳定生效。"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  if command -v bt >/dev/null 2>&1; then
    log "正在重启宝塔面板: bt restart"
    bt restart || log "bt restart 执行失败，请手动重启面板"
    return
  fi

  if [[ -x /etc/init.d/bt ]]; then
    log "正在重启宝塔面板: /etc/init.d/bt restart"
    /etc/init.d/bt restart || log "/etc/init.d/bt restart 执行失败，请手动重启面板"
    return
  fi

  log "未找到 bt 命令，请手动重启宝塔面板。"
}

main() {
  parse_args "$@"
  detect_linux
  ensure_paths
  local py
  py="$(find_python3)"

  if [[ "$SHOW_CONFIG" -eq 1 ]]; then
    show_config "$py"
    exit 0
  fi

  restore_config

  cat <<'EOF'
重要提示:
  你配置的 API 提供商必须兼容 OpenAI API 格式。
  至少需要支持 /v1/chat/completions。
  如果要在面板中点击“获取模型列表”，还需要支持 /v1/models。
  如果要使用 RAG/向量检索，还需要支持 /v1/embeddings。
EOF

  prompt_if_empty BASE_URL "请输入 API Base URL，例如 https://api.example.com/v1"
  BASE_URL="$(normalize_base_url "$BASE_URL")"
  validate_base_url "$py" "$BASE_URL" "API Base URL"
  log "规范化后的 API Base URL: $BASE_URL"
  prompt_if_empty API_KEY "请输入 API Key" "" 1
  auto_select_models "$py"
  prompt_if_empty EMBEDDING_BASE_URL "请输入 Embedding Base URL，留空则使用 API Base URL" "$BASE_URL"
  EMBEDDING_BASE_URL="$(normalize_base_url "$EMBEDDING_BASE_URL")"
  validate_base_url "$py" "$EMBEDDING_BASE_URL" "Embedding Base URL"
  log "规范化后的 Embedding Base URL: $EMBEDDING_BASE_URL"
  prompt_if_empty EMBEDDING_API_KEY "请输入 Embedding API Key，留空则使用 API Key" "$API_KEY" 1
  prompt_if_empty EMBEDDING_MODEL "请输入 Embedding 模型名" "text-embedding-3-small"

  confirm_write
  write_config "$py"
  restart_panel

  if [[ "$DRY_RUN" -eq 0 ]]; then
    log "完成。请打开宝塔 AI 页面测试聊天是否已走自定义接口。"
  fi
}

main "$@"
