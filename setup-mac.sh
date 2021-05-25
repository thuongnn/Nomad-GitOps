#!/bin/zsh -e

# One time setup of server(s) to make a nomad cluster.
#
# Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
# that you have ssh and sudo access to.
#
# Current Overview:
#   Installs nomad server and client on all nodes, securely talking together & electing a leader
#   Installs consul server and client on all nodes
#   Installs load balancer "fabio" on all nodes
#      (in case you want to use multiple IP addresses for deployments in case one LB/node is out)
#   Optionally installs gitlab runner on 1st node
#   Sets up Persistent Volume subdirs on 1st node - deployments needing PV only schedule to this node
#
# NOTE: if setup 3 nodes (h0, h1 & h2) on day 1; and want to add 2 more (h3 & h4) later,
# you can manually run the lines from `config`, then `add-nodes`
# where you set environment variables like this:
#   NODES=(h3 h4)
#   FIRST=[fully qualified DNS name of your first node]
#   CLUSTER_SIZE=2
#   INITIAL_CLUSTER_SIZE=3

MYDIR=${0:a:h}

# where supporting scripts live and will get pulled from
RAW=https://gitlab.com/internetarchive/nomad/-/raw/master

[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  <node 2>  <node 3>  ..

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on FIRST node in your cluster, while ssh-ed in.

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

To simplify, we'll reuse TLS certs, setting up ACL and TLS for nomad.


MACOS:
  Additional requirement:
    TLS command-line args must match pattern:
      [DOMAIN]-cert.pem
      [DOMAIN]-key.pem

  Additional step:
  [System Preferences] [Network] [Advanced] [DNS] [DNS Servers] add '127.0.0.1' as *first* resolver


"  &&  exit 1


# avoid any environment vars from CLI poisoning..
unset   NOMAD_TOKEN
unset   NOMAD_ADDR


function main() {
  if [ "$1" != "baseline"  -a  "$1" != "baseline-nomad" ]; then
    TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
    TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
    shift
    INITIAL_CLUSTER_SIZE=0
    CLUSTER_SIZE=$#
    shift

    set -x
    config

    COUNT=${INITIAL_CLUSTER_SIZE?}

    # use the TLS_CRT and TLS_KEY params
    setup-certs


    # setup baseline & get consul up/ running *first* -- so can use consul for nomad bootstraping
    # https://learn.hashicorp.com/tutorials/nomad/clustering#use-consul-to-automatically-cluster-nodes
    typeset -a $NODES
    NODES=( ${FIRST?} "$@" )
    for NODE in ${NODES?}; do
      # copy ourself / this script over to the node first, then run it
      cat ${MYDIR?}/setup.sh | run-on $NODE 'tee /tmp/setup.sh >/dev/null && chmod +x /tmp/setup.sh'
      run-on $NODE env NFSHOME=$NFSHOME /tmp/setup.sh baseline ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?}
      let "COUNT=$COUNT+1"
    done


    # now get nomad configured and up
    COUNT=${INITIAL_CLUSTER_SIZE?}
    for NODE in ${NODES?}; do
      run-on $NODE env NFSHOME=$NFSHOME /tmp/setup.sh baseline-nomad ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?}
      let "COUNT=$COUNT+1"
    done


    finish
  else
    set -x
    FIRST=$2
    COUNT=$3
    CLUSTER_SIZE=$4

    config

    "$1"
  fi
}


