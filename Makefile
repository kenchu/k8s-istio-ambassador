WORKSPACE=/Users/ken.chu/repo/k8s

ISTIO_NAMESPACE=istio-system
ISTIO_NAME=istio
ISTIO_HOME=$(WORKSPACE)/istio
ISTIO_HELM=$(ISTIO_HOME)/install/kubernetes/helm
ISTIOCTL=$(ISTIO_HOME)/bin/istioctl

AMBASSADOR_NAME=ambassador
AMBASSADOR_HOME=$(WORKSPACE)/ambassador
AMBASSADOR_NODEPORT=32222

MINIKUBE_IP=$(shell minikube ip)

help:
	@echo "To start minikube,         run 'make minikube'"
	@echo "To download istio,         run 'make download-istio'"
	@echo "To install minimal istio,  run 'make helm-install-istio-minimal'"
	@echo "To install ambassador,     run 'make helm-install-ambassador'"


# ==================================
# platform setup
# ==================================

minikube:
	minikube start --memory=6144 --cpus=4

delete-minikube:
	minikube delete

download-istio:
	curl -L "https://git.io/getLatestIstio" | sh -

download-rename-istio:	download-istio
	mv istio-*/ $(ISTIO_HOME)

helm-init:
	kubectl apply -f $(ISTIO_HELM)/helm-service-account.yaml
	helm init --wait --service-account tiller

helm-install-istio-init:	helm-init
	helm upgrade istio-init $(ISTIO_HELM)/istio-init \
		--install \
		--namespace $(ISTIO_NAMESPACE) \
		--wait

helm-install-istio-minimal:	helm-install-istio-init
	helm upgrade $(ISTIO_NAME) $(ISTIO_HELM)/istio \
		--install \
		--namespace $(ISTIO_NAMESPACE) \
		--values $(ISTIO_HELM)/istio/values-istio-minimal.yaml \
		--wait

helm-install-istio:	helm-install-istio-init
	helm upgrade $(ISTIO_NAME)$(ISTIO_HELM)/istio \
		--install \
		--namespace $(ISTIO_NAMESPACE) \
		--wait

# https://istio.io/docs/reference/config/installation-options/
helm-upgrade-istio-nodeport:
	helm upgrade $(ISTIO_NAME) $(ISTIO_HELM)/istio \
		--install \
		--namespace $(ISTIO_NAMESPACE) \
		--set gateways.istio-ingressgateway.type=NodePort \
		--set gateways.istio-egressgateway.type=NodePort \
		--wait

helm-reset-istio:
	helm upgrade $(ISTIO_NAME) $(ISTIO_HELM)/istio \
		--namespace $(ISTIO_NAMESPACE) \
		--force \
		--reset-values

helm-delete-istio:
	helm delete --purge istio
	helm delete --purge istio-init

delete-istio-crds:
	kubectl delete -f $(ISTIO_HELM)/istio-init/files


# ==================================
# label for istio sidecar injection
# ==================================

get-label-istio-injection:
	kubectl get namespace -L istio-injection

set-label-istio-injection:
	kubectl label namespace default istio-injection=enabled


# ==================================
# ambassador
# ==================================

install-ambassador:
	kubectl apply -f 'https://getambassador.io/yaml/ambassador/ambassador-rbac.yaml'
	kubectl apply -f $(AMBASSADOR_HOME)/ambassador-service.yaml

#	https://hub.helm.sh/charts/stable/ambassador
helm-install-ambassador:	helm-init
	helm upgrade $(AMBASSADOR_NAME) stable/ambassador \
		--install --wait \
		--set replicaCount=1 \
		--set service.type=NodePort \
		--set service.http.nodePort=$(AMBASSADOR_NODEPORT)

helm-reset-ambassador:
	helm upgrade $(AMBASSADOR_NAME) stable/ambassador \
		--reset-values --force

helm-delete-ambassador:
	helm delete --purge $(AMBASSADOR_NAME)


# ==================================
# inspection
# ==================================

# if you can see "--authorization-mode=Node,RBAC", then rbac is enabled.
check-rbac-enable:
	kubectl cluster-info dump --namespace kube-system | grep authorization-mode

# should be equal to 53
verify-istio-crds:
	kubectl get crds | grep 'istio.io\|certmanager.k8s.io' | wc -l

inspect-proxy:
	$(eval POD := $(shell kubectl get pod -l app=$(APP) -o jsonpath='{.items..metadata.name}'))
	istioctl proxy-config listeners ${POD} --port $(SERVICE_PORT) -o json

proxy-logs:
	$(eval POD := $(shell kubectl get pod -l app=$(APP) -o jsonpath='{.items..metadata.name}'))
	kubectl logs ${POD} istio-proxy -f

port-forward-ambassador:
	kubectl port-forward ambassador-xxxx-yyy 8877

diagnostics-ambassador:
	open http://localhost:8877/ambassador/v0/diag/ # for mac only


# ==================================
# obsoleted targets
# ==================================

# proxy:
# 	kubectl proxy --port 8888

# port-forward:
# 	kpf -n istio-system istio-ingressgateway-7ff8d8b557-n9fmt 15000

# expose:
# 	kubectl expose deployment istio-ingressgateway \
# 		--type=NodePort \
# 		--port=80 \
# 		--target-port=$(AMBASSADOR_NODEPORT)\
# 		--name=gw

# delete-expose:
# 	kubectl delete svc gw


# ==================================
# grpc-json transcoder istio sidecar
# ==================================

APP=helloworld
SERVICE_PORT=9080
ISTIO_ENVOY_FILTER=$(APP)-istio-envoy-filter.yaml

gen-istio-envoy-filter:	$(APP).pb
	grpc-transcoder \
		--port $(SERVICE_PORT) \
		--service $(APP) \
		--descriptor $(APP)/$(APP).pb \
		> $(APP)/$(ISTIO_ENVOY_FILTER)

$(APP).pb:
	protoc \
		-I $(APP) \
		-I $(GOPATH)/src/github.com/grpc-ecosystem/grpc-gateway/third_party/googleapis \
		--include_imports \
		--descriptor_set_out=$(APP)/$(APP).pb \
		$(APP)/$(APP).proto

clean-$(APP):
	rm -f $(APP)/$(ISTIO_ENVOY_FILTER) $(APP)/$(APP).pb


# ==================================
# deployments
# ==================================

deploy-httpbin:
	@kubectl apply -f $(AMBASSADOR_HOME)/httpbin.yaml

test-httpbin:
	curl http://$(MINIKUBE_IP):$(AMBASSADOR_NODEPORT)/httpbin/ip

delete-httpbin:
	@kubectl delete -f $(AMBASSADOR_HOME)/httpbin.yaml

deploy-helloworld: gen-istio-envoy-filter
	@kubectl apply -f $(APP)/$(ISTIO_ENVOY_FILTER)
	@kubectl apply -f $(APP)/$(APP)-virtualservice.yaml
	@$(ISTIOCTL) kube-inject -f $(APP)/$(APP)-deployment.yaml | kubectl apply -f -
