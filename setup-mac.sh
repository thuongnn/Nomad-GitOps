#!/bin/zsh -e

# One time setup on mac laptop to make a nomad cluster.

MYDIR=${0:a:h}

# where supporting scripts live and will get pulled from
RAW=https://gitlab.com/internetarchive/nomad/-/raw/master


function usage() {
  echo "
usage: $0  [TLS_CRT file]  [TLS_KEY file]

[TLS_CRT file] - file location. wildcard domain PEM format.
[TLS_KEY file] - file location. wildcard domain PEM format.  May need to prepend '[SERVER]:' for rsync..)

Run this script on your mac laptop.
- Installs nomad server and client
- Installs consul server and client
- Installs load balancer "fabio"
- Optionally installs gitlab runner
- Sets up Persistent Volume subdirs

To simplify, we'll reuse TLS certs, setting up ACL and TLS for nomad.
Assumes brew is installed.


Additional requirement:
  TLS command-line args must match pattern:
    [DOMAIN]-cert.pem
    [DOMAIN]-key.pem

Additional step:
[System Preferences] [Network] [Advanced] [DNS] [DNS Servers] add '127.0.0.1' as *first* resolver


"  &&  exit 1
}


function main() {
  [ $# -lt 2 ]  &&  usage

  TLS_CRT=$1  # @see create-https-certs.sh - fully qualified path to crt file it created
  TLS_KEY=$2  # @see create-https-certs.sh - fully qualified path to key file it created

  set -x
  config
  baseline

  setup-dnsmasq
  setup-certs
  setup-misc

  # start up uncustomized version of consul & nomad
  setup-daemons

  # setup fully configured consul
  setup-consul

  # now get nomad configured and up
  setup-nomad

  finish
}


function config() {
  # avoid any environment vars from CLI poisoning..
  unset   NOMAD_TOKEN

  local DOMAIN=$(basename "${TLS_CRT?}" |rev |cut -f2- -d- |rev)
  export FIRST=nom.${DOMAIN?}

  export  NOMAD_ADDR="https://${FIRST?}:4646"
  export CONSUL_ADDR="http://localhost:8500"
  export  FABIO_ADDR="http://localhost:9998"
  export PV_MAX=20
  export PV_DIR=/opt/nomad/pv

  export FIRSTIP=$(ifconfig |egrep -o 'inet [0-9\.]+' |cut -f2 -d' ' |fgrep -v 127.0.0 |head -1)

  # setup unix counterpart default config
    NOMAD_HCL=/etc/nomad.d/nomad.hcl
  CONSUL_HCL=/etc/consul.d/consul.hcl
}


function baseline() {
  cd /tmp

  # install binaries and service files
  #   eg: /usr/bin/nomad  /etc/nomad.d/nomad.hcl  /usr/lib/systemd/system/nomad.service
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


  # restore original config (if reran)
  [ -e $CONSUL_HCL.orig ]  &&  sudo cp -p $CONSUL_HCL.orig $CONSUL_HCL

  # stash copies of original config
  sudo cp -p $CONSUL_HCL $CONSUL_HCL.orig
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

  sudo brew services restart consul  &&  sleep 10


  echo "================================================================================"
  consul members
  echo "================================================================================"


  sudo rm /opt/consul/serf/local.keyring
  sudo brew services restart  consul
  sleep 10

  # and try again manually
  # (All servers need the same contents)

  set +x

  echo "================================================================================"
  ( set -x; consul members )
  echo "================================================================================"
}


function setup-nomad() {
  ## Nomad - setup the fields 'encrypt' etc. as per your cluster.

  [ -e  $NOMAD_HCL.orig ]  &&  sudo cp -p  $NOMAD_HCL.orig  $NOMAD_HCL
  sudo cp -p  $NOMAD_HCL  $NOMAD_HCL.orig

  # We'll put a loadbalancer on all cluster nodes
  # All jobs requiring a PV get put on first cluster node
  local KIND='worker,lb,pv'

  local TOK_N=$(nomad operator keygen |tr -d ^ |cat)

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

# ensure docker jobs can mount volumes
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
}

client {
  meta {
    "kind" = "'$KIND'"
  }
}' | sudo tee -a $NOMAD_HCL

  # pass through disk from host for now.  peg project(s) with PV requirements to this host.
  ( echo '
client {'
  for N in $(seq 1 ${PV_MAX?}); do
    echo -n '
  host_volume "pv'$N'" {
    path      = "'$PV_DIR'/'$N'"
    read_only = false
  }'
  done
    echo '
}' ) | sudo tee -a $NOMAD_HCL

  set -x



  nomad-env-vars
  echo "================================================================================"
  ( set -x; nomad server members )
  echo "================================================================================"
  ( set -x; nomad node status )
  echo "================================================================================"


  sudo brew services restart nomad  &&  sleep 10
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



function setup-misc() {
  # One server in cluster gets marked for hosting repos with Persistent Volume requirements.
  # Keeping things simple, and to avoid complex multi-host solutions like rook/ceph, we'll
  # pass through these `/pv/` dirs from the VM/host to containers.  Each container using it
  # needs to use a unique subdir...
  for N in $(seq 1 ${PV_MAX?}); do
    sudo mkdir -m777 -p ${PV_DIR?}/$N
  done
}


function setup-daemons() {
  # get services ready to go
  sed -i -e 's|<string>-dev</string>|<string>-config=/etc/nomad.d</string>|' \
    /usr/local/Cellar/nomad/*/*plist

  sed -i -e 's|<string>-dev</string>|<string>-config-dir=/etc/consul.d/</string>|' \
    /usr/local/Cellar/consul/*/*plist
  sed -i -e 's|<string>-bind</string>||'      /usr/local/Cellar/consul/*/*plist
  sed -i -e 's|<string>127.0.0.1</string>||'  /usr/local/Cellar/consul/*/*plist

  sudo brew services start nomad
  sudo brew services start consul
}


function setup-certs() {
  # sets up https / TLS  and fabio for routing, loadbalancing, and https traffic
  local DOMAIN=$(echo ${FIRST?} |cut -f2- -d.)
  local CRT=/etc/fabio/ssl/${DOMAIN?}-cert.pem
  local KEY=/etc/fabio/ssl/${DOMAIN?}-key.pem

  local GRP=wheel

  sudo mkdir -p           /etc/fabio/ssl/
  sudo chown root:${GRP?} /etc/fabio/ssl/
  wget -qO- ${RAW?}/etc/fabio.properties |sudo tee /etc/fabio/fabio.properties

  sudo bash -c "(
    rsync -Pav ${TLS_CRT?} ${CRT?}
    rsync -Pav ${TLS_KEY?} ${KEY?}
  )"

  sudo chown root:${GRP?} ${CRT} ${KEY}
  sudo chmod 444 ${CRT}
  sudo chmod 400 ${KEY}


  sudo mkdir -m 500 -p      /opt/nomad/tls
  sudo cp $CRT              /opt/nomad/tls/tls.crt
  sudo cp $KEY              /opt/nomad/tls/tls.key
  sudo chown -R nomad.nomad /opt/nomad/tls
  sudo chmod -R go-rwx      /opt/nomad/tls
}


function setup-dnsmasq() {
  # sets up a wildcard dns domain to resolve to your mac
  # inspiration:
  #   https://hedichaibi.com/how-to-setup-wildcard-dev-domains-with-dnsmasq-on-a-mac/

  brew install dnsmasq

  local DOMAIN=$(echo ${FIRST?} |cut -f2- -d.)

  echo "
# from https://gitlab.com/internetarchive/nomad/-/blob/master/setup.sh

address=/${DOMAIN?}/${FIRSTIP?}
listen-address=127.0.0.1
" |tee /usr/local/etc/dnsmasq.conf

  sudo brew services start dnsmasq
}


function getr() {
  # gets a supporting file from main repo into /tmp/
  wget --backups=1 -qP /tmp/ ${RAW}/"$1"
  chmod +x /tmp/"$1"
}


function finish() {
  sleep 30
  nomad-env-vars

  # ideally fabio is running in docker - but macos issues so alt "exec" driver instead of "docker"
  # https://medium.com/hashicorp-engineering/hashicorp-nomad-from-zero-to-wow-1615345aa539
  nomad run ${RAW?}/etc/fabio-exec.hcl


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


main "$@"
