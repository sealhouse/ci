//go:build ignore

// mldsa-key.go writes a throwaway ML-DSA private key to stdout.
package main

import (
	"crypto/mldsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: go run mldsa-key.go ML-DSA-44|ML-DSA-65|ML-DSA-87")
		os.Exit(2)
	}
	params := map[string]func() mldsa.Parameters{
		"ML-DSA-44": mldsa.MLDSA44,
		"ML-DSA-65": mldsa.MLDSA65,
		"ML-DSA-87": mldsa.MLDSA87,
	}[os.Args[1]]
	if params == nil {
		fmt.Fprintf(os.Stderr, "unknown parameter set %q\n", os.Args[1])
		os.Exit(2)
	}
	key, err := mldsa.GenerateKey(params())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := pem.Encode(os.Stdout, &pem.Block{Type: "PRIVATE KEY", Bytes: der}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
