const IPV6_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/ipv6/CloudFlare-ipv6.txt';
const WS_SUB_PROTOCOL='grpc';

async function fetchIPv6List(count){
    const response=await fetch(IPV6_LIST_URL,{headers:{'User-Agent':'Cloudflare-Worker'}});
    if(!response.ok)throw new Error(`IPv6 地址列表获取失败：HTTP ${response.status}`);
    const text=await response.text();
    const dateGroups={};
    for(const line of text.split(/\r?\n/)){
        const parts=line.trim().split(/\s+/);
        if(parts.length<2)continue;
        const date=parts[0];
        const ipv6=parts[parts.length-1];
        if(!/^\d{4}-\d{2}-\d{2}$/.test(date))continue;
        if(!ipv6.includes(':'))continue;
        if(!dateGroups[date])dateGroups[date]=[];
        if(!dateGroups[date].includes(ipv6))dateGroups[date].push(ipv6);
    }
    const dates=Object.keys(dateGroups);
    if(dates.length===0)throw new Error('IPv6 地址列表为空');
    dates.sort((a,b)=>b.localeCompare(a));
    const ipv6List=[];
    for(const date of dates){
        for(const ipv6 of dateGroups[date]){
            if(!ipv6List.includes(ipv6))ipv6List.push(ipv6);
            if(ipv6List.length>=count)return ipv6List;
        }
    }
    return ipv6List;
}

function base64Encode(text){
    const bytes=new TextEncoder().encode(text);
    let binary='';
    for(let i=0;i<bytes.length;i+=0x8000){
        binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
    }
    return btoa(binary);
}

function base64UrlEncode(bytes){
    let binary='';
    for(const byte of bytes){
        binary+=String.fromCharCode(byte);
    }
    return btoa(binary).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}

function base64UrlDecode(value){
    const normalized=value.replace(/-/g,'+').replace(/_/g,'/');
    const padded=normalized+'='.repeat((4-normalized.length%4)%4);
    const binary=atob(padded);
    const bytes=new Uint8Array(binary.length);
    for(let i=0;i<binary.length;i++){
        bytes[i]=binary.charCodeAt(i);
    }
    return bytes;
}

async function getCryptoKey(secret){
    if(!secret){
        throw new Error('TOKEN_SECRET 未配置');
    }
    const hash=await crypto.subtle.digest(
        'SHA-256',
        new TextEncoder().encode(secret)
    );
    return crypto.subtle.importKey(
        'raw',
        hash,
        {
            name:'AES-GCM'
        },
        false,
        ['encrypt','decrypt']
    );
}

async function createToken(data,secret){
    const key=await getCryptoKey(secret);
    const iv=crypto.getRandomValues(new Uint8Array(12));
    const plaintext=new TextEncoder().encode(JSON.stringify(data));
    const encrypted=await crypto.subtle.encrypt(
        {
            name:'AES-GCM',
            iv
        },
        key,
        plaintext
    );
    const encryptedBytes=new Uint8Array(encrypted);
    const tokenBytes=new Uint8Array(iv.length+encryptedBytes.length);
    tokenBytes.set(iv,0);
    tokenBytes.set(encryptedBytes,iv.length);
    return base64UrlEncode(tokenBytes);
}

async function decodeToken(token,secret){
    try{
        const data=base64UrlDecode(token);
        if(data.length<13)throw new Error('Token 无效');
        const iv=data.slice(0,12);
        const encrypted=data.slice(12);
        const key=await getCryptoKey(secret);
        const decrypted=await crypto.subtle.decrypt(
            {
                name:'AES-GCM',
                iv
            },
            key,
            encrypted
        );
        const text=new TextDecoder().decode(decrypted);
        const config=JSON.parse(text);
        if(!config||!config.uuid||!config.type||!config.path||!config.sni){
            throw new Error('Token 数据无效');
        }
        return config;
    }catch(error){
        throw new Error('订阅 Token 无效');
    }
}

function validateUUID(uuid){
    return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/.test(uuid);
}

function validateConfig(uuid,type,path,sni){
    if(!validateUUID(uuid))throw new Error('UUID 格式错误');
    if(type!=='xhttp'&&type!=='vless'&&type!=='vmess'){
        throw new Error('只支持 xhttp、vless 和 vmess');
    }
    if(!path)throw new Error('路径不能为空');
    if(!path.startsWith('/'))path='/'+path;
    if(path==='/')throw new Error('路径不能为空');
    if(!sni)throw new Error('域名不能为空');
    return{
        uuid,
        type,
        path,
        sni
    };
}

function generateXhttpLink(uuid,ipv6,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('alpn','h3');
    params.set('type','xhttp');
    params.set('path',path);
    params.set('host',sni);
    return`vless://${uuid}@[${ipv6}]:443?${params.toString()}`;
}

function generateVlessWsLink(uuid,ipv6,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('type','ws');
    params.set('path',path);
    params.set('host',sni);
    params.set('max_early_data','2048');
    params.set('early_data_header_name','Sec-WebSocket-Protocol');
    return`vless://${uuid}@[${ipv6}]:443?${params.toString()}`;
}

