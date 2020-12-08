# simple demo "hello world" job

job "hello" {
  datacenters = ["dc1"]
  type = "service"

  group "hello" {
    count = 1

    network {
      port "http" {}
    }

    task "hello" {
      driver = "docker"
      config {
        image = "registry.gitlab.com/internetarchive/bai/master:latest"
        port_map {
          http = 5000
        }
      }

      service {
        name = "hello"
        port = "http"
      }

      resources {
        cpu    = 100
        memory = 100
      }
    }
  }
}
