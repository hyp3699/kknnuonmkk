/* tgweb Service Worker：把 <video> 的 Range 请求改写成加密帧流，本地用 WebCrypto 边收边解。
 *
 * 为什么要它：<video> 只会说 HTTP Range / 206 / video/mp4，这些特征走 Cloudflare 一眼就能被识别、
 * 也容易被规则掐。这里把播放链路的“上网”那一半换成我们的私密协议：
 *
 *   <video src="/<WEB_PATH>/media/12/345">     （只在浏览器内部，永远不出网）
 *     └─ 本 SW 拦截 → POST /<WEB_PATH>/api/blob  {c:12,m:345,o:偏移,e:结束}
 *          ← 200 application/octet-stream + 连续帧 [4 字节长度][密文]
 *     └─ 每收到一帧就用 AES-CTR 解密，立刻 enqueue 回给 <video>
 *
 * AES-CTR 的妙处：keystream 只跟“16 字节块号”有关，第 k 帧的 counter 只由它的文件偏移决定，
 * 所以拖进度条可以直接从任意一帧开始解，不用从头下、不用攒整个文件、也不用转码。
 *
 * 服务端对应的实现见 app.py 的 /api/blob（帧格式、counter、nonce 必须与这里严格一致）。
 */
'use strict';

const ENC_VERSION = 1;
const DEFAULT_FRAME = 512 * 1024;      // 每帧明文 512KB，和 Telethon 单块对齐
const DEFAULT_CAP = 2 * 1024 * 1024;     // 单次请求明文上限（2MB = 4 帧），和 app.py 的 ENC_CAP 一致
                                         // 大了会被 Cloudflare 边缘缓冲/524，起播就卡死
const KEY_TTL = 5 * 60 * 1000;         // 会话密钥在 SW 内存里留 5 分钟
const META_TTL = 60 * 1000;            // 视频大小/mime 缓存 1 分钟

// SW 的作用域就是部署路径（例如 /abc123/），所有接口都相对它拼，子路径部署不用改代码。
let BASE = '';
if (typeof self !== 'undefined' && self.registration && typeof self.registration.scope === 'string') {
  try { BASE = new URL(self.registration.scope).pathname.replace(/\/+$/, ''); } catch (e) { BASE = ''; }
}

let keyCache = null;      // {at, kid, key, frame, cap}
let keyPending = null;
const metaCache = new Map();  // "c:m:u" -> {at, size, mime, frame, cap}

function nowMs() { return Date.now(); }

function defaultFetch(url, init) { return fetch(url, init); }

function b64ToBytes(s) {
  if (typeof atob === 'function') {
    const bin = atob(String(s));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i) & 0xff;
    return out;
  }
  return new Uint8Array(Buffer.from(String(s), 'base64'));
}