function generateVmessWsLink(uuid,ipv6,path,sni){
    const config={
        v:"2",
        ps:`${sni}-${ipv6}`,
        add:ipv6,
        port:"443",
        id:uuid,
        aid:"0",
        scy:"auto",
        net:"ws",
        type:"none",
        host:sni,
        path:path,
        tls:"tls",
        sni:sni,
        alpn:"",
        fp:"",
        max_early_data:2048,
        early_data_header_name:"Sec-WebSocket-Protocol"
    };
    return`vmess://${base64Encode(JSON.stringify(config))}`;
}

async function generateSubscription(uuid,type,path,sni,count){
    const ipv6List=await fetchIPv6List(count);
    const result=[];
    for(const ipv6 of ipv6List){
        if(type==='xhttp'){
            result.push(generateXhttpLink(uuid,ipv6,path,sni));
        }else if(type==='vless'){
            result.push(generateVlessWsLink(uuid,ipv6,path,sni));
        }else{
            result.push(generateVmessWsLink(uuid,ipv6,path,sni));
        }
    }
    return result.join('\n');
}

function htmlPage(message='',result=''){
    return`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IPv6</title>
<style>
body{margin:0;padding:20px;background:#f5f5f5;font-family:Arial,sans-serif}
.container{max-width:700px;margin:40px auto;background:white;padding:25px;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08)}
h2{margin-top:0}
input,select{width:100%;box-sizing:border-box;padding:12px;margin-top:10px;border:1px solid #ccc;border-radius:8px;font-size:14px;background:white}
button{width:100%;margin-top:15px;padding:12px;border:0;border-radius:8px;background:#111;color:white;font-size:16px;cursor:pointer}
textarea{width:100%;box-sizing:border-box;margin-top:15px;padding:12px;border:1px solid #ccc;border-radius:8px;resize:vertical}
.result{height:100px}
</style>
</head>
<body>
<div class="container">
<h2>IPv6</h2>
<form method="POST">
<input name="uuid" placeholder="UUID" required>
<select name="type" required>
<option value="" disabled selected>请选择类型</option>
<option value="xhttp">XHTTP</option>
<option value="vless">VLESS</option>
<option value="vmess">VMess</option>
</select>
<input name="path" placeholder="路径" required>
<input name="sni" placeholder="域名" required>
<button type="submit">生成</button>
</form>
${message?`<div>${escapeHtml(message)}</div>`:''}
${result?`<textarea class="result" readonly onclick="this.select()">${escapeHtml(result)}</textarea>`:''}
</div>
</body>
</html>`;
}

function escapeHtml(text){
    return String(text)
        .replace(/&/g,'&amp;')
        .replace(/</g,'&lt;')
        .replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;')
        .replace(/'/g,'&#039;');
}

function subscriptionResponse(data){
    return new Response(data,{
        status:200,
        headers:{
            'Content-Type':'text/plain; charset=utf-8',
            'Cache-Control':'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma':'no-cache',
            'Access-Control-Allow-Origin':'*'
        }
    });
}

export default{
    async fetch(request,env){
        const url=new URL(request.url);
        if(request.method==='GET'&&url.pathname!=='/'){
            try{
                const token=url.pathname.slice(1);
                if(!token)throw new Error('订阅 Token 不能为空');
                const config=await decodeToken(token,env.TOKEN_SECRET);
                const validated=validateConfig(
                    config.uuid,
                    config.type,
                    config.path,
                    config.sni
                );
                const countValue=url.searchParams.get('count');
                const count=countValue?parseInt(countValue,10):30;
                if(!Number.isInteger(count)||count<1||count>200){
                    throw new Error('节点数量必须是1-200之间的整数');
                }
                const result=await generateSubscription(
                    validated.uuid,
                    validated.type,
                    validated.path,
                    validated.sni,
                    count
                );
                return subscriptionResponse(base64Encode(result));
            }catch(error){
                return new Response(
                    error.message||'订阅生成失败',
                    {
                        status:400,
                        headers:{
                            'Content-Type':'text/plain; charset=utf-8',
                            'Cache-Control':'no-store, no-cache, must-revalidate, max-age=0',
                            'Pragma':'no-cache',
                            'Access-Control-Allow-Origin':'*'
                        }
                    }
                );
            }
        }
        if(url.pathname!=='/')return new Response('Not Found',{status:404});
        if(request.method==='GET'){
            return new Response(htmlPage(),{
                headers:{
                    'Content-Type':'text/html; charset=utf-8'
                }
            });
        }
        if(request.method==='POST'){
            try{
                const form=await request.formData();
                const uuid=String(form.get('uuid')||'').trim();
                const type=String(form.get('type')||'').trim().toLowerCase();
                let path=String(form.get('path')||'').trim();
                const sni=String(form.get('sni')||'').trim();
                if(!path.startsWith('/'))path='/'+path;
                const config=validateConfig(
                    uuid,
                    type,
                    path,
                    sni
                );
                const token=await createToken(config,env.TOKEN_SECRET);
                const subscriptionUrl=`${url.origin}/${token}?count=30`;
                return new Response(
                    htmlPage('',subscriptionUrl),
                    {
                        headers:{
                            'Content-Type':'text/html; charset=utf-8'
                        }
                    }
                );
            }catch(error){
                return new Response(
                    htmlPage('',error.message||'生成失败'),
                    {
                        status:400,
                        headers:{
                            'Content-Type':'text/html; charset=utf-8'
                        }
                    }
                );
            }
        }
        return new Response('Method Not Allowed',{status:405});
    }
};
