// A window with some HTML in it, using nothing but the generated bindings.
//
//   just run hello_window        (or: odin run examples/hello_window.odin -file)
//
// This is the spike that proves the whole approach: one shared library opened at runtime, one exported
// symbol, and every call made through the ISciterAPI function table. Note what is NOT here - no GTK on
// Linux, no Win32 message loop, no Cocoa. `SciterExec(.LOOP)` is Sciter's own cross-platform message
// pump, so the same source builds and runs on all three desktop platforms.
package main

import sciter ".."
import "core:fmt"
import "core:os"
import "core:unicode/utf16"

HTML :: `<html>
<head><style>
  body { background: #1e1e2e; color: #cdd6f4; font: 16px system; padding: 2em; }
  h1   { color: #89b4fa; }
  code { background: #313244; padding: 0 .3em; border-radius: 3px; }
</style></head>
<body>
  <h1>Hello from Odin</h1>
  <p>This window is <code>libsciter.so</code> driven through <code>ISciterAPI</code>.</p>
  <p>Everything you see is HTML and CSS rendered by the Sciter engine.</p>
</body>
</html>`

main :: proc() {
	// 1. Open the engine. Nothing else may be called before this succeeds.
	//
	// `tried` is the candidate list, and it comes back on **every** path, success included - each string
	// separately allocated, and nothing else owns it. Freeing it is the caller's, which is why the defer
	// is here and not only on the failure branch. `sciter_app.load_engine` is this whole block in one
	// call; see docs/rules.md §4.
	err, tried := sciter.load()
	defer {
		for candidate in tried {
			delete(candidate)
		}
		delete(tried)
	}
	if err != .None {
		fmt.eprintfln("could not load the Sciter engine: %v", err)
		fmt.eprintln("looked for", sciter.LIBRARY_NAME, "in:")
		for candidate in tried {
			fmt.eprintfln("  %s", candidate)
		}
		fmt.eprintln("\nSet SCITER_LIB to the library file or its directory, e.g.")
		fmt.eprintln("  SCITER_LIB=/path/to/sciter-js-sdk/bin/linux/x64 just run hello_window")
		os.exit(1)
	}
	api := sciter.api()

	// SciterVersion(n) returns component n of the [v0,v1,v2,v3] version vector.
	fmt.printfln(
		"Sciter %d.%d.%d.%d, ISciterAPI version %d",
		api.SciterVersion(0),
		api.SciterVersion(1),
		api.SciterVersion(2),
		api.SciterVersion(3),
		api.version,
	)

	// 2. Hand the engine argc/argv. It wants this before any window exists.
	//    Note: despite what the comment on SCITER_APP_INIT in sciter-x-def.h says ("p2 - CHAR** argv"),
	//    the engine expects UTF-16 - see application::start() in sciter-x-window.hpp, which builds a
	//    vector<const WCHAR*>. Passing char** or NULL crashes.
	arg0: [64]u16
	utf16.encode_string(arg0[:], "odin-sciter")
	argv: [1][^]u16 = {raw_data(arg0[:])}
	api.SciterExec(.INIT, 1, uintptr(rawptr(&argv[0])))

	// 3. Create a top-level window. SW_MAIN is what makes closing it end the message loop; SW_ENABLE_DEBUG
	//    lets the SDK's `inspector` attach. Sciter 6 commented out the SW_TITLEBAR / SW_RESIZEABLE /
	//    SW_CONTROLS / SW_GLASSY / SW_ALPHA / SW_TOOL flags that 4.x had - a plain top-level window is
	//    now the default and window chrome is styled from CSS instead.
	flags := sciter.Sciter_Create_Window_Flags{.MAIN, .ENABLE_DEBUG}

	frame := sciter.Tag_Rect {
		left   = 200,
		top    = 200,
		right  = 200 + 720,
		bottom = 200 + 480,
	}

	window := api.SciterCreateWindow(flags, &frame, nil, nil, nil)
	if window == nil {
		fmt.eprintln("SciterCreateWindow failed")
		os.exit(1)
	}

	// 4. Load the document. SciterLoadHtml takes UTF-8 bytes plus a base URL for relative references.
	html := HTML
	if !api.SciterLoadHtml(window, raw_data(html), u32(len(html)), nil) {
		fmt.eprintln("SciterLoadHtml failed")
		os.exit(1)
	}

	// 5. Show it, then run Sciter's own message pump until the window closes.
	// `p1` stays a bare uintptr: it is a window state only for SET_STATE - for SET_PLACEMENT it is a
	// `POINT*`, for ACTIVATE a boolean - so there is no one type the bindings could give it.
	api.SciterWindowExec(window, .SET_STATE, uintptr(sciter.Sciter_Window_State.SHOWN), 0)
	api.SciterExec(.LOOP, 0, 0)
	api.SciterExec(.SHUTDOWN, 0, 0)
}
