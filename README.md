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
EXPECTED_CONTEXT=kind-argocd-blog \
CONFIRM_FRESH_CLUSTER=kind-argocd-blog \
  ./scripts/generate-dev-sealed-secrets.sh
```

`kind-argocd-blog`は確認済みの検証用context名です。別のクラスタを使う場合は`kubectl config get-contexts`で対象を確認し、その名前を固定値で指定してください。`EXPECTED_CONTEXT="$(kubectl config current-context)"`では誤接続を検出できません。

この生成スクリプトは、既存データを持たない新しい検証クラスタを初期化するためのものです。その確認を読み飛ばしにくくするため、初回を含む全実行で`CONFIRM_FRESH_CLUSTER`が`EXPECTED_CONTEXT`と一致しなければ停止します。Fernet key、Redis、PostgreSQLの資格情報をまとめて生成するため、既存PVCがあるクラスタへ適用しないでください。既存環境の移行では、PostgreSQL内部のパスワード更新とFernet keyの継承を個別に設計する必要があり、このサンプルの範囲外です。ブログを再現するときは、新しい`kind-argocd-blog`を使うのが安全です。

このスクリプトはMinIO、Airflow、`simple-go-app`用の値を対話入力し、次の5つの`SealedSecret`を生成します。

- `simple-go-app-secrets`
- `minio-credentials`
- `airflow-credentials`
- `airflow-runtime-secrets`
- `airflow-metadata`

`airflow-metadata`には、実行時に生成したPostgreSQLパスワードと、それを使うAirflow metadata database接続文字列が暗号化されます。private GHCR用の`ghcr-pull-credentials`も含めると、生成する`SealedSecret`は合計6つです。

再実行するとFernet key、Redisパスワード、PostgreSQLパスワードも変わるため、既存ファイルがある場合は安全のため停止します。新しく作り直した空のクラスタ向けに暗号文を再生成するときだけ、対象context名を二重確認として指定します。

```bash
EXPECTED_CONTEXT=kind-argocd-blog \
CONFIRM_FRESH_CLUSTER=kind-argocd-blog \
OVERWRITE_SEALED_SECRETS=1 \
  ./scripts/generate-dev-sealed-secrets.sh
