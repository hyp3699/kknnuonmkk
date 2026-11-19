#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
免 key 弹幕服务（OK影视/FongMi 格式）
/danmu?name=剧名&episode=第N集 -> [{"name","url"}]，url 指向 /xml 返回 B站格式 XML
流程：360影视搜剧名拿到各平台播放页 -> 直接拉平台自己的弹幕
支持：腾讯视频(qq) / 爱奇艺(qiyi) / 芒果TV(imgo) / B站番剧(bilibili1) / 优酷(youku)
      巴哈姆特动画疯(baha，台湾动漫) / B站搬运视频(biliv，台综港综等 360 搜不到的节目)
"""
VERSION = "2.4.4"  # 2.4.4: 加密开着时全部视频强制加密播放（不管代理开关），mp4 也加密（Service Worker 解密）；2.4.3: 加密播放时状态栏显示“🔒已加密”；2.4.2: 设置页加密开关（代理播放的采集站视频和 tgweb 视频都加密）；tgweb 里去掉“退出网页登录”；ys 8 重置账号密码改为随机 16-24 位（大小写+数字+符号）；2.4.1: tgweb 不再随安装自动装，只在 ys 14 手动安装；2.4.0: 集成 tgweb（TG 频道视频）：ys 14 安装（Docker，跳过 api_id/hash），网页左上角配置框切到 tgweb，用哈哈的登录；ys 14 管理 tgweb；设置页加退出登录；2.3.2: FH 等短片重复插播段也去掉；2.3.1: 去广告规则按 80 多个采集站 370 个视频校准，修 2.3.0 误删正片的问题；2.3.0: 去广告识别随机文件名的站（如 FH）；2.2.9: 去广告（过滤 m3u8 插播段，缓冲面板可关）；全屏方向按正片，不跟广告转；2.2.8: 集数正序/倒序按钮；弹幕不重叠（满了就不显示）；2.2.7: 名字改“哈哈”；首页分类栏下滑时固定；2.2.6: 全屏左上显示片名和集数；播放器下方显示正在播第几集+上一集/下一集；2.2.5: 手动代理播放失败自动退回直连；代理修 gzip 长度；日志记被拒的视频服务器；2.2.4: 点集数不再自动全屏；换源接着当前集和进度；同一集弹幕换源不重新拉；2.2.3: 进搜索页清空搜索框；播放页播放框固定不随页面滚动；2.2.2: 搜索/换源结果边搜边存（没搜完刷新也在，可继续搜）；2.2.1: 搜索页返回按钮写“返回”；2.2.0: 搜索页返回按钮加宽 3 倍；2.1.9: 保存的搜索结果按配置 id+关键词，不再因站列表变化失效；2.1.8: 搜索页显示已保存的关键词，点了直接看；刷新后恢复上次搜索；换源可停止；2.1.7: 换源结果上限 1000 部/10 天；🔍搜索页结果也保存（Q_MAX=300/10 天），可重新搜索；2.1.6: 自带进度条（点画面出现）；换源结果按片名保存在服务器（上限 ALT_MAX=500，ALT_DAYS=7 天），切换采集站后结果面板保留；2.1.5: 全屏按视频宽高定横竖屏；2.1.4: 全屏 ⏮ 选集 ⏭ 移到屏幕正中间；2.1.3: 去掉播放框右上角全屏按钮；左右滑快进快退整屏有效（含页面下半空白处）；2.1.2: 左右滑快进快退整个播放页都有效（集数/线路列表除外），音量只在播放框；2.1.1: 上下滑调音量恢复全屏和不全屏都有效；2.1.0: 左右滑快进快退照搬油猴 shipin5.0，金色提示框；2.0.9: 播放页全屏按钮改成占两行的方形图标按钮；2.0.8: 去掉双击快进快退；隐藏浏览器自带全屏，播放器框右上角自己的全屏按钮（全屏后能看到上下集/选集）；⏮ 选集 ⏭ 挨在一起放底部中间；2.0.7: 上一集/下一集/选集只在全屏时出现；2.0.6: 点正片/第几集直接全屏，当前集不重播；2.0.5: 播放器框内上一集/下一集/选集、上下滑调音量、双击两侧快退快进 10 秒（中间暂停）；按钮两排固定大小；缓冲设置；去掉下一集按钮；2.0.4: 修播放页返回：加载/换线路/自动换源途中返回会被拉回播放页；首次打开的页面返回直接回首页；2.0.3: 采集站下拉框固定 29% 宽（原 38% 缩 25%）；2.0.2: 首页“记录”不换行；2.0.1: 节点切换按钮（自动切换/指定节点/不用），视频代理也自动换节点；2.0.0: 网页设置里可添加出口节点（vless/vmess/trojan/ss/hy2/tuic 链接或 sing-box JSON，内置单独的 sing-box 进程），采集站直连失败自动走节点（或全部走节点），视频代理也可走节点；1.9.9: 网页支持 type 3 的通用 XPath 规则站（csp_XPath/XPathMac/XPathFilter/XPathMacFilter，Python 引擎；播放页能取到直链才能播）；1.9.8: 配置开头 //注释、行首 # 注释也能读；1.9.7: 不再保存明文密码（旧文件自动删除）、/px 和 /api/probe 只能访问公网（每次跳转都查）、代理并发限制（总 32、每 IP 12）、2525 每 IP 每分钟 240 次；1.9.6: 账号无效时网页拒绝访问、代理按内容识别 m3u8、/api/probe 判断视频类型、播放器错误恢复与续播修正、弹幕跟随倍速；部署脚本原子更新+回滚；1.9.5: 网络中断自动重试+重试按钮、弹幕设置（区域/透明度/字号/速度/数量/偏移/顶底彩色）；1.9.4: 搜索停止按钮、换源面板、自动换线路/采集站、显示当前采集站、20 秒连接超时；1.9.3: 网页支持 type 4（T4 远程接口，含播放解析与请求头）；1.9.2: 配置解析对齐 OK影视（xxxxxxxx** 图片配置、2423 AES 加密配置、;pk;KEY 配置、地址可不带 http://）；1.9.1: 播放记录按片名合并（不同配置/采集站的同一部只留一条，换站继续播）；1.9.0: 网页多配置（像 OK影视 一样添加配置地址，每个配置单独一类，支持图片藏配置/多仓）、聚合搜索；1.8.0: 网页设置(添加/删除/测试采集站、编辑 jjoo.json)、IP 访问限制(白名单/黑名单)、ys 可查看账号密码； 1.7.0: 网页播放器账号密码登录、播放记录(服务器保存，多设备同步)、/sub/jjoo.json 弹幕地址跟随访问域名； 1.6.0: 内置精简网页播放器(端口3003：选采集站/分类/站内搜索/播放+弹幕)； 1.5.0: 兼容弹弹play/danmu_api 接口(MoonTVPlus 网页播放器可直接用)，/sub/ 提供采集站配置文件； 1.4.1: 1.4.1: [代理]整集条目排最前(App 内置抓取器部分平台只拉到第1分钟)； 1.4.0: 新增巴哈姆特动画疯(台湾动漫)、B站搬运视频(台综/港综等)； 1.3.0: 新增优酷弹幕(mtop 签名)； 1.2.0: 先返回平台原始播放页(App 内置抓取器直连拉弹幕)，再返回本服务代理 XML
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
    d = {"user": user, "salt": salt, "hash": pw_hash(salt, pw), "secret": secrets.token_hex(16)}
    tmp = AUTH_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, AUTH_FILE)

def auth_conf():
    """返回有效账号配置；没有/损坏都返回 None（网页端口此时一律拒绝访问，不再放行）"""
    try:
        mt = os.path.getmtime(AUTH_FILE)
    except Exception:
        return None
    if AUTH_CACHE[0] != mt:
        try:
            c = json.load(open(AUTH_FILE))
            if not all(isinstance(c.get(k), str) and c.get(k) for k in ("user", "hash", "salt", "secret")):
                raise ValueError("bad auth")
            if "pass" in c:  # 旧版存过明文密码：删掉，只留盐和哈希
                c.pop("pass", None)
                try:
                    tmp = AUTH_FILE + ".tmp"
                    with open(tmp, "w") as f:
                        json.dump(c, f)
                    os.chmod(tmp, 0o600)
                    os.replace(tmp, AUTH_FILE)
                    mt = os.path.getmtime(AUTH_FILE)
                except Exception:
                    pass
            AUTH_CACHE[1] = c
        except Exception:
            AUTH_CACHE[1] = None
        AUTH_CACHE[0] = mt
    return AUTH_CACHE[1]

def auth_token(c):
    return hmac.new(c["secret"].encode(), (c["user"] + c["hash"]).encode(), "sha256").hexdigest()

def authed():
    c = auth_conf()
    if not c:
        return False  # 没有有效账号配置时拒绝（ys 选 8 设置账号）
    t = request.cookies.get("ys_auth", "")
    return bool(t) and hmac.compare_digest(t, auth_token(c))

def client_ip():
    ra = request.remote_addr or ""
    if ra.startswith("127.") or ra == "::1":
        return request.headers.get("X-Real-IP") or (request.headers.get("X-Forwarded-For", "").split(",")[0].strip()) or ra
    return ra

LOGIN_HTML = """<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 · 哈哈</title><style>body{margin:0;background:#111;color:#eee;font:15px -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center}
form{width:min(320px,88vw);display:flex;flex-direction:column;gap:12px}h1{font-size:22px;text-align:center;margin:0 0 8px}
input,button{font:inherit;color:#eee;background:#222;border:1px solid #333;border-radius:10px;padding:12px}button{background:#e50914;border-color:#e50914;cursor:pointer}
#e{color:#f66;text-align:center;min-height:1.2em;font-size:13px}</style></head><body>
<form id="f"><h1>哈哈</h1><input id="u" placeholder="账号" autocomplete="username" required><input id="p" type="password" placeholder="密码" autocomplete="current-password" required>
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
    return p in ("/web", "/px", "/pvsw.js", "/hls.js", "/login", "/logout", "/tg") or p.startswith("/tg/") or (p.startswith("/api/") and not p.startswith("/api/v2/"))

# 2525 每个 IP 每分钟最多 DANMU_RPM 次（默认 240，0=不限），防止被人拿去刷
DANMU_RPM = int(os.environ.get("DANMU_RPM", "240") or 0)
RATE, RLOCK = {}, threading.Lock()
def rate_ok(ip):
    if DANMU_RPM <= 0:
        return True
    now = int(time.time() // 60)
    with RLOCK:
        m, n = RATE.get(ip, (now, 0))
        if m != now:
            m, n = now, 0
        RATE[ip] = (m, n + 1)
        if len(RATE) > 5000:
            for k in [k for k, v in RATE.items() if v[0] != now]:
                RATE.pop(k, None)
        return n < DANMU_RPM

# ---------- 代理安全：只允许访问公网地址（每次跳转都检查），限制并发 ----------
import socket
PX_MAX, PX_PER_IP = int(os.environ.get("PX_MAX", "32")), int(os.environ.get("PX_PER_IP", "12"))
PX_ACT, PXLOCK = {}, threading.Lock()

def host_public(host):
    try:
        infos = socket.getaddrinfo(host, None)
    except Exception:
        return False
    for i in infos:
        try:
            a = ipaddress.ip_address(i[4][0].split("%")[0])
        except ValueError:
            return False
        if getattr(a, "ipv4_mapped", None):
            a = a.ipv4_mapped
        if not a.is_global or a.is_multicast:
            return False
    return bool(infos)

def safe_get(u, headers, timeout, stream=True, hops=5, proxies=None):
    """跟随跳转，但每一跳都必须是公网 http(s) 地址；内网/回环/云元数据一律拒绝"""
    for _ in range(hops + 1):
        pu = urllib.parse.urlsplit(u)
        if pu.scheme not in ("http", "https") or not pu.hostname or not host_public(pu.hostname):
            raise ValueError("目标地址不允许（只能访问公网）")
        r = S.get(u, headers=headers, stream=stream, timeout=timeout, verify=False, allow_redirects=False, proxies=proxies)
        if r.status_code in (301, 302, 303, 307, 308) and r.headers.get("Location"):
            u = urllib.parse.urljoin(u, r.headers["Location"])
            r.close()
            continue
        return r
    raise ValueError("跳转次数太多")

# ---------- 出口节点：网页设置里添加 sing-box 节点，采集站/视频请求可以走它（单独起一个 sing-box 进程，不碰系统里的 sing-box） ----------
import subprocess, shutil
NODES_FILE = os.environ.get("NODES_FILE", os.path.join(DATA_DIR, "web_nodes.json"))
SB_DIR = os.path.join(DATA_DIR, "sb")
NODE_BASE = int(os.environ.get("NODE_PORT", "20810") or 20810)
NODE = {"proc": None, "sig": None, "err": "", "lock": threading.Lock(), "last": 0}
NODE_HOSTS = {}  # host -> (到期时间, 节点id)：自动模式下直连失败、走某节点成功的站，记 6 小时
NODE_MODES = ("off", "auto", "fixed")  # 不用 / 自动切换（直连失败依次试节点）/ 指定节点（全部走 active）

def nodes_load():
    try:
        d = json.load(open(NODES_FILE, encoding="utf-8"))
        if isinstance(d, dict) and isinstance(d.get("nodes"), list):
            d.setdefault("mode", "auto"); d.setdefault("active", "")
            if d["mode"] == "all":
                d["mode"] = "fixed"
            if d["mode"] not in NODE_MODES:
                d["mode"] = "auto"
            return d
    except Exception:
        pass
    return {"mode": "auto", "active": "", "nodes": []}

def nodes_save(d):
    tmp = NODES_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, NODES_FILE)

def sb_bin():
    for b in (os.environ.get("SINGBOX_BIN"), os.path.join(DATA_DIR, "sing-box"), "/etc/sing-box/sing-box", shutil.which("sing-box"),
              "/usr/local/bin/sing-box", "/etc/s-box/sing-box", "/root/sing-box/sing-box"):
        if b and os.path.isfile(b) and os.access(b, os.X_OK):
            return b
    return ""

def _b64d(t):
    t = re.sub(r"\s+", "", t).replace("-", "+").replace("_", "/")
    return base64.b64decode(t + "=" * (-len(t) % 4)).decode("utf-8", "ignore")

def _tls(q, host, default_on=False, insecure_keys=("allowInsecure", "insecure", "allow_insecure")):
    sec = (q.get("security") or ("tls" if default_on else "")).lower()
    if sec not in ("tls", "reality", "xtls"):
        return None
    t = {"enabled": True}
    sni = q.get("sni") or q.get("peer") or q.get("host") or ""
    if not sni and not re.match(r"^[\d.:\[\]]+$", host):
        sni = host
    if sni:
        t["server_name"] = sni
    if any(str(q.get(k, "")).lower() in ("1", "true") for k in insecure_keys):
        t["insecure"] = True
    if q.get("alpn"):
        t["alpn"] = [x for x in urllib.parse.unquote(q["alpn"]).split(",") if x]
    fp = q.get("fp") or ""
    if sec == "reality":
        t["reality"] = {"enabled": True, "public_key": q.get("pbk", ""), "short_id": q.get("sid", "")}
        fp = fp or "chrome"
    if fp:
        t["utls"] = {"enabled": True, "fingerprint": fp}
    return t

def _transport(q):
    net = (q.get("type") or q.get("net") or "tcp").lower()
    path = urllib.parse.unquote(q.get("path") or "/")
    host = q.get("host") or ""
    if net == "ws":
        tr = {"type": "ws", "path": path}
        m = re.search(r"[?&]ed=(\d+)", path)
        if m:
            tr["path"] = re.sub(r"[?&]ed=\d+", "", path) or "/"
            tr["max_early_data"] = int(m.group(1)); tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
        if host:
            tr["headers"] = {"Host": host}
        return tr
    if net == "grpc":
        return {"type": "grpc", "service_name": urllib.parse.unquote(q.get("serviceName") or q.get("path") or "")}
    if net == "httpupgrade":
        tr = {"type": "httpupgrade", "path": path}
        if host:
            tr["host"] = host
        return tr
    if net in ("h2", "http"):
        tr = {"type": "http", "path": path}
        if host:
            tr["host"] = [host]
        return tr
    if net in ("tcp", "raw", ""):
        return None
    raise ValueError(f"不支持的传输方式 {net}（sing-box 没有 {net}，换个节点）")

def parse_node(link):
    """分享链接 / sing-box 出站 JSON → (名称, sing-box outbound)"""
    link = link.strip()
    if link.startswith("{"):
        ob = json.loads(link)
        if not isinstance(ob, dict) or not ob.get("type") or not ob.get("server"):
            raise ValueError("JSON 不是 sing-box 出站（要有 type 和 server）")
        ob = {k: v for k, v in ob.items() if k not in ("tag", "detour")}
        return str(ob.get("tag") or ob["server"]), ob
    m = re.match(r"([a-z0-9]+)://", link, re.I)
    if not m:
        raise ValueError("看不懂这个链接，支持 vless/vmess/trojan/ss/hy2/tuic 或 sing-box 出站 JSON")
    sch = m.group(1).lower()
    if sch == "vmess":
        j = json.loads(_b64d(link[8:].split("#")[0]))
        q = {k: str(v) for k, v in j.items()}
        host, port = q.get("add", ""), int(q.get("port") or 443)
        ob = {"type": "vmess", "server": host, "server_port": port, "uuid": q.get("id", ""), "alter_id": int(q.get("aid") or 0),
              "security": q.get("scy") or "auto"}
        q["security"] = "tls" if q.get("tls") in ("tls", "reality") else ""
        q["type"] = q.get("net") or "tcp"
        t = _tls(q, host)
        if t:
            ob["tls"] = t
        tr = _transport(q)
        if tr:
            ob["transport"] = tr
        return q.get("ps") or host, ob
    if sch == "ss" and "@" not in link.split("#")[0]:  # ss://base64(method:pass@host:port)
        name = urllib.parse.unquote(link.split("#", 1)[1]) if "#" in link else ""
        link = "ss://" + _b64d(link[5:].split("#")[0]) + ("#" + name if name else "")
    sp = urllib.parse.urlsplit(link)
    q = {k: v for k, v in urllib.parse.parse_qsl(sp.query)}
    name = urllib.parse.unquote(sp.fragment) or sp.hostname or "节点"
    host, port = sp.hostname or "", sp.port or 443
    if not host:
        raise ValueError("链接里没有服务器地址")
    user = urllib.parse.unquote(sp.username or "")
    pw = urllib.parse.unquote(sp.password or "") if sp.password is not None else None
    if sch == "vless":
        ob = {"type": "vless", "server": host, "server_port": port, "uuid": user}
        if q.get("flow"):
            ob["flow"] = q["flow"]
        ob["packet_encoding"] = "xudp"
        t = _tls(q, host)
    elif sch == "trojan":
        ob = {"type": "trojan", "server": host, "server_port": port, "password": user}
        t = _tls(q, host, default_on=True)
    elif sch == "ss":
        if pw is None:
            try:
                user = _b64d(sp.username or "")
            except Exception:
                pass
            method, _, pw = user.partition(":")
        else:
            method = user
        if q.get("plugin"):
            raise ValueError("带插件的 ss 节点不支持")
        return name, {"type": "shadowsocks", "server": host, "server_port": port, "method": method, "password": pw}
    elif sch in ("hysteria2", "hy2"):
        ob = {"type": "hysteria2", "server": host, "server_port": port, "password": user + (":" + pw if pw else "")}
        if q.get("obfs"):
            ob["obfs"] = {"type": q["obfs"], "password": q.get("obfs-password", "")}
        if q.get("mport"):
            pass
        ob["tls"] = _tls(dict(q, security="tls"), host, True) or {"enabled": True}
        return name, ob
    elif sch == "tuic":
        ob = {"type": "tuic", "server": host, "server_port": port, "uuid": user, "password": pw or "",
              "congestion_control": q.get("congestion_control") or "bbr"}
        if q.get("udp_relay_mode"):
            ob["udp_relay_mode"] = q["udp_relay_mode"]
        ob["tls"] = _tls(dict(q, security="tls"), host, True) or {"enabled": True}
        ob["tls"].setdefault("alpn", ["h3"])
        return name, ob
    else:
        raise ValueError(f"不支持 {sch}:// 链接")
    if t:
        ob["tls"] = t
    tr = _transport(q)
    if tr:
        ob["transport"] = tr
    return name, ob

def parse_nodes_text(txt):
    """一次粘贴多行；也认 base64 订阅内容"""
    txt = txt.strip()
    if txt.startswith("{"):
        return [parse_node(txt)]
    if not re.search(r"^[a-z0-9]+://", txt, re.I | re.M):
        try:
            dec = _b64d(txt)
            if re.search(r"^[a-z0-9]+://", dec, re.I | re.M):
                txt = dec
        except Exception:
            pass
    out, errs = [], []
    for ln in txt.splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        try:
            out.append(parse_node(ln))
        except Exception as e:
            errs.append(str(e)[:60])
    if not out:
        raise ValueError(errs[0] if errs else "没有找到节点链接")
    return out

def sb_config(d):
    ins, obs, rules = [], [], []
    for i, n in enumerate(d["nodes"]):
        tag = "n" + str(i)
        ins.append({"type": "mixed", "tag": "in-" + tag, "listen": "127.0.0.1", "listen_port": NODE_BASE + i})
        obs.append(dict(n["ob"], tag=tag))
        rules.append({"inbound": ["in-" + tag], "outbound": tag})
    obs.append({"type": "direct", "tag": "direct"})
    return {"log": {"level": "warn", "timestamp": True}, "inbounds": ins, "outbounds": obs, "route": {"rules": rules, "final": "direct"}}

def sb_stop():
    p = NODE["proc"]
    NODE["proc"] = None
    if p and p.poll() is None:
        p.terminate()
        try:
            p.wait(5)
        except Exception:
            p.kill()

def sb_apply(d=None, force=False):
    """按节点列表（重新）启动内置 sing-box；返回错误说明（空=正常）"""
    with NODE["lock"]:
        d = d or nodes_load()
        if not d["nodes"]:
            sb_stop(); NODE["sig"] = None; NODE["err"] = ""
            return ""
        b = sb_bin()
        if not b:
            NODE["err"] = "服务器上没找到 sing-box 程序（运行 ys 选 1 更新会自动下载）"
            return NODE["err"]
        cfg = json.dumps(sb_config(d), ensure_ascii=False, indent=1)
        sig = hashlib.md5((b + cfg).encode()).hexdigest()
        p = NODE["proc"]
        if not force and sig == NODE["sig"] and p and p.poll() is None:
            return ""
        os.makedirs(SB_DIR, exist_ok=True)
        cf = os.path.join(SB_DIR, "config.json")
        with open(cf + ".new", "w", encoding="utf-8") as f:
            f.write(cfg)
        os.chmod(cf + ".new", 0o600)
        try:
            ck = subprocess.run([b, "check", "-c", cf + ".new"], capture_output=True, text=True, timeout=20)
        except Exception as e:
            NODE["err"] = "sing-box 运行不了：" + repr(e)[:80]
            return NODE["err"]
        if ck.returncode != 0:
            msg = re.sub(r"\x1b\[[0-9;]*m", "", (ck.stderr or ck.stdout or "").strip()).splitlines()
            NODE["err"] = "节点配置有错：" + (msg[-1] if msg else "未知")[:160]
            return NODE["err"]
        os.replace(cf + ".new", cf)
        sb_stop()
        logf = open(os.path.join(SB_DIR, "sing-box.log"), "ab")
        NODE["proc"] = subprocess.Popen([b, "run", "-c", cf], stdout=logf, stderr=logf, stdin=subprocess.DEVNULL)
        NODE["sig"], NODE["err"], NODE["last"] = sig, "", time.time()
        time.sleep(0.8)
        if NODE["proc"].poll() is not None:
            NODE["err"] = "sing-box 启动后退出了，看 " + os.path.join(SB_DIR, "sing-box.log")
            return NODE["err"]
        print("[node] sing-box started", len(d["nodes"]), "nodes", flush=True)
        return ""

def node_px(d=None, idx=None):
    """第 idx 个节点的本地代理（sing-box 没在跑会尝试拉起）；不可用返回 None"""
    d = d or nodes_load()
    if idx is None or idx >= len(d["nodes"]):
        return None
    p = NODE["proc"]
    if not p or p.poll() is not None:
        if time.time() - NODE["last"] < 20:
            return None
        NODE["last"] = time.time()
        if sb_apply(d, force=True):
            return None
    u = f"http://127.0.0.1:{NODE_BASE + idx}"
    return {"http": u, "https": u}

def _bad_status(r):
    return r.status_code in (401, 403, 407, 429, 451) or r.status_code >= 500

def _close(r):
    try:
        r.close()
    except Exception:
        pass

def site_get(url, safe=False, **kw):
    """采集站/视频请求。自动：先直连，连不上或被拒（403/5xx 等）就依次换节点，成功的节点按站记 6 小时；指定：全部走选中的节点"""
    d = nodes_load()
    timeout = kw.pop("timeout", 12)
    def do(idx, to=timeout):
        p = node_px(d, idx) if idx is not None else None
        if idx is not None and not p:
            raise ConnectionError("节点不可用")
        if safe:
            return safe_get(url, kw.get("headers") or {}, to, proxies=p)
        return S.get(url, proxies=p, timeout=to, **kw)
    ids = [n["id"] for n in d["nodes"]]
    if d["mode"] == "off" or not ids:
        return do(None)
    if d["mode"] == "fixed":
        return do(ids.index(d["active"]) if d["active"] in ids else 0)
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    order = [None] + list(range(len(ids)))
    rem = NODE_HOSTS.get(host)
    if rem and rem[0] > time.time() and rem[1] in ids:
        i = ids.index(rem[1])
        order = [i] + [x for x in order if x != i]
    else:
        NODE_HOSTS.pop(host, None)
    first, err, tries = None, None, 0
    for idx in order:
        if idx is not None:
            tries += 1
            if tries > 3:  # 最多试 3 个节点，免得一直卡着
                break
        try:
            r = do(idx, (5, timeout) if idx is None and isinstance(timeout, (int, float)) else timeout)
        except ValueError:
            raise
        except Exception as e:
            err = err or e
            if idx is not None and rem and rem[1] == ids[idx]:
                NODE_HOSTS.pop(host, None)
            continue
        if not _bad_status(r):
            if idx is not None:
                if not (rem and rem[1] == ids[idx]):
                    print("[node] via", d["nodes"][idx]["name"], host, flush=True)
                NODE_HOSTS[host] = (time.time() + 6 * 3600, ids[idx])
            if first is not None:
                _close(first)
            return r
        if first is None:
            first = r
        else:
            _close(r)
    if first is not None:
        return first
    raise err or ConnectionError("连不上")

def node_test(idx):
    """经第 idx 个节点访问，返回出口 IP/地区和耗时"""
    if sb_apply():
        return {"ok": False, "msg": NODE["err"]}
    px = node_px(idx=idx)
    if not px:
        return {"ok": False, "msg": NODE["err"] or "sing-box 没在运行"}
    t0 = time.time()
    for u in ("http://ip-api.com/json/?lang=zh-CN&fields=status,country,regionName,city,isp,query", "https://api.ip.sb/geoip"):
        try:
            j = S.get(u, proxies=px, timeout=10, headers={"User-Agent": UA}).json()
            ms = int((time.time() - t0) * 1000)
            ip = j.get("query") or j.get("ip") or ""
            loc = " ".join(x for x in (j.get("country"), j.get("regionName") or j.get("region"), j.get("city")) if x)
            return {"ok": True, "ms": ms, "msg": f"{ip} {loc} {j.get('isp') or j.get('organization') or ''}".strip()}
        except Exception as e:
            last = e
    return {"ok": False, "msg": "节点连不上：" + type(last).__name__}

def node_watch():
    while True:
        time.sleep(30)
        try:
            d = nodes_load()
            if d["nodes"] and d["mode"] != "off":
                p = NODE["proc"]
                if not p or p.poll() is not None:
                    print("[node] sing-box not running, restart", flush=True)
                    sb_apply(d, force=True)
        except Exception as e:
            print("[node] watch err", repr(e), flush=True)

def px_acquire(ip):
    with PXLOCK:
        tot = sum(PX_ACT.values())
        if tot >= PX_MAX or PX_ACT.get(ip, 0) >= PX_PER_IP:
            return False
        PX_ACT[ip] = PX_ACT.get(ip, 0) + 1
        return True

def px_release(ip):
    with PXLOCK:
        n = PX_ACT.get(ip, 0) - 1
        if n > 0:
            PX_ACT[ip] = n
        else:
            PX_ACT.pop(ip, None)

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
        if not rate_ok(client_ip()):
            return "429 too many requests", 429
        return None
    if p in ("/login", "/hls.js", "/favicon.ico"):
        return None
    if not auth_conf():
        msg = "网页播放器还没有有效的账号密码，在 VPS 上运行 ys 选 8 设置"
        return (jsonify({"error": msg}), 503) if (p.startswith("/api/") or p == "/px") else Response(msg, status=503, mimetype="text/plain; charset=utf-8")
    if authed():
        return None
    if p.startswith("/api/") or p == "/px" or p.startswith("/tg/api/") or p == "/tg/sw.js":
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
    tg_web_logout()  # tgweb 只退出网页会话，TG 账号不退出
    r = redirect("/")
    r.delete_cookie("ys_auth")
    return r

# ---------- 视频加密（设置页开关）：代理播放的采集站视频 + tgweb 视频都加密，CF 只看到 octet-stream 乱码 ----------
ENC_FILE = os.environ.get("ENC_FILE", os.path.join(DATA_DIR, "web_enc.json"))
ENC, ENC_LOCK = {}, threading.Lock()
try:
    from cryptography.hazmat.primitives.ciphers import Cipher as _Ci, algorithms as _Alg, modes as _Mo
except Exception:
    _Ci = None  # 没装 cryptography：采集站加密不可用（tgweb 自己加密，不受影响）

def enc_save():
    tmp = ENC_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ENC, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, ENC_FILE)

def enc_conf():
    with ENC_LOCK:
        if not ENC:
            try:
                ENC.update(json.load(open(ENC_FILE, encoding="utf-8")))
            except Exception:
                pass
            if not ENC.get("key"):
                ENC["key"] = base64.b64encode(secrets.token_bytes(16)).decode()
                ENC.setdefault("on", False)
                try:
                    enc_save()
                except Exception as e:
                    print("[enc] save err", e, flush=True)
        return ENC

def enc_on():
    return bool(enc_conf().get("on"))

def enc_cipher(nonce8):
    """AES-128-CTR，counter = 8 字节随机 nonce + 8 字节块号（从 0 开始），和浏览器 WebCrypto 一致"""
    return _Ci(_Alg.AES(base64.b64decode(enc_conf()["key"])), _Mo.CTR(nonce8 + b"\0" * 8)).encryptor()

def enc_bytes(data):
    n = secrets.token_bytes(8)
    return n + enc_cipher(n).update(data)

def enc_tok(u, hx=""):
    return base64.urlsafe_b64encode(enc_bytes(json.dumps({"u": u, "h": hx or ""}, separators=(",", ":")).encode())).decode().rstrip("=")

def enc_untok(x):
    b = base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
    d = json.loads(enc_cipher(b[:8]).update(b[8:]).decode())
    return str(d.get("u") or ""), str(d.get("h") or "")

@app.route("/api/enc", methods=["GET", "POST"])
def enc_api():
    c = enc_conf()
    if request.method == "POST":
        on = bool((request.get_json(silent=True) or {}).get("on"))
        with ENC_LOCK:
            ENC["on"] = on
            enc_save()
        print("[enc]", "on" if on else "off", flush=True)
    return jsonify({"on": bool(c.get("on")), "ok": bool(_Ci), "key": c["key"]})

# ---------- tgweb（Telegram 频道视频，Docker 只绑 127.0.0.1:9393）：网页 /tg/ 反代，登录用哈哈的 ----------
# 浏览器只认哈哈的登录；tgweb 自己的网页账号密码（.env 里随机生成）由这里代登录，web_token 只在服务器里用，不发给浏览器。
TG_DIR = os.environ.get("TGWEB_DIR", "/root/telegram-stream")
TG_UP = os.environ.get("TGWEB_URL", "http://127.0.0.1:9393").rstrip("/")
TG_S = requests.Session(); TG_S.trust_env = False  # 本机直连，不走节点/系统代理
TG_TOK, TG_LOCK, TG_ST, TG_FAIL = [None], threading.Lock(), [0.0, False], [0.0]
TG_DROP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
           "transfer-encoding", "upgrade", "set-cookie", "x-frame-options", "server", "date"}

