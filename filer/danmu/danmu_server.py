#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
免 key 弹幕服务（OK影视/FongMi 格式）
/danmu?name=剧名&episode=第N集 -> [{"name","url"}]，url 指向 /xml 返回 B站格式 XML
流程：360影视搜剧名拿到各平台播放页 -> 直接拉平台自己的弹幕
支持：腾讯视频(qq) / 爱奇艺(qiyi) / 芒果TV(imgo) / B站番剧(bilibili1) / 优酷(youku)
      巴哈姆特动画疯(baha，台湾动漫) / B站搬运视频(biliv，台综港综等 360 搜不到的节目)
"""
VERSION = "1.9.2"  # 1.9.2: 配置解析对齐 OK影视（xxxxxxxx** 图片配置、2423 AES 加密配置、;pk;KEY 配置、地址可不带 http://）；1.9.1: 播放记录按片名合并（不同配置/采集站的同一部只留一条，换站继续播）；1.9.0: 网页多配置（像 OK影视 一样添加配置地址，每个配置单独一类，支持图片藏配置/多仓）、聚合搜索；1.8.0: 网页设置(添加/删除/测试采集站、编辑 jjoo.json)、IP 访问限制(白名单/黑名单)、ys 可查看账号密码； 1.7.0: 网页播放器账号密码登录、播放记录(服务器保存，多设备同步)、/sub/jjoo.json 弹幕地址跟随访问域名； 1.6.0: 内置精简网页播放器(端口3003：选采集站/分类/站内搜索/播放+弹幕)； 1.5.0: 兼容弹弹play/danmu_api 接口(MoonTVPlus 网页播放器可直接用)，/sub/ 提供采集站配置文件； 1.4.1: 1.4.1: [代理]整集条目排最前(App 内置抓取器部分平台只拉到第1分钟)； 1.4.0: 新增巴哈姆特动画疯(台湾动漫)、B站搬运视频(台综/港综等)； 1.3.0: 新增优酷弹幕(mtop 签名)； 1.2.0: 先返回平台原始播放页(App 内置抓取器直连拉弹幕)，再返回本服务代理 XML
import os, re, sys, time, json, zlib, html, hmac, secrets, threading, base64, hashlib, urllib.parse
from concurrent.futures import ThreadPoolExecutor
import requests
try:
    import zhconv
except Exception:
    zhconv = None
from flask import Flask, request, Response, jsonify
from urllib.parse import quote

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
S = requests.Session()
S.headers.update({"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
POOL = ThreadPoolExecutor(16)
CACHE, CACHE_TTL, LOCK = {}, 6 * 3600, threading.Lock()
MAX_DM = int(os.environ.get("MAX_DM", "8000"))
app = Flask(__name__)
app.json.ensure_ascii = False

def get(url, **kw):
    kw.setdefault("timeout", 12)
    return S.get(url, **kw)

# ---------------- 搜索 ----------------
def norm(s):
    s = re.sub(r"[\(（\[【].*?[\)）\]】]", "", s or "")
    return re.sub(r"[\s·:：\-_,，.。!！?？'\"]", "", s).lower()

def ep_num(s):
    if not s:
        return None
    m = re.search(r"第\s*(\d+)\s*[集话期]", s) or re.search(r"(?:EP|E|ep|e)\s*(\d+)", s) or re.search(r"(\d+)", s)
    return int(m.group(1)) if m else None

def search360(name):
    j = get("https://api.so.360kan.com/index", params={"force_v": 1, "kw": name, "from": "", "pageno": 1, "v_ap": 1, "tab": "all"}).json()
    data = j.get("data") if isinstance(j, dict) else None
    ld = data.get("longData") if isinstance(data, dict) else None
    rows = (ld.get("rows") if isinstance(ld, dict) else None) or []
    rows = [r for r in rows if str(r.get("cat_id")) in ("1", "2", "3", "4")]
    n = norm(name)
    exact = [r for r in rows if norm(r.get("titleTxt")) == n]
    part = [r for r in rows if r not in exact and n and (n in norm(r.get("titleTxt")) or norm(r.get("titleTxt")) in n)]
    return exact + part

# ---------------- 各平台：分集 ----------------
def iqiyi_tvid(url):
    m = re.search(r"/v_(\w+)\.html", url)
    if not m:
        return None
    n = int(m.group(1), 36) ^ 0x75706971676C
    return n if n >= 900000 else 100 * (n + 900000)

def iqiyi_episodes(url):
    tvid = iqiyi_tvid(url)
    info = get(f"https://pcw-api.iqiyi.com/video/video/baseinfo/{tvid}").json().get("data") or {}
    aid = info.get("albumId")
    if not aid:
        return [url]
    out, page = [], 1
    while page < 10:
        d = get("https://pcw-api.iqiyi.com/albums/album/avlistinfo", params={"aid": aid, "page": page, "size": 200}).json().get("data") or {}
        lst = d.get("epsodelist") or []
        out += [e["playUrl"] for e in sorted(lst, key=lambda e: e.get("order") or 0)]
        if page >= (d.get("page") or 1) or not lst:
            break
        page += 1
    return out or [url]

def mgtv_ids(url):
    m = re.search(r"/b/(\d+)/(\d+)", url)
    return (m.group(1), m.group(2)) if m else (None, None)

def mgtv_episodes(url):
    cid, vid = mgtv_ids(url)
    out, page = [], 1
    while page < 10:
        d = get("https://pcweb.api.mgtv.com/episode/list", params={"video_id": vid, "page": page, "size": 50}).json().get("data") or {}
        for e in d.get("list") or []:
            if str(e.get("isIntact", "1")) == "1":
                out.append(f"https://www.mgtv.com/b/{cid}/{e['video_id']}.html")
        if page >= (d.get("total_page") or 1):
            break
        page += 1
    return out or [url]

def bili_episodes(url):
    m = re.search(r"ep(\d+)", url) or None
    s = re.search(r"ss(\d+)", url)
    params = {"ep_id": m.group(1)} if m else {"season_id": s.group(1)}
    r = get("https://api.bilibili.com/pgc/view/web/season", params=params, headers={"Referer": "https://www.bilibili.com/"}).json().get("result") or {}
    return [f"https://www.bilibili.com/bangumi/play/ep{e['id']}" for e in (r.get("episodes") or [])] or [url]

EXPAND = {"qiyi": iqiyi_episodes, "imgo": mgtv_episodes, "bilibili1": bili_episodes}
SUPPORTED = ("qq", "qiyi", "imgo", "bilibili1", "youku")

def pick_url(row, ep):
    """返回 (site, url)"""
    links = row.get("playlinks") or {}
    series_site = row.get("seriesSite")
    series = [(x.get("url") if isinstance(x, dict) else x) for x in (row.get("seriesPlaylinks") or [])]
    series = [u for u in series if isinstance(u, str) and u.startswith("http")]
    is_movie = str(row.get("cat_id")) == "1"
    idx = (ep or 1) - 1
    if is_movie or not ep:
        for site in SUPPORTED:
            if links.get(site):
                return site, links[site]
        if series_site in SUPPORTED and series:
            return series_site, series[0]
        return None, None
    if str(row.get("cat_id")) == "4" and links.get("bilibili1"):  # 动漫优先 B站，弹幕最多
        try:
            eps = bili_episodes(links["bilibili1"])
            if len(eps) > idx:
                return "bilibili1", eps[idx]
        except Exception as e:
            print("bili expand err", e, flush=True)
    if series_site in SUPPORTED and len(series) > idx:
        return series_site, series[idx]
    for site in ("qiyi", "imgo", "bilibili1"):
        if links.get(site):
            try:
                eps = EXPAND[site](links[site])
                if len(eps) > idx:
                    return site, eps[idx]
            except Exception as e:
                print("expand err", site, e)
    return None, None

# ---------------- 各平台：弹幕 ----------------
# 统一格式: (秒, 模式1滚动/4底/5顶, 颜色int, 文本)
def dm_qq(url):
    vid = re.search(r"/([a-zA-Z0-9]{11})\.html", url).group(1)
    base = get(f"https://dm.video.qq.com/barrage/base/{vid}").json()
    segs = [v["segment_name"] for v in (base.get("segment_index") or {}).values()]
    def one(seg):
        try:
            return get(f"https://dm.video.qq.com/barrage/segment/{vid}/{seg}").json().get("barrage_list") or []
        except Exception:
            return []
    out = []
    for lst in POOL.map(one, segs):
        for b in lst:
            color = 0xFFFFFF
            try:
                st = json.loads(b.get("content_style") or "{}")
                if st.get("color"):
                    color = int(st["color"], 16)
            except Exception:
                pass
            out.append((int(b.get("time_offset", 0)) / 1000, 1, color, b.get("content", "")))
    return out

def dm_qiyi(url):
    t = str(iqiyi_tvid(url))
    def one(i):
        try:
            r = get(f"https://cmts.iqiyi.com/bullet/{t[-4:-2]}/{t[-2:]}/{t}_300_{i}.z")
            if r.status_code != 200:
                return None
            return zlib.decompress(r.content).decode("utf-8", "ignore")
        except Exception:
            return None
    out = []
    for x in POOL.map(one, range(1, 41)):
        if not x:
            continue
        for b in re.findall(r"<bulletInfo>(.*?)</bulletInfo>", x, re.S):
            c = re.search(r"<content>(.*?)</content>", b, re.S)
            st = re.search(r"<showTime>(\d+)</showTime>", b)
            co = re.search(r"<color>([0-9a-fA-F]{6})</color>", b)
            if c and st:
                out.append((int(st.group(1)), 1, int(co.group(1), 16) if co else 0xFFFFFF, html.unescape(c.group(1))))
    return out

def dm_imgo(url):
    cid, vid = mgtv_ids(url)
    def one(minute):
        try:
            d = get("https://galaxy.bz.mgtv.com/rdbarrage", params={"vid": vid, "cid": cid, "time": minute * 60000}).json().get("data") or {}
            return d.get("items") or []
        except Exception:
            return []
    out = []
    for items in POOL.map(one, range(0, 150)):
        for b in items:
            out.append((int(b.get("time", 0)) / 1000, 1, 0xFFFFFF, b.get("content", "")))
    return out

def dm_bili(url):
    ep = re.search(r"ep(\d+)", url).group(1)
    r = get("https://api.bilibili.com/pgc/view/web/season", params={"ep_id": ep}, headers={"Referer": "https://www.bilibili.com/"}).json().get("result") or {}
    cid = next((e["cid"] for e in r.get("episodes", []) if str(e["id"]) == ep), None)
    if not cid:
        return []
    c = get(f"https://comment.bilibili.com/{cid}.xml").content
    try:
        c = zlib.decompress(c, -15)
    except Exception:
        pass
    out = []
    for p, txt in re.findall(r'<d p="([^"]+)">(.*?)</d>', c.decode("utf-8", "ignore"), re.S):
        f = p.split(",")
        out.append((float(f[0]), int(f[1]), int(f[3]), html.unescape(txt)))
    return out

YK = {"cna": None, "tk": None, "ts": 0}
YK_LOCK = threading.Lock()

def yk_vid(url):
    m = re.search(r"id_([A-Za-z0-9=]+)\.html", url) or re.search(r"vid=([A-Za-z0-9=%]+)", url)
    return m.group(1).replace("%3D", "=").replace("%3d", "=") if m else None

def yk_token(force=False):
    with YK_LOCK:
        if force or not YK["tk"] or time.time() - YK["ts"] > 1800:
            YK["cna"] = get("https://log.mmstat.com/eg.js").headers.get("etag", "").strip('"') or YK["cna"] or ""
            S.cookies.set("cna", YK["cna"], domain=".youku.com")
            get("https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/", params={"jsv": "2.5.1", "appKey": "24679788"})
            YK["tk"] = S.cookies.get("_m_h5_tk", domain=".youku.com") or S.cookies.get("_m_h5_tk")
            YK["ts"] = time.time()
        return YK["cna"], YK["tk"]

def yk_seg(vid, mat, retry=True):
    cna, tk = yk_token()
    msg = {"ctime": int(time.time() * 1000), "ctype": 10004, "cver": "v1.0", "guid": cna, "mat": mat, "mcount": 1, "pid": 0, "sver": "3.1.0", "type": 1, "vid": vid}
    b = base64.b64encode(json.dumps(msg, separators=(",", ":")).encode()).decode()
    msg["msg"] = b
    msg["sign"] = hashlib.md5((b + "MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr").encode()).hexdigest()
    data = json.dumps(msg, separators=(",", ":"))
    t = str(int(time.time() * 1000))
    sign = hashlib.md5(f"{(tk or '').split('_')[0]}&{t}&24679788&{data}".encode()).hexdigest()
    j = S.post("https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/", timeout=12, data={"data": data},
               headers={"Referer": "https://v.youku.com"},
               params={"jsv": "2.5.6", "appKey": "24679788", "t": t, "sign": sign, "api": "mopen.youku.danmu.list", "v": "1.0",
                       "type": "originaljson", "dataType": "jsonp", "timeout": "20000", "jsonpIncPrefix": "utility"}).json()
    res = (j.get("data") or {}).get("result")
    if not res:
        if retry and any("TOKEN" in str(x) for x in j.get("ret") or []):
            yk_token(force=True)
            return yk_seg(vid, mat, False)
        return []
    return (json.loads(res).get("data") or {}).get("result") or []

def dm_youku(url):
    vid = yk_vid(url)
    info = get("https://openapi.youku.com/v2/videos/show.json", params={"client_id": "53e6cc67237fc59a", "video_id": vid, "package": "com.huawei.hwvplayer.youku", "ext": "show"}).json()
    minutes = int(float(info.get("duration") or 3600) // 60) + 1
    yk_token()
    def one(i):
        try:
            return yk_seg(vid, i)
        except Exception:
            return []
    out = []
    for lst in POOL.map(one, range(minutes)):
        for b in lst:
            color, mode = 0xFFFFFF, 1
            try:
                pr = json.loads(b.get("propertis") or "{}")
                color = int(pr.get("color", color))
            except Exception:
                pass
            out.append((int(b.get("playat", 0)) / 1000, mode, color, b.get("content", "")))
    return out

# ---------------- 巴哈姆特动画疯（台湾，动漫） ----------------
def to_tw(s):
    return zhconv.convert(s, "zh-tw") if zhconv else s

def baha_search(name, ep):
    """返回 (标题, videoSn) 或 None；只接受标题完全匹配（繁简互转后）"""
    out = []
    for kw in dict.fromkeys([to_tw(name), name]):
        j = get("https://api.gamer.com.tw/mobile_app/anime/v1/search.php", params={"kw": kw}).json()
        n = norm(to_tw(name))
        for a in j.get("anime") or []:
            if norm(to_tw(a.get("title", ""))) == n:
                out.append(a)
        if out:
            break
    if not out:
        return None
    a = out[0]
    info = get("https://api.gamer.com.tw/anime/v1/video.php", params={"videoSn": a["video_sn"]}).json().get("data") or {}
    eps = ((info.get("anime") or {}).get("episodes") or {}).get("0") or []
    if not eps:
        return a["title"], a["video_sn"]
    want = ep or 1
    hit = next((e for e in eps if str(e.get("episode")) == str(want)), None)
    if not hit and len(eps) >= want:
        hit = eps[want - 1]
    return (a["title"], hit["videoSn"]) if hit else None

def dm_baha(url):
    sn = re.search(r"sn=(\d+)", url).group(1)
    lst = (get("https://api.gamer.com.tw/anime/v1/danmu.php", params={"videoSn": sn, "geo": "TW,HK"}).json().get("data") or {}).get("danmu") or []
    out = []
    for b in lst:
        try:
            color = int((b.get("color") or "#FFFFFF").lstrip("#"), 16)
        except Exception:
            color = 0xFFFFFF
        out.append((int(b.get("time", 0)) / 10, {1: 5, 2: 4}.get(b.get("position"), 1), color, b.get("text", "")))
    return out

# ---------------- B站搬运视频（台综/港综等） ----------------
WBI_TAB = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
           37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
WBI = {"key": None, "ts": 0}
BH = {"Referer": "https://www.bilibili.com/"}

def wbi_key():
    if not WBI["key"] or time.time() - WBI["ts"] > 6 * 3600:
        if not S.cookies.get("buvid3"):
            get("https://www.bilibili.com/", headers=BH)
        img = get("https://api.bilibili.com/x/web-interface/nav", headers=BH).json()["data"]["wbi_img"]
        raw = img["img_url"].rsplit("/", 1)[1].split(".")[0] + img["sub_url"].rsplit("/", 1)[1].split(".")[0]
        WBI["key"], WBI["ts"] = "".join(raw[i] for i in WBI_TAB)[:32], time.time()
    return WBI["key"]

def bili_search_video(kw):
    params = {"search_type": "video", "keyword": kw, "wts": int(time.time())}
    params = {k: re.sub(r"[!'()*]", "", str(v)) for k, v in sorted(params.items())}
    params["w_rid"] = hashlib.md5((urllib.parse.urlencode(params) + wbi_key()).encode()).hexdigest()
    j = get("https://api.bilibili.com/x/web-interface/wbi/search/type", params=params, headers=BH).json()
    return (j.get("data") or {}).get("result") or []

def ep_hints(epid):
    """把 OK影视 的集名变成标题里可能出现的写法：日期 20261107 -> 2026.11.07/2026-11-07/20261107/1107；EP626 -> 626"""
    e = epid or ""
    m = re.search(r"(20\d{2})[.\-/年]?(\d{2})[.\-/月]?(\d{2})", e)
    if m:
        y, mo, d = m.groups()
        return [f"{y}.{mo}.{d}", f"{y}-{mo}-{d}", f"{y}{mo}{d}", f"{y}/{mo}/{d}", f"{mo}{d}"], f"{y}.{mo}.{d}"
    n = ep_num(e)
    if n:
        return [f"EP{n}", f"E{n}", f"第{n}集", f"第{n}期", f" {n}"], str(n)
    return [], ""

def biliv_find(name, epid):
    hints, q = ep_hints(epid)
    n_s, n_t = norm(name), norm(to_tw(name))
    best = None
    results = []
    for kw in dict.fromkeys([f"{name} {q}".strip(), name]):
        for _ in range(2):  # B站搜索偶尔首次返回空，重试一次
            results = bili_search_video(kw)
            if results:
                break
            time.sleep(0.5)
        if results:
            break
    for v in results:
        title = html.unescape(re.sub(r"<.*?>", "", v.get("title", "")))
        t = norm(title)
        if n_s not in t and n_t not in t:
            continue
        if hints and not any(h.strip().lower() in title.lower() for h in hints):
            continue
        if not best or (v.get("danmaku") or 0) > (best[2] or 0):
            best = (title, v.get("bvid"), v.get("danmaku"))
    return best

def dm_biliv(url):
    bvid = re.search(r"(BV[0-9A-Za-z]{10})", url).group(1)
    p = re.search(r"[?&]p=(\d+)", url)
    pages = (get("https://api.bilibili.com/x/web-interface/view", params={"bvid": bvid}, headers=BH).json().get("data") or {}).get("pages") or []
    if not pages:
        return []
    cid = pages[int(p.group(1)) - 1 if p and int(p.group(1)) <= len(pages) else 0]["cid"]
    c = get(f"https://comment.bilibili.com/{cid}.xml").content
    try:
        c = zlib.decompress(c, -15)
    except Exception:
        pass
    out = []
    for pp, txt in re.findall(r'<d p="([^"]+)">(.*?)</d>', c.decode("utf-8", "ignore"), re.S):
        f = pp.split(",")
        out.append((float(f[0]), int(f[1]), int(f[3]), html.unescape(txt)))
    return out

FETCH = {"qq": dm_qq, "qiyi": dm_qiyi, "imgo": dm_imgo, "bilibili1": dm_bili, "youku": dm_youku, "baha": dm_baha, "biliv": dm_biliv}

# ---------------- 输出 ----------------
def to_xml(dms):
    dms.sort(key=lambda x: x[0])
    if len(dms) > MAX_DM:
        step = len(dms) / MAX_DM
        dms = [dms[int(i * step)] for i in range(MAX_DM)]
    now = int(time.time())
    out = ['<?xml version="1.0" encoding="UTF-8"?>', "<i>"]
    for t, mode, color, txt in dms:
        txt = (txt or "").strip()
        if txt:
            out.append(f'<d p="{t:.2f},{mode},25,{color},{now},0,0,0">{html.escape(txt, quote=False)}</d>')
    out.append("</i>")
    return "\n".join(out)

EMPTY = '<?xml version="1.0" encoding="UTF-8"?><i></i>'
SITE_NAME = {"qq": "腾讯", "qiyi": "爱奇艺", "imgo": "芒果", "bilibili1": "B站", "youku": "优酷", "baha": "巴哈姆特", "biliv": "B站搬运"}

def resolve(name, epid):
    """返回 [(显示名, site, 平台播放页)]，不拉弹幕，很快"""
    ep = ep_num(epid)
    out = []
    try:
        rows = search360(name)[:3]
    except Exception as e:
        print("360 err", repr(e), flush=True)
        rows = []
    for row in rows:
        try:
            site, url = pick_url(row, ep)
        except Exception as e:
            print("pick err", repr(e), flush=True)
            continue
        if url:
            label = f"{row.get('titleTxt')} {epid or ''} [{SITE_NAME.get(site, site)}]".replace("  ", " ")
            out.append((label, site, url))
    cats = {str(r.get("cat_id")) for r in rows}
    # 动漫或 360 搜不到：再查巴哈姆特（台湾）
    if not out or "4" in cats:
        try:
            b = baha_search(name, ep)
            if b:
                out.append((f"{b[0]} {epid or ''} [巴哈姆特]".replace("  ", " "), "baha", f"https://ani.gamer.com.tw/animeVideo.php?sn={b[1]}"))
        except Exception as e:
            print("baha err", repr(e), flush=True)
    # 综艺或仍然没有：查 B站搬运视频（台综/港综大多在这里有弹幕）
    if not out or "3" in cats:
        try:
            v = biliv_find(name, epid)
            if v:
                out.append((f"{v[0][:40]} [B站搬运]", "biliv", f"https://www.bilibili.com/video/{v[1]}"))
        except Exception as e:
            print("biliv err", repr(e), flush=True)
    return out

def xml_for(site, url):
    key = (site, url)
    with LOCK:
        hit = CACHE.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL:
        return hit[1]
    dms = FETCH[site](url)
    xml = to_xml(dms) if dms else EMPTY
    if dms:
        with LOCK:
            CACHE[key] = (time.time(), xml)
            if len(CACHE) > 500:
                CACHE.pop(next(iter(CACHE)))
    return xml

def arg(k, *alts):
    for x in (k,) + alts:
        v = request.values.get(x)
        if v:
            return v.strip()
    return ""

# OK影视 / FongMi 弹幕接口：返回 JSON 数组 [{"name":..., "url": 弹幕XML地址}]
# 配置写法：  "danmaku": "http://你的IP:2525/danmu?name={name}&episode={episode}"
@app.route("/danmu", methods=["GET", "POST"])
@app.route("/danmaku", methods=["GET", "POST"])
def danmu():
    name, epid = arg("name"), arg("episode", "epid")
    if not name:
        return jsonify([])
    if arg("fmt") == "xml":  # 兼容：直接要 XML
        r = resolve(name, epid)
        return Response(xml_for(r[0][1], r[0][2]) if r else EMPTY, mimetype="application/xml")
    try:
        items = resolve(name, epid)
    except Exception as e:
        print("[danmu] err", name, epid, repr(e), flush=True)
        items = []
    base = public_base()
    proxy = [{"name": label + " [代理]", "url": f"{base}/xml?site={site}&u={quote(url, safe='')}"} for label, site, url in items]
    # FongMi 5.8.x 内置腾讯/爱奇艺/芒果/B站抓取器：直接给平台页面地址，手机直连分段加载，最稳
    native = [] if arg("native") == "0" else [{"name": label, "url": url.split("?")[0] if site == "qq" else (f"https://v.youku.com/v_show/id_{yk_vid(url)}.html" if site == "youku" else url)} for label, site, url in items if site != "baha"]
    # 1.4.1: 内置抓取器常只加载开头一段，自动载入会选第一条 → 整集代理放最前
    res = proxy + native
    print("[danmu]", name, epid, "->", [x["name"] for x in res], flush=True)
    return jsonify(res)


# ---------------- 弹弹play / danmu_api 兼容接口（MoonTVPlus 网页版用） ----------------
# MoonTVPlus 后台「弹幕」填 http://本机:2525 ，token 随便（路径前缀会被忽略）
IDS_FILE = os.environ.get("IDS_FILE", "/opt/danmu/anime_ids.json")
try:
    IDS = json.load(open(IDS_FILE))
except Exception:
    IDS = {}
IDS_LOCK = threading.Lock()

def anime_id(title, cat, count):
    aid = zlib.crc32(f"{title}|{cat}".encode()) % 200000 + 1
    with IDS_LOCK:
        if IDS.get(str(aid)) != [title, cat, count]:
            IDS[str(aid)] = [title, cat, count]
            try:
                json.dump(IDS, open(IDS_FILE, "w"), ensure_ascii=False)
            except Exception:
                pass
    return aid

def ep_count(row):
    if str(row.get("cat_id")) == "1":
        return 1
    n = len(row.get("seriesPlaylinks") or [])
    return n or 100

TYPE_DESC = {"1": ("movie", "电影"), "2": ("tvseries", "电视剧"), "3": ("tvseries", "综艺"), "4": ("tvseries", "动漫")}

def dd_search(keyword):
    try:
        rows = search360(keyword)[:8]
    except Exception:
        rows = []
    animes = []
    for r in rows:
        cat = str(r.get("cat_id"))
        aid = anime_id(r.get("titleTxt") or keyword, cat, ep_count(r))
        t, d = TYPE_DESC.get(cat, ("tvseries", "其他"))
        animes.append({"animeId": aid, "bangumiId": str(aid), "animeTitle": r.get("titleTxt"), "type": t, "typeDescription": d,
                       "imageUrl": r.get("cover"), "startDate": f"{r.get('year') or '2000'}-01-01T00:00:00", "episodeCount": ep_count(r),
                       "rating": 0, "isFavorited": False, "source": "360"})
    if not animes:  # 360 搜不到（台综港综/巴哈）也给一个条目，拉弹幕时走巴哈/B站搬运
        aid = anime_id(keyword, "0", 100)
        animes.append({"animeId": aid, "bangumiId": str(aid), "animeTitle": keyword, "type": "tvseries", "typeDescription": "其他",
                       "episodeCount": 100, "rating": 0, "isFavorited": False, "source": "biliv"})
    return animes

def dd_route(rule, **kw):
    def deco(f):
        app.add_url_rule(rule, f.__name__, f, **kw)
        app.add_url_rule("/<tok>" + rule, f.__name__ + "_tok", f, **kw)
        return f
    return deco

@dd_route("/api/v2/search/anime")
def dd_search_anime(tok=None):
    kw = arg("keyword", "anime")
    return jsonify({"errorCode": 0, "success": True, "errorMessage": "", "animes": dd_search(kw) if kw else []})

@dd_route("/api/v2/search/episodes")
def dd_search_episodes(tok=None):
    kw = arg("anime", "keyword")
    out = []
    for a in (dd_search(kw) if kw else []):
        out.append({"animeId": a["animeId"], "animeTitle": a["animeTitle"], "type": a["type"], "typeDescription": a["typeDescription"],
                    "episodes": dd_eps(a["animeId"])})
    return jsonify({"errorCode": 0, "success": True, "errorMessage": "", "hasMore": False, "animes": out})

def dd_eps(aid):
    title, cat, count = IDS.get(str(aid), ["", "2", 100])
    if cat == "1":
        return [{"episodeId": aid * 10000 + 1, "episodeTitle": "正片", "episodeNumber": "1"}]
    return [{"episodeId": aid * 10000 + i, "episodeTitle": f"第{i}集", "episodeNumber": str(i)} for i in range(1, int(count) + 1)]

@dd_route("/api/v2/bangumi/<int:aid>")
def dd_bangumi(aid, tok=None):
    if str(aid) not in IDS:
        return jsonify({"errorCode": 404, "success": False, "errorMessage": "not found", "bangumi": {"episodes": []}})
    title = IDS[str(aid)][0]
    return jsonify({"errorCode": 0, "success": True, "errorMessage": "",
                    "bangumi": {"animeId": aid, "bangumiId": str(aid), "animeTitle": title, "episodes": dd_eps(aid)}})

@dd_route("/api/v2/match", methods=["POST", "GET"])
def dd_match(tok=None):
    j = request.get_json(silent=True) or {}
    fn = j.get("fileName") or arg("fileName")
    fn = re.sub(r"\.(mp4|mkv|m3u8|flv|avi|ts)$", "", fn or "", flags=re.I)
    m = re.search(r"[Ss]\d+[Ee](\d+)|第\s*(\d+)\s*[集话期]|[\s\-_\.](\d{1,3})(?:\D|$)", fn)
    ep = int(next(g for g in m.groups() if g)) if m else 1
    name = re.split(r"[Ss]\d+[Ee]\d+|第\s*\d+\s*[集话期]|[\s\-_\.]\d{1,3}(?:\D|$)", fn)[0].strip(" .-_") or fn
    a = dd_search(name)[:1]
    if not a:
        return jsonify({"errorCode": 0, "success": True, "isMatched": False, "matches": []})
    a = a[0]
    eid = a["animeId"] * 10000 + (1 if a["type"] == "movie" else ep)
    return jsonify({"errorCode": 0, "success": True, "isMatched": True, "matches": [
        {"episodeId": eid, "animeId": a["animeId"], "animeTitle": a["animeTitle"], "episodeTitle": f"第{ep}集",
         "type": a["type"], "typeDescription": a["typeDescription"], "shift": 0}]})

def host_site(u):
    h = urllib.parse.urlsplit(u).hostname or ""
    if "qq.com" in h: return "qq"
    if "iqiyi" in h: return "qiyi"
    if "mgtv" in h: return "imgo"
    if "youku" in h: return "youku"
    if "gamer.com.tw" in h: return "baha"
    if "bilibili" in h: return "bilibili1" if "/bangumi/" in u else "biliv"
    return None

def xml_to_json(x):
    out = []
    for i, (p, txt) in enumerate(re.findall(r'<d p="([^"]+)">(.*?)</d>', x, re.S)):
        f = p.split(",")
        out.append({"cid": i, "p": f"{f[0]},{f[1]},{f[3]},[hark]", "m": html.unescape(txt)})
    return out

def dd_xml(eid):
    aid, ep = divmod(int(eid), 10000)
    title, cat, _ = IDS.get(str(aid), ["", "", 0])
    if not title:
        return EMPTY
    items = resolve(title, "" if cat == "1" else f"第{ep}集")
    for label, site, url in items:
        try:
            x = xml_for(site, url)
            if x != EMPTY:
                print("[dd]", title, ep, "->", label, flush=True)
                return x
        except Exception as e:
            print("[dd] err", label, repr(e), flush=True)
    return EMPTY

def dd_out(x):
    if arg("format") == "xml":
        return Response(x, mimetype="application/xml")
    c = xml_to_json(x)
    return jsonify({"count": len(c), "comments": c})

@dd_route("/api/v2/comment/<int:eid>")
def dd_comment(eid, tok=None):
    return dd_out(dd_xml(eid))

@dd_route("/api/v2/comment")
def dd_comment_url(tok=None):
    u = arg("url")
    site = host_site(u)
    if not site or site not in FETCH:
        return dd_out(EMPTY)
    try:
        return dd_out(xml_for(site, u))
    except Exception:
        return dd_out(EMPTY)

def public_base():
    proto = request.headers.get("X-Forwarded-Proto") or request.scheme
    host = request.headers.get("X-Forwarded-Host") or request.host
    return f"{proto}://{host}"

# ---------------- 采集站配置文件（VPS 定时生成） ----------------
WWW = os.environ.get("WWW_DIR", "/opt/danmu/www")

@app.route("/sub/<path:fn>")
def sub(fn):
    from flask import send_from_directory
    if fn == "jjoo.json" and os.path.exists(os.path.join(WWW, fn)):
        # 弹幕地址跟随访问的地址：用域名订阅就用域名弹幕，用 IP:端口 就用 IP:端口
        try:
            d = json.load(open(os.path.join(WWW, fn), encoding="utf-8"))
            d["danmaku"] = public_base() + "/danmu?name={name}&episode={episode}"
            return Response(json.dumps(d, ensure_ascii=False, indent=2), mimetype="application/json")
        except Exception as e:
            print("[sub] err", repr(e), flush=True)
    r = send_from_directory(WWW, fn, max_age=300)
    if fn.endswith(".json"):
        r.mimetype = "application/json"
    elif fn.endswith(".txt"):
        r.mimetype = "text/plain"
    return r

@app.route("/xml")
def xml():
    site, url = arg("site"), arg("u")
    if site not in FETCH or not url:
        return Response(EMPTY, mimetype="application/xml")
    try:
        x = xml_for(site, url)
    except Exception as e:
        print("[xml] err", site, url, repr(e), flush=True)
        x = EMPTY
    return Response(x, mimetype="application/xml")

# ---------------- 精简网页播放器（端口 WEB_PORT，默认 3003） ----------------
import xml.etree.ElementTree as ET
WEB_PORT = int(os.environ.get("WEB_PORT", "3003"))
WEB_HTML = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web.html")
SITES_CACHE = [0, 0, []]

# ---------- 网页登录（账号密码存 AUTH_FILE，密码只存哈希；ys 菜单可重置） ----------
DATA_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_FILE = os.environ.get("AUTH_FILE", os.path.join(DATA_DIR, "web_auth.json"))
HIST_FILE = os.environ.get("HIST_FILE", os.path.join(DATA_DIR, "web_history.json"))
AUTH_CACHE = [None, None]
FAILS, HLOCK = {}, threading.Lock()

def pw_hash(salt, pw):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 100000).hex()

def set_auth(user, pw):
    salt = secrets.token_hex(8)
    d = {"user": user, "pass": pw, "salt": salt, "hash": pw_hash(salt, pw), "secret": secrets.token_hex(16)}
    tmp = AUTH_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, AUTH_FILE)

def auth_conf():
    try:
        mt = os.path.getmtime(AUTH_FILE)
    except Exception:
        return None
    if AUTH_CACHE[0] != mt:
        try:
            AUTH_CACHE[1] = json.load(open(AUTH_FILE))
            AUTH_CACHE[0] = mt
        except Exception:
            return None
    return AUTH_CACHE[1]

def auth_token(c):
    return hmac.new(c["secret"].encode(), (c["user"] + c["hash"]).encode(), "sha256").hexdigest()

def authed():
    c = auth_conf()
    if not c:
        return True  # 没设账号就不拦（deploy/ys 会创建）
    t = request.cookies.get("ys_auth", "")
    return bool(t) and hmac.compare_digest(t, auth_token(c))

def client_ip():
    ra = request.remote_addr or ""
    if ra.startswith("127.") or ra == "::1":
        return request.headers.get("X-Real-IP") or (request.headers.get("X-Forwarded-For", "").split(",")[0].strip()) or ra
    return ra

LOGIN_HTML = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 · 哈哈影视</title><style>body{margin:0;background:#111;color:#eee;font:15px -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center}
form{width:min(320px,88vw);display:flex;flex-direction:column;gap:12px}h1{font-size:22px;text-align:center;margin:0 0 8px}
input,button{font:inherit;color:#eee;background:#222;border:1px solid #333;border-radius:10px;padding:12px}button{background:#e50914;border-color:#e50914;cursor:pointer}
#e{color:#f66;text-align:center;min-height:1.2em;font-size:13px}</style></head><body>
<form id="f"><h1>哈哈影视</h1><input id="u" placeholder="账号" autocomplete="username" required><input id="p" type="password" placeholder="密码" autocomplete="current-password" required>
<button>登录</button><div id="e"></div></form><script>
f.onsubmit=async e=>{e.preventDefault();document.getElementById('e').textContent='';
const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({u:u.value,p:p.value})});
const d=await r.json().catch(()=>({}));if(r.ok&&d.ok)location.replace('/');else document.getElementById('e').textContent=d.msg||'登录失败'}
</script></body></html>"""

