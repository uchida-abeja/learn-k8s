# learn-k8s

Argo CDとKustomizeを使って、`simple-go-app`と学習用data pipelineをdevクラスタへデプロイするマニフェストリポジトリです。

このリポジトリは、クラスタ固有の平文Secretや利用できない暗号文を含まない状態を初期値にしています。クローン直後に`Application`を適用せず、対象クラスタへSealed Secrets controllerを導入してから、必ず生成スクリプトで`SealedSecret`を作成してください。

## ディレクトリ

```text
.
├── .github/workflows/open-deployment-pr.yml
├── apps/
│   ├── data-pipeline/
│   └── simple-go-app/
├── infrastructure/argocd/
└── scripts/
    ├── generate-dev-sealed-secrets.sh
    └── generate-ghcr-pull-sealed-secret.sh
```

## 初回セットアップの順序

1. `apps/simple-go-app/overlays/dev/kustomization.yaml`のGHCRイメージ名と、`infrastructure/argocd/*-application.yaml`の`repoURL`を自分のリポジトリへ変更する。
2. Argo CD 3.4.5とSealed Secrets 0.38.4をクラスタへ導入する。
3. private Gitリポジトリの認証情報をArgo CDへ登録する。
4. クラスタ固有のアプリケーションSecretを生成する。
5. private GHCR用のpull Secretを生成する。
6. 生成された暗号文と2つの`kustomization.yaml`の差分をレビューし、`main`へ反映する。
7. レンダリングを検証してから`Application`を適用する。

### アプリケーションSecret

```bash
EXPECTED_CONTEXT="$(kubectl config current-context)" \
  ./scripts/generate-dev-sealed-secrets.sh
```

このスクリプトはMinIO、Airflow、`simple-go-app`用の値を対話入力し、次の4つの`SealedSecret`を生成します。

- `simple-go-app-secrets`
- `minio-credentials`
- `airflow-credentials`
- `airflow-runtime-secrets`

再実行するとFernet keyやRedisパスワードも変わるため、既存ファイルがある場合は安全のため停止します。意図的に全資格情報を更新する場合だけ、影響を確認して`OVERWRITE_SEALED_SECRETS=1`を追加してください。GHCRのPATだけを更新するときは、後述のGHCR専用スクリプトを再実行します。

### private GHCRのpull Secret

`GHCR_IMAGE`には、実在するフルcommit SHAタグまたはdigestを指定します。入力するpersonal access token (classic)は`read:packages`だけを付与したpull専用トークンにしてください。

```bash
GHCR_USERNAME=YOUR_GHCR_USERNAME \
GHCR_IMAGE=ghcr.io/YOUR_GITHUB_OWNER/YOUR_APP_REPOSITORY:FULL_COMMIT_SHA \
EXPECTED_CONTEXT="$(kubectl config current-context)" \
  ./scripts/generate-ghcr-pull-sealed-secret.sh
```

スクリプトは対象イメージへのアクセスを検査してから、`ghcr-pull-credentials`を暗号化します。Docker credential helperの設定ファイルは流用しません。平文の認証情報をGitへ追加しないでください。

生成後は、暗号文とresource追加だけであることを確認します。

```bash
git status --short
git diff --check
git diff -- \
  apps/simple-go-app/overlays/dev/kustomization.yaml \
  apps/data-pipeline/overlays/dev/kustomization.yaml
```

## レンダリング確認

`simple-go-app`はstandalone Kustomizeで確認できます。

```bash
kustomize build apps/simple-go-app/overlays/dev >/dev/null
```

data pipelineはHelm chartとKustomization root外の`src`を使います。Argo CDにも同じbuild optionsを設定してください。

```bash
kustomize build apps/data-pipeline/overlays/dev \
  --enable-helm \
  --load-restrictor LoadRestrictionsNone \
  >/dev/null

kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor LoadRestrictionsNone"}}'
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
```

準備が揃ったら、必要な`Application`だけを適用します。

```bash
kubectl apply -f infrastructure/argocd/simple-go-app-application.yaml

# data pipelineも構築する場合
kubectl apply -k infrastructure/argocd/
```

`Application`には自動prune、self-heal、リソース削除用finalizerがあります。削除範囲を理解せず本番環境へ適用しないでください。

## デプロイPR workflow

`deploy/**`へのpushを受けると、`.github/workflows/open-deployment-pr.yml`が既存PRを更新するか、新しいPRを作ります。リポジトリのActions設定でPR作成を許可し、`main`への直接pushは禁止してください。

詳細は各ディレクトリのREADMEを参照してください。
