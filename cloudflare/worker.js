/**
 * =============================================================================
 *  Cloudflare Worker —— wenku8 反向代理中继
 *  v16
 * =============================================================================
 *  链路：  手机 App / WebView  ──TLS──▶  Worker(dhr.kdns.fr)  ──▶  www.wenku8.net
 *
 *  目的：  ① 绕过上游 Cloudflare 对数据中心 IP / 异常指纹的 403 风控
 *          ② 削减首字节时间（TTFB）与页面请求数
 *          ③ 提高边缘缓存命中率，减少「手机 → CF 边缘 → 上游」两次往返
 *
 *  ── 文件结构 ───────────────────────────────────────────────────────────────
 *    §1  CONFIG    配置常量（域名 / UA / TTL / 版本号）
 *    §2  UTIL      通用工具（诊断头、CORS、文本判定）
 *    §3  REWRITE   页面改写（纯字节级，GBK 安全）
 *    §4  COOKIE    Set-Cookie 规范化
 *    §5  CACHE     缓存策略与读写
 *    §6  UPSTREAM  回源与风控重试
 *    §7  HANDLERS  边缘路由（/__noop.js、/__pic/）与入口 fetch
 *
 *  ── 版本沿革（踩过的坑，勿回退）────────────────────────────────────────────
 *   v16  规避升级：WAF 敏感参数名打散抽象为 escapeWafQuery()，回源 URL 变成
 *        「最小规避 → 全面规避」两级候选（upstreamTargets()），只有首跳被拦才升级；
 *        不再对 charset 写死替换，日后新增特征词只需改 WAF_TOKENS 一处。
 *        同时把 v15 的内联规避逻辑从入口搬到 §6，入口只剩一句 upstreamTargets()。
 *   v15  ★ 实测：上游 CF 对 query 里含字面 "charset=" 的 bookcase.php / reader.php
 *        直接 403；3 次重试全挂后本 Worker 自造 502，App 把 502 当登录失败并清
 *        Cookie（表现为「登录成功瞬间报 content not found」）。
 *        把参数名写成 ch%61rset= 即可绕过——PHP 对参数名 urldecode，站点语义不变。
 *   v14  提速：301/302 纳入短缓存（TTL.REDIRECT，未登录时首页/列表不再每轮回源跳转）；
 *              公共页改为按 Cookie 分桶缓存（登录用户同样命中，300s）；
 *              重试在首次成功即止；响应头摆脱上游 no-cache 干扰。
 *        整理：全文件分区 + JSDoc 注释、常量集中、去除重复的统计脚本替换。
 *   v13  静态 7 天 / 正文 10 分钟 / 公共页 5 分钟（仅匿名）；图片子域反代 /__pic/；
 *        第三方统计脚本 → /__noop.js（hm.baidu 同步脚本是首屏空白主因）。
 *   v12  ★ 写缓存必须「返回客户端前同步 clone + 空 body 校验」——
 *        在 ctx.waitUntil 异步里 clone 只能拿到空 body，会造成命中时返回空白页。
 *   v11  引入 caches.default；按 PHPSESSID 分桶，防止不同用户串号。
 *   v9   回源头必须无条件覆盖 sec-fetch-* 与 client hints：透传 App 自带的
 *        sec-fetch-site: same-origin 会与 Host/Referer 不一致 → 上游 403。
 *   v8  ★ 禁止使用 HTMLRewriter：它按 UTF-8 解析 / 重编码，而页面是 GBK，
 *        中文会被替换为 U+FFFD，App 侧 GBK 严格解码直接抛
 *        "FormatException: Bad GBK encoding 0xbd2c"。必须走字节级替换。
 *   v7   Location 强制 https；Set-Cookie 去重、剥 Domain/HttpOnly/SameSite。
 *
 *  ── 连接速度备忘（v14 实测定位）─────────────────────────────────────────────
 *    容器 → CF 边缘实测：DNS ~5ms、TCP ~15ms、**TLS 握手 600-1000ms**、TTFB 1.0-1.3s。
 *    证据：纯边缘生成的 /__noop.js 与 CF 缓存命中的 css 同样是 ~0.96s。
 *    → 页面慢的主因是「每次请求重建 TLS」而非回源；本 Worker 已开启 HTTP/3
 *      （响应头 alt-svc: h3=":443"），客户端走 QUIC 即为 1-RTT / 0-RTT 握手。
 *      因此本层的优化重心是：减少请求数、减少回源、别让边缘缓存白等。
 * =============================================================================
 */

/* ============================================================================
 * §1  CONFIG —— 配置常量
 * ==========================================================================*/

/** 回源目标：官方主站。固定不变，不随客户端所选节点变化。 */
const UPSTREAM = "www.wenku8.net";

/** 页面中出现的上游域名（含备用域），统一改写为中继域名。注意：长串需在前。 */
const UPSTREAM_DOMAINS = [
  "www.wenku8.net", "www.wenku8.cc", "www.wenku8.com",
  "wenku8.net", "wenku8.cc", "wenku8.com",
];

