#!/bin/bash

TAG=${1:-v22}

podman build -t redis-op:${TAG} -f docker/app/Dockerfile . 
podman save -o redis-${TAG}.tar localhost/redis-op:${TAG}
kind load image-archive redis-${TAG}.tar