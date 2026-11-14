# 虚现互通协议 v1（Virtual-Real Bridge Protocol）

> 「虚现互通」= 虚拟身体（App 里的角色）与现实 QQ 账号之间的双向通道。
> 触摸 App → QQ 收到反应；QQ 说话 → App 角色开口。
> 本文件是**唯一接口契约**，插件、Web App、iOS App 三方都必须严格遵守。

## 0. 部署形态

```
iOS App / PWA ──HTTPS──> nginx(samachat.de5.net/pet/) ──> 127.0.0.1:8899 ──> socat 容器 ──> astrbot 容器:8899（插件内嵌 aiohttp 服务）
                                                                                          ↑ 同进程
                                                                                     AstrBot / LLM / NapCat → QQ
```

- 服务端由 AstrBot 插件 `astrbot_plugin_virtual_body` 内嵌 aiohttp 提供（HTTP + WebSocket + 静态前端）。
- 对外基址（生产）：`https://samachat.de5.net/pet/`
- 对外基址（调试）：`http://<server-ip>:8899/`
- 所有接口路径均为基址下的相对路径，例如 `POST /api/touch` → `https://samachat.de5.net/pet/api/touch`。

## 1. 鉴权：先进门，绑定 QQ

角色**只属于一个 QQ 号**（房主）。进 App 前必须完成绑定。

1. 用户在 QQ（私聊机器人或群里 @机器人）发送：`虚现 绑定码`
2. 机器人回复 6 位数字码，10 分钟内有效，一次一码。
3. App 调 `POST /api/bind` 提交 `{code, device, platform}`。
4. 成功后返回 `token`（32 位 hex，长期有效，可被房主在 QQ 里 `虚现 解绑` 作废）。

- 带 `Authorization: Bearer <token>` 头（或 WebSocket `?token=`）才能访问除 `/api/hello`、`/api/bind` 外的所有接口。
- 401 返回 `{"ok":false,"error":"unbound","message":"请先在 QQ 里发送「虚现 绑定码」"}`。

## 2. 统一响应信封

```json
{ "ok": true, "data": { ... } }
{ "ok": false, "error": "bad_code", "message": "绑定码错误或已过期" }
```

## 3. 角色状态对象 Character

```json
{
  "id": "vb1",
  "name": "小虚",
  "owner_qq": "10001",
  "level": 3,
  "exp": 120,
  "exp_next": 300,
  "stats": {
    "affection": 62,     // 亲密度 0-100（长期不互动会衰减）
    "mood": 80,          // 心情 0-100
    "energy": 70,        // 精力 0-100（散步/玩耍掉，睡觉回）
    "satiety": 55,       // 饱食 0-100
    "clean": 90,         // 清洁 0-100
    "trust": 45          // 信任度 0-100（只在私聊里讨论过心事才涨）
  },
  "emotion": "happy",            // happy|calm|shy|sad|angry|sleepy|hungry|excited|love|bored
  "action": "idle",             // idle|walk|jump|sit|sleep|eat|wave|hug|spin|shake|dance|think|panic
  "pose": { "x": 0.5, "y": 0.62, "facing": 1, "scale": 1.0 },   // x/y 为 0-1 归一化坐标（画布相对）
  "outfit": "default",          // default|pajamas|sport|raincoat|hamster
  "room": "day",                // day|night|rain|party|beach
  "bubble": "你回来啦～",         // 当前气泡文字（可为 ""）
  "muted": false,               // 静音（只影响 App 语音/音效）
  "counters": { "pets": 12, "pokes": 3, "feeds": 5, "chats": 40, "touches": 88 },
  "last_active": 1763100000,
  "created_at": 1763000000,
  "updated_at": 1763100000
}
```

## 4. REST 接口

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/api/hello` | 否 | 服务探测 |
| POST | `/api/bind` | 否 | 用绑定码换 token |
| GET | `/api/state` | 是 | 全量快照 `{character, events, bound, muted, server_time}` |
| POST | `/api/touch` | 是 | 触摸事件（核心） |
| POST | `/api/action` | 是 | App 侧意图（让角色做事） |
| POST | `/api/chat` | 是 | App 内聊天（等价于对角色说话） |
| GET | `/api/events?since=<id>` | 是 | 增量事件（WebSocket 不可用时的降级轮询） |
| POST | `/api/device` | 是 | 上报设备信息/心跳 `{device, platform, app_version, muted}` |
| POST | `/api/unbind` | 是 | App 主动解绑（作废 token） |

### 4.1 `GET /api/hello`

```json
{ "ok": true, "data": {
  "service": "virtual-body", "version": "1.0.0",
  "bound": false, "server_time": 1763100000,
  "features": ["ws", "sse", "speech_bubble", "voice_hint"]
} }
```

### 4.2 `POST /api/bind`

请求：`{ "code": "482913", "device": "iPhone 15", "platform": "ios", "app_version": "1.0.0" }`

成功：

```json
{ "ok": true, "data": {
  "token": "9f3c...8a2b",
  "qq": "10001",
  "nickname": "阿蓝",
  "character": { ...Character... }
} }
```

失败：`bad_code` / `expired` / `rate_limited`。

### 4.3 `POST /api/touch` —— 虚→实 的第一条腿

请求：

```json
{
  "type": "pet",          // pet|poke|tap|hug|tickle|drag|feed|slap|kiss|rub|toss
  "x": 0.52, "y": 0.30,   // 归一化触点（0-1，画布左上为原点）
  "region": "head",       // head|face|body|hand|foot|unknown
  "power": 0.6,           // 力度 0-1（长按/拖拽速度换算）
  "item": "草莓",          // 仅 type=feed 时有效，可为空
  "ts": 1763100000.123    // 客户端时间戳（秒，可带小数）
}
```

响应（同时会通过 WebSocket 推给所有已绑定的设备）：

```json
{ "ok": true, "data": {
  "reaction": {
    "text": "唔…别挠那里啦！",     // 角色要说的话（气泡 + TTS）
    "emotion": "shy",
    "action": "shake",
    "effect": "hearts",           // hearts|stars|sparkle|sweat|zzz|anger|none
    "speech": true,               // 是否让 App 读出来
    "dur": 1200                   // 动作时长 ms
  },
  "delta": { "affection": 1, "mood": 2, "energy": -1, "satiety": 0, "clean": 0, "trust": 0 },
  "character": { ...Character... },   // 更新后的完整状态
  "qq_sent": true                       // 是否已把这次触摸播报到了 QQ
} }
```

### 4.4 `POST /api/action`

```json
{ "action": "say|walk|jump|sit|sleep|wake|eat|dance|wave|follow|home|dress|rename|mute|room|play",
  "args": { "text": "晚安", "x": 0.3, "y": 0.5, "outfit": "pajamas", "name": "小虚", "room": "night", "on": true } }
