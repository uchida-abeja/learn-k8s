# ArgoCD - GitOps継続的デリバリー

このディレクトリには、ArgoCDを使用したGitOpsベースの継続的デリバリー設定が含まれています。

## 🚀 クイックスタート

```bash
# 1. ArgoCD Applicationをデプロイ
kubectl apply -k infrastructure/argocd/

# 2. 初期パスワードを取得
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# 3. /etc/hosts を設定
echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts

# 4. ブラウザでアクセス
open http://argocd.local
```

ログイン: `admin` / `上記で取得したパスワード`

## 概要

ArgoCDは、KubernetesのためのGitOps継続的デリバリーツールです。Gitリポジトリを信頼できる唯一の情報源として、アプリケーションを自動的にデプロイ・同期します。

### 主な機能

- **自動同期**: Gitへのコミットで自動デプロイ
- **セルフヒーリング**: クラスタの状態をGitと自動的に同期
- **可視化**: WebUIでデプロイ状態をリアルタイム監視
- **ロールバック**: 簡単にPreviousバージョンへ戻せる
- **マルチテナント**: 複数のアプリケーションを一元管理

## 前提条件

### ArgoCDのインストール

```bash
# ArgoCD Namespaceの作成
kubectl create namespace argocd

# ArgoCDのインストール
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Podの起動を確認
kubectl get pods -n argocd
```

### ArgoCD CLIのインストール（オプション）

macOS:
```bash
brew install argocd
```

Linux:
```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
```

## デプロイ

### 1. ArgoCD UIへのアクセス設定

#### Ingressを使用する場合（推奨）

```bash
# Ingressをデプロイ
kubectl apply -f infrastructure/argocd/ingress.yaml

# /etc/hosts にエントリを追加
echo "127.0.0.1 argocd.local" | sudo tee -a /etc/hosts

# ブラウザでアクセス
open http://argocd.local
```

#### Port-Forwardを使用する場合

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443

# ブラウザでアクセス
open https://localhost:8080
```

### 2. 初期パスワードの取得

```bash
# 初期パスワードはargocd-initial-admin-secret Secretに保存されている
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

ログイン情報:
- **Username**: `admin`
- **Password**: 上記コマンドで取得した値

### 3. パスワード変更（推奨）

```bash
# ArgoCD CLIでログイン
argocd login argocd.local

# パスワード変更
argocd account update-password
```

### 4. Config Management Plugin のセットアップ（data-pipeline用）

data-pipelineはKustomize + Helmを使用しているため、プラグインが必要です：

```bash
# プラグイン設定を適用
kubectl apply -f infrastructure/argocd/argocd-cm-plugin.yaml

# Repo Serverを再起動してプラグインを有効化
kubectl rollout restart deployment argocd-repo-server -n argocd

# 再起動完了を待つ
kubectl rollout status deployment argocd-repo-server -n argocd
```

### 5. Applicationのデプロイ

```bash
# すべてのApplicationをデプロイ
kubectl apply -k infrastructure/argocd/

# または個別にデプロイ
kubectl apply -f infrastructure/argocd/simple-go-app-application.yaml

# data-pipelineはプラグイン設定後にデプロイ
kubectl apply -f infrastructure/argocd/data-pipeline-application.yaml
```

## 管理対象アプリケーション

### data-pipeline
- **パス**: `apps/data-pipeline/overlays/dev`
- **Namespace**: `data-pipeline-dev`
- **内容**: Airflow + MinIO データパイプライン
- **自動同期**: 制限付き（Helm統合の制約により）
- **デプロイ方法**: 手動で `kubectl kustomize --enable-helm` を使用

> **注意**: data-pipelineはKustomize + Helmの組み合わせを使用しているため、ArgoCDの標準機能では完全に管理できません。以下のいずれかの方法を選択してください：
> 1. ArgoCDのConfig Management Pluginを使用（高度）
> 2. CI/CDパイプラインで事前ビルド（推奨）
> 3. 手動デプロイを継続

### simple-go-app
- **パス**: `apps/simple-go-app/overlays/dev`
- **Namespace**: `simple-go-app-dev`
- **内容**: MinIO API Go アプリケーション
- **自動同期**: 有効 ✅
- **デプロイ方法**: GitOps（自動）

## ArgoCD UI の使い方

### アプリケーションの状態確認

1. ブラウザで `http://argocd.local` にアクセス
2. `admin` / `初期パスワード` でログイン
3. ダッシュボードでアプリケーション一覧を確認

**ステータスの意味:**
- **Synced**: GitとKubernetesの状態が一致
- **OutOfSync**: Gitと差分がある
- **Healthy**: すべてのリソースが正常
- **Progressing**: デプロイ中
- **Degraded**: 一部リソースに問題あり