TG_INJ = (b"<style>button[onclick^='webLogout']{display:none!important}</style>"  # 退出用哈哈设置页的，tgweb 里只留退出 TG 账号
          b"<script>(()=>{const f=window.fetch;window.fetch=function(u,o){const p=f.apply(this,arguments);"
          b"if(String(u&&u.url||u).indexOf('/api/web-logout')>=0)p.finally(()=>{try{top.location.href='/'}catch(e){location.href='/'}});return p}})()</script>")

def tg_env():
    d = {}
    try:
        for ln in open(os.path.join(TG_DIR, ".env"), encoding="utf-8"):
            ln = ln.strip()
            if "=" not in ln or ln.startswith("#"):
                continue
            k, v = ln.split("=", 1)
            v = v.strip().replace("\r", "")
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            d[k.strip()] = v  # 和 tg 命令一样，重复的键以最后一行为准
    except Exception:
        pass
    return d

def tg_base(e=None):
    e = e or tg_env()
    p = e.get("WEB_PATH", "").strip().strip("/")
    if e.get("WEB_PATH_ENABLED", "1").strip().lower() in ("0", "false", "off", "no"):
        p = ""
    return ("/" + p) if p else ""

def tg_running(force=False):
    now = time.time()
    if not force and now - TG_ST[0] < 10:
        return TG_ST[1]
    ok = False
    if os.path.isfile(os.path.join(TG_DIR, ".env")):
        try:
            TG_S.get(TG_UP + tg_base() + "/api/status", timeout=2, allow_redirects=False)
            ok = True  # 有任何 HTTP 回应就算在运行（没登录是 401）
        except Exception:
            ok = False
    TG_ST[0], TG_ST[1] = now, ok
    return ok

