package dockerfile

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"unicode"
)

// Layer represents a single instruction / layer in the Dockerfile.
type Layer struct {
	Index       int        `json:"index"`
	Stage       int        `json:"stage"`
	StageName   string     `json:"stage_name,omitempty"`
	Command     string     `json:"command"`
	Flags       []string   `json:"flags,omitempty"`
	Args        []string   `json:"args,omitempty"`
	Value       string     `json:"value"`
	Heredoc     string     `json:"heredoc,omitempty"`
	StartLine   int        `json:"start_line"`
	EndLine     int        `json:"end_line"`
	ShellAST    *ShellNode `json:"shell_ast,omitempty"`
}

// StageInfo tracks a build stage in a multi-stage Dockerfile.
type StageInfo struct {
	Index int    `json:"index"`
	Name  string `json:"name,omitempty"`
	Base  string `json:"base"`
}

// ParseResult holds the parsed layers and stage metadata.
type ParseResult struct {
	Stages []*StageInfo `json:"stages"`
	Layers []*Layer     `json:"layers"`
}

var knownInstructions = map[string]bool{
	"ADD":         true,
	"ARG":         true,
	"CMD":         true,
	"COPY":        true,
	"ENTRYPOINT":  true,
	"ENV":         true,
	"EXPOSE":      true,
	"FROM":        true,
	"HEALTHCHECK": true,
	"LABEL":       true,
	"MAINTAINER":  true,
	"ONBUILD":     true,
	"RUN":         true,
	"SHELL":       true,
	"STOPSIGNAL":  true,
	"USER":        true,
	"VOLUME":      true,
	"WORKDIR":     true,
}

// ParseFile parses a Dockerfile from a file path.
func ParseFile(path string) ([]*Layer, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("unable to open dockerfile %s: %w", path, err)
	}
	defer f.Close()
	return Parse(f)
}

// Parse parses a Dockerfile from an io.Reader and returns an array of layers.
func Parse(r io.Reader) ([]*Layer, error) {
	scanner := bufio.NewScanner(r)
	var lines []string
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading dockerfile: %w", err)
	}

	var layers []*Layer
	currentStage := -1
	currentStageName := ""

	heredocRegex := regexp.MustCompile(`<<-?\s*([A-Za-z0-9_]+)`)

	i := 0
	totalLines := len(lines)

	for i < totalLines {
		rawLine := lines[i]
		trimmed := strings.TrimSpace(rawLine)

		// Skip empty lines or pure comment lines
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			i++
			continue
		}

		startLine := i + 1
		var commandBuf strings.Builder
		commandBuf.WriteString(trimmed)

		// Multi-line continuation using trailing backslash
		for strings.HasSuffix(commandBuf.String(), "\\") && i+1 < totalLines {
			i++
			content := strings.TrimSpace(lines[i])
			// remove the trailing backslash from previous segment
			prev := strings.TrimSuffix(commandBuf.String(), "\\")
			commandBuf.Reset()
			commandBuf.WriteString(strings.TrimRight(prev, " \t"))
			commandBuf.WriteString(" ")
			commandBuf.WriteString(content)
		}

		endLine := i + 1
		fullInstr := commandBuf.String()

		// Extract instruction and rest
		fields := strings.Fields(fullInstr)
		if len(fields) == 0 {
			i++
			continue
		}

		cmdUpper := strings.ToUpper(fields[0])
		if !knownInstructions[cmdUpper] {
			// Not a recognized instruction, skip or treat as generic
			i++
			continue
		}

		rest := strings.TrimSpace(fullInstr[len(fields[0]):])

		// Parse flags and value
		var flags []string
		for strings.HasPrefix(rest, "--") {
			spaceIdx := strings.IndexFunc(rest, unicode.IsSpace)
			if spaceIdx == -1 {
				flags = append(flags, rest)
				rest = ""
				break
			}
			flags = append(flags, rest[:spaceIdx])
			rest = strings.TrimSpace(rest[spaceIdx:])
		}

		// Check for Heredoc syntax (e.g. RUN <<EOF)
		var heredocContent string
		if matches := heredocRegex.FindStringSubmatch(rest); len(matches) > 1 {
			delimiter := matches[1]
			var hdBuf strings.Builder
			i++
			foundEnd := false
			for i < totalLines {
				line := lines[i]
				if strings.TrimSpace(line) == delimiter {
					foundEnd = true
					endLine = i + 1
					break
				}
				hdBuf.WriteString(line)
				hdBuf.WriteString("\n")
				i++
			}
			if foundEnd {
				heredocContent = hdBuf.String()
			}
		}

		// Handle FROM for stage tracking
		if cmdUpper == "FROM" {
			currentStage++
			currentStageName = ""
			fromArgs := strings.Fields(rest)
			for j := 0; j < len(fromArgs); j++ {
				if strings.ToUpper(fromArgs[j]) == "AS" && j+1 < len(fromArgs) {
					currentStageName = fromArgs[j+1]
					break
				}
			}
		}

		// Parse args for json exec form or space separated
		args := parseArgs(rest)

		layer := &Layer{
			Index:       len(layers),
			Stage:       currentStage,
			StageName:   currentStageName,
			Command:     cmdUpper,
			Flags:       flags,
			Args:        args,
			Value:       rest,
			Heredoc:     heredocContent,
			StartLine:   startLine,
			EndLine:     endLine,
		}

		// If the command is RUN, parse into Shell AST
		if cmdUpper == "RUN" {
			cmdToParse := rest
			if heredocContent != "" {
				cmdToParse = heredocContent
			} else if len(args) > 0 && strings.HasPrefix(strings.TrimSpace(rest), "[") {
				// Exec form: ["executable", "param1", ...]
				cmdToParse = strings.Join(args, " ")
			}

			ast, err := ParseShellCommand(cmdToParse)
			if err == nil {
				layer.ShellAST = ast
			}
		}

		layers = append(layers, layer)
		i++
	}

	return layers, nil
}

func parseArgs(val string) []string {
	val = strings.TrimSpace(val)
	if strings.HasPrefix(val, "[") && strings.HasSuffix(val, "]") {
		var jsonArgs []string
		if err := json.Unmarshal([]byte(val), &jsonArgs); err == nil {
			return jsonArgs
		}
	}
	return strings.Fields(val)
}
