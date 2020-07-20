# Minimal basic project using only GitLab CI/CD std. variables
job "[[.CI_PROJECT_PATH_SLUG]]-[[.CI_COMMIT_REF_SLUG]]" {
  group "[[.CI_PROJECT_PATH_SLUG]]-[[.CI_COMMIT_REF_SLUG]]" {
    task "[[.CI_PROJECT_PATH_SLUG]]-[[.CI_COMMIT_REF_SLUG]]" {
      driver = "docker"

      config {
        image = "[[.CI_REGISTRY_IMAGE]]/[[.CI_COMMIT_REF_SLUG]]:[[.CI_COMMIT_SHA]]"

        port_map {
          http = 5000
        }

        auth {
          server_address = "[[.CI_REGISTRY]]"
          username = "[[.CI_REGISTRY_USER]]"
          password = "[[.CI_REGISTRY_PASSWORD]]"
        }
      }

      resources {
        network {
          port "http" {}
        }
      }

      service {
        name = "[[.CI_PROJECT_PATH_SLUG]]-[[.CI_COMMIT_REF_SLUG]]"
        tags = ["urlprefix-[[.CI_PROJECT_PATH_SLUG]]-[[.CI_COMMIT_REF_SLUG]].[[.KUBE_INGRESS_BASE_DOMAIN]]:443/"]
        port = "http"
        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }
    } # end task
  } # end group
} # end job
