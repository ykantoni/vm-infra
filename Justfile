# Task runner for this cluster. Run `just --list` to see all recipes.
#
# Unlike Make, a recipe with no `#!shebang` runs as one shell script — every
# line shares state (cd, variables) — so none of these need Make's `.ONESHELL:`
# or a bash -c wrapper to string commands together.

plan:
    terraform plan

# Apply the Terraform configuration.
apply:
    terraform apply -auto-approve

# Destroy everything Terraform manages: the cluster and its VMs.
# The kubectl steps only run if the apiserver is reachable: if the cluster's
# already gone (e.g. this is a re-run after a prior destroy succeeded),
# there's nothing left for them to guard anyway.
#  - Longhorn refuses to uninstall without its deleting-confirmation-flag.
#  - Argo CD Applications/AppProjects carry a resources finalizer. Stripping
#    it up front isn't enough on its own: the application-controller is
#    still alive and running selfHeal at that point, and its next
#    reconciliation just re-adds the finalizer before terraform gets around
#    to uninstalling Argo CD itself -- observed in practice as the argocd/
#    argocd-apps namespaces hanging in Terminating forever, well past
#    terraform destroy's own timeout, even though this loop ran. Scaling
#    the controller to 0 first and waiting for it to actually stop removes
#    anything that could re-add the finalizer before the strip runs.
#  - Any unhealthy aggregated APIService (observed with metrics-server's,
#    once its pod stopped during teardown) blocks the namespace
#    controller's discovery step for the *entire* cluster, which in turn
#    blocks every namespace deletion -- even one with nothing left in it --
#    with no indication beyond a generic "context deadline exceeded" from
#    terraform. Deleting any that aren't Available up front avoids that;
#    Kubernetes just re-registers a legitimate one if its backing pod comes
#    back, which none will here since the whole cluster is coming down.
destroy:
    if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then \
      kubectl -n longhorn-system patch settings.longhorn.io deleting-confirmation-flag \
        --type=merge -p '{"value":"true"}' || true; \
      for svc in $(kubectl get apiservices.apiregistration.k8s.io \
          -o jsonpath='{range .items[?(@.status.conditions[0].status!="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do \
        kubectl delete apiservice "$svc" || true; \
      done; \
      kubectl scale statefulset,deployment argocd-application-controller -n argocd --replicas=0 2>/dev/null || true; \
      kubectl wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=60s 2>/dev/null || true; \
      for kind in applications appprojects; do \
        for res in $(kubectl get "$kind.argoproj.io" -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do \
          kubectl -n "${res%%/*}" patch "$kind" "${res#*/}" \
            --type=merge -p '{"metadata":{"finalizers":null}}'; \
        done; \
      done; \
    fi
    terraform destroy -auto-approve -var is_destroy=true

# Format all Terraform files in place.
fmt:
    terraform fmt -recursive

# Build both Proxmox VM templates: the plain one (vm_id 9100) common nodes
# clone from, and the GPU one (vm_id 9101) GPU-tagged nodes clone from. Run
# vm-templates/import-ubuntu-cloud-image.sh once first (see packer/README.md).
t-create:
    /usr/bin/bash -c "pushd packer && packer init . && packer build -only='proxmox-clone.ubuntu_common' . && packer build -only='proxmox-clone.ubuntu_gpu' . && popd"

# Destroy both templates. Idempotent (qm destroy itself no-ops with a
# harmless message on an already-absent VM) so it's safe before a first
# build. Deliberately doesn't pre-check with `qm status` first -- that
# check has been observed racing with a VM that was *just* converted to a
# template by the previous build (status transiently fails right after
# `qm template`), which skips the destroy silently and leaves the next
# build's clone step hitting "config file already exists".
t-destroy:
    for id in 9100 9101; do \
      sudo /usr/sbin/qm destroy "$id" || true; \
    done

# Write kubeconfig and an SSH key for ssh_admin_user from Terraform outputs.
generate:
    mkdir -p "$HOME/.kube"
    terraform output -raw kubeconfig > "$HOME/.kube/config"
    terraform output -raw ssh_private_key > "$HOME/.ssh/rke2_admin"
    chmod 600 "$HOME/.kube/config" "$HOME/.ssh/rke2_admin"

# Print Argo CD's initial admin password.
argocd-password:
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Back up the Sealed Secrets controller's key pair to where the next build
# restores it from (var.sealed_secrets_key_file). Run once after the first
# build, once k8s-infra has installed the controller. Keep a copy off-host too.
seal-key-backup file="/var/lib/terraform/sealed-secrets-key.yaml":
    umask 077; kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > "{{file}}"
    echo "Saved to {{file}}"

# Print the Sealed Secrets public cert, to commit as pub-cert.pem in k8s-infra
# and k8s-apps so secrets can be sealed offline.
seal-cert:
    kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller --fetch-cert

# Back up OpenBao's unseal keys + root token (Secret openbao-init, written
# once by k8s-infra's openbao bootstrap Job on first init) to where only
# this host can read them, then delete the cluster-side copy -- nothing
# recreates it once it's gone. Keep a second copy off this host too:
# losing this file means losing every secret OpenBao holds for this build.
bao-keys-backup file="/var/lib/terraform/openbao-init.json":
    umask 077; kubectl -n openbao get secret openbao-init -o jsonpath='{.data.init\.json}' | base64 -d > "{{file}}"
    kubectl -n openbao delete secret openbao-init
    echo "Saved to {{file}} -- keep a second copy off this host"

# Seal status of every OpenBao pod. Shamir seal: any pod that restarts
# (node reboot, upgrade, eviction) comes back sealed on its own.
bao-status:
    for p in openbao-0 openbao-1 openbao-2; do \
      echo "== $p =="; \
      kubectl -n openbao exec "$p" -- bao status || true; \
    done

# Unseal every currently-sealed OpenBao pod, using 3 of the 5 key shares
# from bao-keys-backup's file (point this at your off-host copy if that one
# was already deleted here).
bao-unseal file="/var/lib/terraform/openbao-init.json":
    #!/usr/bin/env bash
    set -euo pipefail
    keys=$(jq -r '.keys_base64[0:3][]' "{{file}}")
    for p in openbao-0 openbao-1 openbao-2; do
      if [ "$(kubectl -n openbao exec "$p" -- bao status -format=json 2>/dev/null | jq -r .sealed)" = "true" ]; then
        while IFS= read -r k; do
          kubectl -n openbao exec "$p" -- bao operator unseal "$k" >/dev/null
        done <<< "$keys"
        echo "$p unsealed"
      else
        echo "$p already unsealed"
      fi
    done
