一键安装

```
bash <(curl -fsSL https://raw.githubusercontent.com/hyp3365/tgweb/main/install.sh)
```

更新：已安装过再跑一次一键安装就是强制更新，也可以直接用 tg update。

```
bash <(curl -fsSL https://raw.githubusercontent.com/hyp3365/tgweb/main/install.sh) --force
tg update
```

网页登录：登录页要填「网页账号 + 网页密码」。账号可以留空不设（老配置继续用，登录页账号框留空、只填密码），
也可以用 `tg reset-auth` 加一个。两样都可以直接回车让它随机生成 12-24 位（数字 + 小写 + 大写 + 特殊符号）。

tg

```
tg
tg status
tg set-id 12345
tg set-hash xxx
tg del
tg reset-auth [user|password|both] [新值]
tg show-auth
tg reset-path
tg show-path
tg set-parallel [1-4]
tg show-parallel
tg sync-session
tg restore-session
tg domain [域名]
tg uninstall
tg restart
tg update
tg help
```

`tg reset-auth` 不带参数进选择菜单：只重置账号 / 只重置密码 / 账号和密码一起重置；
新值留空（直接回车）就随机生成 12-24 位，账号可回显、密码输入不显示。
旧命令 `tg reset-password` / `tg show-password` 仍然可用。
