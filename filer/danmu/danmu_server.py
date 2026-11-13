#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
免 key 弹幕服务：/danmu?name=剧名&epid=第N集  -> B站格式 XML
流程：360影视搜剧名拿到各平台播放页 -> 直接拉平台自己的弹幕
支持：腾讯视频(qq) / 爱奇艺(qiyi) / 芒果TV(imgo) / B站番剧(bilibili1)
"""
import os, re, time, json, zlib, html, threading
from concurrent.futures import ThreadPoolExecutor
import requests
from flask import Flask, request, Response

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
S = requests.Session()
S.headers.update({"User-Agent": UA, "Accept-Language": "zh-CN,zh;q=0.9"})
POOL = ThreadPoolExecutor(16)
CACHE, CACHE_TTL, LOCK = {}, 6 * 3600, threading.Lock()
MAX_DM = int(os.environ.get("MAX_DM", "8000"))
app = Flask(__name__)

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
    rows = (j.get("data") or {}).get("longData", {}).get("rows") or []
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
SUPPORTED = ("qq", "qiyi", "imgo", "bilibili1")

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

FETCH = {"qq": dm_qq, "qiyi": dm_qiyi, "imgo": dm_imgo, "bilibili1": dm_bili}

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

def build(name, epid):
    ep = ep_num(epid)
    for row in search360(name)[:3]:
        site, url = pick_url(row, ep)
        if not url:
            continue
        print(flush=True, *[f"[danmu] {name} {epid} -> {row.get('titleTxt')} {site} {url}"])
        dms = FETCH[site](url)
        if dms:
            return to_xml(dms)
    return EMPTY

@app.route("/danmu")
def danmu():
    name = (request.args.get("name") or "").strip()
    epid = request.args.get("epid") or request.args.get("episode") or ""
    if not name:
        return Response(EMPTY, mimetype="application/xml")
    key = (name, epid)
    with LOCK:
        hit = CACHE.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL:
        return Response(hit[1], mimetype="application/xml")
    try:
        xml = build(name, epid)
    except Exception as e:
        print("[danmu] err", name, epid, repr(e), flush=True)
        xml = EMPTY
    if xml != EMPTY:
        with LOCK:
            CACHE[key] = (time.time(), xml)
            if len(CACHE) > 500:
                CACHE.pop(next(iter(CACHE)))
    return Response(xml, mimetype="application/xml")

@app.route("/")
def root():
    return "danmu ok"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "2525")), threaded=True)