/**
 * 图片子域保护名单。
 * 这些串内部含有 "wenku8.com" 之类的子串，若不做占位保护，会被上游域名
 * 替换规则误改成 pic.dhr.kdns.fr 之类的死链。
 */
const PROTECT_DOMAINS = [
  "pic.wenku8.com", "pic.wenku8.net",
  "img.wenku8.com", "img.wenku8.net",
];

/** 回源伪装 UA / Accept（App 侧与桌面侧各一套，用于风控重试换身份） */
const UA_MOBILE =
  "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Mobile Safari/537.36";
const UA_DESKTOP =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36";
const ACCEPT_HTML =
  "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8";

/** 缓存 TTL（秒）：按资源类型分级 */
const TTL = {
  STATIC:   604800, // 静态资源（css / js / 字体）：7 天
  CONTENT:  600,    // 正文页 / 书籍详情页：10 分钟（按 Cookie 分桶）
  PUBLIC:   300,    // 其它公共页：5 分钟（按 Cookie 分桶）
  REDIRECT: 120,    // 301 / 302 跳转：2 分钟（匿名共享桶；登录桶按 Cookie 独立，不会串号）
  IMAGE:    604800, // 图片反代：7 天
};

/** 缓存版本号：缓存策略一旦调整即递增，可瞬间绕开全部历史脏条目。 */
const CACHE_VERSION = "16";

/** 单次请求最多尝试的「身份组合」次数（首次不被拦就不要再试）。 */
const MAX_ATTEMPTS = 3;

/**
 * WAF 敏感参数名：query 里出现这些字面参数名，上游 Cloudflare 会直接 403
 * （实测 charset 必拦，见文件头 v15）。新增被拦特征词时只改这里一处，
 * escapeWafQuery() 的 level 1 会自动覆盖。
 */
const WAF_TOKENS = ["charset"];

/** 图片反代路由：/__pic/<i|p>/<path> → img|pic.wenku8.com/<path> */
const PIC_ROUTE = "/__pic/";
const PIC_PREFIX = { i: "img.wenku8.com", p: "pic.wenku8.com" };

/** 第三方统计 / 广告脚本 → 边缘空脚本（同步脚本会阻塞 HTML 解析） */
const NOOP_ROUTE = "/__noop.js";

/* ============================================================================
 * §2  UTIL —— 通用工具
 * ==========================================================================*/

/**
 * 打诊断头，便于在 curl / App 侧核对回源次数与风控状态。
 * @param {Response} out       将要返回给客户端的响应
 * @param {number}   attempts  实际回源尝试次数
 * @param {boolean}  blocked   是否最终被上游风控拦截
 */
function tagDiag(out, attempts, blocked) {
  out.headers.set("X-Relay-Upstream", UPSTREAM);
  out.headers.set("X-Relay-Attempts", String(attempts));
  if (blocked) out.headers.set("X-Relay-Blocked", "1");
}

/** CORS 放行（App 内 WebView 与 fetch 混用，需显式放行） */
function applyCors(res) {
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Methods", "GET, POST, HEAD, OPTIONS");
  res.headers.set("Access-Control-Allow-Headers", "*");
}

/**
 * 是否为文本类响应（决定要不要做页面改写）。
 * @param {string} ct content-type 头
 */
function isTexty(ct) {
  return /text\/|json|javascript|xml|xhtml|charset/i.test(ct);
}

/** 正则转义（用于把域名安全地拼进 RegExp） */
function esc(s) {
  return s.replace(/\./g, "\\.");
}

/* ============================================================================
 * §3  REWRITE —— 页面改写（纯字节级，编码无关）
 * ----------------------------------------------------------------------------
 *  为什么不用 HTMLRewriter：它以 UTF-8 解析并重编码，而 wenku8 页面为 GBK。
 *  页面中文字节被判为非法 UTF-8 后逐处替换成 U+FFFD(EF BF BD)，App 侧再按
 *  GBK 严格解码就会切出 BD 2C 这类非法序列并抛 FormatException。
 *
 *  字节级替换只匹配 ASCII 串（域名由 '.'、数字、字母组成，字节值 < 0x40），
 *  绝不可能落在 GBK 双字节序列内部，因此对中文完全无损。
 * ==========================================================================*/

/**
 * string → 单字节数组（每个 charCode 截断为 1 字节，ASCII 场景等价）。
 * @param {string} s
 * @returns {Uint8Array}
 */
function strBytes(s) {
  const a = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i) & 0xff;
  return a;
}

/** ASCII 小写化（非 A-Z 原样返回） */
function lowerByte(c) {
  return (c >= 0x41 && c <= 0x5a) ? (c | 0x20) : c;
}

/**
 * 在字节数组中把 from 全部替换为 to（大小写不敏感，from/to 长度可不等）。
 * 单遍扫描；未命中时原样返回同一引用（调用方可用 `!==` 判断是否有改动）。
 * @param {Uint8Array} bytes 源字节
 * @param {string}     from
 * @param {string}     to
 * @returns {Uint8Array}
 */
