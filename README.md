# envoy-wasm-poc

Tried to simplify a little bit how to build an envoy WASM filter

## 1. Getting envoy with the wasm filter enabled

Right now all the envoy wasm work is done in <https://github.com/envoyproxy/envoy-wasm> , so we will need to build that specific version of envoy to get he wasm support.

Building envoy can get tricky, so, you can avoid it, and just use an already compiled wasm enabled envoy: `docker.io/istio/proxyv2:1.5.0`

As this istio image has some other stuff that we don't need, let's just create a "clean" envoy wasm docker image:

```Dockerfile
FROM docker.io/istio/proxyv2:1.5.0 AS builder

FROM centos:latest
COPY --from=builder /usr/local/bin/envoy /usr/local/bin/envoy
ENTRYPOINT ["/usr/local/bin/envoy"]  
```

I pushed that image already if you don't want to build it: `quay.io/jmprusi/envoy-wasm:latest`.

TODO: build envoy with wasm

## 2. Our first WASM hello world

Envoy WASM expects all our WASM programs to use the Proxy-Wasm ABI specification: <https://github.com/proxy-wasm/spec> , it specifies the required functions that our WASM program should expose for the proxy to interact with us. Also keep in mind, that Envoy is using [WAVM](https://github.com/WAVM/WAVM), which relies on the WASI specification.

The easiest way to create a WASM filter for envoy is to use one of the provided SDKs:

