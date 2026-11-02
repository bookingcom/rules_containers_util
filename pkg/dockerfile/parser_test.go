package dockerfile

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseDockerfile(t *testing.T) {
	content := `
# Simple Dockerfile test
FROM alpine:3.19 AS builder
WORKDIR /app
COPY package.json .
RUN apk add --no-cache curl && \
    curl -fsSL https://example.com/file.tar.gz -o file.tar.gz

FROM alpine:3.19
COPY --from=builder /app/file.tar.gz /opt/file.tar.gz
RUN echo "done"
CMD ["/bin/sh", "-c", "echo ready"]
`

	layers, err := Parse(strings.NewReader(content))
	if err != nil {
		t.Fatalf("unexpected error parsing dockerfile: %v", err)
	}

	if len(layers) != 8 {
		t.Fatalf("expected 8 layers, got %d", len(layers))
	}

	// Layer 0: FROM alpine:3.19 AS builder
	if layers[0].Command != "FROM" || layers[0].Stage != 0 || layers[0].StageName != "builder" {
		t.Errorf("layer 0 mismatch: %+v", layers[0])
	}

	// Layer 1: WORKDIR /app
	if layers[1].Command != "WORKDIR" || layers[1].Value != "/app" {
		t.Errorf("layer 1 mismatch: %+v", layers[1])
	}

	// Layer 3: RUN with shell continuation and shell AST
	runLayer := layers[3]
	if runLayer.Command != "RUN" {
		t.Errorf("layer 3 expected RUN, got %s", runLayer.Command)
	}
	if runLayer.ShellAST == nil {
		t.Fatalf("expected ShellAST on RUN layer, got nil")
	}

	// Check that ShellAST contains children and binary command (&&)
	if len(runLayer.ShellAST.Children) == 0 {
		t.Fatalf("expected children in ShellAST")
	}

	firstStmt := runLayer.ShellAST.Children[0]
	if firstStmt.Type != "BinaryCmd" || firstStmt.Op != "&&" {
		t.Errorf("expected BinaryCmd with &&, got type=%s op=%s", firstStmt.Type, firstStmt.Op)
	}

	// Verify JSON serialization produces valid JSON array
	jsonBytes, err := json.MarshalIndent(layers, "", "  ")
	if err != nil {
		t.Fatalf("failed to marshal layers to JSON: %v", err)
	}

	if len(jsonBytes) == 0 {
		t.Errorf("empty json output")
	}
}

func TestHeredocRUN(t *testing.T) {
	content := `
FROM debian:bookworm-slim
RUN <<EOF
apt-get update
apt-get install -y curl
EOF
`
	layers, err := Parse(strings.NewReader(content))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(layers) != 2 {
		t.Fatalf("expected 2 layers, got %d", len(layers))
	}

	runLayer := layers[1]
	if runLayer.Command != "RUN" {
		t.Fatalf("expected RUN layer")
	}
	if runLayer.ShellAST == nil {
		t.Fatalf("expected ShellAST for heredoc RUN")
	}
	if len(runLayer.ShellAST.Children) != 2 {
		t.Errorf("expected 2 statements in heredoc RUN, got %d", len(runLayer.ShellAST.Children))
	}
}