```

响应：`{ "ok": true, "data": { "reaction": {...}, "character": {...} } }`

### 4.5 `POST /api/chat`

```json
{ "text": "今天有点累", "voice": false }
```

响应：`{ "ok": true, "data": { "reply": "那就靠着我休息一会儿吧。", "reaction": {...}, "character": {...}, "qq_sent": true } }`

> 规则：App 内说的话会**镜像到 QQ**（默认开启），QQ 里说的话也会**镜像到 App**。这就是互通。

### 4.6 `GET /api/events?since=<id>`

```json
{ "ok": true, "data": { "events": [ { "id": 41, "at": 1763100000, "kind": "say", "payload": {...} } ], "last_id": 41 } }
```

事件 `kind`：`say` `touch` `qq` `action` `state` `notice` `gift` `levelup`。

## 5. WebSocket `/ws?token=<token>`

- 连接后立刻下发 `hello`（含完整 state 与 `events` 最近 20 条），客户端应回 `pong`。
- 心跳：服务端每 25s 发 `{"t":"ping"}`，客户端 60s 内无任何帧视为断开重连（指数退避，1s→30s）。

### 5.1 服务端 → 客户端

```json
{"t":"hello",  "state":{...}, "events":[...], "server_time":1763100000}
{"t":"state",  "character":{...}, "patch":{"stats":{"mood":82}}}
{"t":"say",    "id":41, "text":"你回来啦～", "emotion":"happy", "action":"wave", "effect":"sparkle", "speech":true, "dur":1100, "source":"qq"}
{"t":"anim",   "id":42, "action":"jump", "emotion":"excited", "dur":900, "source":"app"}
{"t":"effect", "id":43, "name":"hearts", "x":0.52, "y":0.30}
{"t":"qq",     "id":44, "from":"owner", "nickname":"阿蓝", "text":"在吗", "say":"在的呀", "at":1763100000}
{"t":"notice", "id":45, "level":"info", "text":"QQ 已接通"}
{"t":"pong",   "ts":1763100000.5}
{"t":"ping",   "ts":1763100000.5}
```

### 5.2 客户端 → 服务端

```json
{"t":"touch",  "type":"pet", "x":0.5, "y":0.3, "region":"head", "power":0.6}
{"t":"action", "action":"say", "args":{"text":"你好"}}
{"t":"chat",   "text":"在干嘛"}
{"t":"device", "device":"iPhone 15", "platform":"ios", "muted":false}
{"t":"pong",   "ts":1763100000.5}
{"t":"ping"}
```

## 6. QQ 指令面（房主可用，私聊/群聊均可）

```
虚现 绑定码              生成 6 位 App 绑定码（10 分钟）
虚现 状态                状态卡（等级/心情/亲密/饱食/精力…）
虚现 名字 <新名字>        改名
虚现 换装 <装扮>          装扮：default/pajamas/sport/raincoat/hamster
虚现 场景 <场景>          场景：day/night/rain/party/beach
虚现 来 / 虚现 过去        呼叫角色到 App 里走到屏幕中间
虚现 摸头 / 抱抱 / 戳戳     代替手指去触摸（同样触发反应）
虚现 喂 <食物>            喂食
虚现 睡觉 / 虚现 起床
虚现 玩 / 散步 / 跳舞 / 打滚
虚现 说 <内容>            让角色在 App 里说出这句话
虚现 做 <动作>            让 App 播动作：jump/wave/spin/dance/hug/panic
虚现 表情 <表情>
虚现 静音 / 开声
虚现 解绑                 作废所有 App token
虚现 重置                 角色回到出厂状态（二次确认）
虚现 帮助
```

此外：**任何普通聊天消息**（不以上述前缀开头）→ 角色在 App 里开口说出回复。默认仅房主（owner_qq）触发，可通过配置放开到白名单。

## 7. 兼容与降级

- 无 WebSocket 时：客户端每 3s `GET /api/events?since=` 轮询。
- LLM 不可用时：使用内置规则台词库（每种 emotion/touch 若干句），接口结构不变。
- 无语音合成：`speech:true` 的帧静默丢弃（气泡照常显示）。
