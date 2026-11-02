package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/bookingcom/rules_containers_util/pkg/dockerfile"
)

func main() {
	dockerfilePath := flag.String("dockerfile", "", "Path to Dockerfile to parse (default: stdin)")
	outputPath := flag.String("output", "", "Path to output JSON file (default: stdout)")
	flag.Parse()

	var r io.Reader
	if *dockerfilePath != "" && *dockerfilePath != "-" {
		f, err := os.Open(*dockerfilePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error opening Dockerfile %s: %v\n", *dockerfilePath, err)
			os.Exit(1)
		}
		defer f.Close()
		r = f
	} else if flag.NArg() > 0 && flag.Arg(0) != "-" {
		filePath := flag.Arg(0)
		f, err := os.Open(filePath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error opening Dockerfile %s: %v\n", filePath, err)
			os.Exit(1)
		}
		defer f.Close()
		r = f
	} else {
		r = os.Stdin
	}

	layers, err := dockerfile.Parse(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error parsing Dockerfile: %v\n", err)
		os.Exit(1)
	}

	data, err := json.MarshalIndent(layers, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
		os.Exit(1)
	}

	if *outputPath != "" && *outputPath != "-" {
		if err := os.WriteFile(*outputPath, append(data, '\n'), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing output %s: %v\n", *outputPath, err)
			os.Exit(1)
		}
	} else {
		fmt.Println(string(data))
	}
}
