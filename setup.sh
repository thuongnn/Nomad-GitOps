#!/bin/zsh -e

# one time setup of server(s) to make a nomad cluster (presently single server simple setup)

[ $# -lt 5 ]  &&  echo "
usage: $0  [TLS_DOMAIN]  [TLS_CRT file]  [TLS_KEY file]  [first node]  [cluster size]

[TLS_DOMAIN]   - eg: x.archive.org
[TLS_CRT file] - file location. PEM format.
[TLS_CRT fle]  - file location. PEM format.  May need to prepend 'SERVER:' for use by rsync..)
[first node]   - name of the first node in your cluster - we'll append [TLS_DOMAIN] to it.
[cluster size] - number of nodes - 1 or more.

Run this script on each node in your cluster, while ssh-ed in to them.
(git clone this repo somewhere..)

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

To simplify, we'll setup and unseal your vault server on the same/first server that the
fabio load balancer goes to so we can reuse TLS certs.  This will also setup ACL and TLS for nomad.

"  &&  exit 1
set -x

NOMAD_VERSION=0.11.3
CONSUL_VERSION=1.7.3 # 1.8.0
VAULT_VERSION=1.4.2 # 1.4.3

TLS_DOMAIN=$1
TLS_CRT=$2  # @see create-https-certs.sh - fully qualified path to crt file it created
TLS_KEY=$3  # @see create-https-certs.sh - fully qualified path to key file it created
FIRST=$4
CLUSTER_SIZE=$5

MYDIR=${0:a:h}
NODE=$(hostname -s)

# avoid any environment vars from CLI poisoning..
unset   NOMAD_ADDR   NOMAD_TOKEN
unset  CONSUL_ADDR  CONSUL_TOKEN
unset   VAULT_ADDR   VAULT_TOKEN


FIRSTIP=$(host $FIRST |tail -1 |rev |cut -f1 -d' ' |rev)

NOMAD_HOST=$FIRST.$TLS_DOMAIN
VAULT_DOM=$TLS_DOMAIN
VAULT_HOST=$FIRST.$VAULT_DOM
MAX_PV=20

# xxx should setup user/group `consul` like:
# https://learn.hashicorp.com/consul/datacenter-deploy/deployment-guide#install-consul

# https://medium.com/velotio-perspectives/how-much-do-you-really-know-about-simplified-cloud-deployments-b74d33637e07

cd /tmp