# ---------- IP 访问限制（ACL_FILE：{"web":{"mode":"off|allow|deny","ips":[...]},"danmu":{...}}，ys 菜单设置） ----------
import ipaddress
ACL_FILE = os.environ.get("ACL_FILE", os.path.join(DATA_DIR, "acl.json"))
ACL_CACHE = [None, {}]

def acl_conf():
    try:
        mt = os.path.getmtime(ACL_FILE)
    except Exception:
        return {}
    if ACL_CACHE[0] != mt:
        try:
            ACL_CACHE[1] = json.load(open(ACL_FILE)); ACL_CACHE[0] = mt
        except Exception:
            ACL_CACHE[1] = {}
    return ACL_CACHE[1]

def ip_in(ip, nets):
    try:
        a = ipaddress.ip_address(ip.split("%")[0])
    except Exception:
        return False
    if getattr(a, "ipv4_mapped", None):
        a = a.ipv4_mapped
    for n in nets:
        try:
            if a in ipaddress.ip_network(str(n).strip(), strict=False):
                return True
        except Exception:
            pass
    return False

def acl_ok(scope):
    c = (acl_conf() or {}).get(scope) or {}
    mode = c.get("mode", "off")
    if mode not in ("allow", "deny"):
        return True
    ip = client_ip()
    ra = request.remote_addr or ""
    # 本机直连（ys 状态检查、MoonTV 容器）始终放行
    if ip == ra and ip_in(ra, ["127.0.0.0/8", "::1/128", "172.16.0.0/12"]):
        return True
    hit = ip_in(ip, c.get("ips") or [])
    return hit if mode == "allow" else not hit

