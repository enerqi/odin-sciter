// Streaming video frames into a `<video>` element from Odin.
//
// This is the one part of Sciter's API that is not in `ISciterAPI`. `sciter-x-video-api.h` declares
// `sciter::video_destination` as a C++ class of pure virtual functions with no C declaration at all,
// so there is no slot to call and nothing for the binding generator to see. What the engine hands over
// is a pointer to a C++ object, and using it means laying out its virtual table by hand.
//
// Everything below was measured against the vendored 6.0.4.9 Linux engine rather than read off the
// header - see `docs/RESEARCH-METHOD.md` for why that is the rule here. The measurements that matter:
//
//   - The slot order is the declaration order of `sciter-x-video-api.h`, confirmed against the engine's
//     own `vtable for html::behavior::fragmented_video_destination`, which is a defined symbol in the
//     shipped binary: 13 words, two of Itanium header and eleven functions, in exactly the order
//     `Video_Vtable` below lists them.
//   - `behavior: video` is **backed by libVLC on Linux** and does not attach at all without it. On a
//     machine with no libvlc the element gets no behavior, `element_asset` answers `.OPERATION_FAILED`,
//     and no `VIDEO_BIND_RQ` is ever sent.
//   - `behavior: custom-video` is the one that works with no codec library present. It publishes a SOM
//     asset named `video` whose single method, `renderingSite`, returns the destination. That behavior
//     and that method are in the engine but in none of the SDK's documentation.
//   - The pointer `renderingSite` returns is **not** the destination pointer. It is the behavior's own
//     `som_asset_t`, and the `video_destination` base subobject sits 24 bytes before it.
//     `asset_get_interface` is what knows that offset, so `video_destination` goes through it and
//     never does the arithmetic itself.
//
// The usual shape, all on the engine's thread:
//
//	dest, _ := sciter_app.video_destination(element)
//	sciter_app.video_start_streaming(dest, 640, 480)
//	for frame in frames {
//	    sciter_app.video_render_frame(dest, frame)  // BGRA, top-down
//	}
//	sciter_app.video_stop_streaming(dest)
//
// **Platform note.** The vtable layout is the Itanium C++ ABI's, which is Linux and macOS. Windows
// (MSVC) puts the virtual pointer at offset 0 and orders slots by declaration too, and its x64 calling
// convention passes `this` in the same register position as the first argument, so this is expected to
// work there unchanged - but it is expected, not measured. Nothing else in this repository depends on
// a C++ ABI, and `examples/api_map` cannot check this one.
package sciter_app

import sciter ".."
import "core:c"

// The frame layouts the engine will accept, from `sciter::COLOR_SPACE`.
//
// `.RGB32` is the one to use: it is what the SDK's own generator samples pass, and despite the name the
// bytes are **BGRA**, not RGBA - the same inversion `.RAW` image encoding has (see `graphics.odin`).
Color_Space :: enum c.int {
	Unknown = 0,
	YV12    = 1,
	IYUV    = 2, // a.k.a. I420
	NV12    = 3,
	YUY2    = 4,
	RGB24   = 5,
	RGB555  = 6,
	RGB565  = 7,
	RGB32   = 8, // with alpha; laid out B,G,R,A
}

// Called back when the engine is finished with a buffer handed to `video_render_external_frame`.
// It runs on the engine's thread and must not block.
Frame_Release :: proc "c" (data: [^]byte, user_data: rawptr)

// A `<video>` element's rendering site. Borrowed from the engine: it lives as long as the element's
// behavior does, and `video_is_alive` is how to ask whether that is still true.
Video_Destination :: struct {
	vtbl: ^Video_Vtable,
	isa:  ^sciter.Som_Asset_Class_T, // the som_asset_t base, at +8
}

