# Design: CI to build & push a Docker image to Azure Container Registry

**Date:** 2026-06-15
**Status:** Approved (pending implementation)
**Repo:** `BasvVeen/ita-language-app-k8s`

## Context

`ita-language-app-k8s` is a fresh skeleton: a Python 3.12 project managed with `uv`
(`pyproject.toml`, `uv.lock`), a hello-world `app/main.py`, an empty `README.md`, and
**no `Dockerfile` or `.github/` directory**. The end goal is to host this app in
Kubernetes behind a private, personal-only website. The first slice of that pipeline is
continuous integration: on every push, build a container image and publish it to an
existing Azure Container Registry (ACR).

This design covers building and publishing the image. Kubernetes deployment of the
published image is explicitly out of scope (future work).

## Goals

- On push to `main` **or** `feat--add-github-actions-cicd`, automatically build a Docker
  image and push it to ACR.
- Pushes triggered by any method (git CLI, GitHub web UI edit, GitHub Desktop, IDE) all
  trigger the build — this is GitHub Actions reacting to the push event.
- Tag each image with the commit SHA (immutable, traceable) **and** `latest` (floating).
- Authenticate to Azure passwordlessly — no long-lived secrets stored in GitHub.
- Keep the build commands runnable identically on a laptop and in CI.

## Key facts / decisions

| Decision | Choice | Rationale |
|---|---|---|
| CI system | GitHub Actions | Code is on GitHub; native event triggers on push. `just` cannot trigger on push by itself. |
| Command layer | `just` / `justfile` | Same build/push commands run locally and in CI — no drift, easy to debug. |
| Auth to ACR | Azure AD app + OIDC federated credentials | Best/safest: no stored secrets; short-lived tokens. Costs a bit more one-time setup. |
| Image build | Multi-stage `uv` Dockerfile | `--frozen` matches `uv.lock` exactly; multi-stage keeps the runtime image small. |
| Tagging | `${{ github.sha }}` + `latest` | Immutable SHA tag for k8s pinning; `latest` as a convenience pointer. |
| Triggers | `main` + `feat--add-github-actions-cicd` | Feature branch included now so the pipeline can be tested before reaching main. |

### Concrete values
- ACR name: `italanguageappregistry` → login server `italanguageappregistry.azurecr.io`
- ACR resource group: `rg-ita-language-app`
- Image repository: `ita-language-app`
- GitHub repo: `BasvVeen/ita-language-app-k8s`

## Architecture / flow

```
push (any method) ──▶ GitHub "push" event ──▶ GitHub Actions workflow
                                                  │
                                                  ├─ azure/login (OIDC, no secret)
                                                  ├─ az acr login --name italanguageappregistry
                                                  ├─ install `just`
                                                  └─ just push tag=<commit-sha>
                                                         │
                                                         └─ docker build + docker push ──▶ ACR
```

`just` has no awareness of pushes — GitHub Actions provides the automation; `just` is
just the command the workflow invokes.

## Components

### 1. `Dockerfile` (repo root)

Multi-stage `uv` build. Trivial today (`dependencies = []`) but structured to scale.

```dockerfile
# ---- build stage ----
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS build
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy
# deps first for layer caching
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev
# then source
COPY . .
RUN uv sync --frozen --no-dev

# ---- runtime stage ----
FROM python:3.12-slim-bookworm
WORKDIR /app
COPY --from=build /app /app
ENV PATH="/app/.venv/bin:$PATH"
CMD ["python", "app/main.py"]
```

### 2. `.dockerignore` (repo root)

Keeps the build context (and cache) clean.

```
.git
.venv
.github
.claude
docs
__pycache__
*.pyc
```

### 3. `justfile` (repo root)

The command layer — same recipes locally and in CI.

```just
registry := "italanguageappregistry.azurecr.io"
image := "ita-language-app"
tag := "latest"

# Build the image, tagging both the given tag and latest
build:
    docker build -t {{registry}}/{{image}}:{{tag}} -t {{registry}}/{{image}}:latest .

# Build then push both tags
push: build
    docker push {{registry}}/{{image}}:{{tag}}
    docker push {{registry}}/{{image}}:latest
```

