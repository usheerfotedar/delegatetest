#!/bin/bash -e

mkdir -p logs
(
echo
echo "` date +%d/%m/%Y%t%H:%M:%S `    ###########################"

if [ ! -e start.sh ]; then
  echo
  echo "Delegate must not be run from a different directory"
  echo
  exit 1
fi

JRE_DIR=jdk8u242-b08-jre
JRE_BINARY=$JRE_DIR/bin/java
case "$OSTYPE" in
  solaris*)
    OS=solaris
    ;;
  darwin*)
    OS=macosx
    JRE_DIR=jdk8u242-b08-jre
    JRE_BINARY=$JRE_DIR/Contents/Home/bin/java
    ;;
  linux*)
    OS=linux
    ;;
  bsd*)
    echo "freebsd not supported."
    exit 1;
    ;;
  msys*)
    echo "For windows execute run.bat"
    exit 1;
    ;;
  cygwin*)
    echo "For windows execute run.bat"
    exit 1;
    ;;
  *)
    echo "unknown: $OSTYPE"
    ;;
esac

JVM_URL=https://app.harness.io/public/shared/jre/openjdk-8u242/jre_x64_${OS}_8u242b08.tar.gz

ALPN_BOOT_JAR_URL=https://app.harness.io/public/shared/tools/alpn/release/8.1.13.v20181017/alpn-boot-8.1.13.v20181017.jar

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

function jar_app_version() {
  JAR=$1
  if unzip -l $JAR | grep -q io/harness/versionInfo.yaml
  then
    VERSION=$(unzip -c $JAR io/harness/versionInfo.yaml | grep "^version " | cut -d ":" -f2 | tr -d " " | tr -d "\r" | tr -d "\n")
  fi

  if [ -z "$VERSION" ]
  then
    if unzip -l $JAR | grep -q main/resources-filtered/versionInfo.yaml
    then
      VERSION=$(unzip -c $JAR main/resources-filtered/versionInfo.yaml | grep "^version " | cut -d ":" -f2 | tr -d " " | tr -d "\r" | tr -d "\n")
    fi
  fi

  if [ -z "$VERSION" ]
  then
    VERSION=$(unzip -c $JAR META-INF/MANIFEST.MF | grep Application-Version | cut -d "=" -f2 | tr -d " " | tr -d "\r" | tr -d "\n")
  fi
  echo $VERSION
}

if [ -z "$1" ]; then
  echo "This script is not meant to be executed directly. The watcher uses it to manage delegate processes."
  exit 0
fi

ULIM=$(ulimit -n)
echo "ulimit -n is set to $ULIM"
if [[ "$ULIM" == "unlimited" || $ULIM -lt 10000 ]]; then
  echo
  echo "WARNING: ulimit -n is too low ($ULIM). Minimum 10000 required."
  echo
fi

if [[ "$OSTYPE" == darwin* ]]; then
  MEM=$(top -l 1 -n 0 | grep PhysMem | cut -d ' ' -f 2 | cut -d 'G' -f 1)
  if [[ $MEM =~ "M" ]]; then
    MEM=$(($(echo $MEM | cut -d 'M' -f 1)/1024))
  fi
  echo "Memory is $MEM"
  if [[ $MEM -lt 6 ]]; then
    echo
    echo "WARNING: Not enough memory ($MEM). Minimum 6 GB required."
    echo
  fi
else
  MEM=$(free -m | grep Mem | awk '{ print $2 }')
  echo "Memory is $MEM MB"
  if [[ $MEM -lt 6000 ]]; then
    echo
    echo "WARNING: Not enough memory ($MEM MB). Minimum 6 GB required."
    echo
  fi
fi

