#!/bin/bash

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -r|--registry)
    reg="$2"
    shift # past argument
    shift # past value
    ;;
    -i|--images)
    images="$2"
    shift # past argument
    shift # past value
    ;;
esac
done

if [[ -z $reg ]]; then
    echo "-r|--registry is required"
    exit 1
fi

if [[ -z $images ]]; then
    echo "-i|--images file is required"
    exit 1
fi

echo "Log into Docker registry ${reg}"
docker login ${reg}

for i in $(cat ${images}); do
    docker pull ${i}
    docker tag ${i} ${reg}/${i}
    docker push ${reg}/${i}
done