def is_web_path(p):
    return p in ("/web", "/px", "/hls.js", "/login", "/logout") or (p.startswith("/api/") and not p.startswith("/api/v2/"))

@app.before_request
def web_guard():
    on_web = request.environ.get("SERVER_PORT") == str(WEB_PORT)
    p = request.path
    if not acl_ok("web" if on_web else "danmu"):
        print("[acl] deny", "web" if on_web else "danmu", client_ip(), p, flush=True)
        return "403 forbidden: your IP is not allowed", 403
    if not on_web:
        if is_web_path(p):  # 网页接口只在网页端口开放，弹幕端口 2525 不能绕过登录
            return "not found", 404
        return None
    if p in ("/login", "/hls.js", "/favicon.ico"):
        return None
    if authed():
        return None
    if p.startswith("/api/") or p == "/px":
        return jsonify({"error": "login"}), 401
    return Response(LOGIN_HTML, mimetype="text/html")

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return Response(LOGIN_HTML, mimetype="text/html")
    ip, now = client_ip(), time.time()
    with HLOCK:
        n, t = FAILS.get(ip, (0, 0))
        if now - t > 600:
            n = 0
        if n >= 5:
            return jsonify({"ok": False, "msg": "错误次数太多，10 分钟后再试"}), 429
    j = request.get_json(silent=True) or request.form
    u, pw = str(j.get("u", "")), str(j.get("p", ""))
    c = auth_conf()
    if c and hmac.compare_digest(u, c["user"]) and hmac.compare_digest(pw_hash(c["salt"], pw), c["hash"]):
        with HLOCK:
            FAILS.pop(ip, None)
        r = jsonify({"ok": True})
        https = (request.headers.get("X-Forwarded-Proto") or request.scheme) == "https"
        r.set_cookie("ys_auth", auth_token(c), max_age=30 * 86400, httponly=True, samesite="Lax", secure=https)
        return r
    with HLOCK:
        FAILS[ip] = (n + 1, now)
    time.sleep(1)
    print("[web] login fail", ip, flush=True)
    return jsonify({"ok": False, "msg": "账号或密码错误"}), 403

