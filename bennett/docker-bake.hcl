# Build the production image from this checkout. Run from the repository root:
#
#   docker buildx bake -f bennett/docker-bake.hcl --load
#
# "upstream" is DocuSeal's own Dockerfile, unmodified; "bennett" adds the
# runtime layer on top of its output (bennett/Dockerfile.bennett).
variable "REVISION" { default = "unknown" }
variable "VERSION" { default = "unknown" }
variable "TAG" { default = "bennett-docuseal:local" }

group "default" {
  targets = ["bennett"]
}

target "upstream" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64"]
}

target "bennett" {
  context    = "bennett"
  dockerfile = "Dockerfile.bennett"
  contexts   = { upstream = "target:upstream" }
  platforms  = ["linux/amd64"]
  args       = { REVISION = REVISION, VERSION = VERSION }
  tags       = [TAG]
}
