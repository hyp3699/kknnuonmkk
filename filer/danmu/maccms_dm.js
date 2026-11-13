// 苹果CMS(MacCMS) 采集站通用爬虫 + 自建弹幕
// 适用 FongMi / OK影视 旧版（如 5.1.6）：播放时在 playerContent 里带 danmaku 字段
// 配置示例：
// {"key":"xx","name":"xx","type":3,"api":"https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/maccms_dm.js",
//  "searchable":1,"quickSearch":1,"ext":{"api":"https://采集站/api.php/provide/vod/","playurl":"json:https://解析/?url=","categories":["动作片"]}}

let API = '';
let PLAYURL = '';
let CATS = [];
let DM = 'http://54.206.164.99:2525';
let XML = false;
const UA = { 'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36' };
const SEP = '|dm|';

function baseApi(u) {
    u = (u || '').trim();
    const q = u.indexOf('?');
    if (q >= 0) u = u.substring(0, q);
    return u;
}

function url(params) {
    const qs = Object.keys(params).filter(k => params[k] !== undefined && params[k] !== '').map(k => k + '=' + encodeURIComponent(params[k])).join('&');
    return API + (API.indexOf('?') >= 0 ? '&' : '?') + qs;
}

async function get(u) {
    try {
        const r = await req(u, { headers: UA, timeout: 15000 });
        return (r && r.content) || '';
    } catch (e) {
        return '';
    }
}

// ---------- XML 采集接口(type 0) 解析 ----------
function tag(s, t) {
    const m = s.match(new RegExp('<' + t + '[^>]*>([\\s\\S]*?)</' + t + '>'));
    return m ? m[1].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').trim() : '';
}

function parseXml(text) {
    const out = { class: [], list: [], page: 1, pagecount: 1 };
    const cls = text.match(/<class>([\s\S]*?)<\/class>/);
    if (cls) {
        const re = /<ty id="(\d+)">([\s\S]*?)<\/ty>/g;
        let m;
        while ((m = re.exec(cls[1]))) out.class.push({ type_id: m[1], type_name: m[2].trim() });
    }
    const lm = text.match(/<list([^>]*)>/);
    if (lm) {
        const p = lm[1].match(/page="(\d+)"/), pc = lm[1].match(/pagecount="(\d+)"/);
        if (p) out.page = +p[1];
        if (pc) out.pagecount = +pc[1];
    }
    const vre = /<video>([\s\S]*?)<\/video>/g;
    let v;
    while ((v = vre.exec(text))) {
        const s = v[1];
        const froms = [], urls = [];
        const dre = /<dd flag="([^"]*)">([\s\S]*?)<\/dd>/g;
        let d;
        while ((d = dre.exec(s))) {
            froms.push(d[1] || ('线路' + (froms.length + 1)));
            urls.push(d[2].replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1').trim());
        }
        out.list.push({
            vod_id: tag(s, 'id'), vod_name: tag(s, 'name'), vod_pic: tag(s, 'pic'), vod_remarks: tag(s, 'note'),
            type_name: tag(s, 'type'), vod_year: tag(s, 'year'), vod_area: tag(s, 'area'), vod_lang: tag(s, 'lang'),
            vod_actor: tag(s, 'actor'), vod_director: tag(s, 'director'), vod_content: tag(s, 'des'),
            vod_play_from: froms.join('$$$'), vod_play_url: urls.join('$$$'),
        });
    }
    return out;
}

async function fetchData(params) {
    const text = await get(url(params));
    if (!text) return { class: [], list: [] };
    if (XML || text.trim().startsWith('<')) {
        return parseXml(text);
    }
    try {
        return JSON.parse(text);
    } catch (e) {
        return { class: [], list: [] };
    }
}

function short(v) {
    return { vod_id: String(v.vod_id), vod_name: v.vod_name, vod_pic: v.vod_pic || '', vod_remarks: v.vod_remarks || '' };
}

// ---------- 接口 ----------
async function init(cfg) {
    let ext = cfg && cfg.ext !== undefined ? cfg.ext : cfg;
    if (typeof ext === 'string') {
        try { ext = JSON.parse(ext); } catch (e) { ext = { api: ext }; }
    }
    ext = ext || {};
    API = baseApi(ext.api);
    PLAYURL = ext.playurl || ext.playUrl || '';
    CATS = ext.categories || [];
    if (ext.dm) DM = ext.dm.replace(/\/$/, '');
    XML = /\/at\/xml|xml\.php/i.test(ext.api || '') || ext.type === 0;
}

