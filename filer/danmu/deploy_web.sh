#!/usr/bin/env bash
# 弹幕 + 精简网页播放器（端口 3003）一键安装/更新
#   bash <(curl -Ls https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy_web.sh)
curl -fsSL "https://raw.githubusercontent.com/hyp3699/kknnuonmkk/main/filer/danmu/deploy.sh?t=$(date +%s)" -o /tmp/danmu_deploy.sh && MODE=web bash /tmp/danmu_deploy.sh
