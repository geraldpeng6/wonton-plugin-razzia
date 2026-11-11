# shellcheck shell=bash
# Razzia：sso=none，玩家不用账号，主持界面靠口令解锁（口令是核心生成的密钥，注入容器环境）。
# 玩家会话、游戏状态都走 WebSocket；这里用 /api 验证应用自己的登录和数据。

web_assert() { grep -q '<title>Razzia</title>'; }   # 应用页面（SPA 的 index.html）标题

_razzia_container() { # 本实例里 razzia 服务的容器：按核心打的标签找，插件自带 smoke 和 e2e 套件都成立
  local inst="${SMOKE_INSTANCE:-}" args=(--filter "label=wonton.plugin=$SMOKE_PLUGIN_ID" --filter "label=wonton.service=razzia")
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

_razzia_node() { # <node 脚本>：容器里用自带的 node 调 127.0.0.1:3000 的 API；清掉代理变量，回环不经 egress
  local script="$1"; shift
  docker exec -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= \
    -e ALL_PROXY= -e all_proxy= -e NO_PROXY=127.0.0.1,localhost -e no_proxy=127.0.0.1,localhost \
    "$@" "$(_razzia_container)" node -e "$script"
}

_razzia_manager_token() { # 打印主持会话令牌：口令解锁（应用自己的登录），失败输出原因并退出非 0
  # 核心生成的口令经 compose 插值进容器的 MANAGER_PASSWORD（WONTON_SECRET_* 只用于插值，不进容器环境）。
  _razzia_node '
    const post = (p, body, token) => fetch("http://127.0.0.1:3000" + p, { method: "POST",
      headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}) },
      body: JSON.stringify(body) });
    (async () => {
      const s = await (await post("/api/auth/session", {})).json();
      const m = await (await post("/api/auth/manager", { password: process.env.RAZZIA_PW }, s.token)).json();
      if (m.role !== "manager") throw new Error("口令没解锁成 manager：" + JSON.stringify(m));
      console.log(m.token);
    })().catch(e => { console.error(e.message); process.exit(1); });
  ' -e RAZZIA_PW="$(docker exec "$(_razzia_container)" printenv MANAGER_PASSWORD)"
}

identity_check() { # 应用自己的登录：主持口令能换到 manager 会话
  local token
  token="$(_razzia_manager_token)" || { echo "主持登录失败：$token"; return 1; }
  [[ -n "$token" ]] || { echo "主持登录返回空令牌"; return 1; }
  echo "主持口令解锁成功，拿到 manager 会话令牌"
}

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/razzia-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

data_write() { # 经应用的 API 建一套题，subject 是随机标记
  local container marker token out
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  container="$(_razzia_container)"
  [[ -n "$container" ]] || { echo "找不到 razzia 容器（wonton.plugin 标签）"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  token="$(_razzia_manager_token)" || { echo "主持登录失败：$token"; return 1; }
  out="$(_razzia_node "
    (async () => {
      const r = await fetch('http://127.0.0.1:3000/api/quizz', { method: 'POST',
        headers: { 'content-type': 'application/json', authorization: 'Bearer ' + process.env.RAZZIA_TOKEN },
        body: JSON.stringify({ subject: process.env.RAZZIA_MARKER, gameMode: 'quiz',
          questions: [{ type: 'single', question: '冒烟测试标记题？', answers: ['是', '否', '否', '否'], solutions: [0], cooldown: 3, time: 5 }] }) });
      if (r.status !== 201) { console.error('建题失败：HTTP ' + r.status + ' ' + await r.text()); process.exit(1); }
      console.log('quiz ' + (await r.json()).id + ' 已建');
    })().catch(e => { console.error(e.message); process.exit(1); });
  " -e RAZZIA_TOKEN="$token" -e RAZZIA_MARKER="$marker")" || { echo "写数据失败：$out"; return 1; }
  echo "$out"
  printf '%s' "$marker" >"$(marker_file)"
}

data_check() { # 题库列表里要能找到标记
  local marker token out
  marker="$(cat "$(marker_file)" 2>/dev/null)" || { echo "没有 data_write 留下的标记"; return 1; }
  [[ -n "$marker" ]] || { echo "标记是空的"; return 1; }
  token="$(_razzia_manager_token)" || { echo "主持登录失败：$token"; return 1; }
  out="$(_razzia_node "
    (async () => {
      const r = await fetch('http://127.0.0.1:3000/api/quizz', { headers: { authorization: 'Bearer ' + process.env.RAZZIA_TOKEN } });
      if (r.status !== 200) { console.error('题库列表失败：HTTP ' + r.status + ' ' + await r.text()); process.exit(1); }
      const q = await r.json();
      const hit = (q.quizz || []).find(x => x.subject === process.env.RAZZIA_MARKER);
      console.error('题库现有 ' + (q.quizz || []).length + ' 套：' + (q.quizz || []).map(x => x.subject).join('、'));
      if (!hit) { console.error('找不到标记 ' + process.env.RAZZIA_MARKER); process.exit(1); }
      console.log('标记题还在：' + hit.subject + '（id ' + hit.id + '）');
    })().catch(e => { console.error(e.message); process.exit(1); });
  " -e RAZZIA_TOKEN="$token" -e RAZZIA_MARKER="$marker")" || { echo "data_check 失败：$out"; return 1; }
  echo "$out"
}
