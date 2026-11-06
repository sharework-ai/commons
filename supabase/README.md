# commons/supabase — Supabase self-hosted on the local k3s

Supabase 栈(Postgres + Auth/GoTrue + Storage + Studio)在本机 macus k3s 上的
自托管部署资产。**公共底座**:多个项目共享一个实例(项目各用独立 schema/表 +
Storage bucket,凭据走各自环境变量,不入各项目仓库)。

- chart:`supabase-community/supabase-kubernetes`,版本钉死(见 setup.sh 的
  `VERSION`,operator 与 project 必须**同版本**——二者都对应上游 self-hosted release)。
- 形态:operator(CRD + 控制器)+ project(SingleDatabase/组件 CR)。裁剪了
  analytics/vector/realtime/edgeRuntime(dev 机内存纪律,目标全栈 < 2.5 GiB)。
- 访问:LAN HTTP,`http://supabase.lan`(traefik web entrypoint,192.168.2.1:80)。
  本机不设 TLS(内网明文);要公网再走 frpc/traefik TLS,不要直接开 443 明文。

## 一次性准备

```sh
# helm(如未装): 见 ~/apps/helm
# LAN host 记录:
sudo sh -c 'echo "192.168.2.1 supabase.lan" >> /etc/hosts'
# 内存检查(2026-10 OOM 教训:跑大栈前必看):
free -h
```

## 安装 / 状态 / 凭据

```sh
./setup.sh install          # 幂等(helm upgrade --install),首拉镜像需数分钟
./setup.sh status           # pods + svc + 访问入口提示
./setup.sh credentials      # DB 密码 / Studio 账号 / publishable+secret key
```

端点(安装后):

| 用途 | 入口 |
|---|---|
| Studio(管理台) | `http://supabase.lan`(凭据 `setup.sh credentials` 的 Studio 段) |
| API 网关(envoy):Auth/REST/Storage | `http://supabase.lan`(同主机,`/auth/v1/*` `/rest/v1/*` `/storage/v1/*`) |
| Postgres 直连 | 集群内 svc(项目服务用 `DATABASE_URL` 直连;如需本机直连再议 NodePort) |

API key 体系:0.8.x 用 `publishable-key` / `secret-key`(supabase-jwt secret)。
服务端 secret key 等同旧 service_role 权限,**只放服务端环境变量**,绝不进前端。

## Auth 说明(本机无 SMTP)

`values-project.yaml` 设 `GOTRUE_MAILER_AUTOCONFIRM=true`:邮箱注册即确认,不发
验证邮件(本机没有 SMTP 中继)。要真验证邮件时:加 `GOTRUE_SMTP_*` 配置段 + 建
smtp 凭据 Secret(见 chart values 注释),并把 AUTOCONFIRM 改回 false。

## 数据库迁移(项目 schema)

各项目的 migration SQL 放各自仓库,用本脚本应用(经 pg pod 执行 psql):

```sh
~/projects/commons/supabase/setup.sh apply-migration <project>/supabase/migrations/0001_init.sql
```

## 升级

1. 读上游 changelog:`supabase/supabase` 的 `docker/CHANGELOG.md` + operator
   release notes(API 可能变——operator 仍处早期)。
2. 改 setup.sh `VERSION`(两个 chart 同值)→ `./setup.sh install`。
3. 数据在 PVC(local-path,磁盘),升级不动数据;大版本升级先备份(见下)。

## 备份

Postgres 数据在 `$PROJECT_NS` 的 PVC(local-path: `/var/lib/rancher/k3s/storage/`)。
手工备份(停写窗口内执行):

```sh
DBPOD=$(kubectl -n supabase get pods -o name | grep -E 'single.*db|postgres' | head -1 | cut -d/ -f2)
kubectl -n supabase exec "$DBPOD" -- pg_dump -U postgres -d postgres | gzip > supabase-dump-$(date +%F).sql.gz
```

Storage 对象同目录在 storage PVC;Studio PVC 仅日志/低价值。

## 迁 t5s(未来)

全部资产 helm 化,无本机特有内容(仅 /etc/hosts 与代理);t5s k3s 上
`./setup.sh install` + 恢复备份即完成迁移。
