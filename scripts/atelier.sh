#!/usr/bin/env bash
# Rejoue les exercices 1 à 5, les bonus A à D et l'installation de Portainer dans le Codespace.
# Les sorties utiles au RENDU.md sont enregistrées dans sorties-atelier.txt.
# Usage : ./scripts/atelier.sh
# Il reste à faire à la main : créer le compte admin Portainer, y déployer Mario (exercice 6.2)
# et rendre le port 8585 public.

set -u
cd "$(dirname "$0")/.." || exit 1
OUT=sorties-atelier.txt
: > "$OUT"
log() { echo -e "\n===== $* =====" | tee -a "$OUT"; }
run() { echo "\$ $*" | tee -a "$OUT"; "$@" 2>&1 | tee -a "$OUT"; }

# --- Outils ---------------------------------------------------------------------------
command -v k3d >/dev/null || curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# --- Exercice 1 : cluster --------------------------------------------------------------
log "Exercice 1"
k3d cluster list lab >/dev/null 2>&1 || k3d cluster create lab --servers 1 --agents 2 -p "8081:80@loadbalancer"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run kubectl get nodes -o wide
run docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
run kubectl get pods -A

# --- Exercice 2 : déploiement impératif -------------------------------------------------
log "Exercice 2"
kubectl get deploy web >/dev/null 2>&1 || kubectl create deployment web --image=nginx
kubectl get svc web >/dev/null 2>&1 || kubectl expose deployment web --port=80
kubectl rollout status deploy/web --timeout=180s
run kubectl get all
OLD=$(kubectl get pod -l app=web -o name)
run kubectl delete pod -l app=web
kubectl rollout status deploy/web --timeout=120s
echo "Ancien pod : $OLD / Nouveau pod : $(kubectl get pod -l app=web -o name)" | tee -a "$OUT"

# --- Exercice 3 : modification éphémère -------------------------------------------------
log "Exercice 3"
kubectl exec deploy/web -- sh -c 'echo "<h1>Bienvenue sur mon site Web</h1>" > /usr/share/nginx/html/index.html'
run kubectl exec deploy/web -- cat /usr/share/nginx/html/index.html
run kubectl delete pod -l app=web
kubectl rollout status deploy/web --timeout=120s
echo "Après suppression du pod :" | tee -a "$OUT"
run kubectl exec deploy/web -- grep -o "<title>.*</title>" /usr/share/nginx/html/index.html

# --- Exercice 4 : déclaratif (version initiale : 1 réplica, nginx:1.27) ----------------
log "Exercice 4"
TMP=$(mktemp -d)
cp k8s/site/*.yaml "$TMP"/
sed -i -e 's/replicas: 3/replicas: 1/' -e 's/nginx:1.28/nginx:1.27/' "$TMP/deployment.yaml"
run kubectl apply -f "$TMP"/
kubectl rollout status deploy/site --timeout=180s
run kubectl get deploy,pods,svc,configmap
run kubectl get endpoints site
run kubectl create deployment web --image=nginx --dry-run=server   # create sur un objet existant → erreur

# --- Exercice 5 : scaling, mise à jour, panne, rollback --------------------------------
log "Exercice 5.1 (3 réplicas)"
sed -i 's/replicas: 1/replicas: 3/' "$TMP/deployment.yaml"
kubectl apply -f "$TMP"/ >/dev/null
kubectl rollout status deploy/site --timeout=180s
run kubectl get pods -l app=site -o wide

log "Exercice 5.2 (rolling update vers nginx:1.28, fichiers du dépôt)"
run kubectl apply -f k8s/site/
kubectl rollout status deploy/site --timeout=180s
run kubectl rollout history deploy/site

log "Exercice 5.3 (version cassée nginx:9.99)"
run kubectl set image deploy/site nginx=nginx:9.99
sleep 25
run kubectl get pods -l app=site
BAD=$(kubectl get pods -l app=site --no-headers | grep -vw Running | awk '{print $1}' | head -1)
[ -n "$BAD" ] && kubectl describe pod "$BAD" | sed -n '/Events:/,$p' | tee -a "$OUT"
run kubectl get endpoints site
run kubectl rollout undo deploy/site
kubectl rollout status deploy/site --timeout=180s
run kubectl diff -f k8s/site/
echo "(kubectl diff sans sortie = cluster et fichiers alignés)" | tee -a "$OUT"
rm -rf "$TMP"

# --- Bonus ------------------------------------------------------------------------------
log "Bonus A (Ingress)"
run kubectl apply -f k8s/bonus/ingress.yaml
sleep 5
run curl -s http://localhost:8081
run kubectl delete pod -l app=site --wait=false
sleep 2
run curl -s -o /dev/null -w "HTTP %{http_code} pendant le remplacement des pods\n" http://localhost:8081
kubectl rollout status deploy/site --timeout=180s

log "Bonus B (probe vers /nope)"
kubectl patch deploy site --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/nope"}]'
sleep 30
run kubectl get pods -l app=site
run kubectl rollout undo deploy/site
kubectl rollout status deploy/site --timeout=180s

log "Bonus C (drain de k3d-lab-agent-0)"
run kubectl get pods -A -o wide --field-selector spec.nodeName=k3d-lab-agent-0
run kubectl drain k3d-lab-agent-0 --ignore-daemonsets --delete-emptydir-data --timeout=120s
run kubectl get pods -o wide
run kubectl uncordon k3d-lab-agent-0
sleep 10
run kubectl get pods -o wide

log "Bonus D (namespace prod)"
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f - >/dev/null
run kubectl apply -n prod -f k8s/site/
run kubectl get deploy,svc -n prod

# --- Exercice 6 : Portainer -------------------------------------------------------------
log "Exercice 6 (Portainer)"
kubectl apply -n portainer -f https://downloads.portainer.io/ce-lts/portainer.yaml >/dev/null
kubectl rollout status deploy/portainer -n portainer --timeout=300s
pkill -f "kubectl port-forward" 2>/dev/null
kubectl port-forward svc/site 8080:80 > /tmp/site.log 2>&1 &
kubectl port-forward -n portainer svc/portainer 9000:9000 > /tmp/portainer.log 2>&1 &

cat <<'EOF'

Terminé. Les sorties sont dans sorties-atelier.txt.
À faire maintenant (dans les 5 minutes, sinon Portainer se verrouille) :
  1. Onglet PORTS → port 9000 → créer le compte admin → Get Started
  2. Applications → Create from manifest → namespace default → coller k8s/mario/mario.yaml → Deploy
  3. kubectl port-forward svc/mario 8585:85 > /tmp/mario.log 2>&1 &
  4. PORTS → clic droit 8585 → Port Visibility → Public → copier l'URL (question 12)
  5. kubectl get deploy mario -o yaml   (question 13)
  6. ./scripts/check.sh                 (score en bas de RENDU.md)
EOF
