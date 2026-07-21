package tray

import "testing"

// TestEscapeQuotes verifies escapeQuotes produces AppleScript string
// literals that cannot be broken out of, even when the input contains
// quotes and/or backslashes. It does not fire any real notification.
func TestEscapeQuotes(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain", "hello world", "hello world"},
		{"single quote", `say "hi"`, `say \"hi\"`},
		{
			// A naive implementation that only escapes quotes would turn
			// `\"` into `\\"` — which AppleScript parses as an escaped
			// backslash followed by an unescaped, string-terminating
			// quote. escapeQuotes must escape the backslash too so the
			// output stays inside the literal.
			"backslash then quote",
			`\" with title "pwned`,
			`\\\" with title \"pwned`,
		},
		{"lone backslash", `C:\path\to\file`, `C:\\path\\to\\file`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := escapeQuotes(c.in)
			if got != c.want {
				t.Errorf("escapeQuotes(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

// TestQ verifies q wraps the escaped text in a well-formed AppleScript
// string literal: exactly one leading and one trailing unescaped double
// quote, with every quote/backslash in between escaped.
func TestQ(t *testing.T) {
	in := `break "out" \ and inject`
	got := q(in)
	want := `"break \"out\" \\ and inject"`
	if got != want {
		t.Errorf("q(%q) = %q, want %q", in, got, want)
	}
	if len(got) < 2 || got[0] != '"' || got[len(got)-1] != '"' {
		t.Fatalf("q(%q) = %q, not wrapped in a single pair of quotes", in, got)
	}
}
