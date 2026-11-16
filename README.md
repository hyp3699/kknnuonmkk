只装弹幕（端口 2525，含采集站每 2 天自动更新，OK影视配置 http://IP:2525/sub/jjoo.json）
```bash
bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh)
```

弹幕 + 精简网页播放器（端口 3003，选采集站/分类/站内搜索/播放带弹幕，无需登录和 Docker）
```bash
bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy_web.sh)
```

弹幕 + MoonTVPlus 网页播放器（端口 3003，Docker，账号密码见 /opt/moontv/.env）
```bash
bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy_moontv.sh)
```
