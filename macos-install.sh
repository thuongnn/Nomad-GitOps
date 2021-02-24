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

MYDIR=${0:a:h}


[ $# -lt 1 ]  &&  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]  <node 2>  <node 3>  ..

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on FIRST node in your cluster, while ssh-ed in.
(git clone this repo somewhere in the same place on all your cluster nodes.)

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


function main() {
  # avoid and environment contamination
  unset NOMAD_ADDR
  unset NOMAD_TOKEN

  TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
  TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created

  set -x
  config

  # use the TLS_CRT and TLS_KEY params
  setup-certs

  add-nodes

  finish
  exit 0
}


function config() {
  export SYSCTL=/usr/local/bin/supervisorctl

  export DOMAIN=$(basename "${TLS_CRT?}" |rev |cut -f2- -d- |rev)
  export FIRST=nom.${DOMAIN?}

  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export PV_MAX=20
  export PV_DIR=/pv

  export FIRSTIP=$(ifconfig |egrep -o 'inet [0-9\.]+' |cut -f2 -d' ' |fgrep -v 127.0.0.1)
  export PV_DIR=/opt/nomad/pv

  NOMAD_HCL=/etc/nomad.d/nomad.hcl
  CONSUL_HCL=/etc/consul.d/consul.hcl
}


function add-nodes() {
  # installs & setup stock nomad & consul
  cd /tmp

  # install binaries and service files
  #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service
  brew install  nomad  consul  supervisord

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


  # restore original config (if reran)
  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL


  # stash copies of original config
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig


  # start up uncustomized versions of nomad and consul
  setup-dnsmasq
  setup-certs

  # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
  # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
  # pass through these `/pv/` dirs from the VM/host to containers.  Each container using it
  # needs to use a unique subdir...
  for N in $(seq 1 ${PV_MAX?}); do
    sudo mkdir -m777 -p ${PV_DIR?}/$N
  done

  setup-daemons


  # customize nomad & consul
  # we have to make _all_ nomad servers VERY angry first, before we can get a leader and token
  setup-nomad
  setup-consul


  # 🤦‍♀️ now we can finally get them to cluster up, elect a leader, and do their f***ing job
  echo "================================================================================"
  consul members
  echo "================================================================================"
  nomad-env-vars
  nomad server members
  echo "================================================================================"


  # NOTE: to avoid failures join-ing and messages like:
  #   "No installed keys could decrypt the message"
  sudo rm /opt/consul/serf/local.keyring
  sudo ${SYSCTL?} restart consul


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

  # ideally fabio is running in docker - but macos issues so alt "exec" driver instead of "docker"
  # https://medium.com/hashicorp-engineering/hashicorp-nomad-from-zero-to-wow-1615345aa539
  [nomad run ${MYDIR?}/etc/fabio-exec.hcl



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


To uninstall:
  https://gitlab.com/internetarchive/nomad/-/blob/master/macos-uninstall.sh



"
}


function setup-consul() {
  ## Consul - setup the fields 'encrypt' etc. as per your cluster.

  # starting cluster - how exciting!  mint some tokens
  TOK_C=$(consul keygen |tr -d ^)


  echo '
server = true
advertise_addr = "{{ GetInterfaceIP \"eth0\" }}"
node_name = "'$(hostname -s)'"
bootstrap_expect = 1
encrypt = "'${TOK_C?}'"
retry_join = ["'${FIRSTIP?}'"]
' | sudo tee -a  $CONSUL_HCL

  sudo ${SYSCTL?} restart consul  &&  sleep 10
}


function setup-nomad() {
  ## Nomad - setup the fields 'encrypt' etc. as per your cluster.
  sudo sed -i -e 's^bootstrap_expect =.*$^bootstrap_expect = 1^' $NOMAD_HCL

  ( configure-nomad ) | sudo tee -a $NOMAD_HCL

  sudo ${SYSCTL?} restart nomad  &&  sleep 10  ||  echo 'moving on ...'
}


function configure-nomad() {
  TOK_N=$(nomad operator keygen |tr -d ^ |cat)

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
  KIND="$KIND,lb"
  KIND="$KIND,pv"

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
  for N in $(seq 1 ${PV_MAX?}); do
    echo -n '
  host_volume "pv'$N'" {
    path      = "'$PV_DIR'/'$N'"
    read_only = false
  }'
  done

  echo '
}'

  set -x
}


function nomad-env-vars() {
  CONF=$HOME/.config/nomad

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

  source $CONF
}


function setup-daemons() {
  # get services ready to go

  local SUPERD=/usr/local/etc/supervisor.d
  mkdir -p $SUPERD
  echo "
[program:nomad]
command=/usr/local/bin/nomad  agent -config     /etc/nomad.d
autorestart=true
startsecs=10

[program:consul]
command=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
autorestart=true
startsecs=10
" >| $SUPERD/hashi.ini
  sudo supervisord  ||  echo 'hopefully supervisord is already running..'

}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem
  local GRP=wheel

  sudo mkdir -p           /etc/fabio/ssl/
  sudo chown root:${GRP?} /etc/fabio/ssl/
  cat ${MYDIR?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

  # only need to do this if fabio is running in a container:
  # [ $MAC ] && echo "registry.consul.addr = ${FIRST?}:8500" |sudo tee -a /etc/fabio/fabio.properties

  [ $TLS_CRT ]  &&  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${CRT?}
    rsync -Pav ${TLS_KEY?} ${KEY?}
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

  brew install dnsmasq

  echo "
# from https://gitlab.com/internetarchive/nomad/-/blob/master/setup.sh

address=/${DOMAIN?}/${FIRSTIP?}
listen-address=127.0.0.1
" |tee /usr/local/etc/dnsmasq.conf

  sudo brew services start dnsmasq

  # verify host lookups are working now
}


main "$@"
