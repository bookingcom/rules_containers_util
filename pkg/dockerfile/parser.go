package dockerfile

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/moby/buildkit/frontend/dockerfile/parser"
)

// Layer represents a single instruction / layer in the Dockerfile.
type Layer struct {
	Index     int        `json:"index"`
	Stage     int        `json:"stage"`
	StageName string     `json:"stage_name,omitempty"`
	Command   string     `json:"command"`
	Flags     []string   `json:"flags,omitempty"`
	Args      []string   `json:"args,omitempty"`
	Value     string     `json:"value"`
	Heredocs  []string   `json:"heredocs,omitempty"`
	StartLine int        `json:"start_line"`
	EndLine   int        `json:"end_line"`
	ShellAST  *ShellNode `json:"shell_ast,omitempty"`
}

// ParseFile parses a Dockerfile from a file path using BuildKit's parser.
func ParseFile(path string) ([]*Layer, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("unable to open dockerfile %s: %w", path, err)
	}
	defer f.Close()
	return Parse(f)
}

// Parse parses a Dockerfile from an io.Reader using BuildKit's parser and returns an array of layers.
func Parse(r io.Reader) ([]*Layer, error) {
	result, err := parser.Parse(r)
	if err != nil {
		return nil, fmt.Errorf("failed to parse dockerfile: %w", err)
	}

	var layers []*Layer
	currentStage := -1
	currentStageName := ""

	if result.AST == nil {
		return layers, nil
	}

	for i, node := range result.AST.Children {
		cmdUpper := strings.ToUpper(node.Value)

		// Collect argument tokens from node.Next linked list
		var args []string
		for curr := node.Next; curr != nil; curr = curr.Next {
			args = append(args, curr.Value)
		}

		// Stage tracking on FROM
		if cmdUpper == "FROM" {
			currentStage++
			currentStageName = ""
			for j := 0; j < len(args); j++ {
				if strings.ToUpper(args[j]) == "AS" && j+1 < len(args) {
					currentStageName = args[j+1]
					break
				}
			}
		}

		// Collect heredocs if any
		var heredocTexts []string
		for _, hd := range node.Heredocs {
			heredocTexts = append(heredocTexts, hd.Content)
		}

		// Raw value / argument string
		value := strings.Join(args, " ")

		layer := &Layer{
			Index:     i,
			Stage:     currentStage,
			StageName: currentStageName,
			Command:   cmdUpper,
			Flags:     node.Flags,
			Args:      args,
			Value:     value,
			Heredocs:  heredocTexts,
			StartLine: node.StartLine,
			EndLine:   node.EndLine,
		}

		// If the command is RUN, parse into Shell AST
		if cmdUpper == "RUN" {
			cmdToParse := value
			if len(heredocTexts) > 0 {
				cmdToParse = strings.Join(heredocTexts, "\n")
			} else if len(args) == 1 && strings.HasPrefix(strings.TrimSpace(args[0]), "[") {
				// Exec form in JSON: ["executable", "param1", ...]
				var jsonArgs []string
				if err := json.Unmarshal([]byte(args[0]), &jsonArgs); err == nil {
					cmdToParse = strings.Join(jsonArgs, " ")
				}
			}

			ast, err := ParseShellCommand(cmdToParse)
			if err == nil {
				layer.ShellAST = ast
			}
		}

		layers = append(layers, layer)
	}

	return layers, nil
}
