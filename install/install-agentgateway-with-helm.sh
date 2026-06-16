
#!/bin/sh

export AGENTGATEWAY_VERSION="v2.3.0-rc.3"
export AGENTGATEWAY_HELM_VALUES_FILE="agentgateway-helm-values.yaml"
export K8S_GW_API_VERSION="v1.4.1"
export AGENTGATEWAY_SYSTEM_NAMESPACE="agentgateway-system"


if [ -z "$AGENTGATEWAY_LICENSE_KEY" ]
then
   echo "Solo Enterprise for agentgateway License Key not specified. Please configure the environment variable 'AGENTGATEWAY_LICENSE_KEY' with your Solo Enterprise for agentgateway License Key."
   exit 1
fi

export AGENTGATEWAY_CRDS_URL="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds"
export AGENTGATEWAY_URL="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway"

#----------------------------------------- Install Solo Enterprise for agentgateway -----------------------------------------

printf "\nApply K8S Gateway CRDs ....\n"
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$K8S_GW_API_VERSION/standard-install.yaml


printf "\nInstall Solo Enterprise for agentgateway CRDs ....\n"
helm upgrade --install enterprise-agentgateway-crds $AGENTGATEWAY_CRDS_URL \
    --version $AGENTGATEWAY_VERSION \
    --namespace $AGENTGATEWAY_SYSTEM_NAMESPACE \
    --create-namespace \
    --set installExtAuthCRDs=true \
    --set installRateLimitCRDs=true \
    --set installEnterpriseListenerSetCRD=true


printf "\nInstall Solo Enterprise for agentgateway ...\n"
helm upgrade --install enterprise-agentgateway $AGENTGATEWAY_URL \
    --version $AGENTGATEWAY_VERSION \
    --namespace $AGENTGATEWAY_SYSTEM_NAMESPACE \
    --create-namespace \
    --set-string licensing.licenseKey=$AGENTGATEWAY_LICENSE_KEY \
    -f $AGENTGATEWAY_HELM_VALUES_FILE