function setup-node() {
  # install docker if not already present
  $MYDIR/install-docker-ce.sh

  # install minimal requirements
  sudo apt-get -y install  unzip


  ###################################################################################################
  # install binaries and service files
  for PRODUCT in  consul  nomad  vault; do
    PRODUCTUP=$(echo $PRODUCT |tr a-z A-Z) # uppercasify
    VER=$(eval "echo \${${PRODUCTUP}_VERSION}") # get the version number (from top-level globals)

    wget https://releases.hashicorp.com/$PRODUCT/$VER/${PRODUCT}_${VER}_linux_amd64.zip -qO $PRODUCT.zip
    unzip -o $PRODUCT.zip
    sudo chown root:root $PRODUCT
    sudo mv -fv $PRODUCT /usr/sbin/
    rm -fv $PRODUCT.zip

    # install /etc/ conf and system files
    sudo cp $MYDIR/etc/$PRODUCT.service /etc/systemd/system/
    sudo chown root:root                /etc/systemd/system/$PRODUCT.service

    HCL=/etc/$PRODUCT/server.hcl
    sudo mkdir -p $(dirname $HCL)
    sudo cp $MYDIR/etc/$PRODUCT.hcl $HCL
    sudo chmod 400       $HCL
    sudo chown root.root $HCL
  done


  ###################################################################################################
  # See if we are the first node in the cluster
  HCL=/etc/nomad/server.hcl
  # See how many nodes in the cluster already (might be 0)
  # We will put LB on 1st server
  # We will put PV on 2nd server (or if single node cluster - 1st/only server)
  COUNT=666 # gets re/set below
  N=$(ssh $FIRST "sudo fgrep -c '@@' $HCL |cat")
  if [ $N -gt 0 ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_N=$(nomad operator keygen |tr -d ^)
    TOK_C=$(consul keygen |tr -d ^)
    COUNT=0
  else
    nomad-env-vars
    # ^^ now we can talk to first nomad server
    COUNT=$(nomad node status -t '{{range .}}{{.Name}}{{"\n"}}{{end}}' |egrep . |wc -l |tr -d ' ')
    TOK_N=$(ssh $FIRST "sudo egrep 'encrypt\s*=' /etc/nomad/server.hcl"  |cut -f2- -d= |tr -d '\t "')
    TOK_C=$(ssh $FIRST "sudo egrep 'encrypt\s*=' /etc/consul/server.hcl" |cut -f2- -d= |tr -d '\t "')
  fi


  ## Consul - edit server.hcl and setup the fields 'encrypt' and 'retry_join' as per your cluster.
  HCL=/etc/consul/server.hcl
  sudo sed -i -e "s^@@CONSUL_KEY@@^$TOK_C^"       $HCL
  sudo sed -i -e "s^@@NODE_NAME@@^$NODE^"         $HCL
  sudo sed -i -e "s^@@SRV_IP_ADDRESS@@^$FIRSTIP^" $HCL
  sudo sed -i -e "s^bootstrap_expect\s*=\s*\d^bootstrap_expect = $CLUSTER_SIZE^" $HCL
  sudo fgrep '@@' $HCL  &&  exit 1


  ## Nomad - edit server.hcl and setup the fields 'encrypt' and 'retry_join' as per your cluster.
  HCL=/etc/nomad/server.hcl
  sudo sed -i -e "s^@@NOMAD_KEY@@^$TOK_N^"        $HCL
  sudo sed -i -e "s^@@NODE_NAME@@^$NODE^"         $HCL
  sudo sed -i -e "s^@@SRV_IP_ADDRESS@@^$FIRSTIP^" $HCL
  sudo sed -i -e "s^bootstrap_expect\s*=\s*\d^bootstrap_expect = $CLUSTER_SIZE^" $HCL
  sudo fgrep '@@' $HCL  &&  exit 1


  setup-certs

  ${MYDIR?}/ports-unblock.sh

  sudo service docker restart


  ( configure-nomad ) |sudo tee -a $HCL


  # get services ready to go
  sudo systemctl daemon-reload
  sudo systemctl enable  consul nomad vault

  # get consul running first ...
  sudo systemctl restart consul  &&  sleep 10

  # ... so we can setup and get running Vault and unseal it
  setup-vault


  # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
  # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
  # pass through this `/pv` dir from the VM/host to containers.  Each container using it
  # needs to use unique subdirs...
  for N in $(seq 1 $MAX_PV); do
    sudo mkdir -m777 -p /pv$N
  done


  # This gets us DNS resolving on archive.org VMs, at the VM level (not inside containers)-8
  # for hostnames like:
  #   active.vault.service.consul
  #   services-clusters.service.consul
  [ -e /etc/dnsmasq.d/ ]  &&  (
    echo "server=/consul/127.0.0.1#8600" |sudo tee /etc/dnsmasq.d/nomad
    sudo service dnsmasq restart
    sleep 2
  )


  sudo systemctl restart nomad  &&  sleep 10
  nomad-env-vars

  consul members
  nomad server members
}


function configure-nomad() {
  echo '
client {
  # enabling means _this_ server can schedule jobs - kind of like "tainting" your master in kubernetes
  enabled       = true
'
  # Let's put the loadbalancer on the first two nodes added to cluster.
  # All jobs requiring a PV get put on 2nd node in cluster (or first if cluster of 1).
  local KIND='worker'
  [ $COUNT -le 1 ]  &&  KIND="$KIND,lb"
  [ $COUNT -eq 1  -o  $CLUSTER_SIZE -eq 0 ]  &&  KIND="$KIND,pv"
  echo '
  meta {
    "kind" = "'$KIND'"
  }'

  [ "$NFSHOME" = "" ]  ||  echo '

  host_volume "home-ro" {
    path      = "/home"
    read_only = true
  }

  host_volume "home-rw" {
    path      = "/home"
    read_only = false
  }'

  # pass through disk from host for now.  peg project(s) with PV requirements to this host.
  for N in $(seq 1 $MAX_PV); do
    echo -n '
  host_volume "pv'$N'" {
    path      = "/pv'$N'"
    read_only = false
  }'
  done

  echo '
}'
}


function setup-vault() {
  # https://learn.hashicorp.com/vault/getting-started/deploy
  # update vault config
  sudo sed -i -e "s^VAULT_DOM^$VAULT_DOM^" /etc/vault/server.hcl

  if [ $COUNT -eq 0 ]; then
    # fire up vault and unseal it
    sudo systemctl restart vault  &&  sleep 10

    local VFI=/var/lib/.vault
    export VAULT_ADDR=https://$VAULT_HOST:8200
    vault operator init |sudo tee $VFI
    sudo chmod 400 $VFI

    export VAULT_TOKEN=$(sudo grep 'Initial Root Token:' $VFI |cut -f2- -d: |tr -d ' ')

    set +x
    vault operator unseal $(sudo grep 'Unseal Key 1:' $VFI |cut -f2- -d: |tr -d ' ')
    vault operator unseal $(sudo grep 'Unseal Key 2:' $VFI |cut -f2- -d: |tr -d ' ')
    vault operator unseal $(sudo grep 'Unseal Key 3:' $VFI |cut -f2- -d: |tr -d ' ')
    sleep 10
    echo "$VAULT_TOKEN" | vault login -

    echo '


💥 CONGRATULATIONS!  Your vault is setup and unsealed. 💥


You ** MUST ** now copy this somewhere VERY safe, ideally one Unseal Key to each of trusted people.


    '
    sudo egrep . $VFI
    sudo rm -fv  $VFI
    echo '



💥 TYPE yes ONCE COPIED CONTENTS ABOVE TO CONTINUE (or CTL-C to abort):
    '
    cont=
    while [ "$cont" != "yes" ]; do
      read cont
    done

    set -x

    vault secrets enable -version=2 kv
    vault secrets list -detailed


    unset VAULT_ADDR
  else
    export VAULT_TOKEN=$(ssh $FIRST "sudo egrep 'token\s*=' /etc/nomad/server.hcl"  |cut -f2- -d= |tr -d '\t "')
  fi


  # configure vault section of nomad
  HCL=/etc/nomad/server.hcl
  echo '
vault {
  enabled    = true
  token      = "'${VAULT_TOKEN?}'"
  cert_file  = "/etc/fabio/ssl/'$VAULT_DOM'-cert.pem"
  key_file   = "/etc/fabio/ssl/'$VAULT_DOM'-key.pem"
	address    = "https://'$VAULT_HOST':8200" // active.vault.service.consul:8200"
}

# @see https://learn.hashicorp.com/nomad/transport-security/enable-tls
acl {
  enabled = true
}
tls {
  http = true
  cert_file = "/etc/fabio/ssl/'$VAULT_DOM'-cert.pem"
  key_file  = "/etc/fabio/ssl/'$VAULT_DOM'-key.pem"
}' |sudo tee -a $HCL
}


function nomad-env-vars() {
  CONF=$HOME/.config/nomad
  if [ $COUNT -eq 0 ]; then
    # NOTE: if you can't listen on :443 and :80 (the ideal defaults), you'll need to change
    # the two fabio.* files in this dir, re-copy the fabio.properties file in place and manually
    # restart fabio..
    local NOMACL=$HOME/.config/nomad.${NODE?}
    mkdir -p $(dirname $NOMACL)
    chmod 600 $NOMACL $CONF 2>/dev/null |cat
    export NOMAD_ADDR="https://${NOMAD_HOST?}:4646"
    nomad acl bootstrap |tee $NOMACL
    # NOTE: can run `nomad acl token self` post-facto if needed...
    echo "
export NOMAD_ADDR=$NOMAD_ADDR
export NOMAD_TOKEN="$(fgrep 'Secret ID' $NOMACL |cut -f2- -d= |tr -d ' ') |tee $CONF
    chmod 400 $NOMACL $CONF
  fi
  source $CONF
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  sudo bash -c "(
    mkdir -p /etc/fabio/ssl/
    chown root:root /etc/fabio/ssl/
    cp ${MYDIR?}/etc/fabio.properties /etc/fabio/
  )"

  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} /etc/fabio/ssl/${TLS_DOMAIN?}-cert.pem
    rsync -Pav ${TLS_KEY?} /etc/fabio/ssl/${TLS_DOMAIN?}-key.pem
  )"
}


setup-node



[ $COUNT -eq 0 ]  &&  nomad run ${MYDIR?}/etc/fabio.hcl

# NOTE: if you see failures join-ing and messages like:
#   "No installed keys could decrypt the message"
# try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
echo 'skipping .keyring resets'  ||  (
  sudo rm /var/lib/nomad/server/serf.keyring; sudo service nomad  restart
  sudo rm /var/lib/consul/serf/local.keyring; sudo service consul restart
)
# and try again manually
# (All servers need the same contents)

[ $COUNT -gt 0 ]  &&  nomad server join $FIRST
[ $COUNT -gt 0 ]  &&  consul       join $FIRST

[ $COUNT -eq 0 ]  &&  ${MYDIR?}/setup-runner.sh

consul members
nomad server members
nomad node status