function replaceBytes(bytes, from, to) {
  const f = strBytes(from), t = strBytes(to), fl = f.length;
  if (!fl || bytes.length < fl) return bytes;
  let i = 0, last = 0, parts = null;
  while (i <= bytes.length - fl) {
    let ok = true;
    for (let j = 0; j < fl; j++) {
      if (lowerByte(bytes[i + j]) !== lowerByte(f[j])) { ok = false; break; }
    }
    if (ok) {
      if (!parts) parts = [];
      parts.push(bytes.subarray(last, i));
      parts.push(t);
      i += fl;
      last = i;
    } else {
      i++;
    }
  }
  if (!parts) return bytes;
  parts.push(bytes.subarray(last));
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

/**
 * 头部用的域名改写（纯 ASCII 文本，如 Location / Refresh）。
 * 注意：正文必须用 rewriteBodyBytes()，两者不可混用。
 * @param {string} text
 * @param {string} proxyHost 中继域名
 */
function rewriteHostText(text, proxyHost) {
  if (!text) return text;
  let out = text;
  for (const up of UPSTREAM_DOMAINS) {
    out = out.replace(new RegExp("https?://" + esc(up), "gi"), "https://" + proxyHost);
    out = out.replace(new RegExp("//" + esc(up), "gi"), "//" + proxyHost);
    out = out.replace(new RegExp(esc(up), "gi"), proxyHost);
  }
  out = out.replace(new RegExp("http://" + esc(proxyHost), "gi"), "https://" + proxyHost);
  out = out.replace(new RegExp("http%3A%2F%2F" + esc(proxyHost), "gi"), "https%3A%2F%2F" + proxyHost);
  return out;
}

/**
 * 正文改写流水线。步骤顺序不可随意调整（占位保护必须最先，还原必须在域名替换之后）。
 * @param {Uint8Array} bytes     上游原始响应字节（GBK）
 * @param {string}     proxyHost 中继域名（当前请求的 host）
 * @returns {Uint8Array}
 */
function rewriteBodyBytes(bytes, proxyHost) {
  /* ① 占位保护图片子域：其字样内含 "wenku8.com"，会被第 ② 步误伤成死链 */
  const saved = [];
  for (let idx = 0; idx < PROTECT_DOMAINS.length; idx++) {
    const d = PROTECT_DOMAINS[idx];
    const key = "\u0001" + idx + "\u0001";
    const nb = replaceBytes(bytes, d, key);
    if (nb !== bytes) { saved.push([key, d]); bytes = nb; }
  }

  /* ② 上游域名 → 中继域名 */
  for (const d of UPSTREAM_DOMAINS) bytes = replaceBytes(bytes, d, proxyHost);

  /* ③ 协议统一升级 https（含 URL 编码形式），避免 Android 拦截明文请求 */
  bytes = replaceBytes(bytes, "http://" + proxyHost, "https://" + proxyHost);
  bytes = replaceBytes(bytes, "http%3A%2F%2F" + proxyHost, "https%3A%2F%2F" + proxyHost);

  /* ④ 还原图片子域 */
  for (const [key, d] of saved) bytes = replaceBytes(bytes, key, d);

  /* ⑤ 图片子域 → 本 Worker 反代 /__pic/{i|p}
   *    原图是 http://img.wenku8.com/...（明文 + 跨域 + 无缓存），Android WebView
   *    在 https 页面下会拦混合内容或干等超时。反代后手机只连本域一条 TLS，
   *    图片由 CF 边缘缓存 7 天。注意：带协议的「长串」必须排在裸域名之前。 */
  bytes = replaceBytes(bytes, "https://img.wenku8.com", "https://" + proxyHost + "/__pic/i");
  bytes = replaceBytes(bytes, "http://img.wenku8.com", "https://" + proxyHost + "/__pic/i");
  bytes = replaceBytes(bytes, "https://pic.wenku8.com", "https://" + proxyHost + "/__pic/p");
  bytes = replaceBytes(bytes, "http://pic.wenku8.com", "https://" + proxyHost + "/__pic/p");

  /* ⑥ 第三方统计 / 广告脚本 → 边缘空脚本
   *    hm.baidu.com 是同步 <script>（无 async），会阻塞 HTML 解析 —— 首屏空白主因；
   *    这些域名在手机端常 DNS 慢或不可达，全部就地短路到边缘。
   *    替换顺序：先 https://、再 http://、最后协议相对 //，避免产生 "https:/xxx" 死链。 */
  bytes = replaceBytes(bytes, "https://hm.baidu.com/hm.js", NOOP_ROUTE);
  bytes = replaceBytes(bytes, "http://hm.baidu.com/hm.js", NOOP_ROUTE);
  bytes = replaceBytes(bytes, "//hm.baidu.com/hm.js", NOOP_ROUTE);
  bytes = replaceBytes(bytes, "https://www.clarity.ms/tag/", NOOP_ROUTE + "?t=");
  bytes = replaceBytes(bytes, "https://609999.xyz/ai.js", NOOP_ROUTE);
  bytes = replaceBytes(bytes, "https://609999.xyz/", NOOP_ROUTE + "?");
  bytes = replaceBytes(bytes, "//609999.xyz/", NOOP_ROUTE + "?");
  bytes = replaceBytes(bytes, "https://444495.xyz/", NOOP_ROUTE + "?");
  bytes = replaceBytes(bytes, "//444495.xyz/", NOOP_ROUTE + "?");

  /* ⑦ 剥掉页面自带的 no-cache meta，让 WebView 能复用已下载页面 */
  bytes = replaceBytes(bytes, '<meta http-equiv="Cache-Control" content="no-cache">', "");

  return bytes;
}

/* ============================================================================
 * §4  COOKIE —— Set-Cookie 规范化
 * ----------------------------------------------------------------------------
 *  上游下发 Domain=.wenku8.net 的 cookie，经中继后域名不同，WebView 会拒收；
 *  且同名 cookie（App 的 CookieJar 与 WebView 各持一份）互相覆盖。
 *  处理：按 cookie 名去重（保留最后一条）、剥 Domain/HttpOnly/SameSite、补 Path=/。
 * ==========================================================================*/

/**
 * 规范化 src 的 Set-Cookie 并写入 out。
 * @param {Response} src 上游响应
 * @param {Response} out 将要返回的响应（原地修改）
 */
function normalizeCookies(src, out) {
  const list = src.headers.getSetCookie ? src.headers.getSetCookie() : [];
  if (!list.length) return;
  out.headers.delete("Set-Cookie");
  const byName = new Map();
  for (const raw of list) {
    const name = raw.split("=")[0].trim();
    let v = raw.replace(/;\s*Domain=[^;]*/gi, "");
    v = v.replace(/;\s*HttpOnly/gi, "");
    v = v.replace(/;\s*SameSite=[^;]*/gi, "");
    if (!/;\s*Path=/i.test(v)) v += "; Path=/";
    byName.set(name, v);
  }
  for (const v of byName.values()) out.headers.append("Set-Cookie", v);
}

/* ============================================================================
 * §5  CACHE —— 边缘缓存策略与读写
 * ----------------------------------------------------------------------------
 *  v11 之前对所有响应写 no-cache，导致 css / js / 图片 / 正文每次都走
 *  「手机 → CF 边缘 → 上游」两次往返（~1.2s），这是当时最大的耗时来源。
 *
 *  分级策略：
 *    静态资源            7 天    共享桶（与 Cookie 无关）
 *    正文 / 书籍详情页   10 分钟 按 Cookie 分桶（同一用户一份，绝不串号）
 *    其它公共页          5 分钟  按 Cookie 分桶（v14：登录用户同样命中）
 *    301 / 302           15 秒   按 Cookie 分桶（v14：吸收未登录时首页的重复跳转）
 *    登录 / 书架 / 消息  不缓存
 * ==========================================================================*/

/** 静态资源：按后缀，或按已知静态目录 */
const STATIC_RE = /\.(css|js|mjs|gif|jpe?g|png|webp|svg|ico|bmp|woff2?|ttf|otf|eot|mp3|mp4|webm)$/;
const STATIC_DIR_RE = /^\/(themes|scripts|images|fonts)\//;

/** 正文 / 书籍详情页：同一用户内容稳定，可较长时间分桶缓存 */
const SHARED_RE = /^\/(novel\/.+\.htm|book\/.+\.htm)$|^\/modules\/article\/(reader|articleinfo)\.php$/;

/** 个性化 / 敏感路径：绝不缓存（登录态、书架、私信、搜索等） */
const NO_CACHE_RE =
  /(login|register|logout|my\.php|mybook|bookcase|newmessage|usermessage|usercp|reply|search|ajax|setcookie)/;

/**
 * 计算本次请求的缓存计划。
 * @param {Request} request
 * @param {string}  path 小写化后的 pathname
 * @returns {{isGet:boolean, tier:string, ttl:number, cacheable:boolean}}
 */
function planCache(request, path) {
  const isGet = request.method === "GET" || request.method === "HEAD";
  const isStatic = STATIC_RE.test(path) || STATIC_DIR_RE.test(path);
  const isContent = SHARED_RE.test(path);
  const noCache = NO_CACHE_RE.test(path);
  const isPublic = !noCache && (
    path.startsWith("/novel/") || path.startsWith("/modules/") || path.startsWith("/other/") ||
    path === "/" || path.endsWith(".htm") || path.endsWith(".html") || path.endsWith(".php")
  );

  let tier = "none", ttl = 0;
  if (isStatic)        { tier = "static";   ttl = TTL.STATIC; }
  else if (isContent)  { tier = "content";  ttl = TTL.CONTENT; }
  else if (isPublic)   { tier = "public";   ttl = TTL.PUBLIC; }

  return { isGet, tier, ttl, cacheable: isGet && ttl > 0 };
}

/**
 * djb2 散列：把 Cookie 压成短桶名，避免缓存 key 过长。
 * @param {string} s
 * @returns {string} 36 进制串
 */
function hashStr(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = (((h << 5) + h) + s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

/**
 * 计算 Cookie 分桶名。
 *  - 静态资源为共享资源，固定空桶（否则每个用户都要独立缓存一份，命中率暴跌）
 *  - 优先用 PHPSESSID（登录态唯一标识），退化为整条 Cookie 的散列
 *  - 无 Cookie 时为空桶（匿名用户共享）
 * @param {Request} request
 * @param {boolean} isStatic
 * @returns {string}
 */
function bucketOf(request, isStatic) {
  if (isStatic) return "";
  const cookieRaw = request.headers.get("cookie") || "";
  if (!cookieRaw) return "";
  const psid = /PHPSESSID=([^;,\s]+)/i.exec(cookieRaw);
  return psid ? hashStr(psid[1]) : hashStr(cookieRaw);
}

/**
 * 构造带版本号与分桶的缓存 key。
 * 版本号用于缓存策略调整后一键绕开历史脏条目。
 * @param {Request} request
 * @param {string}  bucket
 * @returns {Request}
 */
function makeCacheKey(request, bucket) {
  const keyUrl = new URL(request.url);
  keyUrl.searchParams.set("__v", CACHE_VERSION);
  if (bucket) keyUrl.searchParams.set("__rb", bucket);
  return new Request(keyUrl.toString(), { method: "GET" });
}

/** 读取缓存（任何异常都视为未命中，绝不影响主链路） */
async function readCache(cacheKey) {
  try {
    const hit = await caches.default.match(cacheKey);
    return hit || null;
  } catch (e) {
    return null;
  }
}

/**
 * 写缓存。
 *
 * ★ 关键陷阱（v12 事故）：Response body 是一次性流。必须在「把响应返回给客户端之前」
 *   同步 clone，若在 ctx.waitUntil 的异步回调里再 clone，只能拿到空 body ——
 *   一旦写进缓存，后续命中就会返回空白页。
 *   因此这里同步 clone 并校验 body 非空，空 body 一律不写。
 *
 * ★ 写缓存前必须剥掉 Set-Cookie，否则命中时会把别人的会话 cookie 发给客户端（串号）。
 *
 * @param {Request}  cacheKey
 * @param {Response} res      即将返回客户端的响应（已含正确头）
 * @param {object}   ctx      Worker execution context（用于 waitUntil）
 * @param {string}   tier     缓存层级（static 时标记 immutable）
 * @param {number}   ttl      缓存秒数
 * @param {boolean}  allowEmpty 允许空 body 落盘。仅 301/302 使用：跳转响应 body 天然为空，
 *                              而 200 文本若为空则说明 clone 时机错了（v12 空白页事故），必须拒绝。
 */
function writeCache(cacheKey, res, ctx, tier, ttl, allowEmpty) {
  res.headers.set(
    "cache-control",
    tier === "static" ? "public, max-age=" + ttl + ", immutable" : "public, max-age=" + ttl
  );

  let snapshot = null;
  try { snapshot = res.clone(); } catch (e) { snapshot = null; }
  if (!snapshot) { res.headers.set("X-Relay-Cache", "NOSTORE"); return; }

  const cleanHeaders = new Headers(res.headers);
  cleanHeaders.delete("Set-Cookie");
  cleanHeaders.delete("set-cookie");

  ctx.waitUntil((async () => {
    try {
      const buf = await snapshot.arrayBuffer();
      if (!allowEmpty && (!buf || !buf.byteLength)) return;   // 200 空 body = clone 时机错误，拒绝落盘
      await caches.default.put(cacheKey, new Response(buf, {
        status: res.status,
        statusText: res.statusText,
        headers: cleanHeaders,
      }));
    } catch (e) {
      /* 写缓存失败不影响主链路 */
    }
  })());
}

/* ============================================================================
 * §6  UPSTREAM —— 回源头与风控重试
 * ----------------------------------------------------------------------------
 *  上游挂 Cloudflare，对数据中心 IP / 异常指纹是「概率性」拦截，同一请求多试
 *  几组身份组合通常就能过；但首次不被拦就应立即停手（v14：命中即 break，
 *  不再为了统计尝试数而继续发请求）。
 *  另有「确定性」拦截：query 含敏感字面参数名（charset=）的页面一律 403，
 *  换身份组合也没用，必须靠参数名打散绕过（v15/v16，见 escapeWafQuery）。
 * ==========================================================================*/

/** 需要特殊处理（改写 Location / 短缓存）的跳转状态码 */
const REDIRECT_STATUS = [301, 302, 303, 307, 308];

/**
 * 回源身份组合。
 *  - sec-fetch-site: App/WebView 自带 same-origin，与中继后的 Host/Referer 不一致
 *    → 上游直接 403，所以必须无条件覆盖。
 */
const VARIANTS = [
  { name: "mobile-none",  site: "none",        referer: "https://" + UPSTREAM + "/",          ua: UA_MOBILE  },
  { name: "mobile-same",  site: "same-origin", referer: "https://" + UPSTREAM + "/index.php", ua: UA_MOBILE  },
  { name: "desktop-none", site: "none",        referer: null,                                 ua: UA_DESKTOP },
];

/**
 * 是否为上游 Cloudflare 的风控拦截页（403 / 503 + 特征字样）。
 * @param {Response} res
 * @returns {Promise<boolean>}
 */
async function isCfBlock(res) {
  if (res.status !== 403 && res.status !== 503) return false;
  if (res.status === 403) return true;
  let text = "";
  try { text = await res.clone().text(); } catch (e) { text = ""; }
  return /cloudflare|attention required|cf-error|cf_chl|just a moment/i.test(text);
}

/**
 * 打散 query 里的敏感参数名，绕过上游 Cloudflare 的字面特征匹配（WAF 规避）。
 *
 *  原理：PHP 会对参数名做 urldecode，因此
 *        /bookcase.php?charset=gbk  与  /bookcase.php?%63harset=gbk 完全等价，
 *        但后者不再命中字面 "charset=" 特征，实测由 403 变为 302。
 *  注意：只动参数名，参数值（gbk / big5）与顺序保持不变。
 * @param {string} search query 串（含前导 ?，可为空串）
 * @param {number} level  1 = 只打散 WAF_TOKENS 命中的参数名（常规，副作用最小）
 *                        2 = 打散全部以字母开头的参数名（兜底，特征词变化时也能绕）
 * @returns {string} 处理后的 query 串
 */
function escapeWafQuery(search, level) {
  if (search.length < 2) return search;              // "" 或 "?"：无需处理
  const pairs = search.slice(1).split("&").map((pair) => {
    const eq = pair.indexOf("=");
    const name = eq < 0 ? pair : pair.slice(0, eq);
    const rest = eq < 0 ? "" : pair.slice(eq);       // 含 = 的剩余部分，值原样保留
    if (!/^[A-Za-z]/.test(name)) return pair;        // 非字母开头（已编码 / 纯数字）不动，避免重复编码
    if (level === 1 && !WAF_TOKENS.includes(name.toLowerCase())) return pair;
    return "%" + name.charCodeAt(0).toString(16) + name.slice(1) + rest;
  });
  return "?" + pairs.join("&");
}

/**
 * 生成回源 URL 候选列表，规避强度递增。
 * 首跳永远用最保守的 level 1，只有它被风控拦下时 fetchUpstream() 才用 level 2 重试。
 * path 与查询值都不变，所以缓存键（仍以客户端原始 URL 计算）不受影响。
 * @param {string} clientUrl 客户端原始 URL
 * @returns {URL[]} 长度 1（无敏感参数名，正常情况）或 2（level 1 与 level 2）
 */
function upstreamTargets(clientUrl) {
  const raw = new URL(clientUrl).search;
  const build = (search) => {
    const u = new URL(clientUrl);
    u.protocol = "https:";                           // 只换协议与 host
    u.host = UPSTREAM;
    u.search = search;
    return u;
  };
  const minimal = build(escapeWafQuery(raw, 1));
  const full = build(escapeWafQuery(raw, 2));
  return minimal.href === full.href ? [minimal] : [minimal, full];
}

/**
 * 构造回源请求头：删除边缘/压缩相关头，并把浏览器指纹字段无条件覆盖。
 * @param {Request} request 客户端原始请求
 * @returns {Headers}
 */
function buildUpstreamHeaders(request) {
  const headers = new Headers(request.headers);
  /* 这些头透传过去会造成：① 指向上一跳的边缘身份泄漏 ② body 与 content-encoding 不符 */
  for (const k of [
    "origin", "host", "referer", "accept-encoding", "dnt", "pragma",
    "cf-connecting-ip", "x-forwarded-for", "x-real-ip", "cf-ipcountry",
    "cf-ray", "cf-visitor", "cdn-loop", "te", "connection", "content-length", "priority",
  ]) headers.delete(k);

  headers.set("Host", UPSTREAM);
  headers.set("User-Agent", UA_MOBILE);
  headers.set("Accept", ACCEPT_HTML);
  headers.set("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
  headers.set("Referer", "https://" + UPSTREAM + "/");
  headers.set("sec-fetch-dest", "document");
  headers.set("sec-fetch-mode", "navigate");
  headers.set("sec-fetch-site", "none");
  headers.set("sec-fetch-user", "?1");
  headers.set("upgrade-insecure-requests", "1");
  headers.set("sec-ch-ua", '"Chromium";v="135", "Not:A-Brand";v="24"');
  headers.set("sec-ch-ua-mobile", "?1");
  headers.set("sec-ch-ua-platform", '"Android"');
  return headers;
}

/**
 * 依次尝试「身份组合 × 规避级别」回源，返回首个未被风控拦下的响应。
 * 第 i 次尝试 = VARIANTS[i] 身份 + targets[min(i, len-1)] 规避级别：
 * 先用最小规避，仍被拦才升级到全面规避，正常请求不会多做改写。
 * @param {Request}  request     客户端原始请求（取 method）
 * @param {URL[]}    targets     回源 URL 候选，见 upstreamTargets()
 * @param {Headers}  baseHeaders 已构造好的回源头，见 buildUpstreamHeaders()
 * @param {ArrayBuffer|null} bodyBuf POST body（只能读一次，已提前缓存）
 * @param {object|undefined} cfOpts 可选的 cf 缓存选项
 * @returns {Promise<{resp:(Response|null), attempts:number, blocked:boolean}>}
 */
async function fetchUpstream(request, targets, baseHeaders, bodyBuf, cfOpts) {
  let resp = null, attempts = 0, blocked = false;
  for (let i = 0; i < VARIANTS.length && i < MAX_ATTEMPTS; i++) {
    const v = VARIANTS[i];
    const target = targets[Math.min(i, targets.length - 1)].toString();
    attempts++;
    const h = new Headers(baseHeaders);
    h.set("sec-fetch-site", v.site);
    if (v.referer) h.set("Referer", v.referer); else h.delete("Referer");
    if (v.ua) h.set("User-Agent", v.ua);

    const r = await fetch(new Request(target, {
      method: request.method,
      headers: h,
      body: bodyBuf,          // POST body 只能读一次，已提前缓存在 bodyBuf
      redirect: "manual",
    }), cfOpts);

    if (await isCfBlock(r)) { blocked = true; continue; }
    resp = r;
    blocked = false;
    break;                    // ★ 首次成功即停手，不再多发请求
  }
  return { resp, attempts, blocked };
}

/* ============================================================================
 * §7  HANDLERS —— 边缘路由与响应组装
 * ==========================================================================*/

/** 边缘空脚本：替换百度统计等同步第三方脚本，消除 HTML 解析阻塞 */
function noopResponse() {
  return new Response("/* noop */", {
    headers: {
      "Content-Type": "application/javascript; charset=utf-8",
      "Cache-Control": "public, max-age=" + TTL.STATIC,
      "Access-Control-Allow-Origin": "*",
    },
  });
}

/**
 * 图片反代：/__pic/<i|p>/<path>?<query> → img|pic.wenku8.com/<path>
 * 让手机只与中继域建立一条 TLS 连接，且图片由边缘缓存 7 天。
 */
async function proxyImage(request, ctx) {
  const u = new URL(request.url);
  const rest = u.pathname.slice(PIC_ROUTE.length);
  const k = rest.indexOf("/");
  const kind = k > 0 ? rest.slice(0, k) : "";
  const p = k > 0 ? rest.slice(k) : "/" + rest;
  const upHost = kind === "p" ? PIC_PREFIX.p : PIC_PREFIX.i;
  const qs = u.search || "";

  const cacheKey = new Request(u.origin + PIC_ROUTE + kind + p + qs, { method: "GET" });
  const hit = await readCache(cacheKey);
  if (hit) {
    const o = new Response(hit.body, hit);
    o.headers.set("X-Relay-Img", upHost);
    o.headers.set("X-Relay-Cache", "HIT");
    applyCors(o);
    return o;
  }

  const ir = await fetch("https://" + upHost + p + qs, {
    headers: {
      "User-Agent": UA_MOBILE,
      "Referer": "https://" + UPSTREAM + "/",
      "Accept": "image/avif,image/webp,image/*,*/*;q=0.8",
    },
    redirect: "follow",
    cf: { cacheEverything: true, cacheTtl: TTL.IMAGE },
  });

  const o = new Response(ir.body, ir);
  o.headers.set("Cache-Control", "public, max-age=" + TTL.IMAGE + ", immutable");
  o.headers.delete("Set-Cookie");
  o.headers.set("X-Relay-Img", upHost);
  o.headers.set("X-Relay-Cache", ir.status === 200 ? "STORE" : "SKIP");
  applyCors(o);
  if (ir.status === 200) writeCache(cacheKey, o, ctx, "static", TTL.IMAGE);
  return o;
}

/**
 * 按上游状态决定是否落缓存，并打 X-Relay-Cache 标记。
 *  200 → 按 tier 分级 TTL；30x → 15 秒短缓存；其余 → 不缓存。
 */
function storeResponse(res, plan, cacheKey, ctx, upstreamStatus) {
  if (!plan.cacheable) {
    res.headers.set("X-Relay-Cache", "BYPASS");
    /* 个性化页（登录/书架/私信）显式禁止中间层缓存，避免登录后仍看到旧页面 */
    if (plan.isGet) res.headers.set("cache-control", "private, no-cache");
    return;
  }
  if (upstreamStatus === 200) {
    res.headers.set("X-Relay-Cache", "STORE");
    writeCache(cacheKey, res, ctx, plan.tier, plan.ttl);
    return;
  }
  if (REDIRECT_STATUS.includes(upstreamStatus) && plan.tier !== "static") {
    res.headers.set("X-Relay-Cache", "STORE-30x");
    writeCache(cacheKey, res, ctx, "redirect", TTL.REDIRECT, true);
    return;
  }
  res.headers.set("X-Relay-Cache", "SKIP");
}

/** 跳转响应：改写 Location、规范化 Cookie，并落 15 秒短缓存 */
function handleRedirect(resp, plan, cacheKey, ctx, proxyHost, attempts, blocked) {
  const out = new Response(resp.body, resp);
  out.headers.delete("Set-Cookie");
  const location = resp.headers.get("Location");
  if (location) out.headers.set("Location", rewriteHostText(location, proxyHost));
  normalizeCookies(resp, out);
  tagDiag(out, attempts, blocked);
  out.headers.delete("content-encoding");
  out.headers.delete("content-length");
  applyCors(out);
  storeResponse(out, plan, cacheKey, ctx, resp.status);
  return out;
}

/** 清理响应头：删掉长度/编码（body 已被改写）与上游的缓存干扰头（由本层接管） */
function cleanOutHeaders(src) {
  const h = new Headers(src.headers);
  for (const k of ["content-encoding", "content-length", "Set-Cookie", "cache-control", "expires", "pragma"]) {
    h.delete(k);
  }
  return h;
}

/** 文本响应：字节级改写后返回（GBK 安全） */
async function handleText(resp, plan, cacheKey, ctx, proxyHost, attempts, blocked) {
  const raw = new Uint8Array(await resp.arrayBuffer());
  const body = rewriteBodyBytes(raw, proxyHost);
  const out = new Response(body, {
    status: resp.status,
    statusText: resp.statusText,
    headers: cleanOutHeaders(resp),
  });
  normalizeCookies(resp, out);
  tagDiag(out, attempts, blocked);
  applyCors(out);
  storeResponse(out, plan, cacheKey, ctx, resp.status);
  return out;
}

/** 二进制响应（字体、附件等）：整体读出以便写入 Cache API */
async function handleBinary(resp, plan, cacheKey, ctx, attempts, blocked) {
  const buf = new Uint8Array(await resp.arrayBuffer());
  const out = new Response(buf.length ? buf : null, {
    status: resp.status,
    statusText: resp.statusText,
    headers: cleanOutHeaders(resp),
  });
  normalizeCookies(resp, out);
  tagDiag(out, attempts, blocked);
  applyCors(out);
  storeResponse(out, plan, cacheKey, ctx, resp.status);
  return out;
}

/* ============================================================================
 *  ENTRY —— Worker 入口
 * ==========================================================================*/
export default {
  /**
   * @param {Request}  request 客户端请求
   * @param {object}   env     绑定（本项目未使用）
   * @param {object}   ctx     execution context，用于 ctx.waitUntil 异步写缓存
   */
  async fetch(request, env, ctx) {
    /* --- 0. CORS 预检，就地作答 --- */
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, HEAD, OPTIONS",
          "Access-Control-Allow-Headers": "*",
        },
      });
    }

    const reqUrl = new URL(request.url);

    /* --- 1. 边缘路由：最先处理，不进上游与缓存逻辑 --- */
    if (reqUrl.pathname === NOOP_ROUTE) return noopResponse();
    if (reqUrl.pathname.startsWith(PIC_ROUTE)) return await proxyImage(request, ctx);

    /* --- 2. 构造回源 URL：只换协议与 host，path/query 原样保留；
           参数名是否需要打散（WAF 规避）由 upstreamTargets() 决定 --- */
    const proxyHost = reqUrl.host;
    const targets = upstreamTargets(request.url);
    if (targets.length > 1) console.log("waf-escape:", targets[0].pathname + targets[0].search);

    /* --- 3. 缓存计划与命中检查 --- */
    const path = targets[0].pathname.toLowerCase();   // 上游路径大小写不敏感
    const plan = planCache(request, path);
    const bucket = bucketOf(request, plan.tier === "static");
    const cacheKey = makeCacheKey(request, bucket);

    if (plan.cacheable) {
      const hit = await readCache(cacheKey);
      if (hit) {
        const out = new Response(hit.body, hit);
        out.headers.set("X-Relay-Cache", "HIT");
        applyCors(out);
        return out;                                   // ★ 命中即返回，零回源
      }
    }

    /* --- 4. 回源准备 --- */
    const baseHeaders = buildUpstreamHeaders(request);
    let bodyBuf = null;
    if (!["GET", "HEAD"].includes(request.method)) bodyBuf = await request.arrayBuffer();

    /* 无 Cookie 的公共请求交给 CF 内置缓存兜底（免费版通常不缓存 HTML，仅作保险） */
    const cfOpts = (!request.headers.has("cookie") && plan.cacheable)
      ? { cf: { cacheEverything: true, cacheTtlByStatus: {
            "200-299": plan.ttl, "301-302": TTL.REDIRECT, "404": 10, "500-599": 0 } } }
      : undefined;

    /* --- 5. 回源（身份组合重试） --- */
    const { resp, attempts, blocked } = await fetchUpstream(
      request, targets, baseHeaders, bodyBuf, cfOpts
    );
    if (!resp) {
      const err = new Response("Upstream blocked by Cloudflare", {
        status: 502,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      });
      err.headers.set("X-Relay-Attempts", String(attempts));
      err.headers.set("X-Relay-Blocked", "1");
      applyCors(err);
      return err;
    }

    /* --- 6. 分流处理 --- */
    if (REDIRECT_STATUS.includes(resp.status)) {
      return handleRedirect(resp, plan, cacheKey, ctx, proxyHost, attempts, blocked);
    }
    const ct = resp.headers.get("Content-Type") || "";
    if (isTexty(ct)) {
      return handleText(resp, plan, cacheKey, ctx, proxyHost, attempts, blocked);
    }
    return handleBinary(resp, plan, cacheKey, ctx, attempts, blocked);
  },
};