@app.route("/logout")
def logout():
    from flask import redirect
    r = redirect("/")
    r.delete_cookie("ys_auth")
    return r

# ---------- 播放记录（服务器保存，手机/电脑同步） ----------
def hist_load():
    try:
        return json.load(open(HIST_FILE, encoding="utf-8"))
    except Exception:
        return []

def hist_save(h):
    tmp = HIST_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(h, f, ensure_ascii=False)
    os.replace(tmp, HIST_FILE)

def hname(n):
    return re.sub(r"[\W_]+", "", str(n or "")).lower()

def hist_merge(h):
    """同一片名只留最新一条（不分配置、采集站）"""
    seen, out = set(), []
    for x in sorted(h, key=lambda x: -int(x.get("ts") or 0)):
        k = hname(x.get("name")) or f'{x.get("key")}|{x.get("id")}'
        if k not in seen:
            seen.add(k); out.append(x)
    return out

@app.route("/api/history", methods=["GET", "POST", "DELETE"])
def api_history():
    with HLOCK:
        h = hist_load()
        if request.method == "GET":
            key, vid, nm = arg("key"), arg("id"), hname(arg("name"))
            if key:
                r = next((x for x in h if x.get("key") == key and str(x.get("id")) == vid), None)
                if not r and nm:
                    r = next((x for x in h if hname(x.get("name")) == nm), None)
                return jsonify(r)
            m = hist_merge(h)
            if len(m) != len(h):
                hist_save(m)
            return jsonify(m)
        if request.method == "DELETE":
            key, vid = arg("key"), arg("id")
            h = [x for x in h if key and not (x.get("key") == key and str(x.get("id")) == vid)]
            hist_save(h)
            return jsonify({"ok": True})
        j = request.get_json(silent=True) or {}
        if not j.get("key") or not j.get("id"):
            return jsonify({"ok": False}), 400
        keep = ("key", "id", "site", "name", "pic", "f", "e", "en", "t", "dur")
        rec = {k: j.get(k) for k in keep if j.get(k) is not None}
        rec["id"] = str(rec["id"])
        rec["ts"] = int(time.time())
        nm = hname(rec.get("name"))
        h = [rec] + [x for x in h if not (x.get("key") == rec["key"] and str(x.get("id")) == rec["id"]) and not (nm and hname(x.get("name")) == nm)]
        hist_save(h[:300])
        return jsonify({"ok": True})

