#!/usr/bin/env bash
# Pre-pull an image into the local k3s containerd without restarting k3s.
#
# The k3s registry mirror order matters here: on this host docker.1ms.run can
# stall for tens of minutes on large images while docker.m.daocloud.io is fast.
# Rather than editing registries.yaml (needs a k3s restart, disrupts other
# workloads on the box), pull via podman (its own mirror config prefers
# daocloud) and import straight into the k3s containerd store.
#
# Usage: ./pre-pull.sh <image-ref> [more refs...]
set -euo pipefail

EXPORT_DIR="${EXPORT_DIR:-$HOME/devcache/image-exports/supabase}"
mkdir -p "$EXPORT_DIR"

for image in "$@"; do
  [ -n "$image" ] || continue
  echo "== $image =="
  podman pull "$image" >/dev/null
  safe="$(echo "$image" | tr '/:' '__')"
  tar="$EXPORT_DIR/$safe.tar"
  podman save --format oci-archive -o "$tar" "$image" >/dev/null
  echo justdid1t | sudo -S k3s ctr images import "$tar" | tail -1
  rm -f "$tar"
done
echo "done. Pods stuck on Pulling will pick the local image on their next retry;"
echo "delete the stuck pod to force it:  kubectl -n supabase delete pod <pod>"