function concatBytes(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

function readBe32(b, o) {
  return (b[o] & 0xff) * 16777216 + ((b[o + 1] & 0xff) << 16) + ((b[o + 2] & 0xff) << 8) + (b[o + 3] & 0xff);
}

// AES-CTR 计数器块：前 8 字节是这次文件的固定 nonce，后 8 字节是大端块号（块号 = 明文偏移 / 16）。
// 和服务端 app.py 的 _ctr_block 一模一样。块号用两段 32 位整数拼，不用 BigInt（老浏览器也能跑）。
function counterBlock(nonce, blockIndex) {
  const c = new Uint8Array(16);
  c.set(nonce, 0);
  const hi = Math.floor(blockIndex / 4294967296);
  const lo = blockIndex - hi * 4294967296;
  c[8] = (hi >>> 24) & 255; c[9] = (hi >>> 16) & 255; c[10] = (hi >>> 8) & 255; c[11] = hi & 255;
  c[12] = (lo >>> 24) & 255; c[13] = (lo >>> 16) & 255; c[14] = (lo >>> 8) & 255; c[15] = lo & 255;
  return c;
}

// 单帧解密：一帧最多 512KB，一次 subtle.decrypt 就够（这是“分帧”的全部理由——
// 原生 WebCrypto 只能整块解，不能喂无限流）。
async function aesCtrDecrypt(ct, nonce, blockIndex, key) {
  if (!ct || !ct.length) return new Uint8Array(0);
  const buf = await crypto.subtle.decrypt(
    { name: 'AES-CTR', counter: counterBlock(nonce, blockIndex), length: 128 }, key, ct);
  return new Uint8Array(buf);
}

// Range 解析：闭合 0-99 / 开放式 100- / 后缀式 -500，只取第一段（多段 Range 视频播放器基本不发）。
// 开放式按 cap 截断后回 206 + 完整 Content-Range，浏览器需要更多会自己接着要下一段。
function parseRange(header, total, cap) {
  const out = { ok: true, ranged: false, start: 0, end: total - 1, open: false };
  if (header === null || header === undefined || String(header).trim() === '') return out;
  if (!(total > 0)) return { ok: false };
  const m = /^bytes\s*=\s*([^,]+)/i.exec(String(header).trim());
  if (!m) return { ok: false };
  const mm = /^(\d*)-(\d*)$/.exec(m[1].trim());
  if (!mm) return { ok: false };
  const a = mm[1], b = mm[2];
  if (a === '' && b === '') return { ok: false };
  let start, end;
  if (a === '') {
    const n = parseInt(b, 10);
    if (!(n > 0)) return { ok: false };
    start = Math.max(0, total - n);
    end = total - 1;
  } else {
    start = parseInt(a, 10);
    end = b === '' ? total - 1 : parseInt(b, 10);
    out.open = b === '';
  }
  if (!isFinite(start) || !isFinite(end)) return { ok: false };
  if (start < 0 || start >= total || end < start) return { ok: false };
  if (end > total - 1) end = total - 1;
  // 单次最多 cap（服务端 ENC_CAP 同一个值）：闭合 Range 也一样截。
  // 浏览器要多的话会拿着 206 的 Content-Range 接着要下一段，和原来 /stream 的行为一致。
  const limit = cap || DEFAULT_CAP;
  if (end - start + 1 > limit) end = start + limit - 1;
  out.ranged = true;
  out.start = start;
  out.end = end;
  return out;
}

// 会话密钥：只由本 SW 持有，页面 JS 拿不到（两个全局环境隔离），退出登录后服务端不再给。
async function getKeys(opts) {
  const o = opts || {};
  if (!o.force) {
    if (keyCache && nowMs() - keyCache.at < KEY_TTL) return keyCache;
    if (keyPending) return keyPending;
  }
  const base = o.base !== undefined ? o.base : BASE;
  const doFetch = o.fetchImpl || defaultFetch;
  keyPending = (async () => {
    const r = await doFetch(base + '/api/blob-key', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' }, body: '{}'
    });
    if (!r.ok) {
      const e = new Error('blob-key ' + r.status);
      e.code = r.status === 401 ? 'auth' : 'key';
      throw e;
    }
    const d = await r.json();
    const raw = b64ToBytes(d.k);
    const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-CTR' }, false, ['decrypt']);
    keyCache = {
      at: nowMs(), kid: d.kid, key: key,
      frame: d.f || DEFAULT_FRAME, cap: d.cap || DEFAULT_CAP
    };
    return keyCache;
  })();
  try {
    return await keyPending;
  } finally {
    keyPending = null;
  }
}

