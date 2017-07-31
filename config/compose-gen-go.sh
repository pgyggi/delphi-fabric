#!/usr/bin/env bash

sudo apt-get -qq install -y jq

CURRENT="$(dirname $(readlink -f ${BASH_SOURCE}))"

COMPOSE_FILE="$CURRENT/docker-compose.yaml"
CONFIG_JSON="$CURRENT/orgs.json"
IMAGE_TAG="x86_64-1.0.0" # latest
CONTAINER_CONFIGTX_DIR="/etc/hyperledger/configtx"
CONTAINER_CRYPTO_CONFIG_DIR="/etc/hyperledger/crypto-config"
TLS_ENABLED=true

COMPANY=$1
MSPROOT=$2
BLOCK_FILE=$3
orgs=()

if [ -z "$COMPANY" ]; then
	echo "missing company parameter"
	exit 1
fi
remain_params=""
for ((i = 4; i <= $#; i++)); do
	j=${!i}
	remain_params="$remain_params $j"
done
while getopts "j:s:v:f:" shortname $remain_params; do
	case $shortname in
	j)
		echo "set config json file (default: $CONFIG_JSON) ==> $OPTARG"
		CONFIG_JSON=$OPTARG
		;;
	s)
		echo "set TLS_ENABLED string true|false (default: $TLS_ENABLED) ==> $OPTARG"
		TLS_ENABLED=$OPTARG
		;;
	v)
		echo "set docker image version tag (default: $IMAGE_TAG) ==> $OPTARG"
		IMAGE_TAG=$OPTARG
		;;
	f)
		echo "set docker-compose file (default: $COMPOSE_FILE) ==> $OPTARG"
		COMPOSE_FILE=$OPTARG
		;;
	?)
		echo "unknown argument"
		exit 1
		;;
	esac
done
COMPANY_DOMAIN=$(jq -r ".$COMPANY.domain" $CONFIG_JSON)

ORDERER_CONTAINER=$(jq -r ".$COMPANY.orderer.containerName" $CONFIG_JSON).$COMPANY_DOMAIN

p2=$(jq -r ".$COMPANY.orgs|keys[]" $CONFIG_JSON)
if [ "$?" -eq "0" ]; then
	for org in $p2; do
		orgs+=($org)
	done
else
	echo "invalid organization json param:"
	echo "--company: $COMPANY"
	exit 1
fi

ORDERER_HOST_PORT=$(jq -r ".$COMPANY.orderer.portMap[0].host" $CONFIG_JSON)
ORDERER_CONTAINER_PORT=$(jq -r ".$COMPANY.orderer.portMap[0].container" $CONFIG_JSON)

rm $COMPOSE_FILE
>"$COMPOSE_FILE"

yaml w -i $COMPOSE_FILE version \"2\" # NOTE it should be a string
# ccenv
yaml w -i $COMPOSE_FILE services.ccenv.image hyperledger/fabric-ccenv:$IMAGE_TAG
yaml w -i $COMPOSE_FILE services.ccenv.container_name ccenv.$COMPANY_DOMAIN

# orderer
ORDERER_SERVICE_NAME="OrdererServiceName.$COMPANY_DOMAIN" # orderer service name will linked to depends_on

p=0
function envPush() {
		local CMD="$1"
		$CMD.environment[$p] "$2"
		((p++))
}

yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].container_name $ORDERER_CONTAINER
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].image hyperledger/fabric-orderer:$IMAGE_TAG
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].working_dir /opt/gopath/src/github.com/hyperledger/fabric/orderers
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].command "orderer"
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].ports[0] $ORDERER_HOST_PORT:$ORDERER_CONTAINER_PORT



yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[0] ORDERER_GENERAL_LOGLEVEL=debug
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[1] ORDERER_GENERAL_LISTENADDRESS=0.0.0.0
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[2] ORDERER_GENERAL_GENESISMETHOD=file

orderer_hostName=$(jq -r ".$COMPANY.orderer.containerName" $CONFIG_JSON)
ORDERER_HOST_FULLNAME=${orderer_hostName,,}.$COMPANY_DOMAIN
ORDERER_STRUCTURE="ordererOrganizations/$COMPANY_DOMAIN/orderers/$ORDERER_HOST_FULLNAME"
CONTAINER_ORDERER_TLS_DIR="$CONTAINER_CRYPTO_CONFIG_DIR/$ORDERER_STRUCTURE/tls"

yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[3] ORDERER_GENERAL_GENESISFILE=$CONTAINER_CONFIGTX_DIR/$(basename $BLOCK_FILE)
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[4] ORDERER_GENERAL_TLS_ENABLED="$TLS_ENABLED"
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[5] ORDERER_GENERAL_TLS_PRIVATEKEY=$CONTAINER_ORDERER_TLS_DIR/server.key
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[6] ORDERER_GENERAL_TLS_CERTIFICATE=$CONTAINER_ORDERER_TLS_DIR/server.crt
# MSP
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[7] ORDERER_GENERAL_LOCALMSPID=OrdererMSP
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[8] ORDERER_GENERAL_LOCALMSPDIR=$CONTAINER_CRYPTO_CONFIG_DIR/$ORDERER_STRUCTURE/msp

yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].volumes[0] "$(dirname $BLOCK_FILE):$CONTAINER_CONFIGTX_DIR"
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].volumes[1] "$MSPROOT:$CONTAINER_CRYPTO_CONFIG_DIR"

rootCAs=$CONTAINER_ORDERER_TLS_DIR/ca.crt
for ((i = 0; i < ${#orgs[@]}; i++)); do
	org=${orgs[$i]}
	PEER_DOMAIN=${org,,}.$COMPANY_DOMAIN
	PEER_ANCHOR=peer0.$PEER_DOMAIN
	USER_ADMIN=Admin@$PEER_DOMAIN
	peerServiceName=$PEER_ANCHOR
	peerContainer=$(jq -r ".$COMPANY.orgs.$org.peers[0].containerName" $CONFIG_JSON).$COMPANY_DOMAIN
	PEER_STRUCTURE="peerOrganizations/$PEER_DOMAIN/peers/$PEER_ANCHOR"
	rootCAs="$rootCAs,$CONTAINER_CRYPTO_CONFIG_DIR/$PEER_STRUCTURE/tls/ca.crt"

    ADMIN_STRUCTURE="peerOrganizations/$PEER_DOMAIN/users/$USER_ADMIN"
	# peer container
	#
	PEERCMD="yaml w -i $COMPOSE_FILE "services["${peerServiceName}"]

	$PEERCMD.container_name $peerContainer
	$PEERCMD.depends_on[0] $ORDERER_SERVICE_NAME
	$PEERCMD.image hyperledger/fabric-peer:$IMAGE_TAG
	$PEERCMD.working_dir /opt/gopath/src/github.com/hyperledger/fabric/peer
	$PEERCMD.command "peer node start"

	#common env
	p=0

	envPush "$PEERCMD" CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
	envPush "$PEERCMD" CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=$COMPANY
	envPush "$PEERCMD" CORE_LOGGING_LEVEL=DEBUG
	envPush "$PEERCMD" CORE_LEDGER_HISTORY_ENABLEHISTORYDATABASE=true

	### GOSSIP setting
	envPush "$PEERCMD" CORE_PEER_GOSSIP_USELEADERELECTION=true
	envPush "$PEERCMD" CORE_PEER_GOSSIP_ORGLEADER=false
	envPush "$PEERCMD" CORE_PEER_GOSSIP_SKIPHANDSHAKE=true
	envPush "$PEERCMD" CORE_PEER_GOSSIP_EXTERNALENDPOINT=$peerContainer:7051

	# CORE_PEER_GOSSIP_EXTERNALENDPOINT=peer0:7051
	# only work when CORE_PEER_GOSSIP_ORGLEADER=true & CORE_PEER_GOSSIP_SKIPHANDSHAKE=false & CORE_PEER_GOSSIP_USELEADERELECTION=false
    envPush "$PEERCMD" CORE_PEER_LOCALMSPID=${org}MSP
	envPush "$PEERCMD" CORE_PEER_MSPCONFIGPATH=$CONTAINER_CRYPTO_CONFIG_DIR/$ADMIN_STRUCTURE/msp
	envPush "$PEERCMD" CORE_PEER_TLS_ENABLED=$TLS_ENABLED
	envPush "$PEERCMD" CORE_PEER_TLS_KEY_FILE=$CONTAINER_CRYPTO_CONFIG_DIR/$PEER_STRUCTURE/tls/server.key
	envPush "$PEERCMD" CORE_PEER_TLS_CERT_FILE=$CONTAINER_CRYPTO_CONFIG_DIR/$PEER_STRUCTURE/tls/server.crt
	envPush "$PEERCMD" CORE_PEER_TLS_ROOTCERT_FILE=$CONTAINER_CRYPTO_CONFIG_DIR/$PEER_STRUCTURE/tls/ca.crt


	#individual env
	envPush "$PEERCMD" CORE_PEER_ID=$PEER_ANCHOR
	envPush "$PEERCMD" CORE_PEER_ADDRESS=$PEER_ANCHOR:7051

	PEER_HOST_PORTS=$(jq ".$COMPANY.orgs.${org}.peers[0].portMap[].host" $CONFIG_JSON)
	PEER_CONTAINER_PORTS=($(jq ".$COMPANY.orgs.${org}.peers[0].portMap[].container" $CONFIG_JSON))
	j=0
	for port in $PEER_HOST_PORTS; do
		$PEERCMD.ports[$j] $port:${PEER_CONTAINER_PORTS[$j]}
		((j++))
	done
	$PEERCMD.volumes[0] "/var/run/:/host/var/run/"
	$PEERCMD.volumes[1] "$MSPROOT:$CONTAINER_CRYPTO_CONFIG_DIR" # for peer channel --cafile
	$PEERCMD.volumes[2] "$(dirname $BLOCK_FILE):$CONTAINER_CONFIGTX_DIR" # for later channel create

	# CA
	p=0
	CACMD="yaml w -i $COMPOSE_FILE "services["ca.$PEER_DOMAIN"]
	$CACMD.image hyperledger/fabric-ca:$IMAGE_TAG
	$CACMD.container_name "ca.$PEER_DOMAIN"
	$CACMD.command "sh -c 'fabric-ca-server start -b admin:adminpw -d'"
	CONTAINER_CA_VOLUME="$CONTAINER_CRYPTO_CONFIG_DIR/peerOrganizations/$PEER_DOMAIN/ca/"
	CA_HOST_VOLUME="${MSPROOT}peerOrganizations/$PEER_DOMAIN/ca/"
	privkeyFilename=$(basename $(find $CA_HOST_VOLUME -type f \( -name "*_sk" \)))
	$CACMD.volumes[0] "$CA_HOST_VOLUME:$CONTAINER_CA_VOLUME"

	envPush "$CACMD" "FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-server" # align with command
	envPush "$CACMD" "FABRIC_CA_SERVER_CA_CERTFILE=${CONTAINER_CA_VOLUME}ca.$PEER_DOMAIN-cert.pem"
	envPush "$CACMD" "FABRIC_CA_SERVER_TLS_CERTFILE=${CONTAINER_CA_VOLUME}ca.$PEER_DOMAIN-cert.pem"

	envPush "$CACMD" "FABRIC_CA_SERVER_TLS_KEYFILE=${CONTAINER_CA_VOLUME}$privkeyFilename"
	envPush "$CACMD" "FABRIC_CA_SERVER_CA_KEYFILE=${CONTAINER_CA_VOLUME}$privkeyFilename"
	envPush "$CACMD" "FABRIC_CA_SERVER_TLS_ENABLED=$TLS_ENABLED"

	CA_HOST_PORT=$(jq ".$COMPANY.orgs.${org}.ca.portMap[0].host" $CONFIG_JSON)
	CA_CONTAINER_PORT=$(jq ".$COMPANY.orgs.${org}.ca.portMap[0].container" $CONFIG_JSON)
	$CACMD.ports[0] $CA_HOST_PORT:$CA_CONTAINER_PORT

done
yaml w -i $COMPOSE_FILE services["$ORDERER_SERVICE_NAME"].environment[9] "ORDERER_GENERAL_TLS_ROOTCAS=[$rootCAs]"

# NOTE: cli container is just a shadow of any existing peer! see the CORE_PEER_ADDRESS & CORE_PEER_MSPCONFIGPATH