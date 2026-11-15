/* model3d.js —— 真正的 3D 角色渲染（three.js + glTF）
 *
 * 与 canvas 2D 的区别：
 *   - 支持用户上传的 glb/gltf 模型（带骨骼动画的模型能直接播动作）；
 *   - 触摸 raycast 命中模型，点头/身体有不同反应；
 *   - 情绪通过模型颜色微调 + 特效粒子表现。
 *
 * 加载策略：three.js 从 CDN 动态 import（module）。**必须通过网络加载**：
 * WKWebView 从 file:// 打开页面时会拦掉 ES module，所以原生 App 用
 * http(s) 地址加载服务端页面时才启用 3D，否则自动回落到 2D canvas。
 */

const THREE_CDN = "https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js";
const GLTF_CDN = "https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/loaders/GLTFLoader.js";

let THREE = null;
let GLTFLoader = null;
let loading = null;

/** 惰性加载 three.js；失败返回 null（调用方回落到 2D）。 */
async function ensureThree() {
  if (THREE) return THREE;
  if (loading) return loading;
  loading = (async () => {
    try {
      THREE = await import(THREE_CDN);
      const mod = await import(GLTF_CDN);
      GLTFLoader = mod.GLTFLoader;
      return THREE;
    } catch (e) {
      console.warn("[3D] three.js 加载失败，回落到 2D：", e && e.message);
      THREE = null;
      return null;
    }
  })();
  return loading;
}

const EMOTION_TINT = {
  happy: 0xffe9a8, calm: 0xffffff, shy: 0xffc2d6, sad: 0xa8c8ff,
  angry: 0xff9e9e, sleepy: 0xb9b3d6, hungry: 0xffd49e, excited: 0xfff0a0,
  love: 0xffb3c8, bored: 0xd8d8d8,
};

class Model3D {
  constructor(canvas) {
    this.canvas = canvas;
    this.renderer = null;
    this.scene = null;
    this.camera = null;
    this.root = null;
    this.mixer = null;
    this.actions = {};
    this.clock = null;
    this.raycaster = null;
    this.pointer = { x: 0, y: 0 };
    this.tweens = [];
    this.jumping = 0;
    this.shake = 0;
    this.spin = 0;
    this.baseScale = 1;
    this.ready = false;
    this.currentUrl = "";
  }

  async init() {
    const T = await ensureThree();
    if (!T) return false;
    this.renderer = new T.WebGLRenderer({ canvas: this.canvas, antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = T.PCFSoftShadowMap;

    this.scene = new T.Scene();
    this.camera = new T.PerspectiveCamera(34, 1, 0.1, 100);
    this.camera.position.set(0, 1.35, 4.2);
    this.camera.lookAt(0, 1.0, 0);

    // 灯光：一个暖色主光 + 一个冷色补光 + 环境光，让模型有立体感
    const key = new T.DirectionalLight(0xfff2e0, 2.1);
    key.position.set(2.4, 4.2, 3);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    key.shadow.camera.near = 0.5;
    key.shadow.camera.far = 20;
    this.scene.add(key);

    const rim = new T.DirectionalLight(0x9db4ff, 1.1);
    rim.position.set(-3, 2.2, -2.4);
    this.scene.add(rim);
    this.scene.add(new T.HemisphereLight(0xbfd4ff, 0x30263f, 0.85));

    // 地面接影（圆形渐隐），让角色不像悬空
    const shadowGeo = new T.CircleGeometry(1.1, 48);
    const shadowMat = new T.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.22 });
    this.ground = new T.Mesh(shadowGeo, shadowMat);
    this.ground.rotation.x = -Math.PI / 2;
    this.ground.position.y = 0.001;
    this.scene.add(this.ground);

    this.raycaster = new T.Raycaster();
    this.clock = new T.Clock();
    this.ready = true;
    this.resize();
    return true;
  }

  resize() {
    if (!this.ready) return;
    const rect = this.canvas.getBoundingClientRect();
    const w = Math.max(1, rect.width);
    const h = Math.max(1, rect.height);
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.camera.updateProjectionMatrix();
  }

  /** 载入 glb/gltf（url 可以是相对 /uploads/xxx.glb） */
  async load(url) {
    if (!this.ready || !url) return false;
    if (this.currentUrl === url) return true;
    const T = THREE;
    const loader = new GLTFLoader();
    return new Promise((resolve) => {
      loader.load(
        url,
        (gltf) => {
          this.clearModel();
          const model = gltf.scene;
          // 归一化：把模型放到「脚踩地面、身高约 1.7」的标准尺寸
          const box = new T.Box3().setFromObject(model);
          const size = new T.Vector3();
          box.getSize(size);
          const height = Math.max(0.001, size.y);
          const s = 1.7 / height;
          model.scale.setScalar(s);
          const box2 = new T.Box3().setFromObject(model);
          const center = new T.Vector3();
          box2.getCenter(center);
          model.position.x -= center.x;
          model.position.z -= center.z;
          model.position.y -= box2.min.y;

          model.traverse((o) => {
            if (o.isMesh) {
              o.castShadow = true;
              o.receiveShadow = true;
              // 记下原始颜色，用于情绪染色后还原
              if (o.material && o.material.color && !o.userData.origColor) {
                o.userData.origColor = o.material.color.clone();
              }
            }
          });

          this.root = new T.Group();
          this.root.add(model);
          this.scene.add(this.root);
          this.baseScale = 1;

          // 骨骼动画
          this.mixer = null;
          this.actions = {};
          if (gltf.animations && gltf.animations.length) {
            this.mixer = new T.AnimationMixer(model);
            gltf.animations.forEach((clip) => {
              this.actions[clip.name.toLowerCase()] = this.mixer.clipAction(clip);
            });
            const idle = this.pickAction("idle") || Object.values(this.actions)[0];
            if (idle) idle.play();
          }

          this.currentUrl = url;
          this.ground.position.y = 0.002;
          resolve(true);
        },
        undefined,
        (err) => {
          console.warn("[3D] 模型加载失败：", err);
          resolve(false);
        },
      );
    });
  }

