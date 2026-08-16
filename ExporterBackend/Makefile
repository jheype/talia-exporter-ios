.PHONY: check test build run

check:
	gofmt -w .
	go vet ./...
	go test -race ./...

test:
	go test ./...

build:
	CGO_ENABLED=0 go build -trimpath -o bin/exporter-api ./cmd/exporter-api

run:
	go run ./cmd/exporter-api

