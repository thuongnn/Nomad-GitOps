#!/bin/zsh -e

# One time setup of server(s) to make a nomad cluster.
#
# Assumes you are creating cluster with debian/ubuntu VMs/baremetals,
# that you have ssh and sudo access to.
#
# Current Overview:
#   Installs nomad server and client on all nodes, securely talking together & electing a leader
#   Installs consul server and client on all nodes
#   Installs load balancer "fabio" on first two nodes
#      (in case you want to use multiple IP addresses for deployments in case one LB/node is out)
#   Optionally installs gitlab runner on 1st node
#   Sets up Persistent Volume subdirs on 1st node - deployments needing PV only schedule to this node
#
# NOTE: if setup 3 nodes (h0, h1 & h2) on day 1; and want to add 2 more (h3 & h4) later,
# you can manually run the lines from `config`, then `add-nodes`
# where you set environment variables like this:
#   NODES=(h3 h4)
#   MYDIR=[set to wherever your nomad clone lives]
#   FIRST=[fully qualified DNS name of your first node]
#   CLUSTER_SIZE=2
#   INITIAL_CLUSTER_SIZE=2

MYDIR=${0:a:h}


[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  <node 2>  <node 3>  ..

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on FIRST node in your cluster, while ssh-ed in.
(git clone this repo somewhere in the same place on all your cluster nodes.)

If invoking cmd-line has env var NFSHOME=1 then we'll setup /home/ r/o and r/w mounts.

To simplify, we'll reuse TLS certs, setting up ACL and TLS for nomad.

"  &&  exit 1


# avoid any environment vars from CLI poisoning..
unset   NOMAD_TOKEN
unset  CONSUL_TOKEN


function main() {
  if [ "$1" = "baseline"  -o  "$1" = "customize"  -o  "$1" = "customize2" ]; then
    set -x
    FIRST=$2
    COUNT=$3
    CLUSTER_SIZE=$4

    config

    "$1"
    exit 0
  else
    FIRST=$(hostname -f)
    TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
    TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created
    shift
    INITIAL_CLUSTER_SIZE=0
    CLUSTER_SIZE=$#
    shift
    typeset -a $NODES
    NODES=( $FIRST "$@" )

    set -x
    config

    # use the TLS_CRT and TLS_KEY params
    ( COUNT=0 setup-certs )

    add-nodes

    finish
    exit 0
  fi

  exit 0
}


function config() {
  export NOMAD_COUNT=${CLUSTER_SIZE?}
  export CONSUL_COUNT=${CLUSTER_SIZE?}

  # We will put PV on 1st server
  # We will put LB/fabio on first X servers
  export LB_COUNT=${CLUSTER_SIZE?}

  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export MAX_PV=20
  export FIRSTIP=$(host ${FIRST?} | perl -ane 'print $F[3] if $F[2] eq "address"')

  # find daemon config files
   NOMAD_HCL=$(dpkg -L nomad  2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
  CONSUL_HCL=$(dpkg -L consul 2>/dev/null |egrep ^/etc/ |egrep -m1 '\.hcl$' || echo -n '')
}


function add-nodes() {
  # install & setup stock nomad & consul
  COUNT=${INITIAL_CLUSTER_SIZE?}
  for NODE in ${NODES?}; do
    ( set -x; ssh $NODE env NFSHOME=$NFSHOME ${MYDIR?}/setup.sh baseline ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
    let "COUNT=$COUNT+1"
  done

  # customize nomad & consul
  # we have to make _all_ nomad servers VERY angry first, before we can get a leader and token
  COUNT=${INITIAL_CLUSTER_SIZE?}
  for NODE in ${NODES?}; do
    ( set -x; ssh $NODE env NFSHOME=$NFSHOME ${MYDIR?}/setup.sh customize ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
    let "COUNT=$COUNT+1"
  done

  # 🤦‍♀️ now we can finally get them to cluster up, elect a leader, and do their f***ing job
  COUNT=${INITIAL_CLUSTER_SIZE?}
  for NODE in ${NODES?}; do
    ( set -x; ssh $NODE env NFSHOME=$NFSHOME ${MYDIR?}/setup.sh customize2 ${FIRST?} ${COUNT?} ${CLUSTER_SIZE?} )
    let "COUNT=$COUNT+1"
  done

  # ugh, facepalm
  for NODE in ${NODES?}; do
    ssh $NODE 'sudo rm /opt/consul/serf/local.keyring;  sudo service consul restart;  echo'
  done
}


function baseline() {
  cd /tmp

  # install docker if not already present
  $MYDIR/install-docker-ce.sh

  # install binaries and service files
  #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service

  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
  sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
  sudo apt-get -yqq update

  sudo apt-get -yqq install  nomad  consul


  config

  # restore original config (if reran)
  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL


  # stash copies of original config
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # start up uncustomized versions of nomad and consul
  setup-certs
  setup-misc
  setup-daemons
}


function customize() {
  setup-nomad
  setup-consul
}


function customize2() {
  echo "================================================================================"
  consul members
  echo "================================================================================"
  nomad-env-vars
  nomad server members
  echo "================================================================================"



  # NOTE: if you see failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  # try either (depending on nomad or consul) inspecting all nodes' contents of file) and:
  echo 'skipping .keyring resets'  ||  (
    sudo rm /opt/nomad/data/server/serf.keyring; sudo service nomad  restart
    sudo rm /opt/consul/serf/local.keyring;      sudo service consul restart
  )
  # and try again manually
  # (All servers need the same contents)

  set +x

  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
  ( set -x; nomad server members )
  echo "================================================================================"
  ( set -x; nomad node status )
  echo "================================================================================"
}


function finish() {
  sleep 30
  nomad run ${MYDIR?}/etc/fabio.hcl


  echo "Setup GitLab runner in your cluster?\n"
  echo "Enter 'yes' now to set up a GitLab runner in your cluster"
  read cont

  if [ "$cont" = "yes" ]; then
    ${MYDIR?}/setup-runner.sh
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

  set +x

  echo '
name = "'$(hostname -s)'"

server {
  encrypt = "'${TOK_N?}'"

  server_join {
    retry_join = ["'${FIRSTIP?}'"]
    retry_max = 0
  }
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

  # Let's put the loadbalancer on the first two nodes added to cluster.
  # All jobs requiring a PV get put on first node in cluster.
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

  set -x
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



function setup-misc() {
  ${MYDIR?}/ports-unblock.sh
  sudo service docker restart  ||  echo 'no docker yet'

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
  sudo systemctl enable  consul  nomad
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo $FIRST |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  sudo mkdir -p /etc/fabio/ssl/
  sudo chown root:root /etc/fabio/ssl/
  cat ${MYDIR?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

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


  sudo mkdir -m 500 -p      /opt/nomad/tls
  sudo cp $CRT              /opt/nomad/tls/tls.crt
  sudo cp $KEY              /opt/nomad/tls/tls.key
  sudo chown -R nomad.nomad /opt/nomad/tls  ||  echo 'future pass will work'
  sudo chmod -R go-rwx      /opt/nomad/tls

}


main "$@"
