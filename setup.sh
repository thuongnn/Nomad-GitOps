#!/bin/zsh -e

# One time setup of server(s) to make a nomad cluster.
#
# Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
# that you have ssh and sudo access to.


[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  [cluster size]  # run on first node
usage: $0  [first node FQDN]                               # run on each additional node

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)
[cluster size] - number of nodes - set if more than 1 node.

[first node FQDN] - fully qualified name of the first node in your cluster

Run this script on each node in your cluster, while ssh-ed in to them.
(git clone this repo somewhere..)

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

To simplify, we'll setup and unseal your vault server on the same/first server that the
fabio load balancer goes to so we can reuse TLS certs.  This will also setup ACL and TLS for nomad.

"  &&  exit 1
set -x


if [ $# -gt 1 ]; then
  FIRST=$(hostname -f)
  TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
  TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
  CLUSTER_SIZE=${3:-"1"}
else
  FIRST=$1
fi

MYDIR=${0:a:h}


# avoid any environment vars from CLI poisoning..
unset   NOMAD_TOKEN
unset  CONSUL_TOKEN
unset   VAULT_TOKEN


export  VAULT_ADDR="https://${FIRST?}:8200"
export  NOMAD_ADDR="https://${FIRST?}:4646"
export CONSUL_ADDR="http://localhost:8500"
export  FABIO_ADDR="http://localhost:9998"
export MAX_PV=20



function main() {
  cd /tmp

  # install docker if not already present
  $MYDIR/install-docker-ce.sh

  # install binaries and service files
  #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  sudo apt-get -yqq update

  sudo apt-get -yqq install  nomad  vault  consul

  # find daemon config files
  NOMAD_HCL=$( dpkg -L nomad  |egrep ^/etc/ |egrep -m1 '\.hcl$')
  CONSUL_HCL=$(dpkg -L consul |egrep ^/etc/ |egrep -m1 '\.hcl$')
  VAULT_HCL=$( dpkg -L vault  |egrep ^/etc/ |egrep -m1 '\.hcl$')

  # restore original config (if reran)
  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL
  [ -e  $VAULT_HCL.orig ]  &&  sudo cp -p  $VAULT_HCL.orig  $VAULT_HCL


  # stash copies of original config
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig
  sudo cp -p  $VAULT_HCL  $VAULT_HCL.orig


  ###################################################################################################
  # See if we are the first node in the cluster
  # See how many nodes in the cluster already (might be 0)
  # We will put LB on 1st server
  # We will put PV on 2nd server (or if single node cluster - 1st/only server)
  COUNT=666 # gets re/set below
  N=$(ssh $FIRST "fgrep -c 'encrypt =' $NOMAD_HCL |cat")
  if [ $N -eq 0 ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_N=$(nomad operator keygen |tr -d ^)
    TOK_C=$(consul keygen |tr -d ^)
    COUNT=0
  else
    nomad-env-vars
    # ^^ now we can talk to first nomad server
    COUNT=$(nomad node status -t '{{range .}}{{.Name}}{{"\n"}}{{end}}' |egrep . |wc -l |tr -d ' ')
    TOK_N=$(ssh $FIRST "egrep  'encrypt\s*=' $NOMAD_HCL"  |cut -f2- -d= |tr -d '\t "')
    TOK_C=$(ssh $FIRST "egrep '^encrypt\s*=' $CONSUL_HCL" |cut -f2- -d= |tr -d '\t "')
    CLUSTER_SIZE=$(ssh $FIRST "egrep ^bootstrap_expect $CONSUL_HCL" |cut -f2- -d= |tr -d '\n\t "')
  fi


  setup-certs
  setup-misc

  # xxx if have issues in the future, relook at `retry_join` back into $CONSUL_HCL $NOMAD_HCL

  # Get consul running first
  setup-consul

  # Once consul is up, we can setup and get running Vault and unseal it
  setup-vault

  setup-nomad
  nomad-env-vars

  consul members
  nomad server members



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

  [ $COUNT -gt 0 ]  &&  nomad server join ${FIRST?}
  [ $COUNT -gt 0 ]  &&  consul       join ${FIRST?}

  consul members
  nomad server members
  nomad node status

  [ $COUNT -eq 0 ]  &&  (
    welcome

    echo "Setup GitLab runner in your cluster?\n"
    echo "[CTL-C] now to skip setting up a GitLab runner in your cluster or "
    echo "[RETURN] to proceed:"
    read cont

    ${MYDIR?}/setup-runner.sh
  )
}


function welcome() {
    echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for nomad, consul, vault, and fabio here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
$CONSUL_ADDR

Vault  (security: secrets r/w)
( https://vaultproject.io )
$VAULT_ADDR
( login with $HOME/.vault-token - keep this safe!)

Fabio  (routing: load balancing, ingress/edge router, https and http2 termination (to http)
( https://fabiolb.net )
$FABIO_ADDR



For localhost urls above - see 'nom-tunnel' alias here:
  https://gitlab.com/internetarchive/nomad/-/blob/master/aliases




"
}


function setup-consul() {
 ## Consul - setup the fields 'encrypt' etc. as per your cluster.
  echo '
server = true
bootstrap_expect = '${CLUSTER_SIZE?}'
encrypt = "'${TOK_C?}'"
' | sudo tee -a  $CONSUL_HCL

  sudo systemctl restart consul  &&  sleep 10
}


function setup-nomad() {
  ## Nomad - setup the fields 'encrypt' etc. as per your cluster.
  sudo sed -i -e 's^bootstrap_expect =.*$^bootstrap_expect = '${CLUSTER_SIZE?}'^' $NOMAD_HCL

  ( configure-nomad ) | sudo tee -a $NOMAD_HCL

  sudo systemctl restart nomad  &&  sleep 10
}


function configure-nomad() {
  echo '
server {
  encrypt = "'${TOK_N?}'"
}'


  # ensure docker jobs can mount volumes
  echo '
plugin "docker" {
  config {
    volumes {
      enabled = true
    }
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}'

  echo '
client {
'

  # Let's put the loadbalancer on the first two nodes added to cluster.
  # All jobs requiring a PV get put on 2nd node in cluster (or first if cluster of 1).
  local KIND='worker'
  [ ${COUNT?} -le 1 ]  &&  KIND="$KIND,lb"
  [ ${COUNT?} -eq 1  -o  ${CLUSTER_SIZE?} = "1" ]  &&  KIND="$KIND,pv"
  echo '
  meta {
    "kind" = "'$KIND'"
  }'

  [ $NFSHOME ]  &&  echo '

  host_volume "home-ro" {
    path      = "/home"
    read_only = true
  }

  host_volume "home-rw" {
    path      = "/home"
    read_only = false
  }'

  # pass through disk from host for now.  peg project(s) with PV requirements to this host.
  for N in $(seq 1 ${MAX_PV?}); do
    echo -n '
  host_volume "pv'$N'" {
    path      = "/pv'$N'"
    read_only = false
  }'
  done

  echo '
}'


  # configure vault section of nomad
  echo '
vault {
  enabled    = true
  token      = "'${VAULT_TOKEN?}'"
  cert_file  = "/opt/nomad/tls/tls.crt"
  key_file   = "/opt/nomad/tls/tls.key"
	address    = "'${VAULT_ADDR?}'" # active.vault.service.consul:8200"
}

# @see https://learn.hashicorp.com/nomad/transport-security/enable-tls
acl {
  enabled = true
}
tls {
  http = true
  cert_file = "/opt/nomad/tls/tls.crt"
  key_file  = "/opt/nomad/tls/tls.key"
}'
}


function nomad-env-vars() {
  CONF=$HOME/.config/nomad
  if [ ${COUNT?} -eq 0 ]; then
    # NOTE: if you can't listen on :443 and :80 (the ideal defaults), you'll need to change
    # the two fabio.* files in this dir, re-copy the fabio.properties file in place and manually
    # restart fabio..
    local NOMACL=$HOME/.config/nomad.$(echo ${FIRST?} |cut -f1 -d.)
    mkdir -p $(dirname $NOMACL)
    chmod 600 $NOMACL $CONF 2>/dev/null |cat
    nomad acl bootstrap |tee $NOMACL
    # NOTE: can run `nomad acl token self` post-facto if needed...
    echo "
export NOMAD_ADDR=$NOMAD_ADDR
export NOMAD_TOKEN="$(fgrep 'Secret ID' $NOMACL |cut -f2- -d= |tr -d ' ') |tee $CONF
    chmod 400 $NOMACL $CONF
  fi
  source $CONF
}


function setup-vault() {
  # switch `storage "file"` to `storage "consul"`
  sudo perl -i -0pe 's/^storage "file".*?}//ms'   $VAULT_HCL

  echo '
    storage "consul" {
      address = "127.0.0.1:8500"
      path    = "vault/"
  }' |sudo tee -a $VAULT_HCL


  # https://learn.hashicorp.com/vault/getting-started/deploy
  # update vault config

  if [ ${COUNT?} -gt 0 ]; then
    export VAULT_TOKEN=$(ssh ${FIRST} "egrep 'token\s*=' $NOMAD_HCL"  |cut -f2- -d= |tr -d '\t "')
    return
  fi


  # fire up vault and unseal it
  sudo systemctl restart vault  &&  sleep 10

  echo "Vault initializing with ${VAULT_ADDR?}"
  local VFI=/var/lib/.vault
  vault operator init |sudo tee $VFI
  sudo chmod 400 $VFI

  export VAULT_TOKEN=$(sudo grep 'Initial Root Token:' $VFI |cut -f2- -d: |tr -d ' ')

  set +x
  vault operator unseal $(sudo grep 'Unseal Key 1:' $VFI |cut -f2- -d: |tr -d ' ')
  vault operator unseal $(sudo grep 'Unseal Key 2:' $VFI |cut -f2- -d: |tr -d ' ')
  vault operator unseal $(sudo grep 'Unseal Key 3:' $VFI |cut -f2- -d: |tr -d ' ')
  sleep 10
  echo "${VAULT_TOKEN?}" | vault login -

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
}


function setup-misc() {
  ${MYDIR?}/ports-unblock.sh

  sudo service docker restart


  # get services ready to go - xxxxxx needed?
  sudo systemctl daemon-reload
  sudo systemctl enable  consul nomad vault


  # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
  # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
  # pass through this `/pv` dir from the VM/host to containers.  Each container using it
  # needs to use unique subdirs...
  for N in $(seq 1 ${MAX_PV?}); do
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
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  VAULT_DOM=$(echo $FIRST |cut -f2- -d.)
  VAULT_TLS_CRT=/etc/fabio/ssl/${VAULT_DOM?}-cert.pem
  VAULT_TLS_KEY=/etc/fabio/ssl/${VAULT_DOM?}-key.pem

  sudo bash -c "(
    mkdir -p /etc/fabio/ssl/
    chown root:root /etc/fabio/ssl/
    cp ${MYDIR?}/etc/fabio.properties /etc/fabio/
  )"

  [ $COUNT -eq 0 ]  &&  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${VAULT_TLS_CRT?}
    rsync -Pav ${TLS_KEY?} ${VAULT_TLS_KEY?}
  )"

  [ $COUNT -gt 0 ]  &&  bash -c "(
    ssh ${FIRST?} sudo cat ${VAULT_TLS_CRT?} |sudo tee ${VAULT_TLS_CRT} >/dev/null
    ssh ${FIRST?} sudo cat ${VAULT_TLS_KEY?} |sudo tee ${VAULT_TLS_KEY} >/dev/null
  )"

  sudo chown root.root ${VAULT_TLS_CRT} ${VAULT_TLS_KEY}
  sudo chmod 444 ${VAULT_TLS_CRT}
  sudo chmod 400 ${VAULT_TLS_KEY}


  # :( it setup self-signed key but for dns name `Vault` - which won't resolve w/o Consul Connect
  # Replace it w/ a wildcard domain file pair; and make it avail to nomad as well
  sudo ls -l /opt/vault/tls/tls.crt  /opt/vault/tls/tls.key

  for NOVA in nomad vault; do
    sudo mkdir -m 500 -p      /opt/$NOVA/tls
    sudo cp $VAULT_TLS_CRT    /opt/$NOVA/tls/tls.crt
    sudo cp $VAULT_TLS_KEY    /opt/$NOVA/tls/tls.key
    sudo chown -R $NOVA.$NOVA /opt/$NOVA/tls
    sudo chmod -R go-rwx      /opt/$NOVA/tls
  done
}


function uninstall() {
  (
    set +e
    for i in  nomad  vault  consul  docker  docker-ce; do
      sudo service $i stop
      sudo apt-get -yqq purge $i
      sudo systemctl daemon-reload

      sudo find  /opt/$i  /etc/$i  /etc/$i.d  /var/lib/$i  -ls -delete

      sudo killall $i
    done
  )
}


main