### 手動同期

自動同期が無効の場合、または強制同期したい場合：

```bash
# CLI経由
argocd app sync data-pipeline

# UIから
# 1. アプリケーションを選択
# 2. "SYNC" ボタンをクリック
# 3. オプションを選択して "SYNCHRONIZE"
```

### ロールバック

```bash
# 履歴を確認
argocd app history data-pipeline

# 特定のリビジョンにロールバック
argocd app rollback data-pipeline <revision-id>
```

## GitOpsワークフロー

### 1. コード変更をコミット

```bash
# アプリケーションの設定を変更
vim apps/data-pipeline/base/deployment.yaml

# コミット＆プッシュ
git add .
git commit -m "Update data-pipeline configuration"
git push origin main
```

### 2. ArgoCDが自動検出

- ArgoCDは定期的（デフォルト3分）にGitリポジトリをポーリング
- 変更を検出すると自動的に同期を開始

### 3. デプロイ完了を確認

```bash
# CLIで確認
argocd app get data-pipeline

# UIで確認
# ブラウザでリアルタイムに同期状況を確認
```

## トラブルシューティング

### Applicationが同期されない

```bash
# Application の詳細を確認
kubectl describe application data-pipeline -n argocd

# ArgoCD Serverのログを確認
kubectl logs -n argocd deployment/argocd-server

# Repo Serverのログを確認
kubectl logs -n argocd deployment/argocd-repo-server
```

**よくある原因:**
1. GitHubへのアクセス権限がない
2. Kustomizeのビルドエラー
3. Helmチャートの依存関係の問題

### Helmチャート統合のエラー

data-pipelineはHelmチャートを使用しているため、以下を確認：

```bash
# Kustomizeビルドを手動でテスト
kubectl kustomize apps/data-pipeline/overlays/dev --enable-helm --load-restrictor LoadRestrictionsNone

# エラーがある場合はログで詳細を確認
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

### Sealed Secretsが復号化されない

Sealed Secrets ControllerがArgoCDより先にインストールされている必要があります：

```bash
# Sealed Secrets Controllerの状態を確認
kubectl get pods -n kube-system -l name=sealed-secrets-controller

# Secretが正しく生成されているか確認
kubectl get secret minio-credentials -n data-pipeline-dev
```

### Ingress経由でアクセスできない

```bash
# Ingressの状態を確認
kubectl get ingress -n argocd

# Traefikのログを確認
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# /etc/hosts に argocd.local が設定されているか確認
grep argocd.local /etc/hosts
```

## セキュリティのベストプラクティス

### 1. RBACの設定

```bash
# 読み取り専用ユーザーの作成
argocd account create readonly --read-only

# ロールの確認
argocd account get --account readonly
```

### 2. Git認証情報の管理

プライベートリポジトリの場合：

```bash
# SSHキーでリポジトリを登録
argocd repo add git@github.com:uchida-abeja/learn-k8s.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# または Personal Access Token
argocd repo add https://github.com/uchida-abeja/learn-k8s.git \
  --username <username> --password <token>
```

### 3. Webhook設定（推奨）

ポーリングではなくWebhookでリアルタイム同期：

1. ArgoCD UIで Settings → Webhooks
2. GitHub リポジトリ設定 → Webhooks → Add webhook
3. Payload URL: `http://argocd.local/api/webhook`
4. Content type: `application/json`
5. Secret: ランダムな文字列を設定

## 高度な設定

### App of Apps パターン

複数のApplicationを1つのApplicationで管理：

```yaml
# infrastructure/argocd/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/uchida-abeja/learn-k8s.git
    targetRevision: main
    path: infrastructure/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### マルチクラスタ管理

```bash
# 別のクラスタを登録
argocd cluster add production-cluster

# クラスタ一覧
argocd cluster list
```

### Notification設定

Slack通知の設定例：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  template.app-deployed: |
    message: |
      Application {{.app.metadata.name}} is now running new version.
  trigger.on-deployed: |
    - send: [app-deployed]
```

## パフォーマンスチューニング

大規模環境の場合：

```bash
# Repo Serverのレプリカ数を増やす
kubectl scale deployment argocd-repo-server -n argocd --replicas=3

# Application Controllerのリソースを増やす
kubectl edit statefulset argocd-application-controller -n argocd
```

## 参考資料

- [ArgoCD 公式ドキュメント](https://argo-cd.readthedocs.io/)
- [GitOps とは](https://www.gitops.tech/)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [Kustomize + Helm 統合](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/)

## クリーンアップ

```bash
# Applicationを削除（リソースも削除される）
kubectl delete -k infrastructure/argocd/

# ArgoCD自体をアンインストール
kubectl delete namespace argocd
```
