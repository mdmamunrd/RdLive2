// Command devtoken prints a short-lived access token for a user id, so you can test the API with
// curl / the WebSocket client without going through Firebase login.
//
//	JWT_SECRET=<same secret as the API> go run ./cmd/devtoken -user 5
//
// DEVELOPMENT ONLY: anyone who knows JWT_SECRET can mint tokens for every account (that is also true of
// the API itself). Never run this against production secrets on a shared machine.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"rdlive/internal/auth"
)

func main() {
	uid := flag.Int64("user", 0, "internal users.id the token is for (required)")
	role := flag.String("role", "user", "role claim (the API re-reads the real role from the database anyway)")
	ttl := flag.Duration("ttl", 12*time.Hour, "token lifetime")
	flag.Parse()

	secret := os.Getenv("JWT_SECRET")
	if len(secret) < 32 {
		log.Fatal("set JWT_SECRET (min 32 chars) to the same value the API uses")
	}
	if *uid <= 0 {
		log.Fatal("-user is required (the numeric users.id, not the 8-digit public id)")
	}
	tok, err := auth.NewTokens(secret, *ttl).Issue(*uid, *role)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(tok)
}