  /** 在模型自带动画里挑一个最接近的（名字包含即可），没有就返回 null */
  pickAction(name) {
    if (!this.actions || !name) return null;
    const key = String(name).toLowerCase();
    if (this.actions[key]) return this.actions[key];
    for (const k of Object.keys(this.actions)) {
      if (k.includes(key) || key.includes(k)) return this.actions[k];
    }
    return null;
  }

  clearModel() {
    if (this.root && this.scene) {
      this.scene.remove(this.root);
      this.root.traverse((o) => {
        if (o.geometry) o.geometry.dispose();
        if (o.material) {
          if (Array.isArray(o.material)) o.material.forEach((m) => m.dispose());
          else o.material.dispose();
        }
      });
      this.root = null;
    }
    this.mixer = null;
    this.actions = {};
    this.currentUrl = "";
  }

  /** 播动作：优先用模型自带的骨骼动画，没有动画就用程序化位移 */
  play(action, dur = 1200) {
    const clip = this.pickAction(action);
    if (clip && this.mixer) {
      Object.values(this.actions).forEach((a) => {
        if (a !== clip) a.stop();
      });
      clip.reset();
      clip.setLoop(THREE.LoopOnce, 1);
      clip.clampWhenFinished = true;
      clip.play();
      return;
    }
    // 程序化动作
    const t = performance.now() / 1000;
    switch (action) {
      case "jump": this.jumping = t; break;
      case "shake": this.shake = t; break;
      case "spin": case "dance": this.spin = t; break;
      default: break;
    }
  }

  setEmotion(emotion) {
    if (!this.root) return;
    const tint = EMOTION_TINT[emotion] || 0xffffff;
    const color = new THREE.Color(tint);
    this.root.traverse((o) => {
      if (o.isMesh && o.material && o.material.color && o.userData.origColor) {
        o.material.color.copy(o.userData.origColor).lerp(color, 0.32);
      }
    });
  }

  /** 射线命中测试：返回 "head" | "body" | null */
  hitTest(clientX, clientY) {
    if (!this.ready || !this.root) return null;
    const rect = this.canvas.getBoundingClientRect();
    this.pointer.x = ((clientX - rect.left) / rect.width) * 2 - 1;
    this.pointer.y = -((clientY - rect.top) / rect.height) * 2 + 1;
    this.raycaster.setFromCamera(this.pointer, this.camera);
    const hits = this.raycaster.intersectObject(this.root, true);
    if (!hits.length) return null;
    const y = hits[0].point.y;      // 世界坐标：脚在 0，头顶约 1.7
    return y > 1.15 ? "head" : "body";
  }

  render() {
    if (!this.ready) return;
    const now = performance.now() / 1000;
    const dt = this.clock.getDelta();

    if (this.mixer) this.mixer.update(dt);

    if (this.root) {
      // 呼吸感
      const breathe = 1 + Math.sin(now * 1.6) * 0.006;
      let y = 0;
      let scaleY = breathe;
      let rotY = Math.sin(now * 0.45) * 0.06;

      if (this.jumping && now - this.jumping < 0.85) {
        const p = (now - this.jumping) / 0.85;
        y = Math.sin(Math.PI * p) * 0.55;
        scaleY *= 1 + Math.sin(Math.PI * p) * 0.05;
      }
      if (this.shake && now - this.shake < 0.7) {
        const p = 1 - (now - this.shake) / 0.7;
        this.root.position.x = Math.sin(now * 42) * 0.035 * p;
      } else {
        this.root.position.x *= 0.86;
      }
      if (this.spin && now - this.spin < 1.2) {
        const p = (now - this.spin) / 1.2;
        rotY += p * Math.PI * 2;
      }

      this.root.position.y = y;
      this.root.rotation.y = rotY;
      this.root.scale.set(1, scaleY, 1);
      this.ground.scale.setScalar(1 - y * 0.35);
      this.ground.material.opacity = 0.22 - y * 0.18;
    }
    this.renderer.render(this.scene, this.camera);
  }

  dispose() {
    this.clearModel();
    if (this.renderer) this.renderer.dispose();
    this.ready = false;
  }
}

/* 普通脚本暴露（ES module 在 file:// 下会被 WKWebView 拦掉） */
window.VBModel3D = { ensureThree: ensureThree, Model3D: Model3D };