async function home(filter) {
    const data = await fetchData({ ac: XML ? 'list' : 'list' });
    let cls = (data.class || []).map(c => ({ type_id: String(c.type_id), type_name: c.type_name }));
    if (CATS.length) {
        const keep = cls.filter(c => CATS.indexOf(c.type_name) >= 0);
        keep.sort((a, b) => CATS.indexOf(a.type_name) - CATS.indexOf(b.type_name));
        if (keep.length) cls = keep;
    }
    return JSON.stringify({ class: cls });
}

async function homeVod() {
    const data = await fetchData({ ac: XML ? 'videolist' : 'detail', pg: 1 });
    return JSON.stringify({ list: (data.list || []).slice(0, 30).map(short) });
}

async function category(tid, pg, filter, extend) {
    pg = pg || 1;
    const data = await fetchData({ ac: XML ? 'videolist' : 'detail', t: tid, pg: pg });
    return JSON.stringify({
        page: +(data.page || pg), pagecount: +(data.pagecount || 1), limit: +(data.limit || 20), total: +(data.total || 0),
        list: (data.list || []).map(short),
    });
}

async function detail(id) {
    const data = await fetchData({ ac: XML ? 'videolist' : 'detail', ids: id });
    const v = (data.list || [])[0];
    if (!v) return JSON.stringify({ list: [] });
    const name = v.vod_name || '';
    // 把剧名、集名塞进播放 id，play 时生成弹幕地址
    const urls = (v.vod_play_url || '').split('$$$').map(group => group.split('#').filter(x => x).map(item => {
        const i = item.indexOf('$');
        const ep = i >= 0 ? item.substring(0, i) : '正片';
        const u = i >= 0 ? item.substring(i + 1) : item;
        return ep + '$' + u + SEP + encodeURIComponent(name) + SEP + encodeURIComponent(ep);
    }).join('#')).join('$$$');
    const vod = {
        vod_id: String(v.vod_id), vod_name: name, vod_pic: v.vod_pic || '', type_name: v.type_name || '',
        vod_year: v.vod_year || '', vod_area: v.vod_area || '', vod_remarks: v.vod_remarks || '',
        vod_actor: v.vod_actor || '', vod_director: v.vod_director || '',
        vod_content: (v.vod_content || '').replace(/<[^>]+>/g, '').trim(),
        vod_play_from: v.vod_play_from || '', vod_play_url: urls,
    };
    return JSON.stringify({ list: [vod] });
}

async function search(wd, quick, pg) {
    const data = await fetchData({ ac: XML ? 'videolist' : 'detail', wd: wd, pg: pg || 1 });
    return JSON.stringify({ list: (data.list || []).map(short) });
}

function isMedia(u) {
    return /\.(m3u8|mp4|flv|mkv|avi|mov|ts)(\?|$)/i.test(u);
}

async function play(flag, id, flags) {
    const parts = id.split(SEP);
    let u = parts[0];
    const name = parts.length > 1 ? decodeURIComponent(parts[1]) : '';
    const ep = parts.length > 2 ? decodeURIComponent(parts[2]) : '';
    const res = { parse: 0, url: u, header: {} };
    if (!isMedia(u)) {
        if (PLAYURL.startsWith('json:')) {
            try {
                const j = JSON.parse(await get(PLAYURL.substring(5) + u));
                if (j && j.url) u = j.url;
            } catch (e) {}
            res.url = u;
            if (!/^https?:/.test(u) || !isMedia(u)) { res.parse = 1; res.jx = 1; }
        } else if (PLAYURL) {
            res.url = PLAYURL + u; res.parse = 1;
        } else {
            res.parse = 1; res.jx = 1;
        }
    }
    if (name) {
        const epArg = /正片|HD|高清|超清|蓝光|TC|TS|抢先/i.test(ep) && !/\d/.test(ep) ? '' : ep;
        res.danmaku = DM + '/danmu?fmt=xml&name=' + encodeURIComponent(name) + '&epid=' + encodeURIComponent(epArg);
    }
    return JSON.stringify(res);
}

export function __jsEvalReturn() {
    return { init: init, home: home, homeVod: homeVod, category: category, detail: detail, play: play, search: search };
}
