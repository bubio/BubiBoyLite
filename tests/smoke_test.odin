package tests

import "core:testing"
import core "bbl:core"

@(test)
test_screen_width :: proc(t: ^testing.T) {
	testing.expect(t, core.SCREEN_WIDTH == 160)
}