def tg_login(force=False):
    with TG_LOCK:
        if TG_TOK[0] and not force:
            return TG_TOK[0]
        if time.time() - TG_FAIL[0] < 20:  # 刚失败过，别一直撞 tgweb 的登录限流
            return None
        e = tg_env()
        try:
            r = TG_S.post(TG_UP + tg_base(e) + "/api/web-login", timeout=8, headers={"X-Real-IP": "127.0.0.1"},
                          json={"username": e.get("WEB_USERNAME", ""), "password": e.get("WEB_PASSWORD", "")})
            tok = r.cookies.get("web_token") if r.status_code == 200 else None
        except Exception as ex:
            tok = None
            print("[tg] login err", repr(ex)[:200], flush=True)
        if not tok:
            TG_FAIL[0] = time.time()
            print("[tg] login failed（检查 %s/.env 里的 WEB_PASSWORD）" % TG_DIR, flush=True)
        TG_TOK[0] = tok
        return tok

def tg_web_logout():
    tok, TG_TOK[0] = TG_TOK[0], None
    if not tok:
        return
    def go():
        try:
            TG_S.post(TG_UP + tg_base() + "/api/web-logout", cookies={"web_token": tok}, timeout=5)
        except Exception:
            pass
    threading.Thread(target=go, daemon=True).start()

