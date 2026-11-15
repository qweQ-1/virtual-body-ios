/* app.js —— 虚拟身体前端主逻辑
 *
 * 三件事：
 *   1. 进去前绑定 QQ（门禁页）；
 *   2. 用手真的能"摸到"它 —— 手势分类成触摸事件发给服务端，反应再推回来；
 *   3. 双向互通事件流：App 触摸↔QQ 播报、QQ 说话↔角色在 App 里开口。
 */

// 角色绘制来自 creature.js（普通脚本，通过 window.VBCreature 暴露）。
// 注意：不要改回 ES module —— WKWebView 从 file:// 加载时会拦掉 module，导致本文件根本不执行。
// creature.js 是以普通脚本加载的，它的 drawCreature / drawMiniCreature 本身就在全局作用域，
// 这里**不能**再声明同名的变量（会报 "duplicate variable shadowing a global property"）。


/* ============================================================ 配置与存储 */

const CFG = window.VB_CONFIG || {};
const IS_NATIVE = !!CFG.native;
const LS = {
  server: "vb.server", token: "vb.token", qq: "vb.qq", nick: "vb.nick",
  speak: "vb.speak", haptic: "vb.haptic", device: "vb.device",
};

const $ = (id) => document.getElementById(id);
const store = {
  get: (k, d = "") => { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* 隐私模式忽略 */ } },
  del: (k) => { try { localStorage.removeItem(k); } catch { } },
};

function guessServerBase() {
  if (CFG.server) return String(CFG.server).replace(/\/+$/, "");
  const saved = store.get(LS.server);
  if (saved) return String(saved).replace(/\/+$/, "");
  if (location.protocol.startsWith("http")) {
    return (location.origin + location.pathname)
      .replace(/index\.html$/, "")
      .replace(/\/+$/, "");
  }
  return "";
}

const state = {
  base: guessServerBase(),
  token: CFG.token || store.get(LS.token),
  qq: store.get(LS.qq),
  nick: store.get(LS.nick),
  device: store.get(LS.device) || (IS_NATIVE ? "iPhone" : "Safari"),
  char: null,
  muted: false,
  lastId: 0,
  ws: null,
  wsOk: false,
  wsTries: 0,
  polling: false,
  demo: false,
  speak: store.get(LS.speak, "1") === "1",
  haptic: store.get(LS.haptic, "1") === "1",
  dragging: false,
};

/* ============================================================ 原生桥 */

function native(cmd) {
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vb) {
      window.webkit.messageHandlers.vb.postMessage(cmd);
      return true;
    }
  } catch { }
  return false;
}
function haptic(style = "light") {
  if (!state.haptic) return;
  if (native({ cmd: "haptic", style })) return;
  try { navigator.vibrate && navigator.vibrate(style === "heavy" ? 28 : 12); } catch { }
}
function say(text) {
  if (!state.speak || !text) return;
  if (native({ cmd: "speak", text, lang: "zh-CN" })) return;
  try {
    if (!window.speechSynthesis) return;
    const u = new SpeechSynthesisUtterance(text.replace(/（[^）]*）/g, ""));
    u.lang = "zh-CN"; u.rate = 1.05; u.pitch = 1.25;
    speechSynthesis.cancel(); speechSynthesis.speak(u);
  } catch { }
}
function nativeStatus(text, level = "ok") {
  const conn = $("conn");
  if (conn) { conn.className = "conn conn-" + (level === "ok" ? "on" : level === "warn" ? "mid" : "off"); }
  native({ cmd: "status", text, level });
}

/* ============================================================ 网络层 */

class ApiError extends Error {
  constructor(code, message) { super(message || code); this.code = code; }
}

async function api(path, { method = "GET", body = null, auth = true, timeout = 15000 } = {}) {
  if (!state.base) throw new ApiError("no_base", "还没设置服务器地址");
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout);
  try {
    const res = await fetch(state.base + path, {
      method,
      headers: Object.assign(
        { "Content-Type": "application/json" },
        auth && state.token ? { Authorization: "Bearer " + state.token } : {},
      ),
      body: body ? JSON.stringify(body) : undefined,
      signal: ctl.signal,
    });
    let data = null;
    try { data = await res.json(); } catch { }
    if (!res.ok || !data || data.ok === false) {
      throw new ApiError((data && data.error) || "http_" + res.status,
        (data && data.message) || ("请求失败：" + res.status));
    }
    return data.data;
  } catch (e) {
    if (e instanceof ApiError) throw e;
    if (e.name === "AbortError") throw new ApiError("timeout", "服务器没响应（超时）");
    throw new ApiError("network", "连不上服务器");
  } finally {
    clearTimeout(timer);
  }
}