export MANAGER_HOST_AND_PORT=https://app.harness.io
if [ -e proxy.config ]; then
  source proxy.config
  if [[ $PROXY_HOST != "" ]]; then
    echo "Using proxy $PROXY_SCHEME://$PROXY_HOST:$PROXY_PORT"
    if [[ $PROXY_USER != "" ]]; then
      export PROXY_USER
      if [[ "$PROXY_PASSWORD_ENC" != "" ]]; then
        export PROXY_PASSWORD=$(echo $PROXY_PASSWORD_ENC | openssl enc -d -a -des-ecb -K 6a444f6d6872)
      fi
      export PROXY_CURL="-x "$PROXY_SCHEME"://"$PROXY_USER:$PROXY_PASSWORD@$PROXY_HOST:$PROXY_PORT
    else
      export PROXY_CURL="-x "$PROXY_SCHEME"://"$PROXY_HOST:$PROXY_PORT
      export http_proxy=$PROXY_SCHEME://$PROXY_HOST:$PROXY_PORT
      export https_proxy=$PROXY_SCHEME://$PROXY_HOST:$PROXY_PORT
    fi
    PROXY_SYS_PROPS="-DproxyScheme=$PROXY_SCHEME -Dhttp.proxyHost=$PROXY_HOST -Dhttp.proxyPort=$PROXY_PORT -Dhttps.proxyHost=$PROXY_HOST -Dhttps.proxyPort=$PROXY_PORT"
  fi

  if [[ $PROXY_MANAGER == "true" || $PROXY_MANAGER == "" ]]; then
    export MANAGER_PROXY_CURL=$PROXY_CURL
  else
    HOST_AND_PORT_ARRAY=(${MANAGER_HOST_AND_PORT//:/ })
    MANAGER_HOST="${HOST_AND_PORT_ARRAY[1]}"
    MANAGER_HOST="${MANAGER_HOST:2}"
    echo "No proxy for Harness manager at $MANAGER_HOST"
    if [[ $NO_PROXY == "" ]]; then
      NO_PROXY=$MANAGER_HOST
    else
      NO_PROXY="$NO_PROXY,$MANAGER_HOST"
    fi
  fi

  if [[ $NO_PROXY != "" ]]; then
    echo "No proxy for domain suffixes $NO_PROXY"
    export no_proxy=$NO_PROXY
    SYSTEM_PROPERTY_NO_PROXY=`echo $NO_PROXY | sed "s/\,/|*/g"`
    PROXY_SYS_PROPS=$PROXY_SYS_PROPS" -Dhttp.nonProxyHosts=*$SYSTEM_PROPERTY_NO_PROXY"
  fi
fi

if [ ! -d $JRE_DIR -o ! -e $JRE_BINARY ]; then
  echo "Downloading JRE packages..."
  JVM_TAR_FILENAME=$(basename "$JVM_URL")
  curl $MANAGER_PROXY_CURL -#kLO $JVM_URL
  echo "Extracting JRE packages..."
  rm -rf $JRE_DIR
  tar xzf $JVM_TAR_FILENAME
  rm -f $JVM_TAR_FILENAME
fi

export DEPLOY_MODE=KUBERNETES

if [[ $DEPLOY_MODE != "KUBERNETES" ]]; then
  echo "Checking Delegate latest version..."
  DELEGATE_STORAGE_URL=https://app.harness.io
  REMOTE_DELEGATE_LATEST=$(curl $MANAGER_PROXY_CURL -ks $DELEGATE_STORAGE_URL/delegateprod.txt)
  REMOTE_DELEGATE_URL=$DELEGATE_STORAGE_URL/$(echo $REMOTE_DELEGATE_LATEST | cut -d " " -f2)
  REMOTE_DELEGATE_VERSION=$(echo $REMOTE_DELEGATE_LATEST | cut -d " " -f1)

  if [ ! -e delegate.jar ]; then
    echo "Downloading Delegate $REMOTE_DELEGATE_VERSION ..."
    curl $MANAGER_PROXY_CURL -#k $REMOTE_DELEGATE_URL -o delegate.jar
  else
    DELEGATE_CURRENT_VERSION=$(jar_app_version delegate.jar)
    if [[ $REMOTE_DELEGATE_VERSION != $DELEGATE_CURRENT_VERSION ]]; then
      echo "The current version $DELEGATE_CURRENT_VERSION is not the same as the expected remote version $REMOTE_DELEGATE_VERSION"
      echo "Downloading Delegate $REMOTE_DELEGATE_VERSION ..."
      mkdir -p backup.$DELEGATE_CURRENT_VERSION
      cp delegate.jar backup.$DELEGATE_CURRENT_VERSION
      curl $MANAGER_PROXY_CURL -#k $REMOTE_DELEGATE_URL -o delegate.jar
    fi
  fi
fi

if [ -z $CLIENT_TOOLS_DOWNLOAD_DISABLED ]; then
  export CLIENT_TOOLS_DOWNLOAD_DISABLED=false
fi

if [ -z $INSTALL_CLIENT_TOOLS_IN_BACKGROUND ]; then
  export INSTALL_CLIENT_TOOLS_IN_BACKGROUND=true
fi

if [ ! -e config-delegate.yml ]; then
  echo "accountId: jDOmhrFmSOGZJ1C91UC_hg" > config-delegate.yml
  echo "accountSecret: 08404c744e9373f06f455a55b9b3f888" >> config-delegate.yml
fi
test "$(tail -c 1 config-delegate.yml)" && `echo "" >> config-delegate.yml`
if ! `grep managerUrl config-delegate.yml > /dev/null`; then
  echo "managerUrl: https://app.harness.io/api/" >> config-delegate.yml
fi
if ! `grep verificationServiceUrl config-delegate.yml > /dev/null`; then
  echo "verificationServiceUrl: https://app.harness.io/verification/" >> config-delegate.yml
else
  sed -i.bak "s|^verificationServiceUrl:.*$|verificationServiceUrl: https://app.harness.io/verification/|" config-delegate.yml
fi
if ! `grep cvNextGenUrl config-delegate.yml > /dev/null`; then
  echo "cvNextGenUrl: https://app.harness.io/cv/api/" >> config-delegate.yml
else
  sed -i.bak "s|^cvNextGenUrl:.*$|cvNextGenUrl: https://app.harness.io/cv/api/|" config-delegate.yml
fi
if ! `grep watcherCheckLocation config-delegate.yml > /dev/null`; then
  echo "watcherCheckLocation: https://app.harness.io/public/prod/premium/watchers/current.version" >> config-delegate.yml
else
  sed -i.bak "s|^watcherCheckLocation:.*$|watcherCheckLocation: https://app.harness.io/public/prod/premium/watchers/current.version|" config-delegate.yml
fi
if ! `grep heartbeatIntervalMs config-delegate.yml > /dev/null`; then
  echo "heartbeatIntervalMs: 60000" >> config-delegate.yml
fi
if ! `grep doUpgrade config-delegate.yml > /dev/null`; then
  echo "doUpgrade: true" >> config-delegate.yml
fi
if ! `grep localDiskPath config-delegate.yml > /dev/null`; then
  echo "localDiskPath: /tmp" >> config-delegate.yml
fi
if ! `grep maxCachedArtifacts config-delegate.yml > /dev/null`; then
  echo "maxCachedArtifacts: 2" >> config-delegate.yml
fi
if ! `grep pollForTasks config-delegate.yml > /dev/null`; then
  if [ "$DEPLOY_MODE" == "ONPREM" ]; then
      echo "pollForTasks: true" >> config-delegate.yml
  else
      echo "pollForTasks: false" >> config-delegate.yml
  fi
fi

if ! `grep useCdn config-delegate.yml > /dev/null`; then
  echo "useCdn: true" >> config-delegate.yml
else
  sed -i.bak "s|^useCdn:.*$|useCdn: true|" config-delegate.yml
fi
if ! `grep cdnUrl config-delegate.yml > /dev/null`; then
  echo "cdnUrl: https://app.harness.io" >> config-delegate.yml
else
  sed -i.bak "s|^cdnUrl:.*$|cdnUrl: https://app.harness.io|" config-delegate.yml
fi


if ! `grep grpcServiceEnabled config-delegate.yml > /dev/null`; then
  echo "grpcServiceEnabled: $GRPC_SERVICE_ENABLED" >> config-delegate.yml
else
  sed -i.bak "s|^grpcServiceEnabled:.*$|grpcServiceEnabled: $GRPC_SERVICE_ENABLED|" config-delegate.yml
fi

if ! `grep grpcServiceConnectorPort config-delegate.yml > /dev/null`; then
  echo "grpcServiceConnectorPort: $GRPC_SERVICE_CONNECTOR_PORT" >> config-delegate.yml
else
  sed -i.bak "s|^grpcServiceConnectorPort:.*$|grpcServiceConnectorPort: $GRPC_SERVICE_CONNECTOR_PORT|" config-delegate.yml
fi

if ! `grep logStreamingServiceBaseUrl config-delegate.yml > /dev/null`; then
  echo "logStreamingServiceBaseUrl: https://app.harness.io/log-service/" >> config-delegate.yml
else
  sed -i.bak "s|^logStreamingServiceBaseUrl:.*$|logStreamingServiceBaseUrl: https://app.harness.io/log-service/|" config-delegate.yml
fi

if ! `grep clientToolsDownloadDisabled config-delegate.yml > /dev/null`; then
  echo "clientToolsDownloadDisabled: $CLIENT_TOOLS_DOWNLOAD_DISABLED" >> config-delegate.yml
fi

if ! `grep installClientToolsInBackground config-delegate.yml > /dev/null`; then
  echo "installClientToolsInBackground: $INSTALL_CLIENT_TOOLS_IN_BACKGROUND" >> config-delegate.yml
fi

if ! `grep versionCheckDisabled config-delegate.yml > /dev/null`; then
  echo "versionCheckDisabled: false" >> config-delegate.yml
else
  sed -i.bak "s|^versionCheckDisabled:.*$|versionCheckDisabled: false|" config-delegate.yml
fi


if [ ! -z "$KUSTOMIZE_PATH" ] && ! `grep kustomizePath config-delegate.yml > /dev/null` ; then
  echo "kustomizePath: $KUSTOMIZE_PATH" >> config-delegate.yml
fi

if [ ! -z "$OC_PATH" ] && ! `grep ocPath config-delegate.yml > /dev/null` ; then
  echo "ocPath: $OC_PATH" >> config-delegate.yml
fi

if [ ! -z "$KUBECTL_PATH" ] && ! `grep kubectlPath config-delegate.yml > /dev/null` ; then
  echo "kubectlPath: $KUBECTL_PATH" >> config-delegate.yml
fi

if [ ! -z "$CF_CLI6_PATH" ] && ! `grep cfCli6Path config-delegate.yml > /dev/null` ; then
  echo "cfCli6Path: $CF_CLI6_PATH" >> config-delegate.yml
fi

if [ ! -z "$CF_CLI7_PATH" ] && ! `grep cfCli7Path config-delegate.yml > /dev/null` ; then
  echo "cfCli7Path: $CF_CLI7_PATH" >> config-delegate.yml
fi

rm -f -- *.bak

export KUBECTL_VERSION=v1.13.2

export SCM_VERSION=0e23b6f1

export DELEGATE_NAME=osshelldeltest
export DELEGATE_PROFILE=8tbhqnKBTHaMte9KzfQEJg
export DELEGATE_TYPE=SHELL_SCRIPT
export VERSION_CHECK_DISABLED=false

export HOSTNAME
export CAPSULE_CACHE_DIR="$DIR/.cache"

if [[ ! -z $INSTRUMENTATION ]]; then
  export JRE_BINARY=$JDK_BINARY
fi

if [ ! -e alpn-boot-8.1.13.v20181017.jar ]; then
  curl $MANAGER_PROXY_CURL -ks $ALPN_BOOT_JAR_URL -o alpn-boot-8.1.13.v20181017.jar
fi

if [[ $DEPLOY_MODE == "KUBERNETES" ]]; then
  echo "Starting delegate - version $2 with java $JRE_BINARY"
  $JRE_BINARY $JAVA_OPTS $INSTRUMENTATION $PROXY_SYS_PROPS $OVERRIDE_TMP_PROPS -Ddelegatesourcedir="$DIR" -Xmx4096m -XX:+HeapDumpOnOutOfMemoryError -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:mygclogfilename.gc -XX:+UseParallelGC -XX:MaxGCPauseMillis=500 -Dfile.encoding=UTF-8 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true -DLANG=en_US.UTF-8 -Xbootclasspath/p:alpn-boot-8.1.13.v20181017.jar -jar $2/delegate.jar config-delegate.yml watched $1
else
  echo "Starting delegate - version $REMOTE_DELEGATE_VERSION with java $JRE_BINARY"
  $JRE_BINARY $JAVA_OPTS $INSTRUMENTATION $PROXY_SYS_PROPS $OVERRIDE_TMP_PROPS -Ddelegatesourcedir="$DIR" -Xmx4096m -XX:+HeapDumpOnOutOfMemoryError -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:mygclogfilename.gc -XX:+UseParallelGC -XX:MaxGCPauseMillis=500 -Dfile.encoding=UTF-8 -Dcom.sun.jndi.ldap.object.disableEndpointIdentification=true -DLANG=en_US.UTF-8 -Xbootclasspath/p:alpn-boot-8.1.13.v20181017.jar -jar delegate.jar config-delegate.yml watched $1
fi

sleep 3
if `pgrep -f "\-Ddelegatesourcedir=$DIR"> /dev/null`; then
  echo "Delegate started"
else
  echo "Failed to start Delegate."
  echo "$(tail -n 30 delegate.log)"
fi )
