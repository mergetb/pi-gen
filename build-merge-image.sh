#!/bin/bash

set -ex

# if we are on fedora we need to use the container builder
if [ -f /etc/fedora-release ] || [ -f /etc/redhat-release ]; then
    # bookworm and trixie block the rpi cert due to sha1
    export BASE_IMAGE=debian:bullseye
    export CONTAINER_NAME=${CONTAINER_NAME:-pigen_work_${RANDOM}}
    export PRESERVE_CONTAINER=0
    ./build-docker.sh -c merge-config
else
    # if on debian, just use the build script without container
    ./build.sh -c merge-config
fi
