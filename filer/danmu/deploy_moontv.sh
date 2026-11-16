#!/usr/bin/env bash
# 弹幕 + MoonTVPlus 网页播放器（端口 3003）一键安装/更新
#   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy_moontv.sh)
curl -fsSL "https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh?t=$(date +%s)" -o /tmp/danmu_deploy.sh && MODE=moontv bash /tmp/danmu_deploy.sh
