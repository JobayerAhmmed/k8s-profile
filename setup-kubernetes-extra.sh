#!/bin/sh

set -x

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kubernetes-extra-done ]; then
    exit 0
fi

logtstart "kubernetes-extra"

maybe_install_packages pssh

# Create a localhost kube-proxy service and fire it off.
cat <<'EOF' | $SUDO tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Local Proxy Service
After=kubelet.service

[Service]
Type=simple
Restart=always
User=root
ExecStart=/bin/sh -c "kubectl proxy --accept-hosts='.*' --accept-paths='^/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/.*' --address=127.0.0.1 --port=8888"
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
service_init_reload
service_enable kube-proxy
service_start kube-proxy

# Expose the dashboard IFF we have a certificate configuration
if [ ! "$SSLCERTTYPE" = "none" -a "$SSLCERTCONFIG" = "proxy" ]; then
    LCNFQDN=`echo $NFQDN | tr '[:upper:]' '[:lower:]'`
    if [ "$SSLCERTTYPE" = "self" ]; then
	certpath="/etc/ssl/easy-rsa/${NFQDN}.crt"
	keypath="/etc/ssl/easy-rsa/${NFQDN}.key"
    elif [ "$SSLCERTTYPE" = "letsencrypt" ]; then
	certpath="/etc/letsencrypt/live/${LCNFQDN}/fullchain.pem"
	keypath="/etc/letsencrypt/live/${LCNFQDN}/privkey.pem"
    fi
    cat <<EOF | $SUDO tee /etc/nginx/sites-available/k8s-dashboard
map \$http_upgrade \$connection_upgrade {
        default Upgrade;
        ''      close;
}

server {
        listen 8080 ssl;
        listen [::]:8080 ssl;
        ssl_certificate ${certpath};
        ssl_certificate_key ${keypath};
        server_name _;
        location / {
                 proxy_set_header Host \$host;
                 proxy_set_header X-Forwarded-Proto \$scheme;
                 proxy_set_header X-Forwarded-Port \$server_port;
                 proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                 proxy_set_header X-Real-IP \$remote_addr;
                 proxy_pass http://localhost:8888;
                 proxy_http_version 1.1;
                 proxy_set_header Upgrade \$http_upgrade;
                 proxy_set_header Connection \$connection_upgrade;
                 proxy_read_timeout 900s;
        }
}
EOF
    $SUDO ln -sf /etc/nginx/sites-available/k8s-dashboard \
        /etc/nginx/sites-enabled/k8s-dashboard
    service_restart nginx
fi

# Generate a cluster-wide token for an admin account, and dump it into
# the profile-setup web dir.
kubectl create serviceaccount admin -n default
kubectl create clusterrolebinding cluster-default-admin --clusterrole=cluster-admin --serviceaccount=default:admin
hassecret=`kubectl get serviceaccount admin -n default -o 'jsonpath={.secrets}'`
if [ -n "$hassecret" ]; then
    secretid=`kubectl get serviceaccount admin -n default -o 'go-template={{(index .secrets 0).name}}'`
else
    #
    # Newer kubernetes lacks automatic secrets for serviceaccounts.
    #
    kubectl -n default apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: admin-secret
  annotations:
    kubernetes.io/service-account.name: admin
type: kubernetes.io/service-account-token
EOF
    secretid="admin-secret"
fi
tries=5
while [ $tries -gt 0 ]; do
    token=`kubectl get secrets $secretid -o 'go-template={{.data.token}}' | base64 -d`
    if [ -n "$token" ]; then
	break
    else
	tries=`expr $tries - 1`
	sleep 8
    fi
done
if [ -z "$token" ]; then
    echo "ERROR: failed to get admin token, aborting!"
    exit 1
fi
echo -n "$token" > $OURDIR/admin-token.txt
chmod 644 $OURDIR/admin-token.txt

# Make kubeconfig and token available in profile-setup web dir.
cp -p ~/.kube/config $OURDIR/kubeconfig
chmod 644 $OURDIR/kubeconfig