```

既存データを持つPostgreSQLでは、この上書きモードを使わないでください。Secretを差し替えるだけでは内部パスワードは更新されません。GHCRのPATだけを更新するときは、後述のGHCR専用スクリプトを再実行します。

### private GHCRのpull Secret

`GHCR_IMAGE`には、実在するフルcommit SHAタグまたはdigestを指定します。入力するpersonal access token (classic)は`read:packages`だけを付与したpull専用トークンにしてください。

```bash
GHCR_USERNAME=YOUR_GHCR_USERNAME \
GHCR_IMAGE=ghcr.io/YOUR_GITHUB_OWNER/YOUR_APP_REPOSITORY:FULL_COMMIT_SHA \
EXPECTED_CONTEXT=kind-argocd-blog \
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
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"

  kustomize build apps/data-pipeline/overlays/dev \
    --enable-helm \
    --load-restrictor LoadRestrictionsNone \
    >/dev/null

  kubectl --context "${EXPECTED_CONTEXT}" patch configmap argocd-cm -n argocd --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-helm --load-restrictor LoadRestrictionsNone"}}'
  kubectl --context "${EXPECTED_CONTEXT}" rollout restart deployment/argocd-repo-server -n argocd
  kubectl --context "${EXPECTED_CONTEXT}" rollout status deployment/argocd-repo-server -n argocd
)
```

準備が揃ったら、必要な`Application`だけを適用します。

```bash
(
  set -euo pipefail

  EXPECTED_CONTEXT=kind-argocd-blog
  test "$(kubectl config current-context)" = "${EXPECTED_CONTEXT}"
  kubectl --context "${EXPECTED_CONTEXT}" apply \
    -f infrastructure/argocd/simple-go-app-application.yaml

  # data pipelineも構築する場合は、上のapplyの代わりに次を実行する
  # kubectl --context "${EXPECTED_CONTEXT}" apply -k infrastructure/argocd/
)
```

`Application`には自動prune、self-heal、リソース削除用finalizerがあります。削除範囲を理解せず本番環境へ適用しないでください。

## デプロイPR workflow

`deploy/**`へのpushを受けると、`.github/workflows/open-deployment-pr.yml`が既存PRを更新するか、新しいPRを作ります。リポジトリのActions設定でPR作成を許可します。

アプリケーション側workflowが使うwrite deploy keyは、特定ブランチだけに権限を絞れません。`main`にはrulesetまたはbranch protectionを設定し、PR経由の変更を必須にしてください。force pushと削除を許可せず、bypass actorを追加しないか、branch protectionの`Do not allow bypassing the above settings`を有効にします。

個人リポジトリで1人だけで試す場合、自分のPRを自分でapproveしてrequired approvalを満たすことはできません。この場合はrequired approvalを0件にし、checksと手動マージを承認境界にします。別reviewerがいる場合だけ1件以上を指定します。

保護設定後は、write deploy keyによるempty commitの直接pushが`GH006`または`GH013`で拒否され、remote `main`のSHAが変わらないことを確認してください。次のテストは、保護が誤っているとファイル差分のないcommitが`main`へ入ります。その場合は先へ進まず、保護設定を直してください。

```bash
(
  set -euo pipefail

  MANIFEST_REPO=YOUR_GITHUB_OWNER/YOUR_MANIFEST_REPOSITORY
  KEY_PATH=/ABSOLUTE/PATH/TO/GITOPS_DEPLOY_KEY
  TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/main-protection.XXXXXX")"
  KNOWN_HOSTS_FILE="${TEST_DIRECTORY}/github-known-hosts"
  cleanup_protection_test() {
    rm -rf -- "${TEST_DIRECTORY}"
  }
  trap cleanup_protection_test EXIT

  test -f "${KEY_PATH}"
  gh api meta \
    --jq '.ssh_keys[] | "github.com " + .' \
    > "${KNOWN_HOSTS_FILE}"
  chmod 0600 "${KNOWN_HOSTS_FILE}"

  git clone "https://github.com/${MANIFEST_REPO}.git" \
    "${TEST_DIRECTORY}/repository"
  git -C "${TEST_DIRECTORY}/repository" \
    -c user.name='Branch protection check' \
    -c user.email='noreply@example.com' \
    commit --allow-empty -m 'Verify main branch protection'

  REMOTE_MAIN_BEFORE="$(
    gh api "repos/${MANIFEST_REPO}/commits/main" --jq .sha
  )"
  set +e
  PUSH_OUTPUT="$(
    GIT_SSH_COMMAND="ssh -i ${KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN_HOSTS_FILE}" \
      git -C "${TEST_DIRECTORY}/repository" push \
        "git@github.com:${MANIFEST_REPO}.git" \
        HEAD:main \
        2>&1
  )"
  PUSH_STATUS="$?"
  set -e
  printf '%s\n' "${PUSH_OUTPUT}"

  REMOTE_MAIN_AFTER="$(
    gh api "repos/${MANIFEST_REPO}/commits/main" --jq .sha
  )"
  if [ "${PUSH_STATUS}" -eq 0 ]; then
    printf 'ERROR: deploy keyのmain直pushが成功しました。\n' >&2
    printf 'before=%s\nafter=%s\n' \
      "${REMOTE_MAIN_BEFORE}" "${REMOTE_MAIN_AFTER}" >&2
    printf 'empty commitがmainへ入っています。自動で履歴を書き換えず、保護設定と復旧方針を確認してください。\n' >&2
    exit 1
  fi
  if [ "${REMOTE_MAIN_AFTER}" != "${REMOTE_MAIN_BEFORE}" ]; then
    printf 'ERROR: push失敗後にremote mainのSHAが変化しています。続行しないでください。\n' >&2
    exit 1
  fi
  if ! printf '%s\n' "${PUSH_OUTPUT}" \
    | grep -Eiq 'GH006|GH013|protected branch|repository rule'; then
    printf 'ERROR: 認証など別の理由で失敗しており、保護確認になっていません。\n' >&2
    exit 1
  fi
  printf 'main protection check passed.\n'
)
```

詳細は各ディレクトリのREADMEを参照してください。
