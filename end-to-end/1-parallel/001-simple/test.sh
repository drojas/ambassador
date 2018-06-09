#!/bin/bash

set -ex -o pipefail

HERE=$(cd $(dirname $0); pwd)

cd "$HERE"

ROOT=$(cd ../..; pwd)
PATH="${ROOT}:${PATH}"

source ${ROOT}/utils.sh

check_rbac

initialize_namespace "001-simple"

kubectl cluster-info

python ${ROOT}/yfix.py ${ROOT}/fixes/test-dep.yfix \
    ${ROOT}/ambassador-deployment.yaml \
    k8s/ambassador-deployment.yaml \
    001-simple \
    001-simple

kubectl apply -f k8s/rbac.yaml

kubectl create cm ambassador-config --namespace=001-simple --from-file k8s/base-config.yaml

kubectl apply -f k8s/ambassador.yaml
kubectl apply -f k8s/ambassador-deployment.yaml
kubectl apply -f k8s/stats-test.yaml

set +e +o pipefail

wait_for_pods 001-simple

CLUSTER=$(cluster_ip)
APORT=$(service_port ambassador 001-simple)

BASEURL="http://${CLUSTER}:${APORT}"

echo "Base URL $BASEURL"
echo "Diag URL $BASEURL/ambassador/v0/diag/"

wait_for_ready "$BASEURL"

if ! check_diag "$BASEURL" 1 "No annotated services"; then
    exit 1
fi

kubectl apply -f k8s/qotm.yaml

wait_for_pods

if ! check_diag "$BASEURL" 2 "QoTM annotated"; then
    exit 1
fi

sleep 5  # ???

if ! qtest.py $CLUSTER:$APORT test-1.yaml; then
    exit 1
fi

kubectl apply -f k8s/authsvc.yaml

wait_for_pods

wait_for_extauth_running "$BASEURL"

kubectl apply -f k8s/authenable.yaml

wait_for_extauth_enabled "$BASEURL"

if ! check_diag "$BASEURL" 3 "Auth annotated"; then
    exit 1
fi

sleep 5  # ???

if ! qtest.py $CLUSTER:$APORT test-2.yaml; then
    exit 1
fi

set -e

APOD=$(ambassador_pod 001-simple)
kubectl exec "$APOD" -n 001-simple -c ambassador -- sh -c 'echo "DUMP" | nc -u -w 1 statsd-sink 8125' > stats.json

rqt=$(jget.py envoy.cluster.cluster_qotm.upstream_rq_total < stats.json)

rc=0

if [ $rqt != 18 ]; then
    echo "Upstream RQ total mismatch: wanted 18, got $rqt"
    rc=1
else
    echo "Upstream RQ total stat good"
fi

rq200=$(jget.py envoy.cluster.cluster_qotm.upstream_rq_2xx < stats.json)

if [ $rq200 != 12 ]; then
    echo "Upstream RQ 200 mismatch: wanted 12, got $rq200"
    rc=1
else
    echo "Upstream RQ 200 stat good"
fi

exit $rc


# kubernaut discard
