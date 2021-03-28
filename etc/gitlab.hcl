job "gitlab" {
  datacenters = ["dc1"]

  group "gitlab" {
   network {
      port "https" {
        to = 443
      }
      port "http" {
        to = 80
      }
    }

    service {
      name = "gitlab"
      tags = [
        "urlprefix-git.x.archive.org:443/",
        "urlprefix-git.x.archive.org:80/",
      ]
      port = "http"
      check {
        type     = "tcp"
        port     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"

        check_restart {
          limit = 3  # auto-restart task when healthcheck fails 3x in a row
          # give container (eg: having issues) custom time amount to stay up for debugging before
          # 1st health check (eg: "3600s" value would be 1hr)
          grace = "600s"
        }
      }
    }

    task "gitlab" {
      driver = "docker"

      config {
        image        = "gitlab/gitlab-ce"
        // network_mode = "host"
        volumes      = [
          "/root/gitlab/config:/etc/gitlab",
          "/root/gitlab/logs:/var/log/gitlab",
          "/root/gitlab/data:/var/opt/gitlab",
          "/root/gitlab/tls:/etc/gitlab/tls", // xxx
        ]
        ports = [
          "https",
          "http",
        ]
        // hostname = "git.x.archive.org"
      }

      resources {
        // "testing showed that while memory limits are enforced as one would expect,
        // "CPU limits are soft limits and not enforced as long as there is available CPU on the host machine."
        //   - https://blog.cloudflare.com/how-we-use-hashicorp-nomad/
        cpu    = 400
        memory = 3500
      }
    }
  }
}
