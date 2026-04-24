variable "REGISTRY" {
  default = "barddoo/zedis"
}

variable "VERSION" {
  default = "dev"
}

group "default" {
  targets = ["alpine", "debian", "distroless"]
}

target "_base" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
}

target "alpine" {
  inherits = ["_base"]
  target   = "alpine"
  tags = [
    "${REGISTRY}:${VERSION}-alpine",
    "${REGISTRY}:${VERSION}",
    "${REGISTRY}:latest",
  ]
}

target "debian" {
  inherits = ["_base"]
  target   = "debian"
  tags = [
    "${REGISTRY}:${VERSION}-debian",
    "${REGISTRY}:${VERSION}-slim",
  ]
}

target "distroless" {
  inherits = ["_base"]
  target   = "distroless"
  tags = [
    "${REGISTRY}:${VERSION}-distroless",
  ]
}
