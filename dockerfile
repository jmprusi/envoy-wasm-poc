FROM docker.io/istio/proxyv2:1.5.0 AS builder

FROM centos:latest
COPY --from=builder /usr/local/bin/envoy /usr/local/bin/envoy
ENTRYPOINT ["/usr/local/bin/envoy"] 
