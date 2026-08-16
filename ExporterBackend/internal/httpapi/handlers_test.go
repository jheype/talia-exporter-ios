package httpapi

import "testing"

func TestNormalisePhone(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "UK spaced", input: "+44 7700 900123", want: "+447700900123"},
		{name: "Brazil punctuation", input: "+55 (11) 99999-9999", want: "+5511999999999"},
		{name: "missing country code", input: "07700900123", wantErr: true},
		{name: "letters", input: "+44 77OO 900123", wantErr: true},
		{name: "too short", input: "+123", wantErr: true},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := normalisePhone(test.input)
			if test.wantErr && err == nil {
				t.Fatalf("normalisePhone(%q) expected error", test.input)
			}
			if !test.wantErr && err != nil {
				t.Fatalf("normalisePhone(%q) unexpected error: %v", test.input, err)
			}
			if got != test.want {
				t.Fatalf("normalisePhone(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}
