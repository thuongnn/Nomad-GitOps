#####  Default config as of nomad v1.1.0 #######################
# Full configuration options can be found at https://www.nomadproject.io/docs/configuration

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
#####  Default config of nomad v1.1.0 #######################



/* variables we'll use below and their defaults

KIND=worker
HOME_NFS=/tmp/home
TOK_N=set-via-setup.sh

*/


name = "$(hostname -s)"

server {
  encrypt = "${TOK_N}"
}

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

# allow this handy driver, too
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
    kind = "${KIND}"
  }

  host_volume "home-ro" {
    path      = "${HOME_NFS}"
    read_only = true
  }

  host_volume "home-rw" {
    path      = "${HOME_NFS}"
    read_only = false
  }
}
