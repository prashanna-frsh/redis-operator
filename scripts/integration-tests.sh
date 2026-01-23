#!/bin/bash

set -eu

SUDO=''
if [[ $(id -u) -ne 0 ]]
then
    SUDO="sudo"
fi

function cleanup {
    echo "=> Removing minikube cluster"
    $SUDO minikube delete
}
trap cleanup EXIT

echo "=> Preparing minikube for running integration tests"
$SUDO minikube start --vm-driver=none --kubernetes-version=v1.22.3

echo "=> Waiting for minikube to start"
sleep 30

# Hack for Travis. The kubeconfig has to be readable
if [[ -v IN_TRAVIS ]]
then
    $SUDO chown -R travis: ${HOME}/.minikube/
    $SUDO chmod a+r ${HOME}/.kube/config
fi

TEST_NAME="${1:-TestRedisFailoverMyMaster}"

echo "=> Running single test: $TEST_NAME"
cd "$REPO_ROOT"
go test ./test/integration/redisfailover -v -tags='integration' -run "$TEST_NAME"