* [C++](https://github.com/proxy-wasm/proxy-wasm-cpp-sdk)
* [Rust](https://github.com/proxy-wasm/proxy-wasm-rust-sdk)
* [AssemblyScript](https://github.com/solo-io/proxy-runtime)

Others:

* There's ongoing work from TinyGO, also there's a golang fork that targets WASI <https://github.com/neelance/go/tree/wasi>

So, let's, check the example envoy C++ wasm filter, I've added some comments on it to better understand it.

```cpp
// NOLINT(namespace-envoy)
#include <string>
#include <unordered_map>

#include "proxy_wasm_intrinsics.h"

// Every wasm filter needs to instantiate a Context and a RootContext.
// Here we are instantiating a new ExmpleRootContext inheriting from the RootContext defined by the SDK,
// and overriding the onStart method: ExampleRootContext::onStart(size_t).

// The RootContext has the same lifetime as the VM/runtime instance and acts as a target for any interactions which happen at initial setup. It is also used for interactions that outlive a request.
class ExampleRootContext : public RootContext {
public:
  explicit ExampleRootContext(uint32_t id, StringView root_id) : RootContext(id, root_id) {}
  // The onstart get's called after finishing loading WASM module and before serving any stream events
  bool onStart(size_t) override;
};

// A Context is created on each stream and has the same lifetime as the stream itself and acts as a target for interactions that are local to that stream.
// It receives an incremental ID that gets incremented on each new stream.
class ExampleContext : public Context {
public:
  explicit ExampleContext(uint32_t id, RootContext* root) : Context(id, root) {}

  // Called at the beginning of filter chain iteration. 
  void onCreate() override;

  // We define the callbacks for different context situations
  // onRequestHeaders: Called when request headers are decoded.
  FilterHeadersStatus onRequestHeaders(uint32_t headers) override;

  // onRequestBody: Called when request body is decoded.
  FilterDataStatus onRequestBody(size_t body_buffer_length, bool end_of_stream) override;

  // onResponseHeaders: Called when response headers are decoded.
  FilterHeadersStatus onResponseHeaders(uint32_t headers) override;
  
  // onDone: Called after stream is ended or reset.
  void onDone() override;

  // onLog: Called to log any stream info.
  void onLog() override;

  // onDelete: Called after logging is done.
  void onDelete() override;
};
static RegisterContextFactory register_ExampleContext(CONTEXT_FACTORY(ExampleContext),
                                                      ROOT_FACTORY(ExampleRootContext),
                                                      "my_root_id");

bool ExampleRootContext::onStart(size_t) {
  LOG_TRACE("onStart");
  return true;
}

void ExampleContext::onCreate() { LOG_WARN(std::string("onCreate " + std::to_string(id()))); }

FilterHeadersStatus ExampleContext::onRequestHeaders(uint32_t) {
  LOG_DEBUG(std::string("onRequestHeaders ") + std::to_string(id()));
  // getRequestHeaderPairs is part of the Headers API, it return a wasmData that contains the pairs of headers
  // from the Request or an empty string if there aren't.
  auto result = getRequestHeaderPairs();
  auto pairs = result->pairs();
  LOG_INFO(std::string("headers: ") + std::to_string(pairs.size()));
  for (auto& p : pairs) {
    LOG_INFO(std::string(p.first) + std::string(" -> ") + std::string(p.second));
  }
  return FilterHeadersStatus::Continue;
}

FilterHeadersStatus ExampleContext::onResponseHeaders(uint32_t) {
  LOG_DEBUG(std::string("onResponseHeaders ") + std::to_string(id()));
  // getResponseHeaderPairs is part of the Headers API, it return a wasmData that contains the pairs of headers
  // from the Response or an empty string if there aren't.
  auto result = getResponseHeaderPairs();
  auto pairs = result->pairs();
  LOG_INFO(std::string("headers: ") + std::to_string(pairs.size()));
  for (auto& p : pairs) {
    LOG_INFO(std::string(p.first) + std::string(" -> ") + std::string(p.second));
  }

  // addResponseHeader adds a new header to the response
  addResponseHeader("newheader", "newheadervalue");

  // replaceResponseHeader replaces a header or creates it if doesn't exists.
  replaceResponseHeader("location", "envoy-wasm");
  return FilterHeadersStatus::Continue;
}

FilterDataStatus ExampleContext::onRequestBody(size_t body_buffer_length, bool end_of_stream) {
  auto body = getBufferBytes(WasmBufferType::HttpRequestBody, 0, body_buffer_length);
  LOG_ERROR(std::string("onRequestBody ") + std::string(body->view()));
  return FilterDataStatus::Continue;
}

void ExampleContext::onDone() { LOG_WARN(std::string("onDone " + std::to_string(id()))); }

void ExampleContext::onLog() { LOG_WARN(std::string("onLog " + std::to_string(id()))); }

void ExampleContext::onDelete() { LOG_WARN(std::string("onDelete " + std::to_string(id()))); }
```

You can check the great documentation on the proxy-wasm project github: <https://github.com/proxy-wasm/proxy-wasm-cpp-sdk/blob/master/docs/wasm_filter.md#context-object-api>.

## 2.1 Building our WASM helloworld

We need to clone and build the builder image. Let's use docker as it simplifies the whole process:

```sh
git clone https://github.com/proxy-wasm/proxy-wasm-cpp-sdk
cd proxy-wasm-cpp-sdk
docker build -t wasmsdk:v2 -f Dockerfile-sdk .
```

This is going to take a while... when it finishes, build the testenv wasm file with:

```sh
cd testenv
docker run -v $PWD:/work -w /work  wasmsdk:v2 /build_wasm.sh
```

Look, do you have a new file named: `envoy_filter_http_wasm_example.wasm`? then congrats, you have compiled your WASM filter!

## 2.2 Running envoy with our wasm filter

Now, let's start envoy, and do some request:

```sh
cd testenv
docker-compose up
```

and

```sh
curl localhost:18000 -v
```

You should get something like this:

```text
→ curl localhost:18000 -v
*   Trying ::1...
* TCP_NODELAY set
* Connected to localhost (::1) port 18000 (#0)
> GET / HTTP/1.1
> Host: localhost:18000
> User-Agent: curl/7.64.1
> Accept: */*
>
< HTTP/1.1 200 OK
< content-length: 13
< content-type: text/plain
< date: Wed, 22 Apr 2020 22:51:45 GMT
< server: envoy
< x-envoy-upstream-service-time: 0
< newheader: newheadervalue
< location: envoy-wasm
<
example body
* Connection #0 to host localhost left intact
* Closing connection 0
```

See? our filter added the headers! also look at the docker-compose logs, you will see all the logged callbacks.

## TODO

* Root makefile that handles everything, get rid of docker compose.
* Envoy config: explain how the filter is loaded and where is valid.
* Better explain the build process.
* Write a more advanced filter... instead of this simple one.
