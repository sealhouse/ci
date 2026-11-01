// semver compares two Go module versions.
package main

import (
	"fmt"
	"os"

	"golang.org/x/mod/semver"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: semver V W")
		os.Exit(2)
	}
	for _, v := range os.Args[1:] {
		if !semver.IsValid(v) {
			fmt.Fprintf(os.Stderr, "semver: %q is not a semantic version\n", v)
			os.Exit(2)
		}
	}
	fmt.Println(semver.Compare(os.Args[1], os.Args[2]))
}
