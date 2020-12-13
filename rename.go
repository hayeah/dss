package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
)

var mappingRE = regexp.MustCompile(`^(.+) -> ([^:]+):?`)

func renameSymbol(from, to string) error {
	// https://github.com/facebookincubator/fastmod
	//
	// brew install fastmod
	//
	// fastmod -e sol --accept-all \
  // '\bilk\b' \
	// collateralType

	if from[0] == '#' {
		return nil
	}

	var fromRe string
	if from[0] == '/' {
		fromRe = from[1:len(from)-1]
	} else {
		fromRe = fmt.Sprintf(`\b%s\b`, regexp.QuoteMeta(from))
	}

	// log.Printf("from matcher: %#v\n", fromRe)

	cmd := exec.Command("fastmod", "-e", "sol", "--accept-all", fromRe, to)
	return cmd.Run()
}

func run(mappingFile string) error {
	f, err := os.Open(mappingFile)
	if err != nil {
		return err
	}
	defer f.Close()

	s := bufio.NewScanner(f)

	for s.Scan() {
		line := s.Text()

		ms := mappingRE.FindStringSubmatch(line)
		if ms == nil {
			continue
		}

		from := ms[1]
		to := ms[2]

		log.Printf("rename %s %s\n", from, to)
		err = renameSymbol(from, to)
		if err != nil {
			return fmt.Errorf("rename symbol: %w", err)
		}
	}

	return s.Err()
}

func main() {
	err := run("mappings")

	if err != nil {
		log.Fatalln("rename", err)
	}
}