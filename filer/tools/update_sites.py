#!/usr/bin/env python3
"""自动维护 filer/jjoo.json 的采集站（OK影视 可直接用的 type 0/1 苹果CMS 接口）

1. 按链接去重（忽略 http/https、www、大小写、末尾斜杠、ac=list、/at/格式、/from/线路）
2. 从 GitHub 搜 TVBox 配置，提取 type 0/1 采集站，测试能出列表 + 能搜索才加入
3. 已有站连续 3 次「确定失效」（域名不存在 / 被停放成网页 / 404）才删除；
   超时、连不上、Cloudflare 这类可能只是屏蔽海外的不计入
"""
import base64, json, os, re, socket, sys, time
import concurrent.futures as cf
from urllib.parse import urlsplit, parse_qsl, urlencode
import requests

requests.packages.urllib3.disable_warnings()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JJOO = os.path.join(ROOT, "jjoo.json")
STATE = os.path.join(ROOT, "tools", "sites_state.json")
UA = "Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36"
TOKEN = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
MAX_NEW = int(os.environ.get("MAX_NEW", "50"))        # 每次最多新增
MAX_FILES = int(os.environ.get("MAX_FILES", "400"))   # 每次最多读取的配置文件
FAIL_LIMIT = 3
QUERIES = [
    '"api.php/provide/vod" "searchable" extension:json',
    '"provide/vod" "quickSearch" extension:json',
    '"inc/apijson.php" extension:json',
]
SEEDS = [  # GitHub 搜索不可用时的兜底
    "cyao2q/files/ok.json", "FreeDTV/FreeD/box.json", "liu673cn/box/m.json",
    "xiongjian83/TvBox/X.json", "a736240087/tvbox/2.json", "anaer/Meow/meow.json",
    "gxnas/TvBox/9kg.json", "yueer59/Tvbox/api.json", "jyoketsu/tv/m.json",
]
ADULT = re.compile(r"🔞|伦理|成人|福利|AV|色|黄|淫|奶|麻豆|嘿|老鸭|丝袜|美少女|杏吧|lsb|JP98|sex|porn", re.I)


