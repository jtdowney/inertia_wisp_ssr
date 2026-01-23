# Justfile
default: build

# Build main library and ssr_server
build: build-ssr-server
    gleam build

# Build ssr_server and bundle to priv/
build-ssr-server:
    cd ssr_server && gleam build
    cd ssr_server && gleam run -m build

# Run all tests
test: build-ssr-server
    gleam test

# Clean build artifacts
clean:
    gleam clean
    rm -rf ssr_server/build
    rm -f priv/ssr_server.js

# Format all code
fmt:
    gleam format
    cd ssr_server && gleam format

publish: build-ssr-server
    gleam publish
