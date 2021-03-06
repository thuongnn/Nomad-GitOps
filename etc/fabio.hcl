job "fabio" {
  datacenters = ["dc1"]
  type        = "system"

  group "fabio" {
    task "fabio" {
      driver = "docker"

      config {
        image        = "fabiolb/fabio"
        network_mode = "host"
        volumes      = [ "/etc/fabio/:/etc/fabio/" ]
      }

      resources {
        // "testing showed that while memory limits are enforced as one would expect,
        // "CPU limits are soft limits and not enforced as long as there is available CPU on the host machine."
        //   - https://blog.cloudflare.com/how-we-use-hashicorp-nomad/
        cpu    = 200
        memory = 128
      }
    }

    network {
      port "lb" {
        static = 443
      }

      port "http" {
        static = 80
      }

      port "ui" {
        static = 9998
      }
    }
  }

  // when 2+ nodes, can constrain to "lb" nodes only...
  constraint {
     attribute    = "${meta.kind}"
     set_contains = "lb"
  }
}