// `sciter::fragmented_video_destination`'s virtual table, in declaration order. The first four come
// from `sciter::om::iasset`, the next six from `video_destination`, the last from
// `fragmented_video_destination`.
//
// Every engine destination measured so far implements the fragmented one, so `render_frame_part` is
// listed here rather than in a second type - but `video_render_frame_part` still asks for the
// interface by name before using it, because a destination that only implements the unfragmented
// interface would have a twelve-word vtable and calling slot 10 on it would land in whatever follows.
Video_Vtable :: struct {
	asset_add_ref:            proc "c" (this: ^Video_Destination) -> c.long,
	asset_release:            proc "c" (this: ^Video_Destination) -> c.long,
	asset_get_interface:      proc "c" (this: ^Video_Destination, name: cstring, out: ^rawptr) -> c.long,
	asset_get_passport:       proc "c" (this: ^Video_Destination) -> ^sciter.Som_Passport_T,
	is_alive:                 proc "c" (this: ^Video_Destination) -> bool,
	start_streaming:          proc "c" (
		this: ^Video_Destination,
		width, height, color_space: c.int,
		source: rawptr,
	) -> bool,
	stop_streaming:           proc "c" (this: ^Video_Destination) -> bool,
	render_frame:             proc "c" (this: ^Video_Destination, data: [^]byte, size: c.uint) -> bool,
	render_frame_with_stride: proc "c" (this: ^Video_Destination, data: [^]byte, size, stride: c.uint) -> bool,
	render_external_frame:    proc "c" (
		this: ^Video_Destination,
		data: [^]byte,
		size, stride: c.uint,
		release: Frame_Release,
		user_data: rawptr,
	) -> bool,
	render_frame_part:        proc "c" (
		this: ^Video_Destination,
		data: [^]byte,
		size: c.uint,
		x, y, width, height: c.int,
	) -> bool,
}

// The interface names the engine matches on, from `sciter-x-video-api.h`.
VIDEO_DESTINATION_INAME :: "destination.video.sciter.com"
FRAGMENTED_VIDEO_DESTINATION_INAME :: "fragmented.destination.video.sciter.com"

// The rendering site of a `<video>` element carrying `behavior: custom-video`.
//
// `.OPERATION_FAILED` means the element has no video behavior. The usual cause on Linux is a plain
// `behavior: video`, which needs libVLC beside the engine and silently attaches nothing without it -
// `custom-video` is the behavior that always attaches. `.Not_Found` means the behavior is there but
// its passport has no `renderingSite`, which would be a newer or older engine than this was measured
// against.
//
// The destination is borrowed. It stays valid while the element's behavior lives; check
// `video_is_alive` before a frame if the document may have moved on, and stop streaming when it says
// no.
video_destination :: proc(element: Element) -> (dest: ^Video_Destination, err: Error) {
	asset := element_asset(element, "video") or_return

	site := asset_call(asset, "renderingSite") or_return
	defer value_clear(&site)

	site_asset := value_to_asset(&site) or_return

	// The pointer adjustment is the engine's to make, not ours.
	p := asset_interface(site_asset, FRAGMENTED_VIDEO_DESTINATION_INAME)
	if p == nil {
		p = asset_interface(site_asset, VIDEO_DESTINATION_INAME)
	}
	if p == nil {
		return nil, .Not_Found
	}
	return (^Video_Destination)(p), nil
}

// Whether the site can still be drawn into - false once the element is gone or the document unloaded.
// Every render call answers false in that state too, so this is for deciding to stop rather than for
// guarding each frame.
video_is_alive :: proc(dest: ^Video_Destination) -> bool {
	if dest == nil {
		return false
	}
	return dest.vtbl.is_alive(dest)
}

