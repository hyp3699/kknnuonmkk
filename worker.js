const IPV6_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/ipv6/CloudFlare-ipv6.txt';
const IPV4_LIST_URL='https://raw.githubusercontent.com/hyp3699/kknnuonmkk/refs/heads/main/ipv6/CloudFlare-ipv4.txt';
const DOMAIN_LIST_URL='https://raw.githubusercontent.com/hyp3699/CF-Pages-BestCF/refs/heads/main/cf_domains.txt';

const WS_SUB_PROTOCOL='grpc';

async function fetchIPv6List(count){
    const response=await fetch(IPV6_LIST_URL,{
        headers:{
            'User-Agent':'Cloudflare-Worker'
        }
    });

    if(!response.ok){
        throw new Error(`IPv6 地址列表获取失败：HTTP ${response.status}`);
    }

    const text=await response.text();
    const dateGroups={};

    for(const line of text.split(/\r?\n/)){
        const parts=line.trim().split(/\s+/);

        if(parts.length<2)continue;

        const date=parts[0];
        const ipv6=parts[parts.length-1];

        if(!/^\d{4}-\d{2}-\d{2}$/.test(date))continue;
        if(!ipv6.includes(':'))continue;

        if(!dateGroups[date]){
            dateGroups[date]=[];
        }

        if(!dateGroups[date].includes(ipv6)){
            dateGroups[date].push(ipv6);
        }
    }

    const dates=Object.keys(dateGroups);

    if(dates.length===0){
        throw new Error('IPv6 地址列表为空');
    }

    dates.sort((a,b)=>b.localeCompare(a));

    const ipv6List=[];

    for(const date of dates){
        for(const ipv6 of dateGroups[date]){
            if(!ipv6List.includes(ipv6)){
                ipv6List.push(ipv6);
            }

            if(ipv6List.length>=count){
                return ipv6List;
            }
        }
    }

    return ipv6List;
}

async function fetchIPv4List(count){
    const response=await fetch(IPV4_LIST_URL,{
        headers:{
            'User-Agent':'Cloudflare-Worker'
        }
    });

    if(!response.ok){
        throw new Error(`IPv4 地址列表获取失败：HTTP ${response.status}`);
    }

    const text=await response.text();
    const ipv4List=[];

    for(const line of text.split(/\r?\n/)){
        const value=line.trim();

        if(!value)continue;

        /*
         * 允许文件中存在日期、备注等内容。
         * 从每行最后一个字段中寻找 IPv4。
         */
        const parts=value.split(/\s+/);
        let ipv4='';

        for(const part of parts){
            if(/^(?:\d{1,3}\.){3}\d{1,3}$/.test(part)){
                const nums=part.split('.').map(Number);

                if(
                    nums.length===4 &&
                    nums.every(n=>n>=0&&n<=255)
                ){
                    ipv4=part;
                    break;
                }
            }
        }

        if(!ipv4)continue;

        if(!ipv4List.includes(ipv4)){
            ipv4List.push(ipv4);
        }

        if(ipv4List.length>=count){
            break;
        }
    }

    if(ipv4List.length===0){
        throw new Error('IPv4 地址列表为空');
    }

    return ipv4List;
}

