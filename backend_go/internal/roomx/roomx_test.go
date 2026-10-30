package roomx

import (
	"strings"
	"testing"
)

func TestHashAndCheck(t *testing.T) {
	sec := []byte("server-secret-0123456789abcdef012")
	h := Hash(sec, "1234")
	if !Check(sec, h, "1234") || Check(sec, h, "1235") || Check(sec, h, "") {
		t.Fatal("check wrong")
	}
	if Check([]byte("another-secret-another-secret-00"), h, "1234") {
		t.Fatal("a different server secret must not verify")
	}
	if Hash(sec, "1234") == h {
		t.Fatal("salt must make hashes differ")
	}
	if strings.Contains(h, "1234") {
		t.Fatal("plaintext leaked")
	}
	for _, bad := range []string{"", "v1$x", "v2$a$b", "plain"} {
		if Check(sec, bad, "1234") {
			t.Errorf("malformed hash %q verified", bad)
		}
	}
}

func TestValidPassword(t *testing.T) {
	for _, p := range []string{"1234", "abcd efgh", "পাসওয়ার্ড"} {
		if !ValidPassword(p) {
			t.Errorf("%q should be valid", p)
		}
	}
	for _, p := range []string{"", "123", strings.Repeat("a", 17), "ab\ncd", "ab\x00cd"} {
		if ValidPassword(p) {
			t.Errorf("%q should be invalid", p)
		}
	}
}