def web_sites():
    p = os.path.join(WWW, "jjoo.json")
    try:
        mt = os.path.getmtime(p)
    except Exception:
        return SITES_CACHE[2]
    if mt != SITES_CACHE[0]:
        try:
            d = json.load(open(p, encoding="utf-8"))
            SITES_CACHE[2] = [{"key": s.get("key"), "name": s.get("name"), "api": s.get("api"), "type": s.get("type")}
                              for s in d.get("sites", []) if s.get("type") in (0, 1) and str(s.get("api", "")).startswith("http")]
            SITES_CACHE[0] = mt
        except Exception as e:
            print("[web] sites err", repr(e), flush=True)
    return SITES_CACHE[2]

# ---------- 多配置：jjoo 内置 + 用户添加的配置地址（每个配置单独一类） ----------
CONFIGS_FILE = os.environ.get("CONFIGS_FILE", os.path.join(DATA_DIR, "web_configs.json"))
CFG_CACHE = {}  # id -> (ts, sites, total, err)

def cfg_list():
    try:
        return json.load(open(CONFIGS_FILE, encoding="utf-8"))
    except Exception:
        return []

def cfg_save(lst):
    tmp = CONFIGS_FILE + ".tmp"
    json.dump(lst, open(tmp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    os.replace(tmp, CONFIGS_FILE)

def loose_json(t):
    t = t.lstrip("\ufeff").strip()
    try:
        return json.loads(t)
    except Exception:
        pass
    out, i, n, instr = [], 0, len(t), False   # 去掉 // 和 /* */ 注释（不动字符串里的）、尾逗号
    while i < n:
        c = t[i]
        if instr:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(t[i + 1]); i += 2; continue
            if c == '"': instr = False
        elif c == '"':
            instr = True; out.append(c)
        elif t.startswith("//", i):
            j = t.find("\n", i); i = n if j < 0 else j; continue
        elif t.startswith("/*", i):
            j = t.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        else:
            out.append(c)
        i += 1
    return json.loads(re.sub(r",\s*([}\]])", r"\1", "".join(out)))

def _aes_dec(mode, key, data, iv=b""):
    import subprocess
    cmd = ["openssl", "enc", "-d", f"-aes-128-{mode}", "-K", key.hex()] + (["-iv", iv.hex()] if mode == "cbc" else [])
    p = subprocess.run(cmd, input=data, capture_output=True, timeout=20)
    if p.returncode:
        raise ValueError("解密失败")
    return p.stdout

def decode_config(b, key=""):
    """与 OK影视(FongMi Decoder) 一致：明文 JSON / xxxxxxxx**base64(常藏在图片尾) / 2423 开头 AES-CBC / ;pk;KEY 的 AES-ECB"""
    import base64
    if isinstance(b, str):
        b = b.encode("utf-8")
    t = b.decode("utf-8", "ignore").strip().lstrip("\ufeff")
    if t[:1] in "{[":
        return loose_json(t)
    m = re.search(rb"[A-Za-z0-9]{8}\*\*", b)
    if m:
        x = re.sub(r"\s", "", b[m.end():].decode("latin1"))
        t = base64.b64decode(x + "=" * (-len(x) % 4)).decode("utf-8", "ignore").strip()
        if t[:1] in "{[":
            return loose_json(t)
    if t.startswith("2423"):
        raw = bytes.fromhex(re.sub(r"[^0-9a-fA-F]", "", t))
        dec = raw.decode("latin1").lower()
        k = (dec[dec.index("$#") + 2: dec.index("#$")] + "0" * 16)[:16].encode("latin1")
        iv = (dec[-13:] + "0" * 16)[:16].encode("latin1")
        h = re.sub(r"[^0-9a-fA-F]", "", t)
        body = bytes.fromhex(h[h.index("2324") + 4: len(h) - 26])
        return loose_json(_aes_dec("cbc", k, body, iv).decode("utf-8", "ignore"))
    if key:
        kk = (key + "0" * 16)[:16].encode()
        try:
            body = bytes.fromhex(t)
        except Exception:
            body = base64.b64decode(t + "=" * (-len(t) % 4))
        return loose_json(_aes_dec("ecb", kk, body).decode("utf-8", "ignore"))
    if re.fullmatch(r"[A-Za-z0-9+/=\s]+", t[:4000] or "x"):
        try:
            x = re.sub(r"\s", "", t)
            return loose_json(base64.b64decode(x + "=" * (-len(x) % 4)).decode("utf-8", "ignore"))
        except Exception:
            pass
    if "<html" in t[:2000].lower():
        raise ValueError("地址返回的是网页，不是配置（可能地址已失效，或要换成 /tv 之类的完整地址）")
    raise ValueError("看不懂这个配置（不是 JSON）")

def fetch_config(url):
    u = url.strip()
    key = ""
    if ";" in u:  # OK影视 的 地址;pk;密钥 写法
        parts = u.split(";")
        u, key = parts[0], (parts[2] if len(parts) > 2 else "")
    if not re.match(r"https?://", u, re.I):
        u = "http://" + u
    try:
        sp = urllib.parse.urlsplit(u)
        if sp.hostname and not sp.hostname.isascii():
            u = urllib.parse.urlunsplit(sp._replace(netloc=sp.netloc.replace(sp.hostname, sp.hostname.encode("idna").decode())))
    except Exception:
        pass
    r = S.get(u, headers={"User-Agent": "okhttp/3.12.13"}, timeout=15, verify=False, allow_redirects=True)
    r.raise_for_status()
    try:
        d = decode_config(r.content, key)
    except json.JSONDecodeError:
        raise ValueError("配置内容格式有错，解析不了")
    if not isinstance(d, dict):
        raise ValueError("配置格式不对")
    return d, r.url

def config_sites(d, base):
    out = []
    for s in d.get("sites") or []:
        api = str(s.get("api") or "").strip()
        if s.get("type") in (0, 1) and api:
            if not api.startswith("http"):
                api = urllib.parse.urljoin(base, api)
            if api.startswith("http"):
                out.append({"key": str(s.get("key") or s.get("name")), "name": str(s.get("name") or s.get("key")), "api": api, "type": s.get("type")})
    return out

def cfg_sites(cid, force=False):
    """返回 (sites, total, err)"""
    if cid in ("", "jjoo"):
        ss = web_sites()
        return ss, len(ss), ""
    c = next((x for x in cfg_list() if x.get("id") == cid), None)
    if not c:
        return [], 0, "配置不存在"
    hit = CFG_CACHE.get(cid)
    if hit and not force and time.time() - hit[0] < 1800:
        return hit[1], hit[2], hit[3]
    try:
        d, final = fetch_config(c["url"])
        ss = [dict(x, key=f"{cid}:{x['key']}") for x in config_sites(d, final)]
        res = (time.time(), ss, len(d.get("sites") or []), "")
    except Exception as e:
        if hit:  # 拉取失败沿用上次
            return hit[1], hit[2], hit[3]
        res = (time.time() - 1500, [], 0, ("加载失败：" + (str(e) or type(e).__name__))[:120])
    CFG_CACHE[cid] = res
    return res[1], res[2], res[3]

def find_site(key):
    key = key or ""
    if ":" in key:
        cid = key.split(":", 1)[0]
        if any(x.get("id") == cid for x in cfg_list()):
            return next((s for s in cfg_sites(cid)[0] if s["key"] == key), None)
    return next((s for s in web_sites() if s["key"] == key), None)

@app.route("/api/configs", methods=["GET", "POST"])
def api_configs():
    if request.method == "GET":
        out = [{"id": "jjoo", "name": "jjoo（内置）", "url": "", "builtin": 1}] + cfg_list()
        if arg("count"):
            for c in out:
                ss, total, err = cfg_sites(c["id"])
                c.update(usable=len(ss), total=total, err=err)
        return jsonify(out)
    j = request.get_json(silent=True) or {}
    url, name = str(j.get("url", "")).strip(), str(j.get("name", "")).strip()
    if not url:
        return jsonify({"ok": False, "msg": "先填配置地址"}), 400
    if not re.match(r"https?://", url, re.I):
        url = "http://" + url
    try:
        d, final = fetch_config(url)
    except Exception as e:
        print("[cfg] add err", url, repr(e), flush=True)
        msg = str(e) or type(e).__name__
        if "NameResolution" in msg or "getaddrinfo" in msg:
            msg = "域名解析不了（地址写错或已失效）"
        elif "Timeout" in msg or "timed out" in msg:
            msg = "连接超时（服务器连不上这个地址）"
        elif "ConnectionError" in type(e).__name__ or "Max retries" in msg:
            msg = "连接失败（服务器连不上这个地址）"
        elif "HTTPError" in type(e).__name__:
            msg = "地址返回 " + msg.split(" for url")[0]
        return jsonify({"ok": False, "msg": "配置打不开：" + msg[:150]}), 400
    lst = cfg_list(); added = []
    subs = [(str(x.get("name") or ""), str(x.get("url") or "")) for x in (d.get("urls") or []) if isinstance(x, dict)] if isinstance(d, dict) else []
    items = subs[:30] if subs and not d.get("sites") else [(name, url)]
    for nm, u in items:
        if not u or any(x.get("url") == u for x in lst):
            continue
        n = 1
        while any(x.get("id") == f"c{n}" for x in lst):
            n += 1
        nm = nm or urllib.parse.urlsplit(u).hostname or f"配置{n}"
        lst.append({"id": f"c{n}", "name": nm, "url": u}); added.append(f"c{n}")
    if not added:
        return jsonify({"ok": False, "msg": "这个配置已经添加过了"}), 400
    cfg_save(lst)
    usable = total = 0
    for cid in added:
        ss, t, _ = cfg_sites(cid, force=True); usable += len(ss); total += t
    return jsonify({"ok": True, "ids": added, "usable": usable, "total": total, "multi": len(added) > 1})

@app.route("/api/configs/del", methods=["POST"])
def api_configs_del():
    cid = (request.get_json(silent=True) or {}).get("id")
    lst = [x for x in cfg_list() if x.get("id") != cid]
    cfg_save(lst); CFG_CACHE.pop(cid, None)
    return jsonify({"ok": True})

def xml_vod(text):
    root = ET.fromstring(text.strip().encode("utf-8") if isinstance(text, str) else text)
    lst = root.find("list")
    out = {"class": [], "list": [], "page": 1, "pagecount": 1}
    if lst is not None:
        out["page"] = int(lst.get("page") or 1)
        out["pagecount"] = int(lst.get("pagecount") or 1)
        for v in lst.findall("video"):
            g = lambda k: (v.findtext(k) or "").strip()
            dds = v.findall("./dl/dd")
            out["list"].append({"vod_id": g("id"), "vod_name": g("name"), "vod_pic": g("pic"), "vod_remarks": g("note"),
                                "type_name": g("type"), "vod_year": g("year"), "vod_content": g("des"),
                                "vod_play_from": "$$$".join(d.get("flag") or "播放" for d in dds),
                                "vod_play_url": "$$$".join((d.text or "").strip() for d in dds)})
    cl = root.find("class")
    if cl is not None:
        out["class"] = [{"type_id": t.get("id"), "type_name": (t.text or "").strip()} for t in cl.findall("ty")]
    return out

def vod_call(site, **params):
    sp = urllib.parse.urlsplit(site["api"])
    q = dict(urllib.parse.parse_qsl(sp.query))
    q.update({k: v for k, v in params.items() if v not in (None, "")})
    r = get(urllib.parse.urlunsplit(sp._replace(query="")), params=q, timeout=10, verify=False)
    r.encoding = r.encoding if r.encoding and r.encoding.lower() != "iso-8859-1" else "utf-8"
    t = r.text
    if site["type"] == 0 or t.lstrip().startswith("<"):
        return xml_vod(t)
    try:
        j = json.loads(t)
    except Exception:
        raise ValueError(re.sub(r"<[^>]+>", "", t)[:60].strip() or "接口返回异常")
    return {"class": j.get("class") or [], "list": j.get("list") or [],
            "page": int(j.get("page") or 1), "pagecount": int(j.get("pagecount") or 1)}

@app.route("/api/sites")
def api_sites():
    ss, total, err = cfg_sites(arg("cfg") or "jjoo", force=bool(arg("refresh")))
    if arg("full"):
        return jsonify([{"key": s["key"], "name": s["name"], "api": s["api"], "type": s["type"]} for s in ss])
    if arg("meta"):
        return jsonify({"sites": [{"key": s["key"], "name": s["name"]} for s in ss], "total": total, "err": err})
    return jsonify([{"key": s["key"], "name": s["name"]} for s in ss])

# ---------- 网页设置：采集站增删、测试、编辑 jjoo.json ----------
CONF_LOCK = threading.Lock()
TOOLS_DIR = os.path.join(DATA_DIR, "tools")
BLOCK_FILE = os.path.join(TOOLS_DIR, "blocked.json")
_US = [None]

def us():
    """复用采集站脚本里的文本级增删（保留 jjoo.json 原格式）和链接规范化"""
    if _US[0] is None:
        import importlib.util
        for p in (os.path.join(TOOLS_DIR, "update_sites.py"), os.path.join(DATA_DIR, "..", "tools", "update_sites.py")):
            if os.path.exists(p):
                spec = importlib.util.spec_from_file_location("update_sites", p)
                m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
                _US[0] = m
                break
    if _US[0] is None:
        raise RuntimeError("缺少 tools/update_sites.py，请重新安装")
    return _US[0]

def jj_path():
    return os.path.join(WWW, "jjoo.json")

def jj_write(raw):
    json.loads(raw)
    p = jj_path()
    if os.path.exists(p):
        try:
            import shutil; shutil.copy(p, p + ".bak")
        except Exception:
            pass
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(raw)
    os.replace(tmp, p)

def block_update(add=(), remove=()):
    try:
        b = set(json.load(open(BLOCK_FILE)))
    except Exception:
        b = set()
    b |= set(add); b -= set(remove)
    os.makedirs(TOOLS_DIR, exist_ok=True)
    json.dump(sorted(b), open(BLOCK_FILE, "w"), ensure_ascii=False, indent=1)

def site_apis(raw):
    try:
        return {str(x.get("api")) for x in json.loads(raw).get("sites", []) if str(x.get("api", "")).startswith("http")}
    except Exception:
        return set()

@app.route("/api/conf", methods=["GET", "POST"])
def api_conf():
    if request.method == "GET":
        try:
            return Response(open(jj_path(), encoding="utf-8").read(), mimetype="text/plain")
        except Exception:
            return Response("", mimetype="text/plain")
    text = (request.get_json(silent=True) or {}).get("text", "")
    try:
        d = json.loads(text)
        assert isinstance(d.get("sites"), list)
    except Exception as e:
        return jsonify({"ok": False, "msg": "JSON 格式错误或缺少 sites：" + str(e)[:120]}), 400
    with CONF_LOCK:
        try:
            old = open(jj_path(), encoding="utf-8").read()
        except Exception:
            old = ""
        jj_write(text)
        try:
            m = us(); gone = site_apis(old) - site_apis(text)
            block_update(add=[m.norm(a) for a in gone], remove=[m.norm(a) for a in site_apis(text)])
        except Exception as e:
            print("[conf] block err", repr(e), flush=True)
    return jsonify({"ok": True})

def detect_type(api):
    r = get(api.split("?")[0] + ("?" + api.split("?", 1)[1] + "&" if "?" in api else "?") + "ac=list", timeout=10, verify=False)
    t = r.text.lstrip("\ufeff").lstrip()
    if t.startswith("<"):
        xml_vod(t); return 0
    json.loads(t); return 1

@app.route("/api/site", methods=["POST"])
def api_site_add():
    j = request.get_json(silent=True) or {}
    name, api = str(j.get("name", "")).strip(), str(j.get("api", "")).strip()
    if not re.match(r"https?://", api):
        return jsonify({"ok": False, "msg": "接口地址要以 http:// 或 https:// 开头"}), 400
    try:
        typ = int(j["type"]) if str(j.get("type", "")) in ("0", "1") else detect_type(api)
    except Exception as e:
        return jsonify({"ok": False, "msg": "接口打不开或不是苹果CMS接口：" + str(e)[:80]}), 400
    with CONF_LOCK:
        m = us(); raw = open(jj_path(), encoding="utf-8").read()
        d = json.loads(raw); k = m.norm(api)
        for x in d.get("sites", []):
            if str(x.get("api", "")).startswith("http") and m.norm(x["api"]) == k:
                return jsonify({"ok": False, "msg": "已存在：" + str(x.get("name"))}), 400
        name = name or (urllib.parse.urlsplit(api).hostname or "新接口")
        keys = {x.get("key") for x in d.get("sites", [])}
        key = name
        while key in keys:
            key += "_"
        o = {"key": key, "name": name, "type": typ, "api": api, "searchable": 1, "quickSearch": 1, "filterable": 0}
        adult = "🔞" in name
        raw = m.insert_sites(raw, [o], before_adult=not adult)
        jj_write(raw)
        block_update(remove=[k])
    return jsonify({"ok": True, "key": key, "type": typ})

@app.route("/api/site/del", methods=["POST"])
def api_site_del():
    keys = set((request.get_json(silent=True) or {}).get("keys") or [])
    if not keys:
        return jsonify({"ok": False}), 400
    with CONF_LOCK:
        m = us(); raw = open(jj_path(), encoding="utf-8").read()
        spans, _ = m.site_spans(raw)
        rm, blk = [], []
        for a, b in spans:
            o = json.loads(raw[a:b])
            if o.get("key") in keys:
                rm.append((a, b))
                if str(o.get("api", "")).startswith("http"):
                    blk.append(m.norm(o["api"]))
        if rm:
            jj_write(m.remove_spans(raw, rm))
            block_update(add=blk)
    return jsonify({"ok": True, "n": len(rm)})

@app.route("/api/test")
def api_test():
    """测试一个采集站：列表 + 第一个视频的播放地址能否打开"""
    site = find_site(arg("key"))
    if not site:
        return jsonify({"ok": False, "msg": "没有这个站"})
    t0 = time.time()
    try:
        d = vod_call(site, ac="detail", pg=1)
        if not d["list"]:
            d2 = vod_call(site, ac="list", pg=1)
            if not d2["list"]:
                return jsonify({"ok": False, "ms": int((time.time() - t0) * 1000), "msg": "列表为空"})
            ids = ",".join(str(v.get("vod_id")) for v in d2["list"][:3])
            d = vod_call(site, ac="detail", ids=ids)
    except Exception as e:
        return jsonify({"ok": False, "ms": int((time.time() - t0) * 1000), "msg": ("接口打不开：" + (str(e) or type(e).__name__))[:80]})
    ms = int((time.time() - t0) * 1000)
    url = ""
    for v in d["list"]:
        for part in str(v.get("vod_play_url") or "").split("$$$"):
            for ep in part.split("#"):
                u = ep.split("$")[-1].strip()
                if re.match(r"https?://", u):
                    url = u; break
            if url: break
        if url: break
    if not url:
        return jsonify({"ok": False, "ms": ms, "msg": "没有播放地址"})
    try:
        r = S.get(url, headers={"User-Agent": UA}, timeout=8, verify=False, stream=True)
        head = next(r.iter_content(2048), b"")
        r.close()
        if r.status_code >= 400:  # 很多 CDN 拒绝机房 IP，手机上通常能播，不算失效
            return jsonify({"ok": True, "warn": 1, "ms": ms, "msg": f"接口可用，播放地址对服务器返回 HTTP{r.status_code}（手机上可能能播）"})
        ct = r.headers.get("Content-Type", "").lower()
        if b"#EXTM3U" in head[:20] or "video" in ct or "mpegurl" in ct or "octet" in ct:
            return jsonify({"ok": True, "ms": ms, "msg": "可用"})
        if not re.search(r"\.(m3u8|mp4|flv)", url):
            return jsonify({"ok": True, "ms": ms, "msg": "可用（网页解析地址，可能需代理）", "warn": 1})
        return jsonify({"ok": True, "warn": 1, "ms": ms, "msg": "接口可用，播放地址不像视频"})
    except Exception as e:
        return jsonify({"ok": True, "warn": 1, "ms": ms, "msg": "接口可用，播放地址服务器连不上（" + type(e).__name__ + "）"})

@app.route("/api/vod")
def api_vod():
    key = arg("key")
    site = find_site(key)
    if not site:
        return jsonify({"error": "no site"}), 404
    ac, t, pg, wd, ids = arg("ac") or "detail", arg("t"), arg("pg") or "1", arg("wd"), arg("ids")
    try:
        if ac == "class":
            d = vod_call(site, ac="list")
            return jsonify({"class": d["class"]})
        try:
            d = vod_call(site, ac="detail", t=t, pg=pg, wd=wd, ids=ids)
        except Exception:
            if ids:
                raise
            d = {"list": []}
        if not d["list"] and not ids:  # 有的站 detail 不支持分类/搜索，退回 list
            d = vod_call(site, ac="list", t=t, pg=pg, wd=wd)
        keep = ("vod_id", "vod_name", "vod_pic", "vod_remarks", "type_name", "vod_year", "vod_area", "vod_actor", "vod_content", "vod_play_from", "vod_play_url")
        d["list"] = [{k: v.get(k) for k in keep if v.get(k) not in (None, "")} for v in d["list"]]
        if not ids:
            for v in d["list"]:
                v.pop("vod_play_url", None); v.pop("vod_content", None)
        return jsonify(d)
    except Exception as e:
        print("[web] vod err", key, ac, repr(e), flush=True)
        return jsonify({"error": str(e)[:200], "list": [], "class": []}), 502

@app.route("/api/dm")
def api_dm():
    """网页播放器弹幕：[[秒, 模式, 颜色, 文本], ...]"""
    name, ep = arg("name"), arg("ep")
    if not name:
        return jsonify([])
    try:
        items = resolve(name, ep)
    except Exception:
        items = []
    for label, site, url in items:
        try:
            x = xml_for(site, url)
        except Exception as e:
            print("[web] dm err", label, repr(e), flush=True)
            continue
        if x != EMPTY:
            out = []
            for p, txt in re.findall(r'<d p="([^"]+)">(.*?)</d>', x, re.S):
                f = p.split(",")
                out.append([round(float(f[0]), 1), int(f[1]), int(f[3]), html.unescape(txt)])
            print("[web] dm", name, ep, "->", label, len(out), flush=True)
            return jsonify(out)
    return jsonify([])

@app.route("/px")
def px():
    """播放代理：直连失败（跨域/防盗链）时网页自动改走这里"""
    u = arg("u")
    if not re.match(r"https?://", u):
        return "bad url", 400
    h = {"User-Agent": UA}
    if request.headers.get("Range"):
        h["Range"] = request.headers["Range"]
    try:
        r = S.get(u, headers=h, stream=True, timeout=15, verify=False, allow_redirects=True)
    except Exception as e:
        return f"proxy err {e}", 502
    ct = r.headers.get("Content-Type", "")
    if r.status_code >= 400:
        return Response(f"upstream {r.status_code}", status=r.status_code, headers={"Access-Control-Allow-Origin": "*"})
    if ".m3u8" in u.split("?")[0] or "mpegurl" in ct.lower():
        body = r.content.decode("utf-8", "ignore")
        if not body.lstrip().startswith("#EXTM3U"):
            return Response(body, status=502)
        base = r.url
        def fix(m):
            return "/px?u=" + quote(urllib.parse.urljoin(base, m), safe="")
        lines = []
        for ln in body.splitlines():
            s = ln.strip()
            if s and not s.startswith("#"):
                lines.append(fix(s))
            else:
                lines.append(re.sub(r'URI="([^"]+)"', lambda m: 'URI="' + fix(m.group(1)) + '"', ln))
        return Response("\n".join(lines), mimetype="application/vnd.apple.mpegurl", headers={"Access-Control-Allow-Origin": "*"})
    hd = {"Access-Control-Allow-Origin": "*"}
    for k in ("Content-Length", "Content-Range", "Accept-Ranges"):
        if k in r.headers:
            hd[k] = r.headers[k]
    return Response(r.iter_content(64 * 1024), status=r.status_code, mimetype=ct or "video/mp2t", headers=hd)

@app.route("/hls.js")
def hls_js():
    from flask import send_file
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hls.min.js")
    if os.path.exists(p):
        return send_file(p, mimetype="application/javascript", max_age=86400)
    from flask import redirect
    return redirect("https://cdn.jsdelivr.net/npm/hls.js@1/dist/hls.min.js")

@app.route("/web")
def web_page():
    try:
        return Response(open(WEB_HTML, encoding="utf-8").read(), mimetype="text/html")
    except Exception:
        return "web.html 不存在，请重新执行 deploy.sh", 404

@app.route("/")
def root():
    if request.environ.get("SERVER_PORT") == str(WEB_PORT):
        return web_page()
    return f"danmu ok v{VERSION}"

@app.route("/version")
def version():
    return VERSION

if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--set-auth":
        set_auth(sys.argv[2], sys.argv[3])
        print("ok")
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--auth-show":
        c = auth_conf()
        print((c or {}).get("user", ""), (c or {}).get("pass", "（旧版未保存，请重置）") if c else "")
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--auth-user":
        c = auth_conf()
        print(c["user"] if c else "")
        sys.exit(0)
    import urllib3
    urllib3.disable_warnings()
    if WEB_PORT and os.environ.get("WEB", "1") != "0":
        from werkzeug.serving import make_server
        try:
            ws = make_server(os.environ.get("WEB_BIND", "0.0.0.0"), WEB_PORT, app, threaded=True)
            threading.Thread(target=ws.serve_forever, daemon=True).start()
            print("web player on", WEB_PORT, flush=True)
        except OSError as e:
            print("web port busy", WEB_PORT, repr(e), flush=True)
    app.run(host=os.environ.get("DANMU_BIND", "0.0.0.0"), port=int(os.environ.get("PORT", "2525")), threaded=True)