@app.route("/api/tg/status")
def tg_status_api():
    return jsonify({"on": tg_running(request.args.get("f") == "1")})

@app.route("/tg", methods=["GET", "HEAD"])
def tg_root():
    from flask import redirect
    return redirect("/tg/")

@app.route("/tg/", defaults={"sub": ""}, methods=["GET", "HEAD", "POST", "PUT", "DELETE"])
@app.route("/tg/<path:sub>", methods=["GET", "HEAD", "POST", "PUT", "DELETE"])
def tg_proxy(sub):
    if request.environ.get("SERVER_PORT") != str(WEB_PORT):
        return "not found", 404
    if sub == "api/web-logout":  # tgweb 里点退出 = 哈哈一起退出网页登录（TG 账号不退）
        tg_web_logout()
        r = jsonify({"ok": True})
        r.delete_cookie("ys_auth")
        return r
    raw = request.environ.get("RAW_URI") or request.environ.get("REQUEST_URI") or request.full_path
    rest = raw.split("?", 1)
    path = rest[0][3:] if rest[0].startswith("/tg") else "/" + sub
    if enc_on() and path.startswith("/stream/"):  # 开了加密：不许明文流
        return Response("已开启加密，只能走加密流", status=403, mimetype="text/plain; charset=utf-8")
    base = tg_base()
    url = TG_UP + base + (path or "/") + ("?" + rest[1] if len(rest) > 1 and rest[1] else "")
    h = {k: v for k, v in request.headers.items() if k.lower() in (
        "content-type", "range", "accept", "accept-language", "if-none-match", "if-modified-since", "if-range")}
    h["Accept-Encoding"] = "identity"  # 不压缩，原样转发字节
    h["X-Real-IP"] = client_ip()
    h["X-Forwarded-Proto"] = request.headers.get("X-Forwarded-Proto") or request.scheme
    body = request.get_data() if request.method in ("POST", "PUT", "DELETE") else None
    def go(tok):
        return TG_S.request(request.method, url, data=body, headers=h, cookies={"web_token": tok} if tok else None,
                            stream=True, timeout=(5, 300), allow_redirects=False)
    try:
        tok = TG_TOK[0] or tg_login()
        r = go(tok)
        if r.status_code == 401:
            txt = r.content[:500]
            if b"need_web_auth" in txt and tg_login(force=True):
                r = go(TG_TOK[0])
    except requests.exceptions.ConnectionError:
        TG_ST[0] = 0
        return Response("tgweb 没有运行（服务器上 ys 选 14 启动）", status=502, mimetype="text/plain; charset=utf-8")
    except Exception as e:
        return Response("tgweb 出错：" + repr(e)[:200], status=502, mimetype="text/plain; charset=utf-8")
    inj = None
    if request.method == "GET" and path == "/api/status" and r.status_code == 200:
        # tgweb 装成 auto（明文/加密都能放），这里按哈哈的加密开关告诉它的前端走哪种
        try:
            j = r.json()
            if isinstance(j.get("enc"), dict) and j["enc"].get("mode") == "auto":
                j["enc"]["mode"] = "strict" if enc_on() else "off"
            inj = json.dumps(j, ensure_ascii=False).encode()
        except Exception:
            inj = None
    if request.method == "GET" and path in ("", "/") and r.status_code == 200 and "text/html" in r.headers.get("content-type", ""):
        # tgweb 里点“退出网页登录”后整个哈哈回到登录页
        inj = r.content.replace(b"</body>", TG_INJ + b"</body>", 1)
    hd = []
    for k, v in r.raw.headers.items():
        lk = k.lower()
        if inj is not None and lk in ("content-length", "etag", "last-modified"):
            continue
        if lk in TG_DROP:
            continue
        if lk == "location" and base and v.startswith(base + "/"):
            v = "/tg" + v[len(base):]
        hd.append((k, v))
    hd.append(("X-Frame-Options", "SAMEORIGIN"))  # 哈哈里用 iframe 嵌入
    if inj is not None:
        r.close()
        return Response(inj, status=200, headers=hd)
    def gen():
        try:
            if r._content_consumed:
                yield r.content
            else:
                for c in r.raw.stream(65536, decode_content=False):
                    yield c
        finally:
            r.close()
    return Response(gen(), status=r.status_code, headers=hd, direct_passthrough=True)

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