function wsUrl() {
  const b = state.base.replace(/^http/, "ws");
  return b + "/ws?token=" + encodeURIComponent(state.token || "");
}

function connectWS() {
  if (!state.base || !state.token) return;
  try { state.ws && state.ws.close(); } catch { }
  let ws;
  try { ws = new WebSocket(wsUrl()); } catch { return schedulePoll(); }
  state.ws = ws;

  ws.onopen = () => {
    state.wsOk = true; state.wsTries = 0; state.polling = false;
    setConn("on", "已连接"); nativeStatus("已连接", "ok");
    toast("QQ 已接通 ✅", "ok");
  };
  ws.onmessage = (ev) => {
    let f = null;
    try { f = JSON.parse(ev.data); } catch { return; }
    applyFrame(f);
  };
  ws.onclose = () => {
    state.wsOk = false;
    setConn("off", "重连中");
    nativeStatus("重连中…", "warn");
    state.wsTries++;
    if (state.wsTries >= 3 && !state.polling) schedulePoll();
    const wait = Math.min(30000, 1000 * Math.pow(1.7, Math.min(6, state.wsTries)));
    setTimeout(connectWS, wait);
  };
  ws.onerror = () => { };
}

let pollTimer = null;
function schedulePoll() {
  state.polling = true;
  clearTimeout(pollTimer);
  const tick = async () => {
    try {
      const d = await api("/api/events?since=" + state.lastId);
      (d.events || []).forEach((e) => applyFrame(Object.assign({ t: e.kind, id: e.id, at: e.at }, e.payload)));
      if (d.character) setChar(d.character);
      if (state.polling && !state.wsOk) setConn("mid", "轮询中");
    } catch (e) {
      if (e.code === "unbound") return handleUnauth();
      if (state.demo) { /* 演示模式忽略 */ }
    }
    if (state.polling) pollTimer = setTimeout(tick, 2500);
  };
  tick();
}

function setConn(kind, text) {
  const c = $("conn");
  if (!c) return;
  c.className = "conn conn-" + (kind === "on" ? "on" : kind === "mid" ? "mid" : "off");
  c.title = text;
  const sc = $("setConn"); if (sc) sc.textContent = text;
}

/* ============================================================ 事件流 */

function setChar(c) {
  if (!c) return;
  state.char = c;
  state.muted = !!c.muted;
  updateHUD();
}

function applyFrame(f) {
  if (!f || !f.t) return;
  if (f.id && f.id > state.lastId) state.lastId = f.id;
  switch (f.t) {
    case "hello":
      if (f.state) { setChar(f.state.character); }
      (f.events || []).forEach((e) => {
        if (e.kind === "say" && e.payload && e.payload.text) {
          bubble(e.payload.text);
        }
      });
      break;
    case "state":
      if (f.character) setChar(f.character);
      break;
    case "say":
      if (f.character) { state.char = f.character; updateHUD(); }
      doReaction(f);
      break;
    case "anim":
      playAction(f.action, f.dur || 1200, f.emotion);
      break;
    case "effect":
      spawnEffect(f.name, f.x, f.y);
      break;
    case "qq":
      if (f.from === "owner") toast(`QQ ${f.nickname || ""}：${f.text}`, "qq");
      break;
    case "touch":
      if (f.text) toast(`👋 别处传来一次触摸：${f.text}`, "");
      break;
    case "notice":
      toast(f.text, f.level === "error" ? "err" : "");
      break;
    case "levelup":
      toast(f.text || "升级啦！", "levelup");
      spawnEffect("stars");
      break;
    case "ping":
      try { state.ws && state.ws.send(JSON.stringify({ t: "pong", ts: Date.now() / 1000 })); } catch { }
      break;
    case "ack":
      if (!state.wsOk && f.data) {
        if (f.data.character) { state.char = f.data.character; updateHUD(); }
        if (f.data.reaction) doReaction(f.data.reaction);
        if (f.of === "chat" && f.data.reply) bubble(f.data.reply);
      }
      break;
    default: break;
  }
}

function doReaction(r) {
  if (!r) return;
  if (r.emotion && state.char) state.char.emotion = r.emotion;
  if (r.action) playAction(r.action, r.dur || 1200, r.emotion);
  if (r.effect) spawnEffect(r.effect);
  if (r.text) {
    bubble(r.text);
    if (r.speech !== false) say(r.text);
  }
}

