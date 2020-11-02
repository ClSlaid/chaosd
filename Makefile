LDFLAGS = $(if $(IMG_LDFLAGS),$(IMG_LDFLAGS),$(if $(DEBUGGER),,-s -w) $(shell ./hack/version.sh))

# Enable GO111MODULE=on explicitly, disable it with GO111MODULE=off when necessary.
export GO111MODULE := on
GOOS := $(if $(GOOS),$(GOOS),"")
GOARCH := $(if $(GOARCH),$(GOARCH),"")
GOENV  := GO15VENDOREXPERIMENT="1" CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH)
CGOENV := GO15VENDOREXPERIMENT="1" CGO_ENABLED=1 GOOS=$(GOOS) GOARCH=$(GOARCH)
GO     := $(GOENV) go
CGO    := $(CGOENV) go
GOTEST := TEST_USE_EXISTING_CLUSTER=false NO_PROXY="${NO_PROXY},testhost" go test
SHELL    := /usr/bin/env bash

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

IMAGE_TAG := $(if $(IMAGE_TAG),$(IMAGE_TAG),latest)

FAILPOINT_ENABLE  := $$(find $$PWD/ -type d | grep -vE "(\.git|bin)" | xargs $(GOBIN)/failpoint-ctl enable)
FAILPOINT_DISABLE := $$(find $$PWD/ -type d | grep -vE "(\.git|bin)" | xargs $(GOBIN)/failpoint-ctl disable)

PACKAGE_LIST := go list ./... | grep -vE "chaos-daemon/test|pkg/ptrace|zz_generated|vendor"
PACKAGE_DIRECTORIES := $(PACKAGE_LIST) | sed 's|github.com/chaos-mesh/chaos-daemon/||'

failpoint-enable: $(GOBIN)/failpoint-ctl
# Converting gofail failpoints...
	@$(FAILPOINT_ENABLE)

failpoint-disable: $(GOBIN)/failpoint-ctl
# Restoring gofail failpoints...
	@$(FAILPOINT_DISABLE)

$(GOBIN)/failpoint-ctl:
	$(GO) get github.com/pingcap/failpoint/failpoint-ctl@v0.0.0-20200210140405-f8f9fb234798

$(GOBIN)/revive:
	$(GO) get github.com/mgechev/revive@v1.0.2-0.20200225072153-6219ca02fffb

$(GOBIN)/goimports:
	$(GO) get golang.org/x/tools/cmd/goimports@v0.0.0-20200309202150-20ab64c0d93f

build: binary

binary: chaosd bin/pause bin/suicide

taily-build:
	if [ "$(shell docker ps --filter=name=$@ -q)" = "" ]; then \
		docker build -t pingcap/chaos-binary ${DOCKER_BUILD_ARGS} .; \
		docker run --rm --mount type=bind,source=$(shell pwd),target=/src \
			--name $@ -d pingcap/chaos-binary tail -f /dev/null; \
	fi;

taily-build-clean:
	docker kill taily-build && docker rm taily-build || exit 0

ifneq ($(TAILY_BUILD),)
image-binary: taily-build image-build-base
	docker exec -it taily-build make binary
	echo -e "FROM scratch\n COPY . /src/bin\n" | docker build -t pingcap/chaos-binary -f - ./bin
else
image-binary: image-build-base
	DOCKER_BUILDKIT=1 docker build -t pingcap/chaos-binary ${DOCKER_BUILD_ARGS} .
endif

chaosd:
	$(CGOENV) go build -ldflags '$(LDFLAGS)' -o bin/chaosd ./cmd/chaos/main.go

image-build-base:
	DOCKER_BUILDKIT=0 docker build --ulimit nofile=65536:65536 -t pingcap/chaos-build-base ${DOCKER_BUILD_ARGS} images/build-base

image-chaosd: image-binary
	docker build -t ${DOCKER_REGISTRY_PREFIX}pingcap/chaosd:${IMAGE_TAG} ${DOCKER_BUILD_ARGS} images/chaosd

bin/pause: ./hack/pause.c
	cc ./hack/pause.c -o bin/pause

bin/suicide: ./hack/suicide.c
	cc ./hack/suicide.c -o bin/suicide

image-chaos-mesh-protoc:
	docker build -t pingcap/chaos-daemon-protoc ${DOCKER_BUILD_ARGS} ./images/protoc

ifeq ($(IN_DOCKER),1)
proto:
	protoc -I pkg/server/serverpb pkg/server/serverpb/*.proto --go_out=plugins=grpc:pkg/server/serverpb --go_out=./pkg/server/serverpb
else
proto: image-chaos-mesh-protoc
	docker run --rm --workdir /mnt/ --volume $(shell pwd):/mnt \
		--user $(shell id -u):$(shell id -g) --env IN_DOCKER=1 pingcap/chaos-daemon-protoc \
		/usr/bin/make proto

	make fmt
endif

check: fmt vet boilerplate lint tidy

# Run go fmt against code
fmt: groupimports
	$(CGOENV) go fmt ./...

groupimports: $(GOBIN)/goimports
	$< -w -l -local github.com/chaos-mesh/chaos-daemon $$($(PACKAGE_DIRECTORIES))

# Run go vet against code
vet:
	$(CGOENV) go vet ./...

lint: $(GOBIN)/revive
	@echo "linting"
	$< -formatter friendly -config revive.toml $$($(PACKAGE_LIST))

boilerplate:
	./hack/verify-boilerplate.sh

tidy:
	@echo "go mod tidy"
	GO111MODULE=on go mod tidy
	git diff -U --exit-code go.mod go.sum

.PHONY: all build check fmt vet lint tidy binary chaosd chaos image-binary image-chaosd
