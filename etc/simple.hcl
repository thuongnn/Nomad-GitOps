# Minimal basic project using only GitLab CI/CD std. variables

# Variables used below and their defaults if not set externally
variables {
  # These all pass through from GitLab [build] phase.
  # Some defaults filled in w/ example repo "bai" in group "internetarchive"
  # (but all 7 get replaced during normal GitLab CI/CD from CI/CD variables).
  CI_REGISTRY = "registry.gitlab.com"                       # registry hostname
  CI_REGISTRY_IMAGE = "registry.gitlab.com/internetarchive/bai"  # registry image location
  CI_COMMIT_REF_SLUG = "master"                             # branch name, slugged
  CI_COMMIT_SHA = "latest"                                  # repo's commit for current pipline
  CI_PROJECT_PATH_SLUG = "internetarchive-bai"              # repo and group it is part of, slugged
  CI_REGISTRY_USER = ""                                     # set for each pipeline and ..
  CI_REGISTRY_PASSWORD = ""                                 # .. allows pull from private registry

  KUBE_INGRESS_BASE_DOMAIN = "x.archive.org"
}

# NOTE: "simple" below should really be "${var.CI_PROJECT_PATH_SLUG}-${var.CI_COMMIT_REF_SLUG}"
# in all four locations.  But (job|group|task) ".."  can't interpolate vars yet in HCL v2.
job "simple" {
  datacenters = ["dc1"]
  group "simple" {
    network {
      port "http" {
        to = 5000
      }
    }
    service {
      name = "simple"
      tags = ["urlprefix-${var.CI_PROJECT_PATH_SLUG}-${var.CI_COMMIT_REF_SLUG}.${var.KUBE_INGRESS_BASE_DOMAIN}:443/"]
      port = "http"
      check {
        type     = "http"
        port     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }
    task "simple" {
      driver = "docker"

      config {
        image = "${var.CI_REGISTRY_IMAGE}/${var.CI_COMMIT_REF_SLUG}:${var.CI_COMMIT_SHA}"

        ports = [ "http" ]

        auth {
          server_address = "${var.CI_REGISTRY}"
          username = "${var.CI_REGISTRY_USER}"
          password = "${var.CI_REGISTRY_PASSWORD}"
        }
      }
    }
  }
}