function config() {
  export CONSUL_COUNT=${CLUSTER_SIZE?}

  # We will put PV on 1st server
  # We will put LB/fabio on all servers
  export LB_COUNT=${CLUSTER_SIZE?}

  export MAC=
  [ $(uname) = "Darwin" ]  &&  export MAC=1


  if [ $MAC ]; then
    SYSCTL1=brew
    SYSCTL2=services
    if [ "$TLS_CRT" = "" ]; then
      local DOMAIN=$(echo "$FIRST" |cut -f2- -d.)
    else
      local DOMAIN=$(basename "${TLS_CRT?}" |rev |cut -f2- -d- |rev)
      export FIRST=nom.${DOMAIN?}
    fi
  else
    SYSCTL1=systemctl
    SYSCTL2=
    if [ "$FIRST" = "" ]; then
      export FIRST=$(hostname -f)
    fi
  fi

  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export PV_MAX=20
  export PV_DIR=/pv

  if [ $MAC ]; then
    export FIRSTIP=$(ifconfig |egrep -o 'inet [0-9\.]+' |cut -f2 -d' ' |fgrep -v 127.0.0 |head -1)
    export PV_DIR=/opt/nomad/pv

    # setup unix counterpart default config
     NOMAD_HCL=/etc/nomad.d/nomad.hcl
    CONSUL_HCL=/etc/consul.d/consul.hcl
  else
    export FIRSTIP=$(host ${FIRST?} | perl -ane 'print $F[3] if $F[2] eq "address"' |head -1)
    # find daemon config files
     NOMAD_HCL=$(dpkg -L nomad  2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
    CONSUL_HCL=$(dpkg -L consul 2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
  fi
}



function run-on() {
  # unix: ssh to node and run a command;  mac: run command (single node cluster :-)
  NODE="$1"
  shift

  if [ $MAC ]; then
    ( set -x; "$@" )
  else
    ( set -x; ssh $NODE "$@" )
  fi
}


function baseline() {
  cd /tmp

  # install binaries and service files
  #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service
  if [ $MAC ]; then
    brew install  nomad  consul

    sudo mkdir -p $(dirname  $NOMAD_HCL)
    sudo mkdir -p $(dirname $CONSUL_HCL)

    # start with unix pkg defaults
    echo '
data_dir = "/opt/nomad/data"
bind_addr = "0.0.0.0"
server {
  enabled = true
  bootstrap_expect = 1
}
client {
  enabled = true
  servers = ["127.0.0.1:4646"]
}
' | sudo tee $NOMAD_HCL

    # start with unix pkg defaults
    echo '
data_dir = "/opt/consul"
client_addr = "0.0.0.0"
ui = true
' | sudo tee $CONSUL_HCL

  else

    sudo apt-get -yqq install  wget

    # install docker if not already present
    getr install-docker-ce.sh
    /tmp/install-docker-ce.sh


    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get -yqq update

    sudo apt-get -yqq install  consul
  fi

  config

  # restore original config (if reran)
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL

  # stash copies of original config
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # start up uncustomized version of consul
  setup-dnsmasq
  setup-certs
  setup-misc
  setup-daemons


  setup-consul


  echo "================================================================================"
  consul members
  echo "================================================================================"


  sudo rm /opt/consul/serf/local.keyring
  sudo ${SYSCTL1?} ${SYSCTL2?} restart  consul
  sleep 10

  # and try again manually
  # (All servers need the same contents)

  set +x

  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
}


function baseline-nomad {
  sudo apt-get -yqq install  nomad

  config

  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig

  [ $MAC ]  ||  sudo systemctl daemon-reload
  [ $MAC ]  ||  sudo systemctl enable  nomad

  setup-certs

  setup-nomad
  # NOTE: if you see failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  # try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
  # sudo rm /opt/nomad/data/server/serf.keyring
  # sudo ${SYSCTL1?} ${SYSCTL2?} restart  nomad


  nomad-env-vars
  echo "================================================================================"
  ( set -x; nomad server members )
  echo "================================================================================"
  ( set -x; nomad node status )
  echo "================================================================================"
}


function finish() {
  sleep 30
  nomad-env-vars

  # ideally fabio is running in docker - but macos issues so alt "exec" driver instead of "docker"
  # https://medium.com/hashicorp-engineering/hashicorp-nomad-from-zero-to-wow-1615345aa539
  [ $MAC ]  &&  nomad run ${RAW?}/etc/fabio-exec.hcl
  [ $MAC ]  ||  nomad run ${RAW?}/etc/fabio.hcl


  echo "Setup GitLab runner in your cluster?\n"
  echo "Enter 'yes' now to set up a GitLab runner in your cluster"
  read cont

  if [ "$cont" = "yes" ]; then
    getr setup-runner.sh
    /tmp/setup-runner.sh
  fi


  echo "

💥 CONGRATULATIONS!  Your cluster is setup. 💥

You can get started with the UI for: nomad consul fabio here:

Nomad  (deployment: managements & scheduling):
( https://www.nomadproject.io )
$NOMAD_ADDR
( login with NOMAD_TOKEN from $HOME/.config/nomad - keep this safe!)

Consul (networking: service discovery & health checks, service mesh, envoy, secrets storage):
( https://www.consul.io )
$CONSUL_ADDR

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

  sudo ${SYSCTL1?} ${SYSCTL2?} restart consul  &&  sleep 10
}


function setup-nomad() {
  ## Nomad - setup the fields 'encrypt' etc. as per your cluster.
  [ $COUNT -ge 1 ] && sudo sed -i -e 's^bootstrap_expect =.*$^^' $NOMAD_HCL

  ( configure-nomad ) | sudo tee -a $NOMAD_HCL

  sudo ${SYSCTL1?} ${SYSCTL2?} restart nomad  &&  sleep 10  ||  echo 'moving on ...'
}


function configure-nomad() {
  [ $COUNT -eq 0 ]  &&  TOK_N=$(nomad operator keygen |tr -d ^ |cat)
  [ $COUNT -ge 1 ]  &&  TOK_N=$(ssh ${FIRST?} "egrep  'encrypt\s*=' ${NOMAD_HCL?}"  |cut -f2- -d= |tr -d '\t "' |cat)

  set +x

  echo '
name = "'$(hostname -s)'"

server {
  encrypt = "'${TOK_N?}'"
}

# some of this could be redundant -- check defaults in node v1+
addresses {
  http = "0.0.0.0"
}

advertise {
  http = "{{ GetInterfaceIP \"eth0\" }}"
  rpc = "{{ GetInterfaceIP \"eth0\" }}"
  serf = "{{ GetInterfaceIP \"eth0\" }}"
}
'


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

  # We'll put a loadbalancer on all cluster nodes
  # All jobs requiring a PV get put on first cluster node
  local KIND='worker'
  [ ${COUNT?} -lt ${LB_COUNT?} ]  &&  KIND="$KIND,lb"
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
    for N in $(seq 1 ${PV_MAX?}); do
      echo -n '
    host_volume "pv'$N'" {
      path      = "'$PV_DIR'/'$N'"
      read_only = false
    }'
    done
  )

  echo '
}'

  set -x
}


function nomad-env-vars() {
  CONF=$HOME/.config/nomad
  if [ ${COUNT?} -eq 0 ]; then
    # NOTE: if you can't listen on :443 and :80 (the ideal defaults), you'll need to change
    # the two fabio.* files in this dir, re-copy the fabio.properties file in place and manually
    # restart fabio..
    [ -e $CONF ]  &&  mv $CONF $CONF.prev
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



function setup-misc() {
  if [ ! $MAC ]; then
    if [ -e /etc/ferm ]; then
      getr ports-unblock.sh
      /tmp/ports-unblock.sh
    fi
    sudo service docker restart  ||  echo 'no docker yet'
  fi

  [ ${COUNT?} -eq 0 ]  &&  (
    # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
    # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
    # pass through these `/pv/` dirs from the VM/host to containers.  Each container using it
    # needs to use a unique subdir...
    for N in $(seq 1 ${PV_MAX?}); do
      sudo mkdir -m777 -p ${PV_DIR?}/$N
    done
  )


  # This gets us DNS resolving on archive.org VMs, at the VM level (not inside containers)-8
  # for hostnames like:
  #   services-clusters.service.consul
  if [ ! "$MAC"  -a  -e /etc/dnsmasq.d/ ]; then
    echo "server=/consul/127.0.0.1#8600" |sudo tee /etc/dnsmasq.d/nomad
    sudo ${SYSCTL1?} ${SYSCTL2?} restart dnsmasq
    sleep 2
  fi
}


function setup-daemons() {
  # get services ready to go
  if [ $MAC ]; then
    sed -i -e 's|<string>-dev</string>|<string>-config=/etc/nomad.d</string>|' \
      /usr/local/Cellar/nomad/*/*plist

    sed -i -e 's|<string>-dev</string>|<string>-config-dir=/etc/consul.d/</string>|' \
      /usr/local/Cellar/consul/*/*plist
    sed -i -e 's|<string>-bind</string>||'      /usr/local/Cellar/consul/*/*plist
    sed -i -e 's|<string>127.0.0.1</string>||'  /usr/local/Cellar/consul/*/*plist

    sudo ${SYSCTL1?} ${SYSCTL2?} start nomad
    sudo ${SYSCTL1?} ${SYSCTL2?} start consul
  else
    sudo systemctl daemon-reload
    sudo systemctl enable  consul
  fi
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo ${FIRST?} |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  local GRP=root
  [ $MAC ]  &&  GRP=wheel

  sudo mkdir -p           /etc/fabio/ssl/
  sudo chown root:${GRP?} /etc/fabio/ssl/
  wget -qO- ${RAW?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

  [ $TLS_CRT ]  &&  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${CRT?}
    rsync -Pav ${TLS_KEY?} ${KEY?}
  )"

  [ ${COUNT?} -gt 0 ]  &&  bash -c "(
    ssh ${FIRST?} sudo cat ${CRT?} |sudo tee ${CRT} >/dev/null
    ssh ${FIRST?} sudo cat ${KEY?} |sudo tee ${KEY} >/dev/null
  )"

  sudo chown root:${GRP?} ${CRT} ${KEY}
  sudo chmod 444 ${CRT}
  sudo chmod 400 ${KEY}


  sudo mkdir -m 500 -p      /opt/nomad/tls
  sudo cp $CRT              /opt/nomad/tls/tls.crt
  sudo cp $KEY              /opt/nomad/tls/tls.key
  sudo chown -R nomad.nomad /opt/nomad/tls  ||  echo 'future pass will work'
  sudo chmod -R go-rwx      /opt/nomad/tls
}


function setup-dnsmasq() {
  # sets up a wildcard dns domain to resolve to your mac
  # inspiration:
  #   https://hedichaibi.com/how-to-setup-wildcard-dev-domains-with-dnsmasq-on-a-mac/
  [ $MAC ]  ||  return 0

  brew install dnsmasq

  local DOMAIN=$(echo ${FIRST?} |cut -f2- -d.)

  echo "
# from https://gitlab.com/internetarchive/nomad/-/blob/master/setup.sh

address=/${DOMAIN?}/${FIRSTIP?}
listen-address=127.0.0.1
" |tee /usr/local/etc/dnsmasq.conf

  sudo brew services start dnsmasq

  # verify host lookups are working now
  #local IP=$(host udev-idev-everybodydev.x.archive.org |rev |cut -f1 -d ' ' |head -1)
  # [ "$IP" = "$FIRSTIP" ]  ||  exit 1
}


function getr() {
  # gets a supporting file from main repo into /tmp/
  wget --backups=1 -qP /tmp/ ${RAW}/"$1"
  chmod +x /tmp/"$1"
}


main "$@"