function handleUnauth() {
  setConn("off", "绑定失效");
  native({ cmd: "status", text: "绑定已失效", level: "error" });
  if (IS_NATIVE) {
    // 原生壳里没有网页门禁页：给出一个按钮让用户去原生设置里解绑/重新绑定
    const el = $("offlineBanner");
    if (el) {
      $("offlineText").textContent = "绑定已失效，请打开设置解绑后重新绑定";
      el.hidden = false;
      $("offlineRetry").textContent = "打开设置";
      $("offlineRetry").onclick = () => native({ cmd: "open_settings" });
    }
    toast("绑定已失效，请在设置里重新绑定", "err");
  } else {
    state.token = ""; store.del(LS.token);
    showGate("绑定已失效，请重新绑定");
  }
}

/* ============================================================ 渲染 */

const cv = $("cv");
const ctx = cv ? cv.getContext("2d") : null;
const view = { w: 0, h: 0, dpr: 1 };
const anim = { action: "idle", start: 0, dur: 0, base: null };
let particles = [];
let blinkAt = performance.now() + 2500;
let blinkUntil = 0;
let dragPose = null;

function resize() {
  if (!cv) return;
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const r = cv.getBoundingClientRect();
  view.w = r.width; view.h = r.height; view.dpr = dpr;
  cv.width = Math.round(r.width * dpr);
  cv.height = Math.round(r.height * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", resize);

function pose() {
  const c = state.char;
  const p = (c && c.pose) || { x: 0.5, y: 0.62, facing: 1 };
  const s = Math.min(1, view.w / 420) * (view.h < 620 ? 0.86 : 1);
  return {
    x: (dragPose ? dragPose.x : p.x) * view.w,
    y: (dragPose ? dragPose.y : p.y) * view.h,
    facing: p.facing >= 0 ? 1 : -1,
    scale: s * (p.scale || 1),
  };
}

function playAction(action, dur, emotion) {
  const persistent = action === "sleep" || action === "sit";
  anim.action = action;
  anim.start = performance.now();
  anim.dur = dur || 1200;
  anim.base = persistent ? action : null;
  if (state.char && emotion) state.char.emotion = emotion;
  if (state.char) state.char.action = action;
}

function currentAction(now) {
  if (state.char && state.char.action && (state.char.action === "sleep" || state.char.action === "sit")) {
    return state.char.action;
  }
  if (anim.action !== "idle" && now - anim.start > anim.dur + 150) return "idle";
  return anim.action;
}

const EFFECT_COLORS = {
  hearts: "#ff6f9c", stars: "#ffd166", sparkle: "#9ae6ff",
  sweat: "#8fd6ff", zzz: "#cbb8ff", anger: "#ff5c5c", none: null,
};
const EFFECT_GLYPHS = { hearts: "♥", stars: "★", sparkle: "✦", anger: "💢", sweat: "💧" };

function spawnEffect(name, nx, ny) {
  const kind = EFFECT_COLORS[name] === undefined ? "sparkle" : name;
  if (kind === "none" || !EFFECT_COLORS[kind]) return;
  const p = pose();
  const ox = nx != null ? nx * view.w : p.x;
  const oy = ny != null ? ny * view.h : p.y - 40 * p.scale;
  const n = kind === "zzz" ? 3 : 10;
  for (let i = 0; i < n; i++) {
    particles.push({
      kind, x: ox + (Math.random() - 0.5) * 46 * p.scale,
      y: oy + (Math.random() - 0.5) * 30 * p.scale,
      vx: (Math.random() - 0.5) * 0.6, vy: -0.5 - Math.random() * 0.9,
      life: 900 + Math.random() * 700, born: performance.now(),
      size: 12 + Math.random() * 8,
    });
  }
}

function drawParticles(now) {
  particles = particles.filter((q) => now - q.born < q.life);
  for (const q of particles) {
    const age = (now - q.born) / q.life;
    const x = q.x + q.vx * (now - q.born) * 0.06;
    const y = q.y + q.vy * (now - q.born) * 0.12 + age * age * 40;
    ctx.save();
    ctx.globalAlpha = Math.max(0, 1 - age);
    ctx.fillStyle = EFFECT_COLORS[q.kind] || "#fff";
    const glyph = EFFECT_GLYPHS[q.kind];
    if (glyph) {
      ctx.font = `${q.size}px -apple-system, sans-serif`;
      ctx.fillText(glyph, x, y);
    } else {
      ctx.beginPath();
      ctx.arc(x, y, q.size * 0.25, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.restore();
  }
}

let lastHead = { headX: 0, headY: 0 };
function frame() {
  if (!ctx) return;
  const now = performance.now();
  ctx.clearRect(0, 0, view.w, view.h);

  // 眨眼
  if (now > blinkAt + 130) { blinkAt = now + 2000 + Math.random() * 4000; }
  const blink = now > blinkAt && now < blinkAt + 130;

  const p = pose();
  const action = currentAction(now);
  const t = anim.action === action && anim.dur ? Math.min(1, (now - anim.start) / anim.dur) : 0;

  lastHead = VBCreature.drawCreature(ctx, {
    x: p.x, y: p.y, scale: p.scale,
    emotion: (state.char && state.char.emotion) || "calm",
    action,
    outfit: (state.char && state.char.outfit) || "default",
    t, now, facing: p.facing, blink,
  });

  drawParticles(now);
  positionBubble();
  requestAnimationFrame(frame);
}

function positionBubble() {
  const b = $("bubble");
  if (!b || b.hidden) return;
  b.style.left = Math.max(90, Math.min(view.w - 90, lastHead.headX)) + "px";
  b.style.top = Math.max(80, lastHead.headY - 12) + "px";
}

let bubbleTimer = null;
function bubble(text) {
  const b = $("bubble");
  if (!b || !text) return;
  b.querySelector("span").textContent = text;
  b.hidden = false;
  positionBubble();
  clearTimeout(bubbleTimer);
  const ms = Math.max(2400, Math.min(9000, 1200 + text.length * 190));
  bubbleTimer = setTimeout(() => { b.hidden = true; }, ms);
}

/* ============================================================ 手势 → 触摸事件 */

const ptr = { down: false, x0: 0, y0: 0, x: 0, y: 0, t0: 0, moved: false, lastSend: 0, longPress: null, rubTimer: null, tossing: false };

function regionOf(px, py) {
  const p = pose();
  const top = p.y - 70 * p.scale, bottom = p.y + 50 * p.scale;
  if (py < p.y - 26 * p.scale) return "head";
  if (py < p.y - 2 * p.scale) return "face";
  if (py > bottom - 6) return "foot";
  if (Math.abs(px - p.x) > 34 * p.scale) return py > (top + bottom) / 2 ? "hand" : "head";
  return "body";
}

function norm(px, py) {
  return { x: +(px / Math.max(1, view.w)).toFixed(3), y: +(py / Math.max(1, view.h)).toFixed(3) };
}

function sendTouch(type, px, py, power) {
  if (state.demo || !state.token) { return demoReaction(type, px, py); }
  const n = norm(px, py);
  const payload = { t: "touch", type, x: n.x, y: n.y, region: regionOf(px, py), power: power || 0.5, ts: Date.now() / 1000 };
  if (state.wsOk && state.ws) {
    try { state.ws.send(JSON.stringify(payload)); } catch { }
    return Promise.resolve(null);
  }
  return api("/api/touch", { method: "POST", body: payload })
    .then((d) => { applyFrame({ t: "ack", of: "touch", data: d }); return d; })
    .catch((e) => { if (e.code === "unbound") handleUnauth(); else demoTouchFallback(type); });
}

function onDown(e) {
  const p = point(e);
  ptr.down = true; ptr.moved = false; ptr.tossing = false;
  ptr.x0 = ptr.x = p.x; ptr.y0 = ptr.y = p.y; ptr.t0 = performance.now();
  hint(false);
  clearTimeout(ptr.longPress);
  clearTimeout(ptr.rubTimer);
  // 长按 650ms 没动 → 揉搓（连续）
  ptr.longPress = setTimeout(() => {
    if (!ptr.down || ptr.moved) return;
    haptic("medium");
    sendTouch("rub", ptr.x, ptr.y, 0.45);
    const rep = () => {
      if (!ptr.down) return;
      sendTouch("rub", ptr.x, ptr.y, 0.4);
      ptr.rubTimer = setTimeout(rep, 700);
    };
    ptr.rubTimer = setTimeout(rep, 700);
  }, 650);
}

function onMove(e) {
  if (!ptr.down) return;
  const p = point(e);
  const dx = p.x - ptr.x0, dy = p.y - ptr.y0;
  const dist = Math.hypot(dx, dy);
  if (dist > 10) ptr.moved = true;
  ptr.x = p.x; ptr.y = p.y;
  if (!ptr.moved) return;

  const vertical = Math.abs(dy) > Math.abs(dx) * 1.6;
  // 往上快速甩 → 拖拽/抛
  if (vertical && dy < -60 && performance.now() - ptr.t0 < 700) {
    if (!ptr.tossing) {
      ptr.tossing = true;
      haptic("heavy");
      sendTouch("toss", p.x, p.y, Math.min(1, Math.abs(dy) / 200));
    }
  } else if (vertical && Math.abs(dy) > 40) {
    // 上下拖动 → 拎起来（视觉跟随）
    dragPose = norm(p.x, Math.max(60, p.y));
  } else {
    // 横向抚摸
    const now = performance.now();
    if (now - ptr.lastSend > 320) {
      ptr.lastSend = now;
      haptic("light");
      sendTouch("pet", p.x, p.y, Math.min(1, Math.abs(dx) / 120));
    }
  }
  // 拖动跟随
  if (ptr.moved && vertical) dragPose = norm(p.x, Math.max(80, p.y - 20));
}

function onUp(e) {
  if (!ptr.down) return;
  ptr.down = false;
  clearTimeout(ptr.longPress);
  clearTimeout(ptr.rubTimer);
  const held = performance.now() - ptr.t0;
  const p = point(e || {});
  const dist = Math.hypot(p.x - ptr.x0, p.y - ptr.y0);
  dragPose = null;

  if (ptr.tossing) { ptr.moved = false; return; }
  if (!ptr.moved && dist < 14 && held < 600) {
    haptic("light");
    const r = regionOf(p.x, p.y);
    sendTouch(r === "head" || r === "face" ? "poke" : "tap", p.x, p.y, 0.4);
  } else if (ptr.moved && dist > 60 && held > 420) {
    sendTouch("drag", p.x, p.y, Math.min(1, dist / 240));
  } else if (held > 900 && !ptr.moved) {
    sendTouch("hug", p.x, p.y, 0.6);
  }
  ptr.moved = false;
}

function point(e) {
  const r = cv.getBoundingClientRect();
  if (e && e.touches && e.touches[0]) return { x: e.touches[0].clientX - r.left, y: e.touches[0].clientY - r.top };
  if (e && e.changedTouches && e.changedTouches[0]) return { x: e.changedTouches[0].clientX - r.left, y: e.changedTouches[0].clientY - r.top };
  if (e && e.clientX != null) return { x: e.clientX - r.left, y: e.clientY - r.top };
  return { x: ptr.x, y: ptr.y };
}

function bindCanvas() {
  if (!cv) return;
  cv.addEventListener("touchstart", (e) => { e.preventDefault(); onDown(e); }, { passive: false });
  cv.addEventListener("touchmove", (e) => { e.preventDefault(); onMove(e); }, { passive: false });
  cv.addEventListener("touchend", (e) => { e.preventDefault(); onUp(e); }, { passive: false });
  cv.addEventListener("touchcancel", (e) => { onUp(e); });
  cv.addEventListener("mousedown", onDown);
  cv.addEventListener("mousemove", (e) => { if (ptr.down) onMove(e); });
  cv.addEventListener("mouseup", onUp);
  cv.addEventListener("mouseleave", (e) => { if (ptr.down) onUp(e); });
}

/* ============================================================ 离线演示（本地规则） */

const DEMO_RULES = {
  pet: ["唔……好舒服。", "再摸摸嘛。", "嗯～头这里最喜欢了。"],
  poke: ["干嘛呀！", "戳我干嘛～", "别戳啦，痒。"],
  tap: ["嗯？", "我在的。", "怎么了？"],
  hug: ["抱紧一点。", "嗯……这样很好。", "不许突然松开哦。"],
  tickle: ["哈哈哈别挠！", "不行不行，我认输！"],
  drag: ["哇——放我下来！", "你要带我去哪？"],
  toss: ["再高一点！再高一点！", "飞起来啦——"],
  rub: ["脸要红了……", "别一直搓啦。"],
  feed: ["唔唔，好吃！", "还有吗？", "谢谢你呀。"],
  kiss: ["……（捂脸）", "突然之间干嘛呀！"],
  slap: ["痛！你干嘛！", "哼，不理你了。"],
};

function demoReaction(type, px, py) {
  const lines = DEMO_RULES[type] || DEMO_RULES.tap;
  const text = lines[Math.floor(Math.random() * lines.length)];
  const emo = { pet: "happy", poke: "excited", tap: "calm", hug: "love", tickle: "shy", drag: "excited", toss: "excited", rub: "shy", feed: "happy", kiss: "love", slap: "angry" }[type] || "calm";
  const eff = { pet: "hearts", hug: "hearts", kiss: "hearts", toss: "stars", rub: "sparkle", slap: "anger", tickle: "sweat", drag: "sweat" }[type] || "none";
  if (state.char) { state.char.emotion = emo; state.char.bubble = text; }
  doReaction({ text, emotion: emo, action: type === "toss" ? "jump" : type === "hug" || type === "kiss" ? "hug" : type === "tickle" ? "jump" : "shake", effect: eff, speech: true });
  haptic("light");
  return Promise.resolve(null);
}
function demoTouchFallback() { demoReaction("tap", view.w / 2, view.h / 2); }

/* ============================================================ UI */

const BARS = [
  ["affection", "亲密度"], ["mood", "心情"], ["energy", "精力"],
  ["satiety", "饱食"], ["clean", "清洁"], ["trust", "信任"],
];

function buildBars() {
  const wrap = $("bars");
  if (!wrap) return;
  wrap.innerHTML = "";
  for (const [k, label] of BARS) {
    const d = document.createElement("div");
    d.className = "bar"; d.dataset.k = k;
    d.innerHTML = `<div class="k"><span>${label}</span><span data-v>0</span></div><div class="t"><i></i></div>`;
    wrap.appendChild(d);
  }
}

function updateHUD() {
  const c = state.char || {};
  if ($("hudName")) $("hudName").textContent = c.name || "小虚";
  if ($("hudLevel")) $("hudLevel").textContent = "Lv." + (c.level || 1);
  if ($("hudExp")) {
    const need = c.exp_next || 120;
    $("hudExp").style.width = Math.max(2, Math.min(100, ((c.exp || 0) / need) * 100)) + "%";
  }
  const stats = c.stats || {};
  document.querySelectorAll(".bar").forEach((el) => {
    const v = Math.round(stats[el.dataset.k] || 0);
    el.querySelector("[data-v]").textContent = v;
    el.querySelector(".t i").style.width = Math.max(1, Math.min(100, v)) + "%";
  });
  const room = $("room");
  if (room) room.className = "room room-" + (c.room || "day");
  if ($("setName")) $("setName").textContent = c.name || "—";
  if ($("setQQ")) $("setQQ").textContent = state.qq || "—";
  if ($("setServer")) $("setServer").textContent = state.base || "—";
}

const DOCK = [
  ["摸头", () => sendTouch("pet", pose().x, pose().y - 40 * pose().scale, 0.5)],
  ["抱抱", () => act("hug")],
  ["挠痒", () => act("tickle")],
  ["喂食", () => quickFeed()],
  ["亲亲", () => sendTouch("kiss", pose().x, pose().y - 40 * pose().scale, 0.5)],
  ["跳舞", () => act("dance")],
  ["散步", () => act("walk")],
  ["抛起来", () => sendTouch("toss", pose().x, pose().y, 0.8)],
  ["睡觉", () => act("sleep")],
  ["起床", () => act("wake")],
  ["说话", () => { const i = $("chatInput"); i && i.focus(); }],
];

function buildDock() {
  const wrap = $("dockActions");
  if (!wrap) return;
  wrap.innerHTML = "";
  for (const [label, fn] of DOCK) {
    const b = document.createElement("button");
    b.textContent = label;
    b.onclick = () => { haptic("light"); fn(); };
    wrap.appendChild(b);
  }
}

function act(action, args) {
  if (state.demo || !state.token) {
    if (action === "hug") return demoReaction("hug");
    if (action === "tickle") return demoReaction("tickle");
    if (action === "dance") return doReaction({ text: "看我转圈～", emotion: "excited", action: "spin", effect: "sparkle" });
    if (action === "walk") return doReaction({ text: "我去那边看看。", emotion: "calm", action: "walk", effect: "none" });
    if (action === "sleep") return doReaction({ text: "那我先睡啦……", emotion: "sleepy", action: "sleep", effect: "zzz" });
    if (action === "wake") return doReaction({ text: "唔……我醒了。", emotion: "sleepy", action: "idle", effect: "none" });
    return Promise.resolve(null);
  }
  const payload = { t: "action", action, args: args || {} };
  if (state.wsOk && state.ws) {
    try { state.ws.send(JSON.stringify(payload)); } catch { }
    return Promise.resolve(null);
  }
  return api("/api/action", { method: "POST", body: payload })
    .then((d) => applyFrame({ t: "ack", of: "action", data: d }))
    .catch((e) => { if (e.code === "unbound") handleUnauth(); });
}

function quickFeed() {
  const foods = ["草莓", "小鱼干", "布丁", "奶茶", "苹果"];
  const item = foods[Math.floor(Math.random() * foods.length)];
  if (state.demo || !state.token) return demoReaction("feed");
  const n = norm(pose().x, pose().y - 30);
  const payload = { t: "touch", type: "feed", item, x: n.x, y: n.y, region: "face", power: 0.5 };
  if (state.wsOk && state.ws) { try { state.ws.send(JSON.stringify(payload)); } catch { } return Promise.resolve(null); }
  return api("/api/touch", { method: "POST", body: payload })
    .then((d) => applyFrame({ t: "ack", of: "touch", data: d }))
    .catch(() => demoReaction("feed"));
}

function sendChat() {
  const input = $("chatInput");
  const text = (input.value || "").trim();
  if (!text) return;
  input.value = "";
  if (state.demo || !state.token) {
    const reply = ["嗯，我在听着呢。", "你说，我都记着。", "唔……今天也辛苦你啦。"][Math.floor(Math.random() * 3)];
    bubble(reply); say(reply); return;
  }
  const payload = { t: "chat", text };
  if (state.wsOk && state.ws) { try { state.ws.send(JSON.stringify(payload)); } catch { } return; }
  api("/api/chat", { method: "POST", body: payload })
    .then((d) => applyFrame({ t: "ack", of: "chat", data: d }))
    .catch((e) => { if (e.code === "unbound") handleUnauth(); else toast("发送失败：" + e.message, "err"); });
}

function toast(text, kind = "") {
  const wrap = $("toastWrap");
  if (!wrap || !text) return;
  const el = document.createElement("div");
  el.className = "toast " + kind;
  el.textContent = text;
  wrap.appendChild(el);
  setTimeout(() => { el.style.transition = "opacity .4s"; el.style.opacity = "0"; }, 2600);
  setTimeout(() => el.remove(), 3100);
  while (wrap.children.length > 4) wrap.removeChild(wrap.firstChild);
}

function hint(show) {
  const h = $("hint");
  if (h) h.style.opacity = show ? "1" : "0";
}

/* ============================================================ 门禁页 */

function showGate(msg) {
  $("gate").classList.remove("hide");
  $("stage").hidden = true;
  if (msg) { const m = $("gateMsg"); m.textContent = msg; m.className = "gate-msg"; }
  if ($("gateServer")) $("gateServer").value = state.base || "";
  if ($("gateDevice")) $("gateDevice").value = state.device;
  const logo = $("gateLogo");
  if (logo) {
    logo.innerHTML = '<canvas width="288" height="288" style="width:96px;height:96px"></canvas>';
    const c = logo.querySelector("canvas").getContext("2d");
    c.scale(3, 3);
    const tick = () => VBCreature.drawMiniCreature(c, 96, performance.now());
    tick();
  }
}

async function doBind() {
  const server = ($("gateServer").value || "").trim().replace(/\/+$/, "");
  const code = ($("gateCode").value || "").trim();
  const device = ($("gateDevice").value || "").trim();
  const msg = $("gateMsg");
  if (!server) return setGateMsg("请填服务器地址");
  if (!/^\d{6}$/.test(code)) return setGateMsg("绑定码是 6 位数字");
  state.base = server;
  store.set(LS.server, server);
  const btn = $("gateBtn");
  btn.disabled = true; btn.textContent = "绑定中…";
  try {
    const d = await api("/api/bind", {
      method: "POST", auth: false,
      body: { code, device: device || "Safari", platform: IS_NATIVE ? "ios" : "web", app_version: "1.0.1" },
    });
    state.token = d.token; state.qq = d.qq || ""; state.nick = d.nickname || "";
    store.set(LS.token, d.token); store.set(LS.qq, state.qq); store.set(LS.nick, state.nick);
    if (device) { state.device = device; store.set(LS.device, device); }
    setGateMsg("绑定成功，正在进入…", true);
    setTimeout(enter, 350);
  } catch (e) {
    setGateMsg(e.message || "绑定失败");
  } finally {
    btn.disabled = false; btn.textContent = "绑定并进入";
  }
}
function setGateMsg(t, ok) {
  const m = $("gateMsg");
  m.textContent = t; m.className = "gate-msg" + (ok ? " ok" : "");
}

/* ============================================================ 启动 */

async function enter() {
  $("gate").classList.add("hide");
  $("stage").hidden = false;
  resize();
  buildBars(); buildDock(); updateHUD();
  hint(true);
  setTimeout(() => hint(false), 6000);
  if (!state.char) {
    state.char = { name: "小虚", level: 1, exp: 0, exp_next: 120, emotion: "calm", action: "idle",
      outfit: "default", room: "day", stats: { affection: 20, mood: 70, energy: 80, satiety: 70, clean: 90, trust: 10 } };
    updateHUD();
  }
  if (state.demo) {
    state.demo = true;
    setConn("mid", "离线试用");
    nativeStatus("离线试用模式", "warn");
    return;
  }
  // 拉一次全量状态
  try {
    const d = await api("/api/state");
    setChar(d.character);
    state.lastId = d.last_id || 0;
    state.muted = !!d.muted;
  } catch (e) {
    if (e.code === "unbound") return handleUnauth();
    toast("连不上服务器：" + e.message, "err");
  }
  connectWS();
}

function setupRoomDeco() {
  const deco = $("roomDeco");
  if (!deco) return;
  const make = () => {
    const room = (state.char && state.char.room) || "day";
    deco.innerHTML = "";
    if (room === "night") {
      for (let i = 0; i < 40; i++) {
        const s = document.createElement("div");
        s.className = "star";
        s.style.left = Math.random() * 100 + "%";
        s.style.top = Math.random() * 60 + "%";
        s.style.opacity = 0.3 + Math.random() * 0.7;
        deco.appendChild(s);
      }
    } else if (room === "rain") {
      for (let i = 0; i < 26; i++) {
        const d = document.createElement("div");
        d.className = "drop";
        d.style.left = Math.random() * 100 + "%";
        d.style.animationDuration = (0.6 + Math.random() * 0.7) + "s";
        d.style.animationDelay = (-Math.random()) + "s";
        deco.appendChild(d);
      }
    } else if (room === "party") {
      const colors = ["#ffd166", "#63e6c8", "#ff6f9c", "#8f7bff"];
      for (let i = 0; i < 18; i++) {
        const d = document.createElement("div");
        d.className = "confetti";
        d.style.left = Math.random() * 100 + "%";
        d.style.background = colors[i % colors.length];
        d.style.animationDuration = (2.6 + Math.random() * 2) + "s";
        d.style.animationDelay = (-Math.random() * 3) + "s";
        deco.appendChild(d);
      }
    }
  };
  make();
  setInterval(make, 8000);
}

function setupSettings() {
  $("btnSettings").onclick = () => { $("sheet").hidden = false; haptic("light"); };
  $("setClose").onclick = () => { $("sheet").hidden = true; };
  $("sheet").onclick = (e) => { if (e.target.id === "sheet") $("sheet").hidden = true; };
  $("setSpeak").checked = state.speak;
  $("setHaptic").checked = state.haptic;
  $("setSpeak").onchange = (e) => { state.speak = e.target.checked; store.set(LS.speak, state.speak ? "1" : "0"); if (!state.speak) native({ cmd: "stop_speak" }); };
  $("setHaptic").onchange = (e) => { state.haptic = e.target.checked; store.set(LS.haptic, state.haptic ? "1" : "0"); };
  $("setReconnect").onclick = () => { $("sheet").hidden = true; state.wsTries = 0; connectWS(); toast("正在重连…"); };
  $("setUnbind").onclick = async () => {
    if (!confirm("解绑本机？需要重新在 QQ 里生成绑定码才能再进来。")) return;
    try { await api("/api/unbind", { method: "POST", body: {} }); } catch { }
    state.token = ""; store.del(LS.token);
    $("sheet").hidden = true;
    if (IS_NATIVE) native({ cmd: "unbind" });
    showGate("已解绑，请重新绑定");
  };
}

async function boot() {
  setupSettings();
  bindCanvas();
  setupRoomDeco();
  requestAnimationFrame(frame);

  if ($("gateBtn")) $("gateBtn").onclick = doBind;
  $("chatSend").onclick = sendChat;
  $("chatInput").addEventListener("keydown", (e) => { if (e.key === "Enter") sendChat(); });

  // 演示模式判定：没地址 / 没 token / 服务端不通
  if (IS_NATIVE && (!state.base || !state.token)) {
    // 原生壳负责绑定；走到这里说明注入的 VB_CONFIG 没生效，显示明确提示而不是一个空登录框
    showGate("原生 App 没有把服务器地址/token 传进来（VB_CONFIG 缺失），请在设置里解绑后重新绑定");
    return;
  }
  if (!state.base || !state.token) {
    if (state.base && !state.token) {
      try {
        const d = await api("/api/hello", { auth: false, timeout: 6000 });
        if (d.bound) { showGate("这台设备还没绑定，请在 QQ 里发送「虚现 绑定码」"); return; }
      } catch { }
      showGate("");
      return;
    }
    showGate("");
    return;
  }
  try {
    await api("/api/hello", { auth: false, timeout: 8000 });
  } catch (e) {
    if (IS_NATIVE) { toast("连不上服务器：" + e.message, "err"); showOffline(e.message); }
    else showOffline(e.message);
    return;
  }
  enter();
}

function showOffline(msg) {
  const el = $("offlineBanner");
  if (el) {
    $("offlineText").textContent = "连不上服务器：" + (msg || "网络错误");
    el.hidden = false;
    $("offlineRetry").onclick = () => { location.reload(); };
  }
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !state.wsOk && state.token) { state.wsTries = 0; connectWS(); }
});

/* 只在同源 http(s) 下装 Service Worker（file:// 的 WKWebView 里没有）
   —— 用 network-first 策略，避免改完前端被旧缓存粘住。 */
if ("serviceWorker" in navigator && location.protocol.startsWith("http")) {
  navigator.serviceWorker.register("sw.js").catch(() => { });
}

window.VB_BOOTED = true;
boot();