// 元数据（真实大小 + 真实 mime）也是加密的：网络上只有一段 base64 密文，
// 不会出现 video/mp4 这种字面量。
async function getMeta(opts) {
  const o = opts || {};
  const base = o.base !== undefined ? o.base : BASE;
  const doFetch = o.fetchImpl || defaultFetch;
  const cacheKey = o.channel + ':' + o.msg + ':' + (o.username || '');
  const hit = metaCache.get(cacheKey);
  if (!o.noCache && hit && nowMs() - hit.at < META_TTL) return hit;
  let keys = await getKeys(o);
  let meta = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await doFetch(base + '/api/blob-meta', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ c: o.channel, m: o.msg, u: o.username || null })
    });
    if (!r.ok) {
      // 被 Cloudflare 拦下时也可能是一页 HTML：把状态码带出去，页面上能看出是哪一层挂了。
      const e = new Error('blob-meta http ' + r.status);
      e.code = r.status === 401 ? 'auth' : (r.status === 404 ? 'nf' : 'http');
      throw e;
    }
    const d = await r.json();
    try {
      const pt = await aesCtrDecrypt(b64ToBytes(d.d), b64ToBytes(d.iv), 0, keys.key);
      meta = JSON.parse(new TextDecoder().decode(pt));
      break;
    } catch (err) {
      // 解出来不是 JSON：基本只可能是服务端重启换了密钥（SW 里还是旧钥匙）。
      // 重取一次密钥再试，不行就真报错。
      if (attempt === 0) {
        keys = await getKeys({ base: base, fetchImpl: doFetch, force: true });
        continue;
      }
      throw err;
    }
  }
  const out = {
    at: nowMs(), size: meta.s, mime: meta.t || 'video/mp4',
    frame: meta.f || keys.frame, cap: keys.cap
  };
  if (metaCache.size > 50) metaCache.clear();
  metaCache.set(cacheKey, out);
  return out;
}

// 从服务端把 [start, end] 这段明文的帧一个个解出来，按需产出（pull 一次解一帧，天然背压）。
//
// 一次 POST 只拿服务端单次上限（cap，默认 2MB）那么多：要的比 cap 多（例如没有 Range 的
// 整文件 200 请求）就按 cap 一段一段接着要，每一段都是独立的 POST + 独立 nonce，
// 每段内部从帧首开始解、自己裁掉起点前的字节。
// 为什么不干脆要一个大段：服务端在 cap 处截断，SW 会把“按上限截断”当成“帧流提前结束”报错，
// 视频就一直播不出来——这正是旧版 auto 模式卡在 🔒 加密传输的原因之一。
async function* framePlaintext(ctx) {
  // keys 放在一个可变盒子里：某一段发现服务端换了密钥（重启）时会就地刷新，后面的段跟着用新的。
  const state = { keys: await getKeys(ctx) };
  let cur = ctx.start;
  while (cur <= ctx.end) {
    const F = (state.keys && state.keys.frame) || DEFAULT_FRAME;
    let segEnd = Math.min(ctx.end, cur + ((state.keys && state.keys.cap) || DEFAULT_CAP) - 1);
    // 段尾尽量落在帧边界上：下一段正好从帧首开始，不会把同一帧重复下一遍
    if (segEnd < ctx.end) {
      const aligned = Math.floor((segEnd + 1) / F) * F - 1;
      if (aligned >= cur) segEnd = aligned;
    }
    const want = segEnd - cur + 1;
    let produced = 0;
    for await (const chunk of segmentPlaintext(ctx, state, cur, segEnd)) {
      produced += chunk.length;
      yield chunk;
    }
    if (produced < want) throw new Error('加密帧流提前结束');
    cur = segEnd + 1;
  }
}

function blobInit(ctx, body) {
  const init = {
    method: 'POST', credentials: 'same-origin', cache: 'no-store',
    headers: { 'Content-Type': 'application/json' }, body: body
  };
  // 浏览器取消这条响应时，这个 signal 会把还没下载完的 POST 一起掐掉
  if (ctx.signal) init.signal = ctx.signal;
  return init;
}

function abortError() {
  const e = new Error('已取消');
  e.code = 'abort';
  return e;
}