# ---------- 保存的搜索结果：换源(alt) 和 🔍搜索页(q)，按 配置+关键词 存服务器；超过上限删最旧，过期自动删 ----------
ALT_MAX = int(os.environ.get("ALT_MAX", "1000") or 1000)
ALT_DAYS = int(os.environ.get("ALT_DAYS", "10") or 10)
Q_MAX = int(os.environ.get("Q_MAX", "300") or 300)
Q_DAYS = int(os.environ.get("Q_DAYS", "10") or 10)
ALOCK = threading.Lock()
SCACHE = {"alt": (os.path.join(DATA_DIR, "web_altcache.json"), lambda: ALT_MAX, lambda: ALT_DAYS),
          "q": (os.path.join(DATA_DIR, "web_qcache.json"), lambda: Q_MAX, lambda: Q_DAYS)}

def _s(x, n):
    return str(x if x is not None else "")[:n]

def _clean_alt(lst):
    return [{"key": _s(x.get("key"), 200), "id": _s(x.get("id"), 200), "rm": _s(x.get("rm"), 60)}
            for x in (lst or [])[:300] if isinstance(x, dict) and x.get("key")]

def _clean_q(lst):
    out = []
    for g in (lst or [])[:300]:
        if not isinstance(g, dict) or not g.get("key"):
            continue
        out.append({"key": _s(g.get("key"), 200), "name": _s(g.get("name"), 60), "more": bool(g.get("more")),
                    "items": [{"id": _s(v.get("id"), 200), "name": _s(v.get("name"), 100), "pic": _s(v.get("pic"), 500), "rm": _s(v.get("rm"), 60)}
                              for v in (g.get("items") or [])[:40] if isinstance(v, dict)]})
    return out

def scache(kind):
    f, mx, days = SCACHE[kind]
    j = request.get_json(silent=True) or {} if request.method == "POST" else {}
    ck = arg("ck") if request.method != "POST" else _s(j.get("ck"), 4000)
    gl = arg("list") if request.method == "GET" else ""
    if not ck and not gl:
        return jsonify(None)
    hk = hashlib.sha1(ck.encode("utf-8")).hexdigest()[:20]
    gh = lambda g: hashlib.sha1(g.encode("utf-8")).hexdigest()[:12]
    with ALOCK:
        try:
            d = json.load(open(f, encoding="utf-8"))
            d = d if isinstance(d, dict) else {}
        except Exception:
            d = {}
        now, ttl = int(time.time()), days() * 86400
        if request.method == "GET" and gl:  # 当前配置保存过的关键词，新的在前
            g = gh(gl)
            return jsonify([v.get("name") for v in sorted(d.values(), key=lambda v: -(v.get("t") or 0))
                            if v.get("g") == g and now - int(v.get("t") or 0) <= ttl and v.get("name")][:100])
        if request.method == "GET":
            r = d.get(hk)
            if not r or now - int(r.get("t") or 0) > ttl:
                return jsonify(None)
            return jsonify({"t": r.get("t"), "n": r.get("n"), "cnt": r.get("cnt", r.get("n")), "list": r.get("list") or []})
        if request.method == "DELETE":
            d.pop(hk, None)
        else:
            d.pop(hk, None)
            d[hk] = {"t": now, "name": _s(j.get("name"), 100), "n": int(j.get("n") or 0), "cnt": int(j.get("cnt") if j.get("cnt") is not None else (j.get("n") or 0)), "g": gh(_s(j.get("g"), 4000)),
                     "list": (_clean_alt if kind == "alt" else _clean_q)(j.get("list"))}
            d = {k: v for k, v in d.items() if now - int(v.get("t") or 0) <= ttl}
            if len(d) > mx():
                for k in sorted(d, key=lambda k: d[k].get("t") or 0)[:len(d) - mx()]:
                    d.pop(k, None)
        tmp = f + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fp:
            json.dump(d, fp, ensure_ascii=False)
        os.replace(tmp, f)
    return jsonify({"ok": True})

@app.route("/api/altcache", methods=["GET", "POST", "DELETE"])
def api_altcache():
    return scache("alt")

@app.route("/api/qcache", methods=["GET", "POST", "DELETE"])
def api_qcache():
    return scache("q")

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
                              for s in d.get("sites", []) if s.get("type") in (0, 1, 4) and str(s.get("api", "")).startswith("http")]
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
        elif c == "#" and t[t.rfind("\n", 0, i) + 1:i].strip() == "":  # 行首 # / ## 注释
            j = t.find("\n", i); i = n if j < 0 else j; continue
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
    t0 = re.sub(r"^(?:\s*(?://[^\n]*|#[^\n]*|/\*.*?\*/))+\s*", "", t, flags=re.S)  # 开头的 //20220821 这类注释
    if t0[:1] in "{[":
        return loose_json(t0)
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
    r = site_get(u, headers={"User-Agent": "okhttp/3.12.13"}, timeout=15, verify=False, allow_redirects=True)
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
        if s.get("type") == 3 and XP_OK and re.match(r"csp_XPath(Mac)?(Filter)?$", api):  # 通用 XPath 规则爬虫：网页用 Python 引擎跑
            ext = s.get("ext")
            if isinstance(ext, dict):
                src = json.dumps(ext, ensure_ascii=False)
            elif isinstance(ext, str) and ext.strip():
                src = ext.strip()
                if not src.startswith("{"):
                    src = urllib.parse.urljoin(base, src)
                    if not src.startswith("http"):
                        continue
            else:
                continue
            out.append({"key": str(s.get("key") or s.get("name")), "name": str(s.get("name") or s.get("key")), "type": 3, "xp": api,
                        "api": src if src.startswith("http") else "xpath:inline", "ext": src})
            continue
        if s.get("type") in (0, 1, 4) and api:
            if not api.startswith("http"):
                api = urllib.parse.urljoin(base, api)
            host = (urllib.parse.urlsplit(api).hostname or "").lower()
            if api.startswith("http") and host not in ("127.0.0.1", "localhost", "0.0.0.0"):
                ext = s.get("ext")
                out.append({"key": str(s.get("key") or s.get("name")), "name": str(s.get("name") or s.get("key")), "api": api, "type": s.get("type"),
                            "ext": ext if isinstance(ext, str) else (json.dumps(ext, ensure_ascii=False) if ext else "")})
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

def t4_get(site, params, timeout=12):
    sp = urllib.parse.urlsplit(site["api"])
    q = dict(urllib.parse.parse_qsl(sp.query))
    if site.get("ext"):
        q["extend"] = site["ext"]
    q.update({k: v for k, v in params.items() if v not in (None, "")})
    r = site_get(urllib.parse.urlunsplit(sp._replace(query="")), params=q, timeout=timeout, verify=False)
    r.encoding = "utf-8"
    try:
        return json.loads(r.text.lstrip("\ufeff"))
    except Exception:
        raise ValueError(re.sub(r"<[^>]+>", "", r.text)[:60].strip() or f"接口返回异常 HTTP{r.status_code}")

def t4_call(site, ac=None, t=None, pg=None, wd=None, ids=None, **_):
    """TVBox type 4（T4）：首页 filter=true / 分类 ac=detail&t=&pg= / 详情 ac=detail&ids= / 搜索 wd=&quick=false"""
    if ids:
        j = t4_get(site, {"ac": "detail", "ids": ids})
    elif wd:
        j = t4_get(site, {"wd": wd, "quick": "false", "pg": pg or "1"})
    elif t:
        j = t4_get(site, {"ac": "detail", "t": t, "pg": pg or "1"})
    else:
        j = t4_get(site, {"filter": "true"})
        if ac == "detail" and not (j.get("list") or []) and (j.get("class") or []):  # 首页没推荐就取第一个分类
            j2 = t4_get(site, {"ac": "detail", "t": j["class"][0].get("type_id"), "pg": pg or "1"})
            j2["class"] = j.get("class")
            j = j2
    pc = j.get("pagecount")
    try:
        pc = int(pc)
    except Exception:
        pc = 1 if (ids or not t) else 999
    if pc <= 0:
        pc = 999 if (j.get("list") or []) else 1
    return {"class": j.get("class") or [], "list": j.get("list") or [], "page": int(j.get("page") or pg or 1) if str(j.get("page") or pg or 1).isdigit() else 1,
            "pagecount": pc}

# ---------- XPath 规则爬虫（TVBox csp_XPath / XPathMac / XPathFilter / XPathMacFilter 的 Python 版） ----------
try:
    import lxml.html as LH
    XP_OK = True
except Exception:
    XP_OK = False
XP_RULES = {}  # src -> (ts, rule)

def xp_rule(site):
    src = site.get("ext") or ""
    c = XP_RULES.get(src)
    if c and time.time() - c[0] < 3600:
        return c[1]
    if src.startswith("{"):
        rule = loose_json(src)
    else:
        r = site_get(src, timeout=12, verify=False, headers={"User-Agent": UA})
        if r.status_code >= 400:
            raise ValueError(f"规则文件打不开 HTTP{r.status_code}")
        rule = decode_config(r.content)
    if not isinstance(rule, dict) or not rule.get("homeUrl"):
        raise ValueError("规则文件格式不对")
    for k in ("homeUrl", "cateUrl", "dtUrl", "playUrl", "searchUrl"):  # 很多规则把 https:// 省掉了（dm84.tv/show-...）
        v = str(rule.get(k) or "").strip()
        if v.startswith("//"):
            v = "https:" + v
        elif v and not re.match(r"[a-z]+://", v, re.I) and re.match(r"[\w-]+(\.[\w-]+)+(:\d+)?(/|$|\?)", v):
            v = "https://" + v
        rule[k] = v
    XP_RULES[src] = (time.time(), rule)
    return rule

