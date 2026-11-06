#!/usr/bin/env bash
# Supabase self-hosted (operator + project charts) on the local k3s — idempotent.
#
# Charts: supabase-community/supabase-kubernetes, pinned at VERSION (operator
# and project share the upstream self-hosted release they target — always
# install matching versions of the two).
#
# Usage:
#   ./setup.sh install                     # helm upgrade --install both charts
#   ./setup.sh status                      # pod rollouts + service endpoints
#   ./setup.sh credentials                 # DB password / Studio login / API keys
#   ./setup.sh apply-migration <file.sql>  # psql one SQL file against the project DB
#   ./setup.sh uninstall                   # remove project + operator (PVCs survive)
#
# Prereqs (once):
#   - k3s running (kubectl on PATH); docker.io mirror already in registries.yaml
#   - helm: ~/apps/helm/linux-amd64/helm (auto-detected, or helm on PATH)
#   - LAN host record: sudo sh -c 'echo "192.168.2.1 supabase.lan" >> /etc/hosts'
#   - Memory discipline: run `free -h` first; whole-stack target < 2.5 GiB.
set -euo pipefail

VERSION=0.8.3
OPERATOR_NS=supabase-operator
PROJECT_NS=supabase
RELEASE_OPERATOR=supabase-operator
RELEASE_PROJECT=supabase

HELM=helm
if ! command -v helm >/dev/null 2>&1; then
  for c in "$HOME/apps/helm/linux-amd64/helm" "$HOME/apps/helm/linux-amd64"*/helm; do
    [ -x "$c" ] && HELM="$c" && break
  done
fi
command -v "$HELM" >/dev/null 2>&1 || { echo "helm not found (install to ~/apps/helm)" >&2; exit 1; }

# Chart repo is github-pages hosted: route through the local proxy by default
# (override with HTTPS_PROXY="" on a host that needs no proxy).
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:24723}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:24723}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
install)
  echo "== memory before =="; free -h | sed -n '1,2p'
  "$HELM" repo add supabase https://supabase-community.github.io/supabase-kubernetes 2>/dev/null || true
  "$HELM" repo update >/dev/null
  "$HELM" upgrade --install "$RELEASE_OPERATOR" supabase/supabase-operator \
    --version "$VERSION" --namespace "$OPERATOR_NS" --create-namespace
  "$HELM" upgrade --install "$RELEASE_PROJECT" supabase/supabase-project \
    --version "$VERSION" --namespace "$PROJECT_NS" --create-namespace \
    -f "$HERE/values-project.yaml"
  echo; echo "waiting for project pods (first pull can take minutes)..."
  kubectl -n "$PROJECT_NS" rollout status --timeout=15m deploy,statefulset 2>/dev/null || \
    kubectl -n "$PROJECT_NS" get pods
  "$0" status
  ;;

status)
  kubectl -n "$PROJECT_NS" get pods -o wide
  echo
  kubectl -n "$PROJECT_NS" get svc
  echo
  echo "LAN entry (once): sudo sh -c 'echo \"192.168.2.1 supabase.lan\" >> /etc/hosts'"
  echo "Studio/API: http://supabase.lan   (traefik web entrypoint on 192.168.2.1:80)"
  ;;

credentials)
  kubectl -n "$PROJECT_NS" get secrets supabase-postgres-auth supabase-envoy-auth supabase-jwt \
    -o go-template='{{range .items}}{{if eq .metadata.name "supabase-postgres-auth"}}{{printf "%-18s: %s" "Database Password" (.data.password | base64decode)}}{{"\n"}}{{end}}{{if eq .metadata.name "supabase-envoy-auth"}}{{printf "%-18s: %s" "Studio Username" (.data.username | base64decode)}}{{"\n"}}{{printf "%-18s: %s" "Studio Password" (.data.password | base64decode)}}{{"\n"}}{{end}}{{if eq .metadata.name "supabase-jwt"}}{{printf "%-18s: %s" "Publishable Key" (index .data "publishable-key" | base64decode)}}{{"\n"}}{{printf "%-18s: %s" "Secret Key" (index .data "secret-key" | base64decode)}}{{"\n"}}{{end}}{{end}}'
  echo "service_role JWT (legacy-style anon/Service role keys): kubectl -n $PROJECT_NS get secret supabase-jwt -o jsonpath='{.data}' | jq 'keys'"
  ;;

apply-migration)
  file="${2:?usage: $0 apply-migration <file.sql>}"
  [ -r "$file" ] || { echo "no such readable file: $file" >&2; exit 1; }
  dbpod="$(kubectl -n "$PROJECT_NS" get pods --no-headers -o custom-columns=':metadata.name' \
    | grep -E 'single.*db|postgres' | head -1)"
  [ -n "$dbpod" ] || { echo "database pod not found" >&2; exit 1; }
  echo "applying $file to $dbpod..."
  kubectl -n "$PROJECT_NS" exec -i "$dbpod" -- psql -U postgres -d postgres < "$file"
  ;;

uninstall)
  "$HELM" uninstall "$RELEASE_PROJECT" -n "$PROJECT_NS" || true
  "$HELM" uninstall "$RELEASE_OPERATOR" -n "$OPERATOR_NS" || true
  echo "PVCs in ns '$PROJECT_NS' are kept; delete manually if truly unwanted:"
  echo "  kubectl -n $PROJECT_NS delete pvc --all"
  ;;

*)
  grep '^#   \./setup.sh' "$0" | sed 's/^#   //'
  exit 1
  ;;
esac