async function fetchDomainList(count){
    const response=await fetch(DOMAIN_LIST_URL,{
        headers:{
            'User-Agent':'Cloudflare-Worker'
        }
    });

    if(!response.ok){
        throw new Error(`优选域名列表获取失败：HTTP ${response.status}`);
    }

    const text=await response.text();
    const domainList=[];

    for(const line of text.split(/\r?\n/)){
        let domain=line.trim();

        if(!domain)continue;

        /*
         * 去除可能存在的协议头
         */
        domain=domain
            .replace(/^https?:\/\//i,'')
            .split('/')[0]
            .split(/\s+/)[0]
            .trim();

        /*
         * 去除可能存在的端口
         */
        if(/^[^:]+:\d+$/.test(domain)){
            domain=domain.replace(/:\d+$/,'');
        }

        /*
         * 基本域名格式检查
         */
        if(
            !/^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$/.test(domain)
        ){
            continue;
        }

        if(!domainList.includes(domain)){
            domainList.push(domain);
        }

        if(domainList.length>=count){
            break;
        }
    }

    if(domainList.length===0){
        throw new Error('优选域名列表为空');
    }

    return domainList;
}

function base64Encode(text){
    const bytes=new TextEncoder().encode(text);
    let binary='';

    for(let i=0;i<bytes.length;i+=0x8000){
        binary+=String.fromCharCode(
            ...bytes.subarray(i,i+0x8000)
        );
    }

    return btoa(binary);
}

function base64UrlEncode(bytes){
    let binary='';

    for(const byte of bytes){
        binary+=String.fromCharCode(byte);
    }

    return btoa(binary)
        .replace(/\+/g,'-')
        .replace(/\//g,'_')
        .replace(/=+$/,'');
}

function base64UrlDecode(value){
    const normalized=value
        .replace(/-/g,'+')
        .replace(/_/g,'/');

    const padded=
        normalized+
        '='.repeat((4-normalized.length%4)%4);

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

    const iv=crypto.getRandomValues(
        new Uint8Array(12)
    );

    const plaintext=new TextEncoder().encode(
        JSON.stringify(data)
    );

    const encrypted=await crypto.subtle.encrypt(
        {
            name:'AES-GCM',
            iv
        },
        key,
        plaintext
    );

    const encryptedBytes=new Uint8Array(encrypted);

    const tokenBytes=new Uint8Array(
        iv.length+encryptedBytes.length
    );

    tokenBytes.set(iv,0);
    tokenBytes.set(encryptedBytes,iv.length);

    return base64UrlEncode(tokenBytes);
}

async function decodeToken(token,secret){
    try{
        const data=base64UrlDecode(token);

        if(data.length<13){
            throw new Error('Token 无效');
        }

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

        if(
            !config||
            !config.uuid||
            !config.type||
            !config.path||
            !config.sni
        ){
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
    if(!validateUUID(uuid)){
        throw new Error('UUID 格式错误');
    }

    if(
        type!=='xhttp'&&
        type!=='vless'&&
        type!=='vmess'
    ){
        throw new Error(
            '只支持 xhttp、vless 和 vmess'
        );
    }

    if(!path){
        throw new Error('路径不能为空');
    }

    if(!path.startsWith('/')){
        path='/'+path;
    }

    if(path==='/'){
        throw new Error('路径不能为空');
    }

    if(!sni){
        throw new Error('域名不能为空');
    }

    return{
        uuid,
        type,
        path,
        sni
    };
}

/*
 * 服务器地址格式
 *
 * IPv4：
 * 1.2.3.4
 *
 * IPv6：
 * [2001:db8::1]
 *
 * 域名：
 * example.com
 */
function formatServerAddress(server){
    if(server.includes(':')){
        return`[${server}]:443`;
    }

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
    params.set(
        'early_data_header_name',
        'Sec-WebSocket-Protocol'
    );

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

    return`vmess://${base64Encode(
        JSON.stringify(config)
    )}`;
}

/*
 * mode:
 *
 * y = 优选域名
 * 4 = IPv4
 * 6 = IPv6
 *
 * 例如：
 * y
 * 4
 * 6
 * y4
 * y6
 * 46
 * y46
 */
function validateMode(mode){
    if(!mode){
        return'6';
    }

    mode=String(mode)
        .toLowerCase()
        .replace(/[^y46]/g,'');

    /*
     * 去重并固定顺序：
     * y -> 4 -> 6
     */
    let result='';

    if(mode.includes('y')){
        result+='y';
    }

    if(mode.includes('4')){
        result+='4';
    }

    if(mode.includes('6')){
        result+='6';
    }

    if(!result){
        throw new Error(
            '地址类型参数无效，只支持 y、4、6'
        );
    }

    return result;
}

async function generateSubscription(
    uuid,
    type,
    path,
    sni,
    count,
    mode
){
    mode=validateMode(mode);

    const servers=[];

    /*
     * 优选域名
     */
    if(mode.includes('y')){
        const domains=await fetchDomainList(count);

        for(const domain of domains){
            servers.push({
                address:domain,
                type:'domain'
            });
        }
    }

    /*
     * IPv4
     */
    if(mode.includes('4')){
        const ipv4List=await fetchIPv4List(count);

        for(const ipv4 of ipv4List){
            servers.push({
                address:ipv4,
                type:'ipv4'
            });
        }
    }

    /*
     * IPv6
     */
    if(mode.includes('6')){
        const ipv6List=await fetchIPv6List(count);

        for(const ipv6 of ipv6List){
            servers.push({
                address:ipv6,
                type:'ipv6'
            });
        }
    }

    if(servers.length===0){
        throw new Error('没有可用的服务器地址');
    }

    const result=[];

    for(const server of servers){
        if(type==='xhttp'){
            result.push(
                generateXhttpLink(
                    uuid,
                    server.address,
                    path,
                    sni
                )
            );
        }else if(type==='vless'){
            result.push(
                generateVlessWsLink(
                    uuid,
                    server.address,
                    path,
                    sni
                )
            );
        }else{
            result.push(
                generateVmessWsLink(
                    uuid,
                    server.address,
                    path,
                    sni
                )
            );
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
body{
    margin:0;
    padding:20px;
    background:#f5f5f5;
    font-family:Arial,sans-serif
}

.container{
    max-width:700px;
    margin:40px auto;
    background:white;
    padding:25px;
    border-radius:12px;
    box-shadow:0 2px 12px rgba(0,0,0,.08)
}

h2{
    margin-top:0
}

input,
select{
    width:100%;
    box-sizing:border-box;
    padding:12px;
    margin-top:10px;
    border:1px solid #ccc;
    border-radius:8px;
    font-size:14px;
    background:white
}

.address-options{
    margin-top:15px;
    padding:12px;
    border:1px solid #ccc;
    border-radius:8px;
    background:#fafafa
}

.address-title{
    font-size:14px;
    font-weight:bold;
    margin-bottom:10px
}

.option{
    display:flex;
    align-items:center;
    margin:8px 0;
    font-size:14px
}

.option input{
    width:auto;
    margin:0 8px 0 0;
    padding:0
}

button{
    width:100%;
    margin-top:15px;
    padding:12px;
    border:0;
    border-radius:8px;
    background:#111;
    color:white;
    font-size:16px;
    cursor:pointer
}

textarea{
    width:100%;
    box-sizing:border-box;
    margin-top:15px;
    padding:12px;
    border:1px solid #ccc;
    border-radius:8px;
    resize:vertical
}

.result{
    height:100px
}
</style>
</head>
<body>
<div class="container">

<h2>IPv6</h2>

<form method="POST">

<input
    name="uuid"
    placeholder="UUID"
    required
>

<select name="type" required>
    <option value="" disabled selected>
        请选择类型
    </option>
    <option value="xhttp">XHTTP</option>
    <option value="vless">VLESS</option>
    <option value="vmess">VMess</option>
</select>

<input
    name="path"
    placeholder="路径"
    required
>

<input
    name="sni"
    placeholder="域名"
    required
>

<div class="address-options">

<div class="address-title">
    服务器地址
</div>

<label class="option">
    <input
        type="checkbox"
        name="address"
        value="y"
    >
    优选域名
</label>

<label class="option">
    <input
        type="checkbox"
        name="address"
        value="4"
    >
    IPv4
</label>

<label class="option">
    <input
        type="checkbox"
        name="address"
        value="6"
        checked
    >
    IPv6
</label>

</div>

<button type="submit">
    生成
</button>

</form>

${message?`<div>${escapeHtml(message)}</div>`:''}

${result?`
<textarea
    class="result"
    readonly
    onclick="this.select()"
>${escapeHtml(result)}</textarea>
`:''}

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
            'Cache-Control':
                'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma':'no-cache',
            'Access-Control-Allow-Origin':'*'
        }
    });
}

export default{

    async fetch(request,env){

        const url=new URL(request.url);

        /*
         * 订阅请求
         *
         * 支持：
         * /TOKEN?6
         * /TOKEN?46
         * /TOKEN?y6
         * /TOKEN?y46
         *
         * 也兼容：
         * /TOKEN?count=30&y46
         */
        if(
            request.method==='GET'&&
            url.pathname!=='/'
        ){

            try{

                const token=url.pathname.slice(1);

                if(!token){
                    throw new Error(
                        '订阅 Token 不能为空'
                    );
                }

                const config=await decodeToken(
                    token,
                    env.TOKEN_SECRET
                );

                const validated=validateConfig(
                    config.uuid,
                    config.type,
                    config.path,
                    config.sni
                );

                /*
                 * count 保持原来的功能
                 */
                const countValue=
                    url.searchParams.get('count');

                const count=countValue
                    ?parseInt(countValue,10)
                    :30;

                if(
                    !Number.isInteger(count)||
                    count<1||
                    count>200
                ){
                    throw new Error(
                        '节点数量必须是1-200之间的整数'
                    );
                }

                /*
                 * 获取地址组合
                 *
                 * ?6
                 * ?46
                 * ?y46
                 *
                 * URLSearchParams 对 ?y46
                 * 会把 y46 当作 key。
                 */
                let mode='';

                for(const key of url.searchParams.keys()){

                    if(key==='count')continue;

                    if(/^[y46]+$/i.test(key)){
                        mode+=key;
                    }
                }

                /*
                 * 没有指定时默认 IPv6
                 */
                mode=validateMode(mode||'6');

                const result=await generateSubscription(
                    validated.uuid,
                    validated.type,
                    validated.path,
                    validated.sni,
                    count,
                    mode
                );

                return subscriptionResponse(
                    base64Encode(result)
                );

            }catch(error){

                return new Response(
                    error.message||'订阅生成失败',
                    {
                        status:400,
                        headers:{
                            'Content-Type':
                                'text/plain; charset=utf-8',
                            'Cache-Control':
                                'no-store, no-cache, must-revalidate, max-age=0',
                            'Pragma':'no-cache',
                            'Access-Control-Allow-Origin':'*'
                        }
                    }
                );
            }
        }

        /*
         * 非根路径
         */
        if(url.pathname!=='/'){
            return new Response(
                'Not Found',
                {
                    status:404
                }
            );
        }

        /*
         * 首页
         */
        if(request.method==='GET'){

            return new Response(
                htmlPage(),
                {
                    headers:{
                        'Content-Type':
                            'text/html; charset=utf-8'
                    }
                }
            );
        }

        /*
         * 创建订阅
         */
        if(request.method==='POST'){

            try{

                const form=await request.formData();

                const uuid=String(
                    form.get('uuid')||''
                ).trim();

                const type=String(
                    form.get('type')||''
                ).trim().toLowerCase();

                let path=String(
                    form.get('path')||''
                ).trim();

                const sni=String(
                    form.get('sni')||''
                ).trim();

                /*
                 * 获取复选框
                 */
                const addressValues=form.getAll(
                    'address'
                );

                let mode='';

                for(const value of addressValues){

                    if(
                        value==='y'||
                        value==='4'||
                        value==='6'
                    ){
                        mode+=value;
                    }
                }

                /*
                 * 如果用户一个都没选，
                 * 自动使用 IPv6
                 */
                mode=validateMode(mode||'6');

                if(!path.startsWith('/')){
                    path='/'+path;
                }

                const config=validateConfig(
                    uuid,
                    type,
                    path,
                    sni
                );

                /*
                 * 将地址模式保存到 Token
                 *
                 * Token 本身仍然保持 AES-GCM 加密。
                 */
                config.mode=mode;

                const token=await createToken(
                    config,
                    env.TOKEN_SECRET
                );

                /*
                 * 生成非常短的订阅地址
                 *
                 * y46
                 * 46
                 * 6
                 */
                const subscriptionUrl=
                    `${url.origin}/${token}?${mode}&count=30`;

                return new Response(
                    htmlPage(
                        '',
                        subscriptionUrl
                    ),
                    {
                        headers:{
                            'Content-Type':
                                'text/html; charset=utf-8'
                        }
                    }
                );

            }catch(error){

                return new Response(
                    htmlPage(
                        '',
                        error.message||'生成失败'
                    ),
                    {
                        status:400,
                        headers:{
                            'Content-Type':
                                'text/html; charset=utf-8'
                        }
                    }
                );
            }
        }

        return new Response(
            'Method Not Allowed',
            {
                status:405
            }
        );
    }
};