def xp_fetch(rule, url, ua_key="ua"):
    ua = rule.get(ua_key) or rule.get("ua") or UA
    r = site_get(url, safe=True, headers={"User-Agent": ua, "Referer": rule.get("homeUrl", "")}, timeout=12)
    try:
        raw = r.content
    finally:
        r.close()
    if r.status_code >= 400:
        raise ValueError(f"网站返回 HTTP{r.status_code}")
    enc = r.encoding if r.encoding and r.encoding.lower() != "iso-8859-1" else None
    m = re.search(rb'<meta[^>]+charset=["\']?([\w-]+)', raw[:3000], re.I)
    enc = (m.group(1).decode() if m else None) or enc or "utf-8"
    try:
        txt = raw.decode(enc, "ignore")
    except LookupError:
        txt = raw.decode("utf-8", "ignore")
    return txt, r.url

def xp_doc(txt):
    return LH.fromstring(txt or "<html></html>")

def _xp_eval(node, rule, doc=None):
    """规则里的 /a/@href 是相对当前节点；// 开头先在节点内找，找不到再全页找（与 JsoupXpath 习惯一致）"""
    r = rule.strip()
    while r.startswith("///"):
        r = r[1:]
    if r.startswith("/"):
        rel = "." + r
    else:
        rel = "./" + r
    try:
        res = node.xpath(rel)
    except Exception:
        res = []
    if not res and doc is not None and r.startswith("//"):
        try:
            res = doc.xpath(r)
        except Exception:
            res = []
    return res

def xp_val(node, rule, rx="", doc=None):
    if not rule:
        return ""
    res = _xp_eval(node, rule, doc)
    v = ""
    for x in res:
        x = x.text_content() if hasattr(x, "text_content") else str(x)
        x = re.sub(r"\s+", " ", x).strip()
        if x:
            v = x
            break
    if v and rx:
        try:
            m = re.search(rx, v)
            if m:
                v = m.group(1) if m.groups() else m.group(0)
        except re.error:
            pass
    return v.strip()

def xp_nodes(node, rule, doc=None):
    if not rule:
        return []
    return [x for x in _xp_eval(node, rule, doc) if hasattr(x, "xpath")]

def xp_list(rule, doc, base, pre):
    out = []
    for n in xp_nodes(doc, rule.get(pre + "Node")):
        vid = xp_val(n, rule.get(pre + "Id"), rule.get(pre + "IdR"))
        name = xp_val(n, rule.get(pre + "Name"), rule.get(pre + "NameR"))
        if not vid or not name:
            continue
        pic = xp_val(n, rule.get(pre + "Img"), rule.get(pre + "ImgR"))
        out.append({"vod_id": vid, "vod_name": name, "vod_pic": urllib.parse.urljoin(base, pic) if pic else "",
                    "vod_remarks": xp_val(n, rule.get(pre + "Mark"), rule.get(pre + "MarkR"))})
    return out

def xp_classes(rule):
    cm = rule.get("cateManual")
    if isinstance(cm, dict) and cm:
        return [{"type_id": str(v), "type_name": str(k)} for k, v in cm.items()]
    out = []
    if rule.get("cateNode"):
        txt, base = xp_fetch(rule, rule["homeUrl"])
        doc = xp_doc(txt)
        for n in xp_nodes(doc, rule["cateNode"]):
            i = xp_val(n, rule.get("cateId"), rule.get("cateIdR"))
            nm = xp_val(n, rule.get("cateName"), rule.get("cateNameR"))
            if i and nm and all(c["type_id"] != i for c in out):
                out.append({"type_id": i, "type_name": nm})
    return out

def xp_fill(tpl, **kv):
    first = re.search(r"\[firstPage=(.*?)\]", tpl)
    tpl = re.sub(r"\[firstPage=.*?\]", "", tpl)
    if first and str(kv.get("catePg")) == "1":
        tpl = first.group(1)
    for k, v in kv.items():
        tpl = tpl.replace("{" + k + "}", str(v))
    return re.sub(r"\{\w+\}", "", tpl)  # 筛选占位符（{year}{area}…）没选就留空

def xp_json_path(j, path):
    for k in [x for x in path.split(".") if x]:
        if isinstance(j, dict):
            j = j.get(k)
        elif isinstance(j, list) and k.isdigit() and int(k) < len(j):
            j = j[int(k)]
        else:
            return None
    return j

def xp_rx(v, rx):
    v = str(v or "").strip()
    if v and rx:
        try:
            m = re.search(rx, v)
            if m:
                v = m.group(1) if m.groups() else m.group(0)
        except re.error:
            pass
    return v

def xp_search(rule, wd, pg):
    url = xp_fill(rule.get("searchUrl") or "", wd=quote(wd), pg=pg, catePg=pg)
    if not url:
        return []
    txt, base = xp_fetch(rule, url)
    node = rule.get("scVodNode") or ""
    if node.startswith("json:"):
        try:
            j = json.loads(txt.lstrip("\ufeff"))
        except Exception:
            return []
        out = []
        for it in xp_json_path(j, node[5:]) or []:
            if not isinstance(it, dict):
                continue
            vid = xp_rx(it.get(rule.get("scVodId") or "id"), rule.get("scVodIdR"))
            nm = xp_rx(it.get(rule.get("scVodName") or "name"), rule.get("scVodNameR"))
            if vid and nm:
                pic = xp_rx(it.get(rule.get("scVodImg") or "pic"), rule.get("scVodImgR"))
                out.append({"vod_id": vid, "vod_name": nm, "vod_pic": urllib.parse.urljoin(base, pic) if pic else "",
                            "vod_remarks": xp_rx(it.get(rule.get("scVodMark") or ""), rule.get("scVodMarkR"))})
        return out
    return xp_list(rule, xp_doc(txt), base, "scVod")

def xp_detail(rule, vid):
    url = xp_fill(rule.get("dtUrl") or "{vid}", vid=vid)
    url = urllib.parse.urljoin(rule["homeUrl"], url)
    txt, base = xp_fetch(rule, url)
    doc = xp_doc(txt)
    nd = (xp_nodes(doc, rule.get("dtNode")) or [doc])[0]
    g = lambda k: xp_val(nd, rule.get(k), rule.get(k + "R"), doc)
    froms = [xp_val(n, rule.get("dtFromName"), rule.get("dtFromNameR")) for n in xp_nodes(doc, rule.get("dtFromNode"))]
    groups = []
    for un in xp_nodes(doc, rule.get("dtUrlNode")):
        eps = []
        for a in xp_nodes(un, rule.get("dtUrlSubNode")):
            pid = xp_val(a, rule.get("dtUrlId"), rule.get("dtUrlIdR"))
            nm = xp_val(a, rule.get("dtUrlName"), rule.get("dtUrlNameR")) or str(len(eps) + 1)
            if pid:
                eps.append(nm.replace("$", " ").replace("#", " ") + "$" + pid)
        if eps:
            groups.append("#".join(eps))
    fr = [(froms[i] if i < len(froms) and froms[i] else f"线路{i + 1}").replace("$", " ") for i in range(len(groups))]
    pic = g("dtImg")
    return {"vod_id": vid, "vod_name": g("dtName"), "vod_pic": urllib.parse.urljoin(base, pic) if pic else "",
            "type_name": g("dtCate"), "vod_year": g("dtYear"), "vod_area": g("dtArea"), "vod_remarks": g("dtMark"),
            "vod_actor": g("dtActor"), "vod_director": g("dtDirector"), "vod_content": g("dtDesc"),
            "vod_play_from": "$$$".join(fr), "vod_play_url": "$$$".join(groups)}

def xp_call(site, ac=None, t=None, pg=None, wd=None, ids=None, **_):
    rule = xp_rule(site)
    pg = str(pg or "1")
    if ids:
        return {"class": [], "list": [xp_detail(rule, i) for i in str(ids).split(",")[:3] if i], "page": 1, "pagecount": 1}
    if wd:
        lst = xp_search(rule, wd, pg)
        return {"class": [], "list": lst, "page": int(pg), "pagecount": 1}
    if t:
        url = xp_fill(rule.get("cateUrl") or "", cateId=t, catePg=pg)
        txt, base = xp_fetch(rule, url)
        lst = xp_list(rule, xp_doc(txt), base, "cateVod")
        return {"class": [], "list": lst, "page": int(pg), "pagecount": (int(pg) + 1 if lst else int(pg))}
    cls = xp_classes(rule)
    lst = []
    if ac == "detail":
        try:
            if rule.get("homeVodNode"):
                txt, base = xp_fetch(rule, rule["homeUrl"])
                lst = xp_list(rule, xp_doc(txt), base, "homeVod")
            if not lst and cls:
                return dict(xp_call(site, t=cls[0]["type_id"], pg=pg), **{"class": cls})
        except ValueError:
            if not cls:
                raise
    return {"class": cls, "list": lst, "page": 1, "pagecount": 1}

def mac_player_url(txt, base):
    """从苹果CMS播放页里取真实地址：player_xxx={...url,encrypt}；再不行找页面里的 m3u8/mp4"""
    m = re.search(r"player_\w+\s*=\s*(\{.*?\})\s*(?:;|</script>)", txt, re.S)
    if m:
        try:
            j = json.loads(m.group(1))
            u = str(j.get("url") or "")
            enc = str(j.get("encrypt") or "0")
            if enc == "1":
                u = urllib.parse.unquote(u)
            elif enc == "2":
                u = urllib.parse.unquote(base64.b64decode(u + "=" * (-len(u) % 4)).decode("latin1"))
            u = u.replace("\\/", "/")
            if re.match(r"https?://", u) or u.startswith("//"):
                return urllib.parse.urljoin(base, u)
        except Exception:
            pass
    m = re.search(r"""(https?:)?(\\?/\\?/[^"'\s<>]+?\.(?:m3u8|mp4)(?:\?[^"'\s<>]*)?)""", txt)
    if m:
        return urllib.parse.urljoin(base, (m.group(1) or "https:") + m.group(2).replace("\\/", "/"))
    return ""

