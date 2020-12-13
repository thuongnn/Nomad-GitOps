#!/bin/zsh -e

function xxx() {

CERTS=home:/opt/.petabox/us.archive.org; env NFSHOME=1 ~/dev/nomad/setup.sh  ${CERTS?}.combined.crt  ${CERTS}.nopassword.key  kube-a-08

}

# One time setup of server(s) to make a nomad cluster.
#
# Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
# that you have ssh and sudo access to.
#
# Current Overview, assuming 2 or 3 node cluster:
#   Installs consul on first
#   Installs vault and unseals it on first
#   Installs nomad server and client on all nodes, securely talking together & electing a leader
#   Installs load balancer "fabio" on first two nodes
#      (in case you want to use multiple IP addresses for deployments in case one LB/node is out)
#   Optionally installs gitlab runner on first node
#   Sets up Persistent Volume subdirs on 1st node - deployments needing PV only schedule to this node

MYDIR=${0:a:h}


[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  <node 2>  <node 3>  ..

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on FIRST node in your cluster, while ssh-ed in.
(git clone this repo somewhere in the same place on all your cluster nodes.)

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

Invoking with env var VAULT= will _skip_ setting up a vault service.

To simplify, we'll setup and unseal your vault server on the same/first server that the
fabio load balancer goes to so we can reuse TLS certs.  This will also setup ACL and TLS for nomad.

"  &&  exit 1


# are we now installing and setting up X or not?
[ -z ${CONSUL+unset} ] && CONSUL=consul
[ -z ${VAULT+notset} ] &&  VAULT=vault
[ -z ${NOMAD+notset} ] &&  NOMAD=nomad

# avoid any environment vars from CLI poisoning..
unset   NOMAD_TOKEN
unset  CONSUL_TOKEN
unset   VAULT_TOKEN


function runner() {
  if [ "$1" = "auto" ]; then
    set -x
    FIRST=$2
    COUNT=$3
    CLUSTER_SIZE=$4

    daemons-count

    main
    exit 0
  else
    FIRST=$(hostname -f)
    TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
    TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
    shift
    CLUSTER_SIZE=$#
    shift
    typeset -a $NODES
    NODES=( $FIRST "$@" )

    daemons-count

    # check if this cluster will _NOT_ have a vault at all..
    [ $VAULT ]  ||  NO_VAULT=1

    # get the first node https setup out of the way
    ( COUNT=0 VAULT= NOMAD= setup-certs )

    # install & setup consul first across nodes - so they can properly group up and elect a leader
    COUNT=0
    for NODE in $NODES; do
      ( set -x; ssh $NODE env NOMAD= VAULT= NFSHOME=$NFSHOME $MYDIR/setup.sh auto ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
      let "COUNT=$COUNT+1"
      [ "${COUNT?}" = "${CONSUL_COUNT?}" ]  &&  break
    done

    # ugh, facepalm
    for NODE in $NODES; do
      ssh $NODE 'sudo rm /opt/consul/serf/local.keyring;  sudo service consul restart;  echo'
    done


    # install & setup vault
    COUNT=0
    [ $VAULT ]  &&  (
      ( set -x; ssh $FIRST env CONSUL= NOMAD= NFSHOME=$NFSHOME $MYDIR/setup.sh auto ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
    )

    # install & setup nomad
    COUNT=0
    for NODE in $NODES; do
      ( set -x; ssh $NODE env CONSUL= VAULT= NFSHOME=$NFSHOME $MYDIR/setup.sh auto ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
      let "COUNT=$COUNT+1"
    done

    exit 0
  fi

  exit 0
}


function daemons-count() {
  # giving up on 2+ nodes w/ consul -- keep repedatedly dumassing themselves out of cluster
  # even though they elected a leader and communicated just fine, all decrypts are identical...
  # with messages like this after ~60s
  # memberlist: failed to receive: No installed keys could decrypt the message from=...
  # cries in beer
  export CONSUL_COUNT=${CLUSTER_SIZE?}
  export CONSUL_COUNT=1 # xxx

  # giving up on 2+ nodes w/ nomad -- cant even get one started unless &*!#$3ing cluster of 1
  # cries in beer
  export NOMAD_COUNT=${CLUSTER_SIZE?}
  export NOMAD_COUNT=1 # xxx

  # We will put PV on 1st server
  # We will put LB/fabio on first two servers
  export LB_COUNT=2
}


function main() {
  export  VAULT_ADDR="https://${FIRST?}:8200"
  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export MAX_PV=20
  export FIRSTIP=$(host ${FIRST?} | perl -ane 'print $F[3] if $F[2] eq "address"')


  cd /tmp

  # install docker if not already present
  [ $NOMAD ]  &&  $MYDIR/install-docker-ce.sh

  [ $CONSUL ]  &&  (
    # install binaries and service files
    #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service

    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get -yqq update
  )

  sudo apt-get -yqq install  $CONSUL  $VAULT  $NOMAD

  # find daemon config files
  [ $CONSUL ]  &&  CONSUL_HCL=$(dpkg -L consul |egrep ^/etc/ |egrep -m1 '\.hcl$')
  [ $VAULT  ]  &&   VAULT_HCL=$(dpkg -L vault  |egrep ^/etc/ |egrep -m1 '\.hcl$')
  [ $NOMAD  ]  &&   NOMAD_HCL=$(dpkg -L nomad  |egrep ^/etc/ |egrep -m1 '\.hcl$')

  # restore original config (if reran)
  [ $CONSUL ]  &&  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL
  [ $NOMAD  ]  &&  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  [ $VAULT  ]  &&  [ -e  $VAULT_HCL.orig ]  &&  sudo cp -p  $VAULT_HCL.orig  $VAULT_HCL


  # stash copies of original config
  [ $CONSUL ]  &&  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig
  [ $NOMAD  ]  &&  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig
  [ $VAULT  ]  &&  sudo cp -p  $VAULT_HCL  $VAULT_HCL.orig



  setup-certs
  [ $CONSUL ]  &&  setup-misc
  setup-daemons

  # Get consul running first
  # Once consul is up, we can setup and get running Vault and unseal it
  [ $CONSUL ]  &&  setup-consul
  [ $VAULT  ]  &&  setup-vault
  [ $NOMAD  ]  &&  setup-nomad


  echo "================================================================================"
  [ $CONSUL ]  &&  consul members
  echo "================================================================================"
  [ $NOMAD  ]  &&  nomad-env-vars
  [ $NOMAD  ]  &&  nomad server members
  echo "================================================================================"



  [ $NOMAD ]  &&  [ ${COUNT?} -le ${LB_COUNT?} ]  &&  nomad run ${MYDIR?}/etc/fabio.hcl

  # NOTE: if you see failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  # try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
  echo 'skipping .keyring resets'  ||  (
    sudo rm /opt/nomad/data/server/serf.keyring; sudo service nomad  restart
    sudo rm /opt/consul/serf/local.keyring;      sudo service consul restart
  )
  # and try again manually
  # (All servers need the same contents)

  [ $COUNT -gt 0 ]  [ $COUNT -lt ${CONSUL_COUNT?} ]  &&  consul join ${FIRST?}
  [ $COUNT -gt 0 ]  &&  nomad server join ${FIRSTIP?}

  set +x

  echo "================================================================================"
  [ $CONSUL ]  &&  ( set -x; consul members )
  echo "================================================================================"
  [ $NOMAD  ]  &&  ( set -x; nomad server members )
  echo "================================================================================"
  [ $NOMAD  ]  &&  ( set -x; nomad node status )
  echo "================================================================================"


  [ $NOMAD ]  &&  [ $COUNT -eq 0 ]  &&  (
    echo "Setup GitLab runner in your cluster?\n"
    echo "Enter 'yes' now to set up a GitLab runner in your cluster"
    read cont

    if [ "$cont" = "yes" ]; then
      ${MYDIR?}/setup-runner.sh
    fi
  )


  let "LAST=$CLUSTER_SIZE-1"
  [ $NOMAD ]  &&  [ $COUNT -eq $LAST ]  &&  welcome
}


function welcome() {
  echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for: nomad consul $VAULT fabio here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
$CONSUL_ADDR
"

  [ $VAULT ]  &&  echo "
Vault  (security: secrets r/w)
( https://vaultproject.io )
$VAULT_ADDR
( login with $HOME/.vault-token - keep this safe!)
"

  echo "

Fabio  (routing: load balancing, ingress/edge router, https and http2 termination (to http))
( https://fabiolb.net )
$FABIO_ADDR



For localhost urls above - see 'nom-tunnel' alias here:
  https://gitlab.com/internetarchive/nomad/-/blob/master/aliases

To uninstall:
  https://gitlab.com/internetarchive/nomad/-/blob/master/wipe-node.sh



"
}


function setup-consul() {
  ## Consul - setup the fields 'encrypt' etc. as per your cluster.

  if [ ${COUNT?} -eq 0 ]; then
    # starting cluster - how exciting!  mint some tokens
    TOK_C=$(consul keygen |tr -d ^)
  else
    TOK_C=$(ssh ${FIRST?} "egrep '^encrypt\s*=' ${CONSUL_HCL?}" |cut -f2- -d= |tr -d '\t "')
  fi

  echo '
server = true
advertise_addr = "{{ GetInterfaceIP \"eth0\" }}"
node_name = "'$(hostname -s)'"
bootstrap_expect = '${CONSUL_COUNT?}'
encrypt = "'${TOK_C?}'"
retry_join = ["'${FIRSTIP?}'"]
' | sudo tee -a  $CONSUL_HCL

  sudo systemctl restart consul  &&  sleep 10
}


function setup-nomad() {
  ## Nomad - setup the fields 'encrypt' etc. as per your cluster.
  sudo sed -i -e 's^bootstrap_expect =.*$^bootstrap_expect = '${NOMAD_COUNT?}'^' $NOMAD_HCL

  ( configure-nomad ) | sudo tee -a $NOMAD_HCL

  sudo systemctl restart nomad  &&  sleep 10
}


function configure-nomad() {
  [ $COUNT -eq 0 ]  &&  TOK_N=$(nomad operator keygen |tr -d ^ |cat)
  [ $COUNT -ge 1 ]  &&  TOK_N=$(ssh ${FIRST?} "egrep  'encrypt\s*=' ${NOMAD_HCL?}"  |cut -f2- -d= |tr -d '\t "' |cat)

  [ $COUNT -lt ${NOMAD_COUNT?} ]  &&  echo '
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


  echo '
client {
'

  # Let's put the loadbalancer on the first two nodes added to cluster.
  # All jobs requiring a PV get put on first node in cluster.
  local KIND='worker'
  [ ${COUNT?} -le ${LB_COUNT?} ]  &&  KIND="$KIND,lb"
  [ ${COUNT?} -eq 0 ]             &&  KIND="$KIND,pv"
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

  [ ${COUNT?} -eq 0 ]  &&  (
    # pass through disk from host for now.  peg project(s) with PV requirements to this host.
    for N in $(seq 1 ${MAX_PV?}); do
      echo -n '
    host_volume "pv'$N'" {
      path      = "/pv/'$N'"
      read_only = false
    }'
    done
  )

  echo '
}'


  # configure vault section of nomad
  [ $NO_VAULT ]  ||  (
    VAULT_TOKEN=$(cat $HOME/.vault-token)
    echo '
vault {
  enabled    = true
  token      = "'${VAULT_TOKEN?}'"
  cert_file  = "/opt/nomad/tls/tls.crt"
  key_file   = "/opt/nomad/tls/tls.key"
  address    = "'${VAULT_ADDR?}'" # active.vault.service.consul:8200"
}'
  )
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

  [ ${COUNT?} -gt 0 ]  &&  return


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

  [ ${COUNT?} -eq 0 ]  &&  (
    # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
    # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
    # pass through these `/pv/` dirs from the VM/host to containers.  Each container using it
    # needs to use a unique subdir...
    for N in $(seq 1 ${MAX_PV?}); do
      sudo mkdir -m777 -p /pv/$N
    done
  )


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


function setup-daemons() {
  # get services ready to go
  sudo systemctl daemon-reload
  sudo systemctl enable  $CONSUL  $NOMAD  $VAULT
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo $FIRST |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  sudo bash -c "(
    mkdir -p /etc/fabio/ssl/
    chown root:root /etc/fabio/ssl/
    cp ${MYDIR?}/etc/fabio.properties /etc/fabio/
  )"

  [ $TLS_CRT ]  &&  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${CRT?}
    rsync -Pav ${TLS_KEY?} ${KEY?}
  )"

  [ ${COUNT?} -gt 0 ]  &&  bash -c "(
    ssh ${FIRST?} sudo cat ${CRT?} |sudo tee ${CRT} >/dev/null
    ssh ${FIRST?} sudo cat ${KEY?} |sudo tee ${KEY} >/dev/null
  )"

  sudo chown root.root ${CRT} ${KEY}
  sudo chmod 444 ${CRT}
  sudo chmod 400 ${KEY}


  # :( it setup self-signed key but for dns name `Vault` - which won't resolve w/o Consul Connect
  # Replace it w/ a wildcard domain file pair; and make it avail to nomad as well
  [ $VAULT ]  &&  sudo ls -l /opt/vault/tls/tls.crt  /opt/vault/tls/tls.key

  for NOVA in $NOMAD $VAULT; do
    sudo mkdir -m 500 -p      /opt/$NOVA/tls
    sudo cp $CRT              /opt/$NOVA/tls/tls.crt
    sudo cp $KEY              /opt/$NOVA/tls/tls.key
    sudo chown -R $NOVA.$NOVA /opt/$NOVA/tls
    sudo chmod -R go-rwx      /opt/$NOVA/tls
  done
}


runner "$@"
