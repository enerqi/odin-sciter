// Attaching the SDK's inspector to a running window.
//
//   just example inspector
//
// Sciter ships a DevTools-style inspector as a separate application. It attaches over a socket to any
// window created with `.ENABLE_DEBUG`, and gives you the DOM tree, the computed styles, a script
// console and a debugger - the same things a browser's developer tools do.
//
// There are three halves - the name is wrong and the count is right, because the third one is the one
// everybody misses:
//
//   1. the window must be created with `.ENABLE_DEBUG`. Without it the window is invisible to the
//      inspector, and there is no way to enable it afterwards.
//   2. `SCITER_SET_DEBUG_MODE` must be on, which is what makes the engine listen. This example sets it
//      before creating the window.
//   3. **the script runtime must be allowed `.SOCKET_IO`**, because the connection is a socket opened
//      by the document's own runtime. With 1 and 2 and not 3 the inspector waits forever on "Waiting
//      for a connection with Sciter's view", which reads as a problem with 1 or 2.
//
// Then run the SDK's inspector next to it:
//
//   ./sciter-js-sdk/bin/linux/x64/inspector
//
// **Start the inspector first if it does not pick the app up.** Its own screen says so, and once both
// are running `CTRL+SHIFT+I` in the app's window connects the current view by hand.
//
// It is not vendored here - `lib/` carries the engine only. Get it from the SDK checkout described in
// docs/PLAN.md section 1.
package main

import "../sciter_app"
import "core:fmt"
import "core:os"

DOC :: `<html>
<head>
  <title>odin-sciter: inspector</title>
  <style>
  html   { background: #1e1e2e; color: #cdd6f4; font: 16px system; }
  body   { padding: 2em; margin: 0; }
  h1     { color: #89b4fa; margin-top: 0; }
  code   { background: #313244; padding: 0 .3em; border-radius: 3px; }
  #probe { padding: 1em; margin-top: 1em; background: #313244; border-radius: 4px; }
  .hot   { color: #f38ba8; }
  </style>
  <script type="module">
    // Something for the inspector's console and debugger to look at.
    globalThis.counter = 0;
    globalThis.bump = function() {
      globalThis.counter += 1;
      document.$("#probe").innerText = "counter = " + globalThis.counter;
      return globalThis.counter;
    }
  </script>
</head>
<body>
  <h1>inspector</h1>
  <p>
    This window was created with <code>.ENABLE_DEBUG</code>. Start the SDK's
    <code>inspector</code> and it will find this window.
  </p>
  <p>Things to try once it is attached:</p>
  <ul>
    <li>select <code>#probe</code> in the DOM tree and edit its style live</li>
    <li>run <code>bump()</code> in the console &mdash; it is defined in this document</li>
    <li>add the class <code class="hot">hot</code> to the heading and watch it turn red</li>
  </ul>
  <div id="probe">counter = 0</div>
</body>
</html>`

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	if err := sciter_app.init(); err != nil {
		fmt.eprintln("init failed:", err)
		os.exit(1)
	}

	// **Half one, and the one that is easy to miss: the connection is a socket, made by the document's
	// own script runtime, so the runtime has to be allowed to open one.** Without `.SOCKET_IO` the
	// window is inspectable in every other respect and the inspector sits on "Waiting for a connection
	// with Sciter's view" forever, which looks like the flags below being wrong rather than this being
	// missing. `.FILE_IO` is wanted alongside it - the inspector's own notice asks for both - and
	// `.EVAL` and `.SYSINFO` are what make its console and environment panes work.
	//
	// This is a security decision, not a formality: it is the same switch that lets any document this
	// window loads read the filesystem and open sockets. Turn it on for a debug build, not for a
	// shipped one.
	if err := sciter_app.set_script_features({.FILE_IO, .SOCKET_IO, .EVAL, .SYSINFO}); err != nil {
		fmt.eprintln("could not enable script features:", err)
		os.exit(1)
	}

	// Half two: make the engine listen for an inspector. This is a global option, so it is set with a
	// nil window and it has to happen before the window exists.
	if err := sciter_app.set_debug_mode(); err != nil {
		fmt.eprintln("could not enable debug mode:", err)
		os.exit(1)
	}

	// Half three: mark the window as inspectable. There is no way to add this later.
	window, werr := sciter_app.create_window({width = 760, height = 560, flags = {.MAIN, .ENABLE_DEBUG}})
	if werr != nil {
		fmt.eprintln("could not create a window:", werr)
		os.exit(1)
	}
	if err := sciter_app.load_html(window, DOC); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}

	fmt.println("window is inspectable - run the SDK's `inspector` to attach")
	fmt.println("(bin/<platform>/inspector in the sciter-js-sdk checkout; not vendored here)")

	sciter_app.show(window)
	sciter_app.run()
	sciter_app.shutdown()
}