def xp_play(site, pid):
    rule = xp_rule(site)
    tpl = rule.get("playUrl") or ""
    url = xp_fill(tpl, playUrl=pid) if "{playUrl}" in tpl else (tpl + pid if tpl else pid)
    url = urllib.parse.urljoin(rule["homeUrl"], url)
    if re.search(r"\.(m3u8|mp4|flv)(\?|$)", url):
        return url, {}
    txt, base = xp_fetch(rule, url, "playUa")
    u = mac_player_url(txt, base)
    if u and re.search(r"\.(m3u8|mp4|flv)", u):
        return u, ({"User-Agent": rule["playUa"]} if rule.get("playUa") else {})
    if u:
        raise ValueError("这一集是解析接口地址，需要网页嗅探，网页播放器不支持，换一条线路试试")
    raise ValueError("播放页里没找到视频地址（需要嗅探），换一条线路试试")

def vod_call(site, **params):
    if site.get("type") == 4:
        return t4_call(site, **params)
    if site.get("type") == 3:
        return xp_call(site, **params)
    sp = urllib.parse.urlsplit(site["api"])
    q = dict(urllib.parse.parse_qsl(sp.query))
    q.update({k: v for k, v in params.items() if v not in (None, "")})
    r = site_get(urllib.parse.urlunsplit(sp._replace(query="")), params=q, timeout=10, verify=False)
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
    if site.get("type") in (3, 4) and not any(v.get("vod_play_url") for v in d["list"]):
        try:
            d = vod_call(site, ids=str(d["list"][0].get("vod_id")))
        except Exception as e:
            return jsonify({"ok": False, "ms": int((time.time() - t0) * 1000), "msg": "详情打不开：" + str(e)[:60]})
    ms = int((time.time() - t0) * 1000)
    url, th = "", {}
    for v in (d["list"] if site.get("type") not in (3, 4) else []):
        for part in str(v.get("vod_play_url") or "").split("$$$"):
            for ep in part.split("#"):
                u = ep.split("$")[-1].strip()
                if re.match(r"https?://", u):
                    url = u; break
            if url: break
        if url: break
    if not url and site.get("type") == 3:
        for v in d["list"]:
            ep = str(v.get("vod_play_url") or "").split("$$$")[0].split("#")[0]
            if ep:
                try:
                    url, th = xp_play(site, ep.split("$")[-1])
                except Exception as e:
                    return jsonify({"ok": False, "ms": ms, "msg": "列表和详情能打开，但" + str(e)[:50]})
            break
    if not url and site.get("type") == 4:
        for v in d["list"]:
            fr = str(v.get("vod_play_from") or "").split("$$$")
            for fi, part in enumerate(str(v.get("vod_play_url") or "").split("$$$")):
                ep = part.split("#")[0]
                if ep:
                    try:
                        j = t4_get(site, {"play": ep.split("$")[-1], "flag": fr[fi] if fi < len(fr) else ""}, timeout=12)
                        url = j.get("url") if isinstance(j.get("url"), str) else ""
                        th = j.get("header") if isinstance(j.get("header"), dict) else {}
                    except Exception:
                        pass
                    break
            break
    if not url:
        return jsonify({"ok": False, "ms": ms, "msg": "没有播放地址"})
    try:
        r = S.get(url, headers=dict({"User-Agent": UA}, **{str(k): str(v) for k, v in th.items()}), timeout=8, verify=False, stream=True)
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

@app.route("/api/nodes", methods=["GET", "POST"])
def api_nodes():
    """出口节点：GET 列表；POST {act: add|del|use|mode|video|test, ...}"""
    d = nodes_load()
    if request.method == "GET":
        p = NODE["proc"]
        nm = {n["id"]: n["name"] for n in d["nodes"]}
        return jsonify({"mode": d["mode"], "active": d["active"], "bin": bool(sb_bin()),
                        "running": bool(p and p.poll() is None), "err": NODE["err"],
                        "hosts": sorted(f"{h}→{nm[t[1]]}" for h, t in list(NODE_HOSTS.items()) if t[0] > time.time() and t[1] in nm),
                        "nodes": [{"id": n["id"], "name": n["name"], "type": n["ob"].get("type"), "server": f'{n["ob"].get("server")}:{n["ob"].get("server_port")}'} for n in d["nodes"]]})
    j = request.get_json(silent=True) or {}
    act = j.get("act")
    if act == "add":
        try:
            got = parse_nodes_text(str(j.get("link") or ""))
        except Exception as e:
            return jsonify({"ok": False, "msg": str(e)[:120]})
        if len(d["nodes"]) + len(got) > 50:
            return jsonify({"ok": False, "msg": "节点最多 50 个"})
        n0 = len(d["nodes"])
        for nm, ob in got:
            i = 1
            while any(x["id"] == f"n{i}" for x in d["nodes"]):
                i += 1
            d["nodes"].append({"id": f"n{i}", "name": (str(j.get("name") or "").strip() if len(got) == 1 else "") or nm[:40], "ob": ob})
        if not d["active"]:
            d["active"] = d["nodes"][0]["id"]
        err = ""
        if sb_bin():
            old = nodes_load()
            nodes_save(d)
            err = sb_apply(d)
            if err:
                nodes_save(old); sb_apply(old)
                return jsonify({"ok": False, "msg": err})
        else:
            nodes_save(d)
            err = "已保存，但服务器上没找到 sing-box 程序（ys 选 1 更新会自动下载）"
        return jsonify({"ok": True, "n": len(d["nodes"]) - n0, "msg": err})
    if act == "del":
        d["nodes"] = [n for n in d["nodes"] if n["id"] != j.get("id")]
        if d["active"] == j.get("id"):
            d["active"] = d["nodes"][0]["id"] if d["nodes"] else ""
        nodes_save(d); NODE_HOSTS.clear(); sb_apply(d)
        return jsonify({"ok": True})
    if act == "use" and any(n["id"] == j.get("id") for n in d["nodes"]):
        d["active"] = j["id"]; nodes_save(d); NODE_HOSTS.clear()
        return jsonify({"ok": True})
    if act == "mode" and j.get("mode") in NODE_MODES:
        d["mode"] = j["mode"]
        if j.get("id") and any(n["id"] == j["id"] for n in d["nodes"]):
            d["active"] = j["id"]
        nodes_save(d); NODE_HOSTS.clear()
        return jsonify({"ok": True})
    if act == "test":
        idx = next((i for i, n in enumerate(d["nodes"]) if n["id"] == j.get("id")), None)
        if idx is None:
            return jsonify({"ok": False, "msg": "没有这个节点"})
        return jsonify(node_test(idx))
    return jsonify({"ok": False, "msg": "参数不对"})

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
        if site.get("type") in (3, 4):
            d["t4"] = 1  # 播放时先走 /api/play 解析
        return jsonify(d)
    except Exception as e:
        print("[web] vod err", key, ac, repr(e), flush=True)
        return jsonify({"error": str(e)[:200], "list": [], "class": []}), 502

@app.route("/api/probe")
def api_probe():
    """看一眼播放地址的内容：hls / file / 空（不确定）"""
    u = arg("u")
    if not re.match(r"https?://", u):
        return jsonify({"kind": ""})
    h = {"User-Agent": UA, "Range": "bytes=0-2047"}
    try:
        h.update({str(k): str(v) for k, v in json.loads(arg("h") or "{}").items() if str(k).lower() not in ("host", "range")})
    except Exception:
        pass
    try:
        r = safe_get(u, h, 6)
        ct = r.headers.get("Content-Type", "").lower()
        b = next(r.iter_content(2048), b"")
        r.close()
    except Exception:
        return jsonify({"kind": ""})
    t = b.lstrip(b"\xef\xbb\xbf \r\n\t")
    if t.startswith(b"#EXTM3U") or "mpegurl" in ct:
        return jsonify({"kind": "hls"})
    if b[4:8] == b"ftyp" or b[:3] == b"FLV" or b[:4] == b"\x1a\x45\xdf\xa3" or ct.startswith(("video/", "audio/")):
        return jsonify({"kind": "file"})
    return jsonify({"kind": ""})

