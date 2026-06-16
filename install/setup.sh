#!/bin/sh

pushd ..

# Deploy the Gateway parameters and Gateway
kubectl apply -f gateways/gw-parameters.yaml
kubectl apply -f gateways/gw.yaml

# Create namespaces if they do not yet exist
kubectl create namespace httpbin --dry-run=client -o yaml | kubectl apply -f -

# Deploy the HTTPBin application
printf "\nDeploy HTTPBin application ...\n"
kubectl apply -f apis/httpbin.yaml

# Reference Grants
printf "\nDeploy Reference Grants ...\n"
kubectl apply -f referencegrants/httpbin-ns/agentgateway-system-ns-httproute-service-rg.yaml

# HTTPRoute
printf "\nDeploy HTTPRoute ...\n"
kubectl apply -f routes/api-example-com-httproute.yaml

popd
