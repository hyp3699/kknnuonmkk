const IPV6_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/ipv6/CloudFlare-ipv6.txt';
const IPV4_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/ipv6/CloudFlare-ipv4.txt';
const DOMAIN_LIST_URL='https://raw.githubusercontent.com/hyp3699/CF-Pages-BestCF/refs/heads/main/cf_domains.txt';
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
async function fetchIPv4List(count){
    const response=await fetch(IPV4_LIST_URL,{headers:{'User-Agent':'Cloudflare-Worker'}});
    if(!response.ok)throw new Error(`IPv4 地址列表获取失败：HTTP ${response.status}`);
    const text=await response.text();
    const ipv4List=[];
    for(const line of text.split(/\r?\n/)){
        const value=line.trim();
        if(!value)continue;
        const parts=value.split(/\s+/);
        let ipv4='';
        for(const part of parts){
            if(/^(?:\d{1,3}\.){3}\d{1,3}$/.test(part)){
                const nums=part.split('.').map(Number);
                if(nums.length===4&&nums.every(n=>n>=0&&n<=255)){
                    ipv4=part;
                    break;
                }
            }
        }
        if(!ipv4)continue;
        if(!ipv4List.includes(ipv4))ipv4List.push(ipv4);
        if(ipv4List.length>=count)break;
    }
    if(ipv4List.length===0)throw new Error('IPv4 地址列表为空');
    return ipv4List;
}
async function fetchDomainList(count){
    const response=await fetch(DOMAIN_LIST_URL,{headers:{'User-Agent':'Cloudflare-Worker'}});
    if(!response.ok)throw new Error(`优选域名列表获取失败：HTTP ${response.status}`);
    const text=await response.text();
    const domainList=[];
    for(const line of text.split(/\r?\n/)){
        let domain=line.trim();
        if(!domain)continue;
        domain=domain.replace(/^https?:\/\//i,'').split('/')[0].split(/\s+/)[0].trim();
        if(/^[^:]+:\d+$/.test(domain))domain=domain.replace(/:\d+$/,'');
        if(!/^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/.test(domain))continue;
        if(!domainList.includes(domain))domainList.push(domain);
        if(domainList.length>=count)break;
    }
    if(domainList.length===0)throw new Error('优选域名列表为空');
    return domainList;
}
function base64Encode(text){
    const bytes=new TextEncoder().encode(text);
    let binary='';
    for(let i=0;i<bytes.length;i+=0x8000)binary+=String.fromCharCode(...bytes.subarray(i,i+0x8000));
    return btoa(binary);
}
function base64UrlEncode(bytes){
    let binary='';
    for(const byte of bytes)binary+=String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
function base64UrlDecode(value){
    const normalized=value.replace(/-/g,'+').replace(/_/g,'/');
    const padded=normalized+'='.repeat((4-normalized.length%4)%4);
    const binary=atob(padded);
    const bytes=new Uint8Array(binary.length);
    for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
    return bytes;
}
async function getCryptoKey(secret){
    if(!secret)throw new Error('TOKEN_SECRET 未配置');
    const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(secret));
    return crypto.subtle.importKey('raw',hash,{name:'AES-GCM'},false,['encrypt','decrypt']);
}
async function createToken(data,secret){
    const key=await getCryptoKey(secret);
    const iv=crypto.getRandomValues(new Uint8Array(12));
    const plaintext=new TextEncoder().encode(JSON.stringify(data));
    const encrypted=await crypto.subtle.encrypt({name:'AES-GCM',iv},key,plaintext);
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
        const decrypted=await crypto.subtle.decrypt({name:'AES-GCM',iv},key,encrypted);
        const text=new TextDecoder().decode(decrypted);
        const config=JSON.parse(text);
        if(!config||!config.uuid||!config.type||!config.path||!config.sni)throw new Error('Token 数据无效');
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
    if(type!=='xhttp'&&type!=='vless'&&type!=='vmess')throw new Error('只支持 xhttp、vless 和 vmess');
    if(!path)throw new Error('路径不能为空');
    if(!path.startsWith('/'))path='/'+path;
    if(path==='/')throw new Error('路径不能为空');
    if(!sni)throw new Error('域名不能为空');
    return{uuid,type,path,sni};
}
function parseNodeLink(nodeLink){
    nodeLink=String(nodeLink||'').trim().replace(/^```[a-zA-Z]*\s*/,'').replace(/\s*```$/,'').trim();
    if(!nodeLink)throw new Error('节点链接不能为空');
    if(/^vmess:\/\//i.test(nodeLink)){
        const body=nodeLink.slice(8).trim();
        if(!body.includes('@')){
            try{
                const decoded=new TextDecoder().decode(base64UrlDecode(body));
                const config=JSON.parse(decoded);
                const uuid=String(config.id||config.uuid||'').trim();
                const path=String(config.path||'').trim();
                const sni=String(config.sni||config.host||'').trim();
                if(!uuid)throw new Error('VMess 节点中没有 UUID');
                if(!path)throw new Error('VMess 节点中没有路径');
                if(!sni)throw new Error('VMess 节点中没有 SNI/Host');
                return{uuid,type:'vmess',path,sni};
            }catch(error){}
        }
        try{
            const parsed=new URL(nodeLink);
            const uuid=decodeURIComponent(parsed.username||'').trim();
            const params=parsed.searchParams;
            const path=String(params.get('path')||'').trim();
            const sni=String(params.get('sni')||params.get('host')||'').trim();
            if(!uuid)throw new Error('VMess 节点中没有 UUID');
            if(!path)throw new Error('VMess 节点中没有路径');
            if(!sni)throw new Error('VMess 节点中没有 SNI/Host');
            return{uuid,type:'vmess',path,sni};
        }catch(error){
            if(error.message&&!error.message.includes('Invalid URL'))throw error;
            throw new Error('VMess 节点链接格式无法解析');
        }
    }
    if(/^vless:\/\//i.test(nodeLink)){
        try{
            const parsed=new URL(nodeLink);
            const uuid=decodeURIComponent(parsed.username||'').trim();
            const params=parsed.searchParams;
            const path=String(params.get('path')||'').trim();
            const sni=String(params.get('sni')||params.get('host')||'').trim();
            const transport=String(params.get('type')||'').trim().toLowerCase();
            const type=transport==='xhttp'?'xhttp':'vless';
            if(!uuid)throw new Error('VLESS 节点中没有 UUID');
            if(!path)throw new Error('VLESS 节点中没有路径');
            if(!sni)throw new Error('VLESS 节点中没有 SNI/Host');
            return{uuid,type,path,sni};
        }catch(error){
            if(error.message&&!error.message.includes('Invalid URL'))throw error;
            throw new Error('VLESS 节点链接格式无法解析');
        }
    }
    throw new Error('只支持 vmess:// 和 vless:// 节点链接');
}
function formatServerAddress(server){
    if(server.includes(':'))return`[${server}]:443`;
    return`${server}:443`;
}
function generateXhttpLink(uuid,server,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('alpn','h3');
    params.set('type','xhttp');
    params.set('path',path);
    params.set('host',sni);
    return`vless://${uuid}@${formatServerAddress(server)}?${params.toString()}`;
}
function generateVlessWsLink(uuid,server,path,sni){
    const params=new URLSearchParams();
    params.set('encryption','none');
    params.set('security','tls');
    params.set('sni',sni);
    params.set('type','ws');
    params.set('path',path);
    params.set('host',sni);
    params.set('max_early_data','2048');
    params.set('early_data_header_name','Sec-WebSocket-Protocol');
    return`vless://${uuid}@${formatServerAddress(server)}?${params.toString()}`;
}
function generateVmessWsLink(uuid,server,path,sni){
    const config={
        v:"2",
        ps:server,
        add:server,
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
function validateMode(mode){
    if(!mode)return'6';
    mode=String(mode).toLowerCase().replace(/[^y46]/g,'');
    let result='';
    if(mode.includes('y'))result+='y';
    if(mode.includes('4'))result+='4';
    if(mode.includes('6'))result+='6';
    if(!result)throw new Error('地址类型参数无效，只支持 y、4、6');
    return result;
}
async function generateSubscription(uuid,type,path,sni,count,mode){
    mode=validateMode(mode);
    const servers=[];
    if(mode.includes('y')){
        const domains=await fetchDomainList(count);
        for(const domain of domains)servers.push({address:domain,type:'domain'});
    }
    if(mode.includes('4')){
        const ipv4List=await fetchIPv4List(count);
        for(const ipv4 of ipv4List)servers.push({address:ipv4,type:'ipv4'});
    }
    if(mode.includes('6')){
        const ipv6List=await fetchIPv6List(count);
        for(const ipv6 of ipv6List)servers.push({address:ipv6,type:'ipv6'});
    }
    if(servers.length===0)throw new Error('没有可用的服务器地址');
    const result=[];
    for(const server of servers){
        if(type==='xhttp')result.push(generateXhttpLink(uuid,server.address,path,sni));
        else if(type==='vless')result.push(generateVlessWsLink(uuid,server.address,path,sni));
        else result.push(generateVmessWsLink(uuid,server.address,path,sni));
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
.node-link{margin-top:15px}
.node-link-title{font-size:14px;font-weight:bold;margin-bottom:6px}
.node-link-hint{font-size:12px;color:#777;margin-top:6px;line-height:1.5}
.parse-status{font-size:13px;margin-top:8px;min-height:18px}
.address-options{margin-top:15px;padding:12px;border:1px solid #ccc;border-radius:8px;background:#fafafa}
.address-title{font-size:14px;font-weight:bold;margin-bottom:10px}
.option{display:flex;align-items:center;margin:8px 0;font-size:14px}
.option input{width:auto;margin:0 8px 0 0;padding:0}
button{width:100%;margin-top:15px;padding:12px;border:0;border-radius:8px;background:#111;color:white;font-size:16px;cursor:pointer}
textarea{width:100%;box-sizing:border-box;margin-top:15px;padding:12px;border:1px solid #ccc;border-radius:8px;resize:vertical}
.node-input{min-height:100px}
.result{height:100px}
</style>
</head>
<body>
<div class="container">
<h2>IPv6</h2>
<form method="POST">
<div class="node-link">
<div class="node-link-title">直接解析节点</div>
<textarea class="node-input" id="node_link" name="node_link" placeholder="粘贴 vmess:// 或 vless:// 节点链接"></textarea>
<div class="node-link-hint">粘贴后自动提取 UUID、类型、路径、SNI，下面可以检查并手动修改。</div>
<div id="parse_status" class="parse-status"></div>
</div>
<input id="uuid" name="uuid" placeholder="UUID">
<select id="type" name="type">
<option value="" selected>请选择类型</option>
<option value="xhttp">XHTTP</option>
<option value="vless">VLESS</option>
<option value="vmess">VMess</option>
</select>
<input id="path" name="path" placeholder="路径">
<input id="sni" name="sni" placeholder="域名">
<div class="address-options">
<div class="address-title">服务器地址</div>
<label class="option"><input type="checkbox" name="address" value="y">优选域名</label>
<label class="option"><input type="checkbox" name="address" value="4">IPv4</label>
<label class="option"><input type="checkbox" name="address" value="6" checked>IPv6</label>
</div>
<button type="submit">生成</button>
</form>
${message?`<div>${escapeHtml(message)}</div>`:''}
${result?`<textarea class="result" readonly onclick="this.select()">${escapeHtml(result)}</textarea>`:''}
</div>
<script>
function decodeBase64Text(value){
    value=value.trim().replace(/-/g,'+').replace(/_/g,'/');
    value+='='.repeat((4-value.length%4)%4);
    const binary=atob(value);
    const bytes=new Uint8Array(binary.length);
    for(let i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
}
function parseNodeLinkClient(nodeLink){
    nodeLink=String(nodeLink||'').trim().replace(/^\\\`\\\`\\\`[a-zA-Z]*\\s*/,'').replace(/\\s*\\\`\\\`\\\`$/,'').trim();
    if(!nodeLink)throw new Error('节点链接不能为空');
    if(/^vmess:\\/\\//i.test(nodeLink)){
        const body=nodeLink.slice(8).trim();
        if(!body.includes('@')){
            try{
                const config=JSON.parse(decodeBase64Text(body));
                const uuid=String(config.id||config.uuid||'').trim();
                const path=String(config.path||'').trim();
                const sni=String(config.sni||config.host||'').trim();
                if(!uuid)throw new Error('VMess 中没有 UUID');
                if(!path)throw new Error('VMess 中没有路径');
                if(!sni)throw new Error('VMess 中没有 SNI/Host');
                return{uuid,type:'vmess',path,sni};
            }catch(error){}
        }
        try{
            const parsed=new URL(nodeLink);
            const uuid=decodeURIComponent(parsed.username||'').trim();
            const params=parsed.searchParams;
            const path=String(params.get('path')||'').trim();
            const sni=String(params.get('sni')||params.get('host')||'').trim();
            if(!uuid)throw new Error('VMess 中没有 UUID');
            if(!path)throw new Error('VMess 中没有路径');
            if(!sni)throw new Error('VMess 中没有 SNI/Host');
            return{uuid,type:'vmess',path,sni};
        }catch(error){
            if(error.message&&!error.message.includes('Invalid URL'))throw error;
            throw new Error('VMess 节点格式无法解析');
        }
    }
    if(/^vless:\\/\\//i.test(nodeLink)){
        try{
            const parsed=new URL(nodeLink);
            const uuid=decodeURIComponent(parsed.username||'').trim();
            const params=parsed.searchParams;
            const path=String(params.get('path')||'').trim();
            const sni=String(params.get('sni')||params.get('host')||'').trim();
            const transport=String(params.get('type')||'').trim().toLowerCase();
            const type=transport==='xhttp'?'xhttp':'vless';
            if(!uuid)throw new Error('VLESS 中没有 UUID');
            if(!path)throw new Error('VLESS 中没有路径');
            if(!sni)throw new Error('VLESS 中没有 SNI/Host');
            return{uuid,type,path,sni};
        }catch(error){
            if(error.message&&!error.message.includes('Invalid URL'))throw error;
            throw new Error('VLESS 节点格式无法解析');
        }
    }
    throw new Error('只支持 vmess:// 和 vless:// 节点');
}
const nodeLinkInput=document.getElementById('node_link');
const uuidInput=document.getElementById('uuid');
const typeInput=document.getElementById('type');
const pathInput=document.getElementById('path');
const sniInput=document.getElementById('sni');
const parseStatus=document.getElementById('parse_status');
function parseAndFillNode(){
    const value=nodeLinkInput.value.trim();
    if(!value){
        parseStatus.textContent='';
        return;
    }
    try{
        const parsed=parseNodeLinkClient(value);
        uuidInput.value=parsed.uuid;
        typeInput.value=parsed.type;
        pathInput.value=parsed.path;
        sniInput.value=parsed.sni;
        parseStatus.textContent='✓ 节点解析成功，可以检查或修改下面的参数';
        parseStatus.style.color='green';
    }catch(error){
        parseStatus.textContent='✗ '+(error.message||'节点解析失败');
        parseStatus.style.color='red';
    }
}
nodeLinkInput.addEventListener('input',parseAndFillNode);
nodeLinkInput.addEventListener('paste',function(){setTimeout(parseAndFillNode,50)});
nodeLinkInput.addEventListener('blur',parseAndFillNode);
</script>
</body>
</html>`;
}
function escapeHtml(text){
    return String(text).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#039;');
}
function subscriptionResponse(data){
    return new Response(data,{status:200,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store, no-cache, must-revalidate, max-age=0','Pragma':'no-cache','Access-Control-Allow-Origin':'*'}});
}
export default{
    async fetch(request,env){
        const url=new URL(request.url);
        if(request.method==='GET'&&url.pathname!=='/'){
            try{
                const token=url.pathname.slice(1);
                if(!token)throw new Error('订阅 Token 不能为空');
                const config=await decodeToken(token,env.TOKEN_SECRET);
                const validated=validateConfig(config.uuid,config.type,config.path,config.sni);
                const countValue=url.searchParams.get('count');
                const count=countValue?parseInt(countValue,10):30;
                if(!Number.isInteger(count)||count<1||count>200)throw new Error('节点数量必须是1-200之间的整数');
                let mode='';
                for(const key of url.searchParams.keys()){
                    if(key==='count')continue;
                    if(/^[y46]+$/i.test(key))mode+=key;
                }
                mode=validateMode(mode||'6');
                const result=await generateSubscription(validated.uuid,validated.type,validated.path,validated.sni,count,mode);
                return subscriptionResponse(base64Encode(result));
            }catch(error){
                return new Response(error.message||'订阅生成失败',{status:400,headers:{'Content-Type':'text/plain; charset=utf-8','Cache-Control':'no-store, no-cache, must-revalidate, max-age=0','Pragma':'no-cache','Access-Control-Allow-Origin':'*'}});
            }
        }
        if(url.pathname!=='/')return new Response('Not Found',{status:404});
        if(request.method==='GET'){
            return new Response(htmlPage(),{headers:{'Content-Type':'text/html; charset=utf-8'}});
        }
        if(request.method==='POST'){
            try{
                const form=await request.formData();
                const nodeLink=String(form.get('node_link')||'').trim();
                let uuid=String(form.get('uuid')||'').trim();
                let type=String(form.get('type')||'').trim().toLowerCase();
                let path=String(form.get('path')||'').trim();
                let sni=String(form.get('sni')||'').trim();
                if(nodeLink){
                    const parsed=parseNodeLink(nodeLink);
                    if(!uuid)uuid=parsed.uuid;
                    if(!type)type=parsed.type;
                    if(!path)path=parsed.path;
                    if(!sni)sni=parsed.sni;
                }
                const addressValues=form.getAll('address');
                let mode='';
                for(const value of addressValues){
                    if(value==='y'||value==='4'||value==='6')mode+=value;
                }
                mode=validateMode(mode||'6');
                if(path&&!path.startsWith('/'))path='/'+path;
                const config=validateConfig(uuid,type,path,sni);
                config.mode=mode;
                const token=await createToken(config,env.TOKEN_SECRET);
                const subscriptionUrl=`${url.origin}/${token}?${mode}&count=30`;
                return new Response(htmlPage('',subscriptionUrl),{headers:{'Content-Type':'text/html; charset=utf-8'}});
            }catch(error){
                return new Response(htmlPage('',error.message||'生成失败'),{status:400,headers:{'Content-Type':'text/html; charset=utf-8'}});
            }
        }
        return new Response('Method Not Allowed',{status:405});
    }
};