@app.route("/api/play")
def api_play():
    """T4 播放解析：play=&flag= → 真实地址 + 请求头"""
    site = find_site(arg("key"))
    if not site:
        return jsonify({"error": "no site"}), 404
    pid, flag = arg("id"), arg("flag")
    if site.get("type") == 3:
        try:
            u, hd = xp_play(site, pid)
            return jsonify({"url": u, "header": hd})
        except ValueError as e:
            return jsonify({"error": str(e)}), 502
        except Exception as e:
            return jsonify({"error": "解析失败：" + str(e)[:80]}), 502
    if site.get("type") != 4:
        return jsonify({"url": pid})
    try:
        j = t4_get(site, {"play": pid, "flag": flag}, timeout=15)
    except Exception as e:
        return jsonify({"error": "解析失败：" + str(e)[:80]}), 502
    u = j.get("url") or ""
    if isinstance(u, list):  # 多清晰度 ["名称","地址",...]
        u = next((x for x in u[1::2] if str(x).startswith("http")), "")
    hd = j.get("header") or j.get("headers") or {}
    if isinstance(hd, str):
        try:
            hd = json.loads(hd)
        except Exception:
            hd = {}
    if not str(u).startswith("http"):
        return jsonify({"error": "这一集没有解析出播放地址"}), 502
    if str(j.get("parse")) == "1" or str(j.get("jx")) == "1":
        if not re.search(r"\.(m3u8|mp4|flv)", u):
            return jsonify({"error": "这一集要网页嗅探解析，网页播放器不支持，换一条线路试试", "url": u}), 502
    return jsonify({"url": u, "header": hd})

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
    x, enc, fm = arg("x"), False, arg("m") == "1"
    if x:  # 加密模式：地址也藏在 token 里，CF 看不到 .m3u8/.ts
        if not _Ci:
            return "加密不可用（服务器缺 cryptography，ys 选 1 更新）", 501
        try:
            u, hx = enc_untok(x)
        except Exception:
            return "bad token", 400
        enc = True
    else:
        u, hx = arg("u"), arg("h")
    if not re.match(r"https?://", u):
        return "bad url", 400
    h = {"User-Agent": UA}
    if hx:
        try:
            h.update({str(k): str(v) for k, v in json.loads(hx).items() if str(k).lower() not in ("host", "range")})
        except Exception:
            pass
    if request.headers.get("Range"):
        h["Range"] = request.headers["Range"]
    if enc and fm:
        h["Accept-Encoding"] = "identity"  # 按字节偏移加密，不能被 gzip 打乱
    ip = client_ip()
    if not px_acquire(ip):
        return "代理并发太多，稍后再试", 429
    done = [False]
    def rel():
        if not done[0]:
            done[0] = True
            px_release(ip)
    try:
        return px_inner(u, h, hx, rel, enc, fm)
    except Exception:
        rel()
        raise

def px_inner(u, h, hx, rel, enc=False, fm=False):
    try:
        r = site_get(u, safe=True, headers=h, timeout=15)
    except ValueError as e:
        rel()
        return str(e), 403
    except Exception as e:
        rel()
        print(f"[px] err {urllib.parse.urlsplit(u).hostname} {e!r}"[:300], flush=True)
        return f"proxy err {e}", 502
    ct = r.headers.get("Content-Type", "")
    if r.status_code >= 400:
        r.close(); rel()
        print(f"[px] upstream {r.status_code} {urllib.parse.urlsplit(u).hostname}", flush=True)
        return Response(f"upstream {r.status_code}", status=r.status_code, headers={"Access-Control-Allow-Origin": "*"})
    is_m3u = ".m3u8" in u.split("?")[0] or "mpegurl" in ct.lower()
    first = b""
    it = r.iter_content(64 * 1024)
    if not is_m3u and not ct.lower().startswith(("video/", "audio/")):
        try:
            first = next(it, b"")  # 无后缀/类型乱写的源：看内容是不是 #EXTM3U
        except Exception:
            first = b""
        is_m3u = first.lstrip(b"\xef\xbb\xbf \r\n\t").startswith(b"#EXTM3U")
    if is_m3u:
        buf = bytearray(first)
        try:
            for ch in it:
                buf += ch
                if len(buf) > 5 * 1024 * 1024:  # 播放列表不可能这么大
                    break
        finally:
            r.close(); rel()
        body = bytes(buf).decode("utf-8", "ignore")
        if not body.lstrip("\ufeff \r\n\t").startswith("#EXTM3U"):
            return Response(body[:500], status=502)
        base = r.url
        def fix(m):
            full = urllib.parse.urljoin(base, m)
            if enc:  # #u= 只给浏览器去广告认路径用，# 后面不会发给服务器/CF
                return "/px?x=" + enc_tok(full, hx) + "#u=" + quote(full, safe="")
            return "/px?u=" + quote(full, safe="") + ("&h=" + quote(hx, safe="") if hx else "")
        lines = []
        for ln in body.splitlines():
            s = ln.strip()
            if s and not s.startswith("#"):
                lines.append(fix(s))
            else:
                lines.append(re.sub(r'URI="([^"]+)"', lambda m: 'URI="' + fix(m.group(1)) + '"', ln))
        out = "\n".join(lines)
        if enc:
            return Response(base64.b64encode(enc_bytes(out.encode("utf-8"))), mimetype="application/octet-stream",
                            headers={"Cache-Control": "private, no-store, no-transform"})
        return Response(out, mimetype="application/vnd.apple.mpegurl", headers={"Access-Control-Allow-Origin": "*"})
    hd = {"Access-Control-Allow-Origin": "*"}
    gz = bool(r.headers.get("Content-Encoding"))  # requests 会自动解压，原长度就不对了
    for k in ("Content-Length", "Content-Range", "Accept-Ranges"):
        if k in r.headers and not (gz and k == "Content-Length"):
            hd[k] = r.headers[k]
    if enc and fm:  # mp4 等整文件加密：按字节位置 AES-CTR（支持拖动/Range），浏览器 Service Worker 解密
        st0 = 0
        m = re.match(r"bytes (\d+)-", r.headers.get("Content-Range", "")) if r.status_code == 206 else None
        if m:
            st0 = int(m.group(1))
        n = hashlib.sha256(u.encode()).digest()[:8]
        ci = _Ci(_Alg.AES(base64.b64decode(enc_conf()["key"])), _Mo.CTR(n + (st0 // 16).to_bytes(8, "big"))).encryptor()
        ci.update(b"\0" * (st0 % 16))
        hd = {k: v for k, v in hd.items() if k != "Access-Control-Allow-Origin"}
        hd.update({"Cache-Control": "private, no-store, no-transform", "X-N": base64.b64encode(n).decode(),
                   "X-T": ct if ct.lower().startswith(("video/", "audio/")) else "video/mp4"})
        def fgen():
            try:
                if first:
                    yield ci.update(first)
                for c in it:
                    yield ci.update(c)
            finally:
                r.close(); rel()
        resp = Response(fgen(), status=r.status_code, mimetype="application/octet-stream", headers=hd)
        resp.call_on_close(rel)
        return resp
    if enc:  # 分片加密：前 8 字节 nonce，后面 AES-CTR 密文（边下边加密，不占内存）
        hd = {"Cache-Control": "private, no-store, no-transform"}
        if r.headers.get("Content-Length") and not gz:
            hd["Content-Length"] = str(int(r.headers["Content-Length"]) + 8)
        n = secrets.token_bytes(8); ci = enc_cipher(n)
        def egen():
            try:
                yield n
                if first:
                    yield ci.update(first)
                for c in it:
                    yield ci.update(c)
            finally:
                r.close(); rel()
        resp = Response(egen(), status=200, mimetype="application/octet-stream", headers=hd)
        resp.call_on_close(rel)
        return resp
    def gen():
        try:
            if first:
                yield first
            yield from it
        finally:
            r.close(); rel()
    resp = Response(gen(), status=r.status_code, mimetype=ct or "video/mp2t", headers=hd)
    resp.call_on_close(rel)
    return resp

PVSW_JS = r"""// 哈哈：mp4 加密播放解密（只管 /pv/ 地址，其它请求不碰）
let K=null;
self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
const b64d=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
async function key(){if(K)return K;const j=await (await fetch('/api/enc',{credentials:'same-origin'})).json();
  K=await crypto.subtle.importKey('raw',b64d(j.key),{name:'AES-CTR'},false,['decrypt']);return K}
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);
  if(u.origin!==location.origin||!u.pathname.startsWith('/pv/'))return;e.respondWith(pv(e.request,u))});
async function pv(rq,u){const k=await key(),h={},rg=rq.headers.get('Range');if(rg)h.Range=rg;
  const r=await fetch('/px?m=1&x='+u.pathname.slice(4),{headers:h,credentials:'same-origin'});
  const nn=r.headers.get('X-N');if(!r.ok||!nn)return r;
  const n=b64d(nn);let off=0;const m=/bytes (\d+)-/.exec(r.headers.get('Content-Range')||'');if(m)off=+m[1];
  const ts=new TransformStream({async transform(ch,c){const s=off%16,b=Math.floor(off/16),cnt=new Uint8Array(16);cnt.set(n,0);
    const dv=new DataView(cnt.buffer);dv.setUint32(8,Math.floor(b/4294967296));dv.setUint32(12,b>>>0);
    const buf=new Uint8Array(s+ch.byteLength);buf.set(ch,s);
    const pt=new Uint8Array(await crypto.subtle.decrypt({name:'AES-CTR',counter:cnt,length:64},k,buf));off+=ch.byteLength;c.enqueue(pt.subarray(s))}});
  const hd=new Headers();for(const x of ['Content-Length','Content-Range','Accept-Ranges'])if(r.headers.get(x))hd.set(x,r.headers.get(x));
  hd.set('Content-Type',r.headers.get('X-T')||'video/mp4');
  return new Response(r.body.pipeThrough(ts),{status:r.status,headers:hd})}
"""

@app.route("/pvsw.js")
def pvsw_js():
    return Response(PVSW_JS, mimetype="application/javascript", headers={"Cache-Control": "no-cache"})

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
        c = auth_conf()  # 只显示账号；密码不再保存明文，忘了就重置
        print((c or {}).get("user", ""))
        sys.exit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--check-auth":
        sys.exit(0 if auth_conf() else 1)
    if len(sys.argv) >= 2 and sys.argv[1] == "--auth-user":
        c = auth_conf()
        print(c["user"] if c else "")
        sys.exit(0)
    import urllib3
    urllib3.disable_warnings()
    if nodes_load()["nodes"]:
        threading.Thread(target=sb_apply, daemon=True).start()
    threading.Thread(target=node_watch, daemon=True).start()
    if WEB_PORT and os.environ.get("WEB", "1") != "0":
        from werkzeug.serving import make_server
        try:
            ws = make_server(os.environ.get("WEB_BIND", "0.0.0.0"), WEB_PORT, app, threaded=True)
            threading.Thread(target=ws.serve_forever, daemon=True).start()
            print("web player on", WEB_PORT, flush=True)
        except OSError as e:
            print("web port busy", WEB_PORT, repr(e), flush=True)
    app.run(host=os.environ.get("DANMU_BIND", "0.0.0.0"), port=int(os.environ.get("PORT", "2525")), threaded=True)