Local use: `just push tag=$(git rev-parse --short HEAD)`. CI use: `just push tag=$GITHUB_SHA`.

**Caching trade-off:** plain `docker build`/`push` is used (not
`docker/build-push-action` with `type=gha` cache) so the exact same recipe works locally.
For this tiny app the build is seconds. If builds get heavy later, add registry-based
cache (`--cache-from type=registry`), which works both locally and in CI.

### 4. `.github/workflows/build-and-push.yml`

```yaml
name: Build and Push to ACR

on:
  push:
    branches:
      - main
      - feat--add-github-actions-cicd   # included for testing now

permissions:
  id-token: write   # required for OIDC login to Azure
  contents: read

env:
  REGISTRY: italanguageappregistry.azurecr.io
  IMAGE_NAME: ita-language-app

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Azure login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Log in to ACR
        run: az acr login --name italanguageappregistry

      - name: Install just
        uses: extractions/setup-just@v2

      - name: Build and push
        run: just push tag=${{ github.sha }}
```

## One-time setup (user runs locally with `az` + `gh`)

Creates the passwordless trust between the repo and Azure. Requires an Azure account with
rights to register an app and assign roles on the registry / resource group.

```bash
ACR_NAME="italanguageappregistry"
RESOURCE_GROUP="rg-ita-language-app"
REPO="BasvVeen/ita-language-app-k8s"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# 1. App registration + service principal (the identity)
APP_ID=$(az ad app create --display-name "gha-ita-language-app" --query appId -o tsv)
az ad sp create --id "$APP_ID"

# 2. AcrPush role, scoped to just this registry
ACR_ID=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create --assignee "$APP_ID" --role AcrPush --scope "$ACR_ID"

# 3. Federated credential per branch (trust rule binding GitHub OIDC -> the identity)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":"gha-main","issuer":"https://token.actions.githubusercontent.com",
  "subject":"repo:'"$REPO"':ref:refs/heads/main","audiences":["api://AzureADTokenExchange"]}'
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":"gha-feature","issuer":"https://token.actions.githubusercontent.com",
  "subject":"repo:'"$REPO"':ref:refs/heads/feat--add-github-actions-cicd","audiences":["api://AzureADTokenExchange"]}'

# 4. Expose IDs to the workflow as repo variables (these are IDs, not secrets)
gh variable set AZURE_CLIENT_ID --body "$APP_ID"
gh variable set AZURE_TENANT_ID --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID"
```

> A federated credential binds to one exact `subject` (branch ref), so each triggering
> branch needs its own credential — hence the two above.

## Verification (end-to-end)

1. Run the one-time setup above; confirm `gh variable list` shows the three variables.
2. Commit the `Dockerfile`, `.dockerignore`, `justfile`, and workflow to
   `feat--add-github-actions-cicd` and push.
3. Watch the run: `gh run watch` (or the Actions tab). Confirm the **Build and push**
   step succeeds.
4. Confirm the image landed in ACR:
   ```bash
   az acr repository show-tags -n italanguageappregistry --repository ita-language-app -o table
   ```
   Expect the commit SHA tag and `latest`.
5. (Optional) Pull and run locally:
   ```bash
   az acr login -n italanguageappregistry
   docker run --rm italanguageappregistry.azurecr.io/ita-language-app:latest
   # -> "Hello from ita-language-app-k8s!"
   ```
6. (Optional) Edit a file via the GitHub web UI on the feature branch and confirm the
   push triggers the workflow — proving any push method works.

## Out of scope (future work)

- Kubernetes manifests / deploying the pushed image.
- Multi-arch builds, image vulnerability scanning, SBOM.
- Releasing on semver git tags (current design tags by SHA + latest only).
- Registry-based or gha build-layer caching (add if builds become slow).

## Prerequisites / risks

- Azure account must be able to register an app and assign `AcrPush` on the registry /
  resource group. On a personal subscription this is normally the case; on a corporate
  tenant it may require an admin.
- The service principal (spn) does not exist yet — the user will create it via the
  one-time setup before the first successful CI run.