// 一段（不超过 cap）的明文：一次 POST /api/blob，边读边解边 yield。
async function* segmentPlaintext(ctx, state, start, end) {
  const want = end - start + 1;
  const body = JSON.stringify({ c: ctx.channel, m: ctx.msg, u: ctx.username || null, o: start, e: end });
  let resp = null;
  for (let attempt = 0; ; attempt++) {
    let r;
    try {
      r = await ctx.fetchImpl(ctx.base + '/api/blob', blobInit(ctx, body));
    } catch (e) {
      if (ctx.signal && ctx.signal.aborted) throw abortError();
      const err = new Error('blob 请求失败：' + String((e && e.message) || e));
      err.code = 'net';
      throw err;
    }
    const st = r.headers.get('X-Blob-S');
    const kid = r.headers.get('X-Blob-Kid');
    // 服务端重启过（密钥换了）：重新取一次密钥再开一次，不用让用户重进页面
    if (kid && kid !== state.keys.kid && attempt === 0) {
      try { await r.body.cancel(); } catch (e) { /* 忽略 */ }
      state.keys = await getKeys({ base: ctx.base, fetchImpl: ctx.fetchImpl, force: true });
      continue;
    }
    // 光看 X-Blob-S 不够：被 Cloudflare 拦下时拿到的是 502/524 的 HTML 页或质询页，
    // 既不是 200 也没有 X-Blob-S。绝不能把那种 HTML 当成 4 字节帧长去解析（会解出天量垃圾）。
    if (!r.ok || !st) {
      try { await r.body.cancel(); } catch (e) { /* 忽略 */ }
      const err = new Error('blob http ' + r.status + (st ? ' ' + st : ' 无 X-Blob-S'));
      err.code = r.status === 401 ? 'auth' : 'http';
      throw err;
    }
    if (st !== 'ok') {
      try { await r.body.cancel(); } catch (e) { /* 忽略 */ }
      const err = new Error('blob ' + st);
      err.code = st === 'auth' ? 'auth' : 'nf';
      throw err;
    }
    resp = r;
    break;
  }
  if (!resp.body) throw new Error('blob 没有响应体');
  const keys = state.keys;
  const F = keys.frame || DEFAULT_FRAME;
  // 本次响应的 nonce（服务端每次随机给一个，跟着响应头走）：AES-CTR 绝对不能复用 keystream
  const nHeader = resp.headers.get('X-Blob-N');
  const nonce = nHeader ? b64ToBytes(nHeader) : new Uint8Array(8);
  const frame0 = Math.floor(start / F);
  let pos = frame0 * F;                       // 当前帧在文件里的明文起点（16 的倍数）
  let skip = start - pos;                     // 第一帧前面要裁掉的字节（起点没有 16 对齐时 > 0）
  const reader = resp.body.getReader();
  let carry = new Uint8Array(0);
  function aborted() { return !!(ctx.signal && ctx.signal.aborted); }
  // 从流里精确取 n 个字节（跨 chunk 拼），取不够说明连接提前断了
  async function take(n) {
    while (carry.length < n) {
      if (aborted()) throw abortError();
      let r;
      try {
        r = await reader.read();
      } catch (e) {
        if (aborted()) throw abortError();
        throw e;
      }
      if (r.done) throw new Error('加密帧流提前结束');
      const v = r.value || new Uint8Array(0);
      carry = carry.length ? concatBytes(carry, v) : new Uint8Array(v);
    }
    const out = carry.length === n ? carry : carry.subarray(0, n);
    carry = carry.subarray(n);
    return out;
  }
  try {
    let produced = 0;
    let first = true;
    while (produced < want) {
      const hdr = await take(4);
      const len = readBe32(hdr, 0);
      if (len <= 0 || len > F + 16) throw new Error('帧长度异常：' + len);
      const ct = await take(len);
      const pt = await aesCtrDecrypt(ct, nonce, pos / 16, keys.key);
      pos += pt.length;
      let data = pt;
      if (first) {
        first = false;
        if (skip > 0) {
          if (skip >= data.length) throw new Error('首帧比请求起点还短：' + data.length);
          data = data.subarray(skip);
        }
      }
      const n = Math.min(data.length, want - produced);
      if (n > 0) {
        produced += n;
        yield data.subarray(0, n);
      }
    }
  } finally {
    // 播够/被取消/出错都主动掐掉上游：服务端会因为连接断开停止从 Telegram 下载
    try { await reader.cancel(); } catch (e) { /* 忽略 */ }
  }
}