# Make $SWAPPER a member of the docker group, so that they can do stuff sans sudo.
parallel-ssh -h $OURDIR/pssh.all-nodes sudo usermod -a -G docker $SWAPPER

# If the user wants a local, private, insecure registry on $HEAD $MGMTLAN, set that up.
if [ "$DOLOCALREGISTRY" = "1" ]; then
    ip=`getnodeip $HEAD $MGMTLAN`
    $SUDO docker create --restart=always -p $ip:5000:5000 --name local-registry registry:2
    $SUDO docker start local-registry
fi

# If the user wanted the Local Path Provisioner, make it the default
# storageclass.  The provisioner itself is stateless (volumes live on the
# nodes that use them), so run it on the control plane, prefer the second
# control-plane node, and let it fail over quickly to another one.
if [ -n "$DOLOCALPATH" -a "$DOLOCALPATH" = "1" ]; then
    LPPREFNODE=$HEAD
    if [ $NODECOUNT -gt 1 -a -n "$CONTROLPLANECOUNT" ] \
	&& [ $CONTROLPLANECOUNT -gt 1 ]; then
	LPPREFNODE=`echo $NODES | cut -d ' ' -f2`
    fi
    curl -fsSL -o $OURDIR/local-path-storage.yaml \
	https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCALPATHVERSION}/deploy/local-path-storage.yaml
    if [ ! $? -eq 0 ]; then
	echo "ERROR: failed to download local-path-provisioner ${LOCALPATHVERSION}; aborting"
	exit 1
    fi
    sed -i -e "s|/opt/local-path-provisioner|$LOCALPATHDIR|" \
	$OURDIR/local-path-storage.yaml
    kubectl apply -f $OURDIR/local-path-storage.yaml
    LPPATCH=$(cat <<EOF
{"spec":{"template":{"spec":{
  "affinity":{"nodeAffinity":{
    "requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[
      {"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]}]},
    "preferredDuringSchedulingIgnoredDuringExecution":[
      {"weight":100,"preference":{"matchExpressions":[
        {"key":"kubernetes.io/hostname","operator":"In","values":["$LPPREFNODE"]}]}}]}},
  "tolerations":[
    {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},
    {"key":"node.kubernetes.io/not-ready","operator":"Exists","effect":"NoExecute","tolerationSeconds":30},
    {"key":"node.kubernetes.io/unreachable","operator":"Exists","effect":"NoExecute","tolerationSeconds":30}]
}}}}
EOF
)
    kubectl -n local-path-storage patch deployment local-path-provisioner \
	--type merge -p "$LPPATCH"
    kubectl -n local-path-storage rollout status \
	deployment/local-path-provisioner --timeout=300s
    if [ ! $? -eq 0 ]; then
	echo "ERROR: local-path-provisioner did not become ready; aborting"
	exit 1
    fi
    kubectl patch storageclass local-path \
	-p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

# If the user wanted NFS, install a dynamic nfs subdir provisioner; it is the
# default storageclass only if local-path is not.
NFSDEFAULTCLASS=true
if [ -n "$DOLOCALPATH" -a "$DOLOCALPATH" = "1" ]; then
    NFSDEFAULTCLASS=false
fi
if [ -n "$DONFS" -a "$DONFS" = "1" ]; then
    NFSSERVERIP=`getnodeip $HEAD $DATALAN`
    helm repo add nfs-subdir-external-provisioner \
        https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
    helm repo update
    cat <<EOF >$OURDIR/nfs-provisioner-values.yaml
nfs:
  server: "$NFSSERVERIP"
  path: $NFSEXPORTDIR
  mountOptions:
    - "nfsvers=3"
storageClass:
  defaultClass: $NFSDEFAULTCLASS
EOF
    helm install nfs-subdir-external-provisioner \
        nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
	-f $OURDIR/nfs-provisioner-values.yaml --wait
fi



logtend "kubernetes-extra"
touch $OURDIR/kubernetes-extra-done
exit 0