// Announces the frame geometry and starts the stream. Every frame after this must match `width`,
// `height` and `space`.
//
// `source` is a `sciter::video_source*` - a C++ object letting the element's own controls drive
// playback - and there is no way to implement one from Odin, since it is the same kind of hand-laid
// vtable in the opposite direction. Passing nil is what the SDK's own generator samples do, and means
// the document cannot seek or pause; drive it from Odin instead.
video_start_streaming :: proc(
	dest: ^Video_Destination,
	width, height: int,
	space := Color_Space.RGB32,
	source: rawptr = nil,
) -> bool {
	if dest == nil {
		return false
	}
	return dest.vtbl.start_streaming(dest, c.int(width), c.int(height), c.int(space), source)
}

// Ends the stream. The element keeps showing the last frame.
video_stop_streaming :: proc(dest: ^Video_Destination) -> bool {
	if dest == nil {
		return false
	}
	return dest.vtbl.stop_streaming(dest)
}

// Hands over one whole frame. `frame` must hold exactly the `width * height * bytes-per-pixel` the
// stream was started with, packed with no padding between rows - use `video_render_frame_with_stride`
// when the rows are padded.
//
// The engine copies during the call, so the buffer can be reused immediately afterwards. False means
// the site is no longer alive.
video_render_frame :: proc(dest: ^Video_Destination, frame: []byte) -> bool {
	if dest == nil || len(frame) == 0 {
		return false
	}
	return dest.vtbl.render_frame(dest, raw_data(frame), c.uint(len(frame)))
}

// The same, for a buffer whose rows are `stride` bytes apart.
video_render_frame_with_stride :: proc(dest: ^Video_Destination, frame: []byte, stride: int) -> bool {
	if dest == nil || len(frame) == 0 {
		return false
	}
	return dest.vtbl.render_frame_with_stride(dest, raw_data(frame), c.uint(len(frame)), c.uint(stride))
}

// Hands over a frame the engine will read *later*, from the caller's own memory, and calls `release`
// when it is finished with it.
//
// This is the zero-copy path: the buffer goes into a queue for upload to the GPU, so it must stay
// valid and unmodified until `release` runs. `release` is called on the engine's thread.
//
// Nothing in this package keeps `user_data` alive - it is passed straight through and comes back
// untouched.
video_render_external_frame :: proc(
	dest: ^Video_Destination,
	frame: []byte,
	stride: int,
	release: Frame_Release,
	user_data: rawptr = nil,
) -> bool {
	if dest == nil || len(frame) == 0 || release == nil {
		return false
	}
	return dest.vtbl.render_external_frame(
		dest,
		raw_data(frame),
		c.uint(len(frame)),
		c.uint(stride),
		release,
		user_data,
	)
}

// Updates a rectangle of the frame rather than all of it, which is what a source producing small
// changes at a high rate wants. `frame` holds just that rectangle, `width * height` pixels packed.
//
// False if the destination does not implement the fragmented interface, as well as if it is not alive.
video_render_frame_part :: proc(dest: ^Video_Destination, frame: []byte, x, y, width, height: int) -> bool {
	if dest == nil || len(frame) == 0 {
		return false
	}
	out: rawptr
	if dest.vtbl.asset_get_interface(dest, FRAGMENTED_VIDEO_DESTINATION_INAME, &out) == 0 {
		return false
	}
	return dest.vtbl.render_frame_part(
		dest,
		raw_data(frame),
		c.uint(len(frame)),
		c.int(x),
		c.int(y),
		c.int(width),
		c.int(height),
	)
}

// Takes a reference of the caller's own, for a destination that has to outlive the call it arrived in -
// a worker thread producing frames, which is the case this exists for. Pair with `video_release`.
//
// The rendering calls are **not** thread safe. A worker may hold a reference and check `video_is_alive`,
// but the frames themselves go through `post_callback` onto the engine's thread.
video_add_ref :: proc(dest: ^Video_Destination) {
	if dest != nil {
		dest.vtbl.asset_add_ref(dest)
	}
}

// Drops a reference taken by `video_add_ref`.
video_release :: proc(dest: ^Video_Destination) {
	if dest != nil {
		dest.vtbl.asset_release(dest)
	}
}