// 组装给 <video> 的响应：对浏览器来说这就是一个正常的 206 视频响应，
// 但它只在浏览器内部存在，一个字节都没出网。
async function buildMediaResponse(opts) {
  const o = opts || {};
  const base = o.base !== undefined ? o.base : BASE;
  const doFetch = o.fetchImpl || defaultFetch;
  const meta = await getMeta({ base: base, fetchImpl: doFetch, channel: o.channel, msg: o.msg, username: o.username, noCache: o.noCache });
  const total = meta.size;
  if (!(total > 0)) return new Response('', { status: 404 });
  const rg = parseRange(o.rangeHeader, total, meta.cap);
  if (!rg.ok) {
    return new Response('', {
      status: 416, headers: { 'Content-Range': 'bytes */' + total, 'Accept-Ranges': 'bytes' }
    });
  }
  const ctx = {
    base: base, fetchImpl: doFetch, channel: o.channel, msg: o.msg, username: o.username,
    start: rg.start, end: rg.end, signal: null
  };
  // 真实浏览器会主动取消这条流（Chrome 读完 moov 就取消、拖进度条、关掉播放器），
  // 取消时得把还没下完的那个 POST /api/blob 一起 abort：否则旧请求会一直占着服务端的
  // _download_sem 并发槽，连开几个视频就把名额占完，后面全部卡死。
  let abortCtrl = null;
  if (typeof AbortController === 'function') {
    try { abortCtrl = new AbortController(); ctx.signal = abortCtrl.signal; } catch (e) { abortCtrl = null; }
  }
  const gen = framePlaintext(ctx);
  const stream = new ReadableStream({
    async pull(controller) {
      try {
        const r = await gen.next();
        if (r.done) controller.close();
        else controller.enqueue(r.value);
      } catch (e) {
        // 读流中途出的错（上游断流、502/524 被拦成 HTML、帧长异常、服务端重启…）
        // 必须报给页面，否则角标上只剩“🔒 加密传输”，看不出到底哪一层挂了。
        // 用户拖进度条 / 关播放器导致的 abort 不算错误，绝不能拿它去覆盖角标。
        const aborted = (e && e.code === 'abort') || !!(ctx.signal && ctx.signal.aborted);
        if (!aborted) notifyPage((e && e.code) || 'stream', (e && e.message) || String(e));
        try { controller.error(e); } catch (e2) { /* 流已经关掉了 */ }
      }
    },
    cancel() {
      if (abortCtrl) { try { abortCtrl.abort(); } catch (e) { /* 忽略 */ } }
      try {
        const p = gen.return();
        // 正在等的 reader.read() 会因为 abort 而以 AbortError 结束，那个异常会落在
        // 这次 return 的 promise 上；有人接住它，就不会变成未处理的 rejection。
        if (p && typeof p.catch === 'function') p.catch(() => {});
      } catch (e) { /* 忽略 */ }
    }
  }, { highWaterMark: 4 });   // 队列里最多 4 帧（约 2MB），再多就等 <video> 取走，内存不会涨
  const headers = {
    'Content-Type': meta.mime || 'video/mp4',
    'Cache-Control': 'no-store',
    'Accept-Ranges': 'bytes',
    // 长度是确定的（就算得出来），写上它 Chrome 才不用“猜”：
    // 有些内核会校验 206 的长度与 Content-Range 是否一致，不给就报 payload length 不对。
    // 这个头只存在于浏览器内部，不上网。
    'Content-Length': String(rg.end - rg.start + 1)
  };
  if (rg.ranged) headers['Content-Range'] = 'bytes ' + rg.start + '-' + rg.end + '/' + total;
  return new Response(stream, { status: rg.ranged ? 206 : 200, headers: headers });
}

function resetCaches() {
  keyCache = null;
  keyPending = null;
  metaCache.clear();
}

// 页面发来的消息：目前只有“退出网页登录”一条。
// 会话密钥只在 SW 里（页面拿不到，也就删不掉），所以退出时只能由页面通知 SW 自己清：
// 换了账号还留着上一份 keyCache，就会出现“新账号的流拿旧钥匙去解”的情况。
// 抽成纯函数，Node 测试可以直接喂一个假 event 验缓存是否真的清了。
function handleSwMessage(event) {
  if (!event || !event.data || event.data.type !== 'tgweb-logout') return false;
  resetCaches();
  return true;
}

