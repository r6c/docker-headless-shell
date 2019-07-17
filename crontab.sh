#!/bin/bash

set -e

SRC=$(realpath $(cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd ))

TREE=/media/src
CHANNELS="stable beta dev"
BUILDATTEMPTS=5

export PATH=$PATH:$HOME/src/misc/chrome/depot_tools
export CHROMIUM_BUILDTOOLS_PATH=/media/src/chromium/src/buildtools

# join_by ',' "${ARRAY[@]}"
function join_by {
  local IFS="$1"; shift; echo "$*";
}

mkdir -p $SRC/out

pushd $SRC &> /dev/null

echo "------------------------------------------------------------"
echo ">>>>> STARTING ($(date)) <<<<<"

# retrieve channel versions
declare -A VERSIONS
for CHANNEL in $CHANNELS; do
  VER=$($TREE/chromium/src/tools/omahaproxy.py --os=linux --channel=$CHANNEL)
  VERSIONS[$CHANNEL]=$VER
  echo ">>>>> CHANNEL $(tr '[:lower:]' '[:upper:]' <<< "$CHANNEL"): $VER <<<<<"
done

echo ">>>>> CLEAN UP ($(date)) <<<<<"
rm -f .last

# remove containers
CONTAINERS=$(docker container ls \
  --filter=ancestor=chromedp/headless-shell \
  --filter=status=exited \
  --filter=status=dead \
  --filter=status=created \
  --quiet
)
if [ ! -z "$CONTAINERS" ]; then
  echo ">>>>> REMOVING DOCKER CONTAINERS ($(date)) <<<<<"
  docker container rm --force $CONTAINERS
fi

# remove images
IMAGES=$(docker images \
  --filter=reference=chromedp/headless-shell \
  |sed 1d \
  |egrep -v "($(join_by '|' "${!VERSIONS[@]}"))" \
  |egrep -v "(latest|$(join_by '|' "${VERSIONS[@]}"))" \
  |awk '{print $3}'
)
if [ ! -z "$IMAGES" ]; then
  echo ">>>>> REMOVING DOCKER IMAGES ($(date)) <<<<<"
  docker rmi --force $IMAGES
fi

pushd $SRC/out &> /dev/null
# remove old builds
DIRS=$(find . -maxdepth 1 -type d -printf "%f\n"|egrep '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'|egrep -v "($(join_by '|' "${VERSIONS[@]}"))"||:)
if [ ! -z "$DIRS" ]; then
  rm -rf $DIRS
fi
ARCHIVES=$(find . -maxdepth 1 -type f -printf "%f\n"|egrep '^headless-shell-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.tar\.bz2'|egrep -v "($(join_by '|' "${VERSIONS[@]}"))"||:)
if [ ! -z "$ARCHIVES" ]; then
  rm -rf $ARCHIVES
fi
popd &> /dev/null

echo ">>>>> ENDED CLEAN UP ($(date)) <<<<<"

for CHANNEL in $CHANNELS; do
  VER=${VERSIONS[$CHANNEL]}
  if [ -f "$SRC/out/headless-shell-$VER.tar.bz2" ]; then
    echo ">>>>> SKIPPPING BUILD FOR CHANNEL $CHANNEL $VER <<<<<"
    continue;
  fi

  echo ">>>>> STARTING BUILD FOR CHANNEL $CHANNEL $VER ($(date)) <<<<<"
  ./build-headless-shell.sh $TREE $VER $BUILDATTEMPTS
  echo ">>>>> ENDED BUILD FOR $CHANNEL $VER ($(date)) <<<<<"
done

echo ">>>>> STARTING DOCKER PULL ($(date)) <<<<<"
docker pull blitznote/debase:18.04
echo ">>>>> ENDED DOCKER PULL ($(date)) <<<<<"

# build docker images
for CHANNEL in $CHANNELS; do
  VER=${VERSIONS[$CHANNEL]}

  if [ -f $SRC/out/headless-shell-$VER.tar.bz2.docker_build_done ]; then
    echo ">>>>> SKIPPPING DOCKER BUILD FOR CHANNEL $CHANNEL $VER <<<<<"
    continue
  fi

  rm -rf $SRC/out/$VER
  mkdir -p  $SRC/out/$VER

  tar -jxf $SRC/out/headless-shell-$VER.tar.bz2 -C $SRC/out/$VER/

  echo ">>>>> STARTING DOCKER BUILD FOR CHANNEL $CHANNEL $VER ($(date)) <<<<<"
  docker build \
    --build-arg VER=$VER \
    --tag chromedp/headless-shell:$VER \
    --tag chromedp/headless-shell:$CHANNEL \
    --quiet .

  if [ "$CHANNEL" = "stable" ]; then
    docker tag chromedp/headless-shell:$VER chromedp/headless-shell:latest
  fi

  touch $SRC/out/headless-shell-$VER.tar.bz2.docker_build_done

  echo ">>>>> ENDED DOCKER BUILD FOR CHANNEL $CHANNEL $VER ($(date)) <<<<<"
done

for CHANNEL in $CHANNELS; do
  VER=${VERSIONS[$CHANNEL]}

  if [ -f $SRC/out/headless-shell-$VER.tar.bz2.docker_push_done ]; then
    echo ">>>>> SKIPPPING DOCKER BUILD FOR CHANNEL $CHANNEL $VER <<<<<"
    continue
  fi

  TAGS=($VER)
  TAGS+=($CHANNEL)
  if [ "$CHANNEL" = "stable" ]; then
    TAGS+=(latest)
  fi

  echo ">>>>> STARTING DOCKER PUSH FOR CHANNEL $CHANNEL $VER ($(date)) <<<<<"
  for TAG in ${TAGS[@]}; do
    docker push chromedp/headless-shell:$TAG
  done

  touch $SRC/out/headless-shell-$VER.tar.bz2.docker_push_done
  echo ">>>>> ENDED DOCKER PUSH FOR CHANNEL $CHANNEL $VER ($(date)) <<<<<"
done

STABLE=$SRC/out/headless-shell-${VERSIONS[stable]}.tar.bz2
if [ ! -f $STABLE.slack_done ]; then
  echo ">>>>> PUBLISH SLACK ($(date)) <<<<<"
  curl \
    -F file=@$STABLE \
    -F channels=CGEV595RP \
    -H "Authorization: Bearer $(cat $HOME/.slack-token)" \
    https://slack.com/api/files.upload
  touch $STABLE.slack_done
  echo -e "\n>>>>> END SLACK ($(date)) <<<<<"
else
  echo ">>>>> SKIPPING PUBLISH SLACK $STABLE <<<<<"
fi

popd &> /dev/null

echo ">>>>> DONE ($(date)) <<<<<"
