# Rendu — Atelier Kubernetes

> Complétez ce fichier au fil de l'atelier, puis faites un commit et un push (voir la section « Rendu » du README).

**Nom / Prénom :** KOBRIN Maxime
**Groupe :** RS2

---

## Exercice 1 — Cluster

1. Combien de nœuds affiche `kubectl get nodes` ? Quel est le rôle de chacun ?
   > **3 nœuds.** `k3d-lab-server-0` a le rôle `control-plane` : il héberge l'API Server, le scheduler, le controller-manager et la base d'état (etcd/kine). `k3d-lab-agent-0` et `k3d-lab-agent-1` ont le rôle `<none>` (k3s v1.35.5) : ce sont les **workers**, qui exécutent les pods applicatifs. Sur un cluster « vide », `kubectl get pods -A` montre déjà les pods système de k3s dans le namespace `kube-system` (`coredns`, `local-path-provisioner`, `metrics-server` et les jobs `helm-install-traefik*`, qui installent ensuite `traefik` et `svclb-traefik`).
2. Que montre `docker ps` ? Qu'est-ce qu'un « nœud » dans k3d, concrètement ?
   > Un conteneur par nœud : `k3d-lab-server-0`, `k3d-lab-agent-0` et `k3d-lab-agent-1` (image `rancher/k3s`), plus `k3d-lab-serverlb` (image `ghcr.io/k3d-io/k3d-proxy`), le load balancer qui publie `0.0.0.0:8081->80` et le port de l'API (`->6443`). Concrètement, un nœud k3d est **un conteneur Docker qui exécute k3s** (en mode server ou agent), avec son propre containerd à l'intérieur : les pods sont des conteneurs lancés *dans* ce conteneur.

## Exercice 2 — Premier déploiement

3. Quels objets Kubernetes ont été créés par `kubectl create deployment` ? (indice : `kubectl get all`)
   > Un **Deployment** `web`, qui a créé un **ReplicaSet** `web-<hash>`, qui a lui-même créé un **Pod** `web-<hash>-<id>`. Le **Service** `web` (ClusterIP) vient de `kubectl expose` ; le Service `kubernetes` existait déjà.
4. Vous avez supprimé le pod `web-...` : que s'est-il passé, et pourquoi ?
   > L'ancien pod passe en `Terminating` et un **nouveau pod, avec un autre nom**, est aussitôt créé (`Pending` → `ContainerCreating` → `Running`). Le ReplicaSet constate qu'il y a 0 pod au lieu de 1 et en recrée un : c'est la boucle de réconciliation (état désiré contre état réel).

## Exercice 3 — Modifier un conteneur en direct

5. Après suppression du pod, votre message « Bienvenue... » a-t-il survécu ? Pourquoi ?
   > **Non**, la page *Welcome to nginx!* d'origine revient. La modification avait été écrite dans la couche inscriptible du conteneur, qui est **éphémère** : elle disparaît avec le pod, et le nouveau pod repart de l'image `nginx` intacte.
6. Pourquoi le `port-forward` a-t-il cessé de fonctionner après la suppression du pod ?
   > `kubectl port-forward svc/web` ne passe pas réellement par le Service : au lancement, il choisit **un seul pod** derrière le Service et ouvre un tunnel vers lui. Quand ce pod est supprimé, le tunnel n'a plus de cible (erreur dans `/tmp/web.log`, du type *lost connection to pod*) et il ne bascule pas sur le nouveau pod.

## Exercice 4 — Déclaratif

7. Quelle différence entre `kubectl create` et `kubectl apply` ?
   > `create` est **impératif** : il crée un objet et échoue (`AlreadyExists`) s'il existe déjà. `apply` est **déclaratif** et idempotent : il crée l'objet s'il n'existe pas, sinon il le met à jour pour qu'il corresponde au fichier (fusion à partir de l'annotation `last-applied-configuration`). On peut le relancer autant de fois que l'on veut, ce qui permet de versionner l'état désiré dans Git.
8. À quoi sert le `selector` d'un Service ? Que se passe-t-il s'il ne correspond à aucun pod ?
   > Il désigne, par leurs **labels**, les pods vers lesquels le Service envoie le trafic. Kubernetes tient à jour la liste de leurs IP dans les Endpoints du Service. Si le selector ne correspond à aucun pod, le Service existe et garde son IP, mais il n'a **aucun endpoint** (`kubectl get endpoints site` est vide) : les connexions échouent et `port-forward svc/site` ne trouve aucun pod.

## Exercice 5 — Scaling & mises à jour