// 把“为什么播不出来”告诉页面：SW 控制台在手机上看不到，页面才能把原因显示出来。
function notifyPage(code, message) {
  try {
    if (typeof self === 'undefined' || !self.clients || typeof self.clients.matchAll !== 'function') return;
    const p = self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (!p || typeof p.then !== 'function') return;
    p.then(function (list) {
      (list || []).forEach(function (c) {
        try { c.postMessage({ type: 'tgweb-enc-error', code: code, message: message }); } catch (e) { /* 忽略 */ }
      });
    }).catch(function () { /* 忽略 */ });
  } catch (e) { /* 忽略 */ }
}

// ---------- Service Worker 接线 ----------
async function handleMedia(request) {
  const url = new URL(request.url);
  const rest = url.pathname.slice((BASE + '/media/').length);
  const parts = rest.split('/');
  const channel = parseInt(parts[0], 10);
  const msg = parseInt(parts[1], 10);
  if (!isFinite(channel) || !isFinite(msg)) return new Response('', { status: 404 });
  const username = url.searchParams.get('username');
  try {
    const resp = await buildMediaResponse({
      channel: channel, msg: msg, username: username,
      rangeHeader: request.headers.get('range')
    });
    if (request.method === 'HEAD') {
      // 只需要头部：把刚建好的流取消掉，不要白占一条下载（HEAD 不发 body）
      try { if (resp.body) await resp.body.cancel(); } catch (e) { /* 忽略 */ }
      return new Response(null, { status: resp.status, headers: resp.headers });
    }
    return resp;
  } catch (e) {
    // 没登录就不再往下走：页面自己的 /api 调用会 401 并弹密码框
    if (e && e.code === 'auth') return new Response('', { status: 401 });
    // 浏览器自己取消了这条响应（拖进度条、关播放器、读完 moov 就撒手）：
    // 这是正常行为，不是“加密失败”，静默回一个 499 就行，绝不 notifyPage。
    if (e && e.code === 'abort') {
      return new Response('', { status: 499, headers: { 'X-Tgweb-Err': 'abort' } });
    }
    const code = String((e && e.code) || 'err');
    const message = String((e && e.message) || e);
    notifyPage(code, message);
    return new Response('', { status: 502, headers: { 'X-Tgweb-Err': code } });
  }
}

if (typeof self !== 'undefined' && typeof self.addEventListener === 'function' && self.registration) {
  self.addEventListener('install', function () {
    // 让新版本立刻进入 waiting -> active，用户不用关两次页面
    self.skipWaiting();
  });
  self.addEventListener('activate', function (event) {
    // 立刻接管已经打开的页面，第一次访问也不用再刷新一次
    event.waitUntil(self.clients.claim());
  });
  self.addEventListener('fetch', function (event) {
    const req = event.request;
    if (req.method !== 'GET' && req.method !== 'HEAD') return;
    let url;
    try { url = new URL(req.url); } catch (e) { return; }
    if (url.origin !== self.location.origin) return;
    if (!url.pathname.startsWith(BASE + '/media/')) return;
    event.respondWith(handleMedia(req));
  });
  // 页面退出网页登录时会 postMessage({type:'tgweb-logout'})：把会话密钥和元数据缓存清掉。
  self.addEventListener('message', function (event) {
    handleSwMessage(event);
  });
}

// Node 里的自动化测试要直接调这些纯逻辑（浏览器里没有 module，这段会被忽略）
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    ENC_VERSION: ENC_VERSION,
    DEFAULT_FRAME: DEFAULT_FRAME,
    DEFAULT_CAP: DEFAULT_CAP,
    b64ToBytes: b64ToBytes,
    readBe32: readBe32,
    counterBlock: counterBlock,
    parseRange: parseRange,
    aesCtrDecrypt: aesCtrDecrypt,
    getKeys: getKeys,
    getMeta: getMeta,
    buildMediaResponse: buildMediaResponse,
    framePlaintext: framePlaintext,
    segmentPlaintext: segmentPlaintext,
    handleMedia: handleMedia,
    notifyPage: notifyPage,
    resetCaches: resetCaches,
    handleSwMessage: handleSwMessage
  };
}
