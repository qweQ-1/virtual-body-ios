/* creature.js —— 程序化绘制的小生命（不依赖任何图片资源）
 *
 * 设计：
 *   - 所有部位都用 canvas 路径画出来，所以离线、无网络也能看到角色；
 *   - drawCreature(ctx, o) 接受情绪/动作/时间，返回"头部的画布坐标"给气泡定位；
 *   - 情绪改表情，动作改姿态；两者正交，可以任意组合（生气地跳、困着挥手……）。
 */

const BODY_LIGHT = "#cfd8ff";
const BODY_DARK = "#8f9dff";
const BELLY = "#eef2ff";
const BLUSH = "rgba(255,122,168,.55)";
const OUTLINE = "rgba(30,26,60,.55)";

function ease(t) { return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t; }
function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* ------------------------------------------------------------------ 五官 */

function drawEyes(ctx, emotion, blink, s, t) {
  const ex = 11 * s;          // 双眼水平间距的一半
  const ey = -4 * s;          // 眼睛高度
  const r = 5.2 * s;
  ctx.save();
  ctx.fillStyle = "#2b2545";
  ctx.strokeStyle = "#2b2545";
  ctx.lineWidth = 2.4 * s;
  ctx.lineCap = "round";

  const closed = blink || emotion === "sleepy";
  const drawClosed = (sign) => {
    ctx.beginPath();
    ctx.moveTo(sign * ex - r * 0.9, ey);
    ctx.quadraticCurveTo(sign * ex, ey + (emotion === "sad" ? 2.2 * s : 1.6 * s), sign * ex + r * 0.9, ey);
    ctx.stroke();
  };

  if (closed) {
    drawClosed(-1); drawClosed(1);
  } else if (emotion === "happy" || emotion === "love") {
    // ^ ^ 笑眼
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(sign * ex - r, ey + 1.6 * s);
      ctx.quadraticCurveTo(sign * ex, ey - 2.6 * s, sign * ex + r, ey + 1.6 * s);
      ctx.stroke();
    }
  } else if (emotion === "excited") {
    // 星星眼
    for (const sign of [-1, 1]) {
      const cx = sign * ex, cy = ey;
      ctx.beginPath();
      for (let i = 0; i < 10; i++) {
        const a = (Math.PI / 5) * i - Math.PI / 2;
        const rr = i % 2 === 0 ? r * 1.15 : r * 0.48;
        const px = cx + Math.cos(a) * rr, py = cy + Math.sin(a) * rr;
        i ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
      }
      ctx.closePath();
      ctx.fill();
    }
  } else if (emotion === "angry") {
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.arc(sign * ex, ey + 0.4 * s, r * 0.82, 0, Math.PI * 2);
      ctx.fill();
      // 怒眉
      ctx.beginPath();
      ctx.moveTo(sign * ex - sign * r * 1.35, ey - r * 1.5);
      ctx.lineTo(sign * ex + sign * r * 0.85, ey - r * 0.85);
      ctx.stroke();
    }
  } else if (emotion === "bored") {
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.arc(sign * ex, ey + 0.6 * s, r * 0.7, Math.PI * 0.15, Math.PI * 0.85, true);
      ctx.fill();
    }
  } else if (emotion === "sad") {
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.arc(sign * ex, ey + 0.8 * s, r * 0.86, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(sign * ex - sign * r * 1.2, ey - r * 1.35);
      ctx.lineTo(sign * ex + sign * r * 0.9, ey - r * 1.1);
      ctx.stroke();
    }
    // 泪
    ctx.fillStyle = "rgba(120,190,255,.85)";
    ctx.beginPath();
    ctx.ellipse(-ex + 1.5 * s, ey + r * 2.1 + Math.sin(t / 300) * 1.2 * s, 2.2 * s, 3.4 * s, 0, 0, Math.PI * 2);
    ctx.fill();
  } else if (emotion === "hungry") {
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.arc(sign * ex, ey, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#fff";
      ctx.beginPath();
      ctx.arc(sign * ex - r * 0.3, ey - r * 0.35, r * 0.34, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#2b2545";
    }
  } else {
    // calm / shy / 其它：圆眼 + 高光
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.arc(sign * ex, ey, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "rgba(255,255,255,.92)";
      ctx.beginPath();
      ctx.arc(sign * ex - r * 0.32, ey - r * 0.38, r * 0.36, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(sign * ex + r * 0.34, ey + r * 0.36, r * 0.16, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = "#2b2545";
    }
    if (emotion === "shy") {
      // 半眯眼
      ctx.globalCompositeOperation = "destination-out";
      ctx.beginPath();
      ctx.rect(-ex - r * 1.4, ey - r * 1.6, (ex + r * 1.4) * 2, r * 0.9);
      ctx.fill();
      ctx.globalCompositeOperation = "source-over";
    }
  }
  ctx.restore();
}

function drawMouth(ctx, emotion, s, t) {
  ctx.save();
  ctx.strokeStyle = "#2b2545";
  ctx.lineWidth = 2.2 * s;
  ctx.lineCap = "round";
  const my = 7.5 * s;
  if (emotion === "happy" || emotion === "love" || emotion === "excited") {
    ctx.beginPath();
    ctx.arc(0, my - 1.4 * s, 4.6 * s, 0.22 * Math.PI, 0.78 * Math.PI);
    ctx.stroke();
  } else if (emotion === "angry") {
    ctx.beginPath();
    ctx.moveTo(-4 * s, my + 1.4 * s);
    ctx.quadraticCurveTo(0, my - 2.2 * s, 4 * s, my + 1.4 * s);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(0, my + 2.6 * s, 3.4 * s, 0.15 * Math.PI, 0.85 * Math.PI);
    ctx.fillStyle = "#7a2233";
    ctx.fill();
  } else if (emotion === "sad") {
    ctx.beginPath();
    ctx.arc(0, my + 3.2 * s, 4 * s, 1.2 * Math.PI, 1.8 * Math.PI);
    ctx.stroke();
  } else if (emotion === "hungry") {
    const open = 2.4 * s + Math.abs(Math.sin(t / 220)) * 1.6 * s;
    ctx.beginPath();
    ctx.ellipse(0, my + 1.2 * s, 3.4 * s, open, 0, 0, Math.PI * 2);
    ctx.fillStyle = "#7a2233";
    ctx.fill();
  } else if (emotion === "sleepy") {
    const puff = Math.sin(t / 900) * 0.6 * s;
    ctx.beginPath();
    ctx.ellipse(0, my + 1.4 * s, 2.6 * s + puff, 1.6 * s, 0, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(43,37,69,.5)";
    ctx.fill();
  } else {
    ctx.beginPath();
    ctx.moveTo(-2.6 * s, my);
    ctx.quadraticCurveTo(0, my + 2.4 * s, 2.6 * s, my);
    ctx.stroke();
  }
  ctx.restore();
}

function drawBlush(ctx, strength, s) {
  if (strength <= 0) return;
  ctx.save();
  ctx.fillStyle = BLUSH;
  ctx.globalAlpha = Math.min(1, strength);
  for (const sign of [-1, 1]) {
    ctx.beginPath();
    ctx.ellipse(sign * 15.5 * s, 3.5 * s, 5.2 * s, 3.2 * s, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.restore();
}

/* ------------------------------------------------------------------ 身体 */

function bodyPath(ctx, w, h, squash) {
  // 圆润的胖身体（用贝塞尔画一个软软的团子）
  const W = w * squash, H = h / squash;
  ctx.beginPath();
  ctx.moveTo(0, -H * 0.62);
  ctx.bezierCurveTo(W * 0.62, -H * 0.66, W * 0.72, H * 0.18, 0, H * 0.55);
  ctx.bezierCurveTo(-W * 0.72, H * 0.18, -W * 0.62, -H * 0.66, 0, -H * 0.62);
  ctx.closePath();
}

function drawEars(ctx, s, emotion, t) {
  ctx.save();
  ctx.fillStyle = BODY_DARK;
  const twitch = Math.sin(t / 700) * 0.06;
  for (const sign of [-1, 1]) {
    ctx.save();
    ctx.translate(sign * 17 * s, -34 * s);
    ctx.rotate(sign * (0.42 + twitch * (emotion === "excited" ? 2.5 : 1)));
    ctx.beginPath();
    ctx.moveTo(-9 * s, 12 * s);
    ctx.quadraticCurveTo(-4 * s, -14 * s, 6 * s, -12 * s);
    ctx.quadraticCurveTo(11 * s, 0, 6 * s, 12 * s);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = "rgba(255,170,205,.75)";
    ctx.beginPath();
    ctx.moveTo(-3.5 * s, 9 * s);
    ctx.quadraticCurveTo(-1 * s, -7 * s, 4.5 * s, -6.5 * s);
    ctx.quadraticCurveTo(6 * s, 2 * s, 3 * s, 9 * s);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = BODY_DARK;
    ctx.restore();
  }
  ctx.restore();
}

function drawArm(ctx, side, angle, len, s, t) {
  ctx.save();
  ctx.rotate(side * angle);
  ctx.fillStyle = BODY_LIGHT;
  ctx.beginPath();
  ctx.ellipse(side * 30 * s, 4 * s, 8.5 * s, len, side * 0.3, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

/* ------------------------------------------------------------------ 主绘制 */

/**
 * @returns {{headX:number, headY:number}} 头部在画布中的坐标（用于气泡定位）
 */
export function drawCreature(ctx, o) {
  const {
    x = 0, y = 0, scale = 1, emotion = "calm", action = "idle",
    t = 0, now = 0, facing = 1, blink = false, outfit = "default", effectTint = null,
  } = o;
  const s = 1.6 * scale;                     // 身体单位 → 像素
  const p = clamp01(t);                      // 动作进度 0..1

  // ---- 动作 → 位移/形变 ----
  let dx = 0, dy = 0, rot = 0, sx = 1, sy = 1, armL = -0.5, armR = 0.5, lying = 0;
  switch (action) {
    case "jump": {
      const h = Math.sin(Math.PI * p);
      dy = -78 * s * h;
      sy = 1 + 0.16 * (p < 0.15 ? p / 0.15 : (p > 0.85 ? (p - 0.85) / 0.15 : 0));
      sx = 2 - sy;
      armL = -1.5; armR = 1.5;
      break;
    }
    case "walk":
      dx = Math.sin(now / 220) * 2 * s;
      dy = -Math.abs(Math.sin(now / 220)) * 2.2 * s;
      armL = -0.5 - Math.sin(now / 200) * 0.5;
      armR = 0.5 - Math.sin(now / 200 + Math.PI) * 0.5;
      break;
    case "sit": dy = 12 * s; sy = 0.9; sx = 1.08; armL = -0.2; armR = 0.2; break;
    case "sleep": lying = 1; sy = 0.72; sx = 1.2; break;
    case "eat":
      sy = 1 + Math.sin(now / 180) * 0.04; sx = 2 - sy;
      armL = -1.1; armR = 1.1;
      break;
    case "wave": armR = 2.2 + Math.sin(now / 140) * 0.45; armL = -0.4; break;
    case "hug": armL = -1.75; armR = 1.75; dy = -3 * s; break;
    case "spin": {
      const a = p * Math.PI * 2;
      sx = Math.cos(a) >= 0 ? Math.max(0.15, Math.cos(a)) : Math.max(0.15, Math.cos(a));
      sx = Math.cos(a);
      dx = Math.sin(a) * 6 * s;
      armL = -1.2; armR = 1.2;
      break;
    }
    case "shake": dx = Math.sin(now / 45) * 3.4 * s; break;
    case "shakehead": rot = Math.sin(now / 90) * 0.16; break;
    case "dance":
      rot = Math.sin(now / 190) * 0.22;
      dx = Math.sin(now / 190) * 5 * s;
      armL = -1.8 + Math.sin(now / 190) * 0.6; armR = 1.8 - Math.sin(now / 190) * 0.6;
      break;
    case "think": rot = 0.09; armR = 1.9; armL = -0.3; dy = -1 * s; break;
    case "panic":
      dx = Math.sin(now / 38) * 4.2 * s;
      dy = -Math.abs(Math.sin(now / 150)) * 5 * s;
      armL = -2.1; armR = 2.1;
      break;
    case "nod": dy = Math.max(0, Math.sin(now / 150)) * 4.5 * s; break;
    default: // idle
      dy = Math.sin(now / 780) * 2.6 * s;
      sy = 1 + Math.sin(now / 780) * 0.018;
      sx = 2 - sy;
      armL = -0.5 + Math.sin(now / 900) * 0.08;
      armR = 0.5 - Math.sin(now / 900) * 0.08;
  }

  const cxp = x + dx;
  const cyp = y + dy;

  // ---- 地面阴影 ----
  ctx.save();
  const shScale = lying ? 1.35 : 1;
  ctx.fillStyle = "rgba(0,0,0,.22)";
  ctx.beginPath();
  ctx.ellipse(x, y + 46 * s, 34 * s * shScale * sx, 8 * s, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  ctx.save();
  ctx.translate(cxp, cyp);
  // 旋转动作会让 sx 穿过 0（翻转），夹一下避免整帧消失
  const sxe = (sx < 0 ? -1 : 1) * Math.max(0.08, Math.abs(sx));
  ctx.scale(facing * sxe, sy);
  ctx.rotate(rot * facing);
  if (lying) ctx.rotate(-0.34 * facing);

  // ---- 手臂（在身体后面）----
  drawArm(ctx, -1, armL, 9 * s, s, now);
  drawArm(ctx, 1, armR, 9 * s, s, now);

  // ---- 尾巴 ----
  ctx.save();
  ctx.strokeStyle = BODY_DARK;
  ctx.lineWidth = 4.2 * s;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(-26 * s, 22 * s);
  const wag = Math.sin(now / (emotion === "happy" || emotion === "excited" ? 160 : 420)) * 6 * s;
  ctx.quadraticCurveTo(-40 * s, 26 * s + wag, -36 * s, 12 * s + wag);
  ctx.stroke();
  ctx.restore();

  // ---- 耳朵 ----
  drawEars(ctx, s, emotion, now);

  // ---- 身体 ----
  const grad = ctx.createLinearGradient(0, -46 * s, 0, 46 * s);
  grad.addColorStop(0, BODY_LIGHT);
  grad.addColorStop(1, BODY_DARK);
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,.35)";
  ctx.shadowBlur = 18 * s;
  ctx.shadowOffsetY = 6 * s;
  bodyPath(ctx, 44, 92, 1);
  ctx.fillStyle = grad;
  ctx.fill();
  ctx.restore();

  ctx.save();
  bodyPath(ctx, 44, 92, 1);
  ctx.strokeStyle = OUTLINE;
  ctx.lineWidth = 2.2 * s;
  ctx.stroke();
  ctx.restore();

  // 肚子
  ctx.save();
  ctx.globalAlpha = .85;
  ctx.fillStyle = BELLY;
  ctx.beginPath();
  ctx.ellipse(0, 18 * s, 24 * s, 22 * s, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();

  // 装扮
  drawOutfit(ctx, outfit, s, now, emotion);

  // ---- 脸 ----
  ctx.save();
  ctx.translate(0, -16 * s);
  if (action === "nod") ctx.translate(0, Math.sin(now / 150) * 1.4 * s);
  drawBlush(ctx, emotion === "shy" || emotion === "love" ? 1 : (emotion === "happy" ? 0.55 : 0.25), s);
  drawEyes(ctx, emotion, blink, s, now);
  drawMouth(ctx, emotion, s, now);
  ctx.restore();

  // 特效挂件
  if (action === "think") {
    ctx.save();
    ctx.fillStyle = "rgba(255,255,255,.92)";
    ctx.font = `${Math.round(16 * s)}px -apple-system, sans-serif`;
    ctx.fillText("?", 30 * s, -44 * s + Math.sin(now / 400) * 2 * s);
    ctx.restore();
  }
  if (emotion === "sleepy" || action === "sleep") {
    ctx.save();
    ctx.fillStyle = "rgba(255,255,255,.9)";
    ctx.font = `${Math.round(13 * s)}px -apple-system, sans-serif`;
    for (let i = 0; i < 3; i++) {
      const ph = (now / 1400 + i * 0.33) % 1;
      ctx.globalAlpha = 1 - ph;
      ctx.fillText("z", 26 * s + i * 9 * s, -34 * s - ph * 26 * s);
    }
    ctx.restore();
  }
  if (effectTint) {
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    ctx.globalAlpha = 0.12;
    ctx.fillStyle = effectTint;
    ctx.beginPath();
    ctx.ellipse(0, 0, 60 * s, 70 * s, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  ctx.restore();

  return { headX: cxp, headY: cyp - 62 * s * sy };
}

function drawOutfit(ctx, outfit, s, now, emotion) {
  ctx.save();
  if (outfit === "pajamas") {
    ctx.fillStyle = "rgba(120,150,255,.85)";
    ctx.beginPath();
    ctx.moveTo(-30 * s, -40 * s);
    ctx.quadraticCurveTo(-30 * s, -58 * s, -10 * s, -54 * s);
    ctx.quadraticCurveTo(0, -70 * s, 10 * s, -54 * s);
    ctx.quadraticCurveTo(30 * s, -58 * s, 30 * s, -40 * s);
    ctx.quadraticCurveTo(0, -34 * s, -30 * s, -40 * s);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = "#fff";
    ctx.beginPath();
    ctx.arc(0, -70 * s, 5 * s, 0, Math.PI * 2);
    ctx.fill();
  } else if (outfit === "sport") {
    ctx.strokeStyle = "#ff6b81";
    ctx.lineWidth = 5 * s;
    ctx.beginPath();
    ctx.moveTo(-32 * s, -34 * s);
    ctx.quadraticCurveTo(0, -42 * s, 32 * s, -34 * s);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(-32 * s, -34 * s);
    ctx.lineTo(-44 * s, -30 * s);
    ctx.moveTo(32 * s, -34 * s);
    ctx.lineTo(44 * s, -30 * s);
    ctx.stroke();
  } else if (outfit === "raincoat") {
    ctx.fillStyle = "rgba(255,214,102,.85)";
    ctx.beginPath();
    ctx.moveTo(-34 * s, -28 * s);
    ctx.quadraticCurveTo(-34 * s, -52 * s, 0, -52 * s);
    ctx.quadraticCurveTo(34 * s, -52 * s, 34 * s, -28 * s);
    ctx.quadraticCurveTo(0, -20 * s, -34 * s, -28 * s);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,.5)";
    ctx.beginPath();
    ctx.ellipse(-12 * s, -24 * s, 3 * s, 5 * s, 0.2, 0, Math.PI * 2);
    ctx.fill();
  } else if (outfit === "hamster") {
    ctx.fillStyle = "rgba(255,220,170,.95)";
    for (const sign of [-1, 1]) {
      ctx.beginPath();
      ctx.ellipse(sign * 26 * s, -2 * s, 9 * s, 7 * s, 0, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  ctx.restore();
}

/* 小图标角色（绑定页用），复用主绘制 */
export function drawMiniCreature(ctx, size, now = 0) {
  ctx.clearRect(0, 0, size, size);
  ctx.save();
  ctx.translate(size / 2, size * 0.62);
  drawCreature(ctx, {
    x: 0, y: 0, scale: size / 165, emotion: "happy", action: "idle",
    now, t: 0, facing: 1, outfit: "default",
  });
  ctx.restore();
}