9. Sur quels nœuds se trouvent vos 3 réplicas ? Collez la sortie de `kubectl get pods -l app=site -o wide`.
   ```
   NAME                    READY   STATUS    RESTARTS   AGE   IP          NODE               NOMINATED NODE   READINESS GATES
   site-64cd9bb78f-b5g5b   1/1     Running   0          21s   10.42.0.6   k3d-lab-agent-1    <none>           <none>
   site-64cd9bb78f-brq7k   1/1     Running   0          20s   10.42.1.6   k3d-lab-server-0   <none>           <none>
   site-64cd9bb78f-jcbzh   1/1     Running   0          29s   10.42.2.6   k3d-lab-agent-0    <none>           <none>
   ```
   > Un pod par nœud : le scheduler les répartit. Le nœud `server-0` reçoit lui aussi des pods, car k3s ne pose pas de *taint* sur le control plane.
10. Avec l'image `nginx:9.99`, quel statut avait le pod ? Quelle commande vous a donné la cause ?
    > `ErrImagePull`, puis `ImagePullBackOff`. La cause apparaît dans la section *Events* de `kubectl describe pod <pod>` : *Failed to pull image "nginx:9.99": … docker.io/library/nginx:9.99: not found*. Ce tag n'existe pas sur Docker Hub.
11. Pendant la panne, le site restait-il accessible ? Pourquoi ?
    > **Oui.** Le rolling update crée d'abord un nouveau pod (`maxSurge` = 1) et ne supprime un ancien pod que lorsque le nouveau est prêt (avec 3 réplicas, `maxUnavailable` = 25 % arrondi à 0). Le pod `nginx:9.99` ne devient jamais prêt, donc le déploiement reste bloqué et les 3 anciens pods continuent de servir le site via le Service : `kubectl get endpoints site` listait toujours les 3 IP des anciens pods. `kubectl rollout undo` revient ensuite à la révision précédente.

## Exercice 6 — Portainer & Mario

12. URL publique de votre Mario :
    > https://super-waffle-g445xqwvxg5j297p5-8585.app.github.dev/ (port 8585 en visibilité *Public*, répond HTTP 200 sans authentification)
13. Retrouvez le Deployment `mario` en ligne de commande. Portainer et `kubectl` parlent-ils au même composant ? Lequel ?
    > Oui : `kubectl get deploy mario` l'affiche comme les autres. Portainer et `kubectl` sont deux clients du même composant, l'**API Server** (kube-apiserver) du nœud `server-0`. `kubectl` s'authentifie avec le kubeconfig, Portainer avec un ServiceAccount (il tourne dans le cluster avec des droits cluster-admin). Le Deployment est un objet Kubernetes standard ; Seule différence avec ceux créés en ligne de commande : Portainer y a ajouté ses propres labels (`io.portainer.kubernetes.application.owner: admin`, `…application.kind: content`, `…stackid: "1"`). Il s'en sert pour savoir qui a créé l'application, et il affiche `site` et `web` comme **External**, car ils n'ont pas été créés par lui.

## Bonus (facultatif)

14. Bonus réalisés et remarques :
    > **A — Ingress** (`k8s/bonus/ingress.yaml` → Service `site`, port 80) : le site répond sur le port 8081 via Traefik, et sans tunnel à relancer : Traefik suit les endpoints à jour au lieu d'être attaché à un seul pod comme `port-forward`. Supprimer un pod ne coupe pas le site. En revanche, en supprimant **les 3 pods d'un coup**, j'ai obtenu un `HTTP 503` pendant quelques secondes : plus aucun pod prêt, jusqu'au démarrage des remplaçants.
    >
    > **B — Probes et ressources** : `readinessProbe` HTTP sur `/:80`, requests 50m / 32Mi, limits 100m / 64Mi. Avec `/nope`, nginx répond 404 : le nouveau pod est `Running` mais `0/1` READY, ils ne reçoivent pas de trafic et le rolling update se bloque, tandis que les anciens pods continuent de servir.
    >
    > **C — Drain** : les pods de `agent-0` (un pod `site`, `local-path-provisioner`) sont évincés et recréés sur `server-0` et `agent-1`. Le DaemonSet `svclb-traefik` est ignoré. Après `uncordon`, ils **ne reviennent pas** : le scheduler ne place que les nouveaux pods et ne rééquilibre jamais les pods existants.
    >
    > **D — Namespace `prod`** : une seconde copie de `site` tourne dans `prod`, avec les mêmes noms d'objets sans conflit, car chaque namespace isole ses noms.
    >
    > Remarque : après un `rollout undo`, kubectl avertit que l'annotation `last-applied-configuration` n'est pas mise à jour. C'est une raison de plus pour corriger le fichier et refaire un `apply`, ce qui est le principe du GitOps.

---

**Score obtenu avec `./scripts/check.sh` :** 18 / 18
