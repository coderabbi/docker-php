qa: lint lint-shell build test scan-vulnerability
build: clean-tags build-nts build-zts
push: build push-nts push-zts
ci-push-nts: ci-docker-login push-nts
ci-push-zts: ci-docker-login push-zts

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(abspath $(patsubst %/,%,$(dir $(mkfile_path))))

.PHONY: *

BUILDINGIMAGE=*

# Docker PHP images build matrix ./build-php.sh (nts/zts) (PHP version) (Alpine version)
build-nts: BUILDINGIMAGE=nts
build-nts: clean-tags
	./build-php.sh nts 7.3 3.8
	./build-php.sh nts 7.3 3.9

build-zts: BUILDINGIMAGE=zts
build-zts: clean-tags
	./build-php.sh zts 7.3 3.8
	./build-php.sh zts 7.3 3.9

.NOTPARALLEL: clean-tags
clean-tags:
	rm ${current_dir}/tmp/build-${BUILDINGIMAGE}.tags || true

# Docker images push
push-nts: BUILDINGIMAGE=nts
push-nts:
	cat ./tmp/build-${BUILDINGIMAGE}.tags | xargs -I % docker push %

push-zts: BUILDINGIMAGE=zts
push-zts:
	cat ./tmp/build-${BUILDINGIMAGE}.tags | xargs -I % docker push %

# CI dependencies
ci-docker-login:
	docker login --username $$DOCKER_USER --password $$DOCKER_PASSWORD

lint:
	docker run -v ${current_dir}:/project:ro --workdir=/project --rm -it hadolint/hadolint:latest-debian hadolint /project/Dockerfile-nts /project/Dockerfile-zts

test: test-cli test-fpm test-http

test-nts: ./tmp/build-nts.tags
	xargs -I % ./test-nts.sh % < ./tmp/build-nts.tags

test-zts: ./tmp/build-zts.tags
	xargs -I % ./test-zts.sh % < ./tmp/build-zts.tags

scan-vulnerability:
	docker-compose -f test/security/docker-compose.yml -p clair-ci up -d
	RETRIES=0 && while ! wget -T 10 -q -O /dev/null http://localhost:6060/v1/namespaces ; do sleep 1 ; echo -n "." ; if [ $${RETRIES} -eq 10 ] ; then echo " Timeout, aborting." ; exit 1 ; fi ; RETRIES=$$(($${RETRIES}+1)) ; done
	mkdir -p ./tmp/clair/usabillabv
	cat ./tmp/build-*.tags | xargs -I % sh -c 'clair-scanner --ip 172.17.0.1 -r "./tmp/clair/%.json" -l ./tmp/clair/clair.log % || echo "% is vulnerable"'
	docker-compose -f test/security/docker-compose.yml -p clair-ci down

ci-scan-vulnerability:
	docker-compose -f test/security/docker-compose.yml -p clair-ci up -d
	RETRIES=0 && while ! wget -T 10 -q -O /dev/null http://localhost:6060/v1/namespaces ; do sleep 1 ; echo -n "." ; if [ $${RETRIES} -eq 10 ] ; then echo " Timeout, aborting." ; exit 1 ; fi ; RETRIES=$$(($${RETRIES}+1)) ; done
	mkdir -p ./tmp/clair/usabillabv
	cat ./tmp/build-*.tags | xargs -I % sh -c 'clair-scanner --ip 172.17.0.1 -r "./tmp/clair/%.json" -l ./tmp/clair/clair.log %'; \
	XARGS_EXIT=$$?; \
	if [ $${XARGS_EXIT} -eq 123 ]; then find ./tmp/clair/usabillabv -type f | sed 's/^/-Fjson=@/' | xargs -d'\n' curl -X POST ${WALLE_REPORT_URL} -F channel=team_oz -F buildUrl=https://circleci.com/gh/wyrihaximusnet/docker-php/${CIRCLE_BUILD_NUM}#artifacts/containers/0; else exit $${XARGS_EXIT}; fi