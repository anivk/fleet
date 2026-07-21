package tray

import (
	"bytes"
	"image/png"
	"testing"
)

func TestIconsAreValidPNG(t *testing.T) {
	cases := []struct {
		name string
		data []byte
	}{
		{"iconKoalaTemplate", iconKoalaTemplate},
		{"iconKoalaRegular", iconKoalaRegular},
		{"iconKoalaAlert", iconKoalaAlert},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if len(c.data) == 0 {
				t.Fatalf("%s: empty icon bytes", c.name)
			}
			img, err := png.Decode(bytes.NewReader(c.data))
			if err != nil {
				t.Fatalf("%s: failed to decode PNG: %v", c.name, err)
			}
			if b := img.Bounds(); b.Dx() == 0 || b.Dy() == 0 {
				t.Fatalf("%s: empty image bounds", c.name)
			}
		})
	}
}
