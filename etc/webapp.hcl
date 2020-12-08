/*
modified from:
https://learn.hashicorp.com/nomad/vault-integration/vault-postgres


https://learn.hashicorp.com/consul/security-networking/forwarding


# formally allow services to talk to each other -- IFF using consul connect, etc.
consul intention create -allow webapp webapp-db

# Towards trying to get name lookups _inside_ containers..
# NOTE: replace 207.241.224.9 with your DNS resolver

# NEED TO UPDATE consul.hcl AND RESTART CONSUL WITH 'recursors' stanza FIRST
# ALSO add/update (to make consul DNS resolving listener listen on 127.0.0.1):
addresses {
  http = "0.0.0.0"
  dns = "127.0.0.1"
}


# (IP addresses per /etc/resolv.conf)
IP=$(ifconfig |egrep 'inet [0-9\.]+' |cut -f2 -d' ' |fgrep -v 127.0.0.1)
iptables -t nat -A PREROUTING -p tcp -d ${IP?} --dport 53 -j DNAT --to-destination ${IP?}:8600
iptables -t nat -A PREROUTING -p udp -d ${IP?} --dport 53 -j DNAT --to-destination ${IP?}:8600
iptables -t nat -A OUTPUT     -p tcp -d ${IP?} --dport 53 -j DNAT --to-destination ${IP?}:8600
iptables -t nat -A OUTPUT     -p udp -d ${IP?} --dport 53 -j DNAT --to-destination ${IP?}:8600

# verify
dig @localhost -p 8600 webapp-db.service.consul. A
dig @localhost -p   53 webapp-db.service.consul. A
dig @localhost -p 8600 msn.com. A
dig @localhost -p   53 msn.com. A

dig @207.241.224.9 -p 53 msn.com. A
# FAILING xxxx
dig @207.241.224.9 -p 53 webapp-db.service.consul. A

# to see updated rules
iptables -t nat --list --line-number -n |egrep '8600|53|$'

# to delete a rule:
iptables -t nat -D PREROUTING [LINE-NUMBER]


*/

job "webapp" {
  datacenters = ["dc1"]

  group "webapp" {
    network {
      port "http" {}
      port "db"   { static = 5432 }
    }

    task "webapp" {
      driver = "docker"

      config {
        image = "hashicorp/nomad-vault-demo:latest"
        port_map {
          http = 8080
        }
      }

      template {
        destination = "secrets/config.json"
        # example to get docker bridge IP
        # data = "BRIDGE_IP={{ env \"attr.driver.docker.bridge_ip\" }}"
        data = <<EOF
{
  "host": "webapp-db.service.consul",
  "port": 5432,
  "username": "postgres",
  "password": "postgres123",
  "db": "postgres"
}
EOF
      }

      service {
        name = "nomad-vault-demo"
        port = "http"

        tags = [
          "urlprefix-/",
        ]

        check {
          expose   = true
          type     = "tcp"
          interval = "2s"
          timeout  = "2s"
        }
      }
    }


    task "webapp-db" {
      driver = "docker"

      config {
        image = "hashicorp/postgres-nomad-demo:latest"
        port_map {
          db = 5432
        }
      }

      service {
        name = "webapp-db"
        port = "db"

        check {
          expose   = true
          port     = "db"
          type     = "tcp"
          interval = "2s"
          timeout  = "2s"
        }

        check {
          # This posts containers bridge IP address (starting with "172.") into an expected
          # file that other docker container can reach this DB docker container with.
          type     = "script"
          name     = "setup"
          command  = "/bin/sh"
          args     = ["-c", "hostname -i |tee /alloc/data/webapp-db.ip"]
          interval = "1h"
          timeout  = "10s"
        }

        check {
          type     = "script"
          name     = "db-ready"
          command  = "/usr/bin/pg_isready"
          args     = ["-Upostgres", "-h", "127.0.0.1", "-p", "5432"]
          interval = "10s"
          timeout  = "10s"
        }
      }
    }
  }
}