def norm(api):
    """链接去重用的规范化 key"""
    api = (api or "").strip()
    p = urlsplit(api if "://" in api else "http://" + api)
    host = (p.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if p.port and p.port not in (80, 443):
        host += f":{p.port}"
    path = re.sub(r"/+", "/", p.path)
    path = re.sub(r"/at/\w+", "", path, flags=re.I)
    path = re.sub(r"/(json|josn|xml)/?$", "", path, flags=re.I)
    path = re.sub(r"/from/[^/]+", "", path, flags=re.I).rstrip("/")   # 同一站不同线路/格式算重复
    q = [(k, v) for k, v in parse_qsl(p.query) if k.lower() not in ("ac",)]
    return host + path + ("?" + urlencode(sorted(q)) if q else "")


# ---------- jjoo.json 文本级增删（保留原格式） ----------
def site_spans(raw):
    i = raw.index("[", raw.index('"sites"')) + 1
    spans, depth, instr, esc, start, k = [], 0, False, False, None, i
    while True:
        c = raw[k]
        if instr:
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': instr = False
        else:
            if c == '"': instr = True
            elif c == "{":
                if depth == 0: start = k
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0: spans.append((start, k + 1))
            elif c == "]" and depth == 0:
                return spans, k
        k += 1


def remove_spans(raw, spans):
    for a, b in sorted(spans, reverse=True):
        m = re.match(r"\s*,", raw[b:])
        if m:
            raw = raw[: raw.rfind("\n", 0, a)] + raw[b + m.end():]
        else:
            raw = raw[: raw.rfind(",", 0, a)] + raw[b:]
    return raw


def insert_sites(raw, objs, before_adult=True):
    if not objs:
        return raw
    spans, end = site_spans(raw)
    pos = None
    if before_adult:
        for a, b in spans:
            if "🔞" in json.loads(raw[a:b]).get("name", ""):
                pos = a; break
    txt = ",\n".join("    " + json.dumps(o, ensure_ascii=False, indent=2).replace("\n", "\n    ") for o in objs)
    if pos is not None:
        ls = raw.rfind("\n", 0, pos) + 1
        return raw[:ls] + txt + ",\n" + raw[ls:]
    last_b = spans[-1][1] if spans else None
    if last_b is None:
        return raw[:end] + "\n" + txt + "\n  " + raw[end:]
    return raw[:last_b] + ",\n" + txt + raw[last_b:]


# ---------- 测试接口 ----------
def with_q(api, **kw):
    sep = "&" if "?" in api else "?"
    base = re.sub(r"([?&])ac=list(&|$)", r"\1", api).rstrip("?&")
    sep = "&" if "?" in base else "?"
    return base + sep + urlencode(kw)


def parse_list(text):
    """返回 (是否接口, 条目数)"""
    t = text.lstrip("\ufeff \r\n\t")
    if t.startswith("{"):
        try:
            d = json.loads(t)
        except Exception:
            return False, 0
        if not isinstance(d, dict) or not any(k in d for k in ("list", "class", "total", "pagecount")):
            return False, 0
        return True, len(d.get("list") or [])
    if t.startswith("<?xml") or t.startswith("<rss"):
        return True, len(re.findall(r"<video>", t))
    return False, 0


def probe(api):
    """ok / dead(确定失效) / unknown(可能只是屏蔽海外)"""
    host = urlsplit(api).hostname or ""
    if not re.match(r"^\d+\.\d+\.\d+\.\d+$", host):
        try:
            socket.getaddrinfo(host, None)
        except socket.gaierror:
            return "dead", "域名不存在"
    try:
        r = requests.get(with_q(api, ac="list"), headers={"User-Agent": UA}, timeout=12, verify=False)
    except Exception as e:
        return "unknown", type(e).__name__
    if r.status_code in (404, 410):
        return "dead", f"HTTP{r.status_code}"
    if r.status_code != 200:
        return "unknown", f"HTTP{r.status_code}"
    ok, _ = parse_list(r.text)
    if not ok:
        if "Just a moment" in r.text[:2000]:
            return "unknown", "cloudflare"
        if "<html" in r.text[:500].lower():
            return "dead", "返回网页(域名停放)"
        return "unknown", "非接口内容"
    return "ok", ""


ADULT_CLASS = re.compile(r"无码|有码|中文字幕|巨乳|人妻|自拍|偷拍|制服|丝袜|成人|里番|萝莉|乱伦|黑丝|探花|网红主播|国产传媒|麻豆|SM调教|强奸|口交|颜射")


def full_test(api):
    """新站：列表有数据 + 搜索可用 + 详情有播放地址。返回 None(不可用) / 'adult' / 'normal'"""
    try:
        r = requests.get(with_q(api, ac="detail", pg=1), headers={"User-Agent": UA}, timeout=10, verify=False)
        ok, n = parse_list(r.text)
        if not ok or n == 0 or ("vod_play_url" not in r.text and "<dd" not in r.text):
            return None
        r2 = requests.get(with_q(api, ac="detail", wd="爱"), headers={"User-Agent": UA}, timeout=10, verify=False)
        if not parse_list(r2.text)[0]:
            return None
        r3 = requests.get(with_q(api, ac="list"), headers={"User-Agent": UA}, timeout=10, verify=False)
        try:
            cls = " ".join(str(c.get("type_name", "")) for c in json.loads(r3.text.lstrip("\ufeff")).get("class") or [])
        except Exception:
            cls = " ".join(re.findall(r"<ty[^>]*>([^<]*)</ty>", r3.text))
        return "adult" if len(set(ADULT_CLASS.findall(cls))) >= 3 else "normal"
    except Exception:
        return None


# ---------- 从 GitHub 收集 ----------
ACTIVE_DAYS = int(os.environ.get("ACTIVE_DAYS", "90"))  # 只要最近 N 天有更新的仓库
REPO_QUERIES = ["tvbox", "TVBox 接口", "影视 接口 json", "fongmi", "ok影视", "影视仓", "tvbox 采集"]


def gh_search():
    """搜更新活跃的仓库 + 代码搜索，按仓库最后推送时间排序，只留近 ACTIVE_DAYS 天的"""
    if not TOKEN:
        return []
    h = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json"}
    since = time.strftime("%Y-%m-%d", time.gmtime(time.time() - ACTIVE_DAYS * 86400))
    pushed = {}   # repo -> pushed_at
    files = []

    def get(url, **params):
        try:
            r = requests.get(url, headers=h, params=params, timeout=20)
            if r.status_code == 200:
                return r.json()
            print("gh", r.status_code, url, r.text[:100])
        except Exception as e:
            print("gh err", e)
        return None

    # 1) 活跃仓库
    for q in REPO_QUERIES:
        d = get("https://api.github.com/search/repositories", q=f"{q} pushed:>{since}", sort="updated", order="desc", per_page=50)
        for it in (d or {}).get("items", []):
            pushed[it["full_name"]] = it["pushed_at"]
    # 2) 代码搜索
    for q in QUERIES:
        for page in (1, 2, 3):
            d = get("https://api.github.com/search/code", q=q, per_page=100, page=page)
            items = (d or {}).get("items", [])
            for i in items:
                files.append(f'{i["repository"]["full_name"]}/{i["path"]}')
            time.sleep(7)  # code search 限 10 次/分钟
            if len(items) < 100:
                break
    # 代码搜索命中的仓库补查更新时间
    for repo in list(dict.fromkeys(f.split("/")[0] + "/" + f.split("/")[1] for f in files)):
        if repo not in pushed:
            d = get(f"https://api.github.com/repos/{repo}")
            if d: pushed[repo] = d.get("pushed_at") or ""
    active = {r: t for r, t in pushed.items() if t and t[:10] >= since}
    # 活跃仓库里的 json 文件（每仓最多 8 个）
    for repo in sorted(active, key=active.get, reverse=True)[:80]:
        d = get(f"https://api.github.com/repos/{repo}/git/trees/HEAD", recursive=1)
        js = [t["path"] for t in (d or {}).get("tree", [])
              if t.get("type") == "blob" and t["path"].lower().endswith((".json", ".txt")) and 500 < t.get("size", 0) < 400000]
        files += [f"{repo}/{p}" for p in js[:8]]
    files = [f for f in files if "/".join(f.split("/")[:2]) in active]
    files.sort(key=lambda f: active["/".join(f.split("/")[:2])], reverse=True)
    print("活跃仓库", len(active), "文件", len(files))
    return list(dict.fromkeys(files))


def load_cfg(path):
    repo = "/".join(path.split("/")[:2]); fp = "/".join(path.split("/")[2:])
    url = f"https://raw.githubusercontent.com/{repo}/HEAD/{fp}"
    try:
        t = requests.get(url, timeout=15).text
    except Exception:
        return []
    t = t.lstrip("\ufeff")
    try:
        d = json.loads(t)
    except Exception:
        try:  # 去掉 // 注释再试
            d = json.loads(re.sub(r"(?m)^\s*//.*$", "", t))
        except Exception:
            return []
    sites = d.get("sites") if isinstance(d, dict) else None
    return sites if isinstance(sites, list) else []


def main():
    raw = open(JJOO, encoding="utf-8").read()
    state = json.load(open(STATE)) if os.path.exists(STATE) else {"fails": {}}
    log = []

    # 1) 现有配置按链接去重
    spans, _ = site_spans(raw)
    seen, dup = set(), []
    for a, b in spans:
        o = json.loads(raw[a:b])
        k = norm(o.get("api", "")) if str(o.get("api", "")).startswith("http") else "key:" + o.get("key", "")
        if k in seen:
            dup.append((a, b)); log.append(f"去重删除: {o.get('name')} ({o.get('api')})")
        seen.add(k)
    raw = remove_spans(raw, dup)

    # 2) 检测现有 type0/1 站，连续 FAIL_LIMIT 次确定失效才删
    spans, _ = site_spans(raw)
    cur = [(a, b, json.loads(raw[a:b])) for a, b in spans]
    targets = [(a, b, o) for a, b, o in cur if o.get("type") in (0, 1) and str(o.get("api", "")).startswith("http")]
    with cf.ThreadPoolExecutor(20) as ex:
        res = list(ex.map(lambda t: probe(t[2]["api"]), targets))
    rm = []
    for (a, b, o), (st, why) in zip(targets, res):
        k = norm(o["api"])
        if st == "dead":
            state["fails"][k] = state["fails"].get(k, 0) + 1
            if state["fails"][k] >= FAIL_LIMIT:
                rm.append((a, b)); log.append(f"失效删除: {o.get('name')} ({why}, 连续{state['fails'][k]}次)")
                state["fails"].pop(k, None)
            else:
                log.append(f"失效计数 {state['fails'][k]}/{FAIL_LIMIT}: {o.get('name')} ({why})")
        else:
            state["fails"].pop(k, None)
    raw = remove_spans(raw, rm)

    # 3) 从 GitHub 收集新站
    spans, _ = site_spans(raw)
    seen = {norm(json.loads(raw[a:b]).get("api", "")) for a, b in spans}
    keys = {json.loads(raw[a:b]).get("key") for a, b in spans}
    files = list(dict.fromkeys(gh_search() + SEEDS))[:MAX_FILES]
    print("配置文件数", len(files))
    cand = {}
    with cf.ThreadPoolExecutor(16) as ex:
        for sites in ex.map(load_cfg, files):
            for s in sites:
                if not isinstance(s, dict) or s.get("type") not in (0, 1):
                    continue
                api = str(s.get("api", "")).strip()
                if not api.startswith("http") or "provide" not in api and "apijson" not in api and "xml.php" not in api:
                    continue
                k = norm(api)
                if k in seen or k in cand:
                    continue
                cand[k] = s
    print("候选新站", len(cand))
    items = list(cand.items())
    with cf.ThreadPoolExecutor(20) as ex:
        oks = list(ex.map(lambda kv: full_test(kv[1]["api"]) if probe(kv[1]["api"])[0] == "ok" else None, items))
    new_norm, new_adult = [], []
    for (k, s), ok in zip(items, oks):
        if not ok or len(new_norm) + len(new_adult) >= MAX_NEW:
            continue
        name = str(s.get("name") or s.get("key") or urlsplit(s["api"]).hostname)
        key = str(s.get("key") or name)
        while key in keys:
            key += "_"
        keys.add(key)
        o = {"key": key, "name": name, "type": s["type"], "api": s["api"].strip(),
             "searchable": 1, "quickSearch": 1, "filterable": 0}
        if s.get("categories"):
            o["categories"] = s["categories"]
        adult = ok == "adult" or bool(ADULT.search(name))
        if adult and "🔞" not in o["name"]:
            o["name"] = "🔞" + o["name"]
        (new_adult if adult else new_norm).append(o)
        log.append(f"新增: {o['name']} ({o['api']})")
    raw = insert_sites(raw, new_norm, before_adult=True)
    raw = insert_sites(raw, new_adult, before_adult=False)

    json.loads(raw)  # 校验
    open(JJOO, "w", encoding="utf-8").write(raw)
    json.dump(state, open(STATE, "w"), ensure_ascii=False, indent=1)
    total = len(json.loads(raw)["sites"])
    summary = "\n".join(log) or "无变化"
    print(summary); print("现有站点", total)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(f"### 采集站更新\n现有 {total} 个\n```\n{summary}\n```\n")


if __name__ == "__main__":
    main()
