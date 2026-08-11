// Nodes: the half of the DOM that is not elements.
//
// `dom.odin` walks elements, which is what an application wants nearly all of the time. A document is
// really a tree of *nodes*, though - text and comments are nodes with no element wrapping them - and
// there are jobs that need that view: reading the text around an inline `<b>` without flattening it,
// inserting a text node between two elements, or walking a document exactly as it is written.
//
// Two rules, both from the C API and neither hidden here:
//
//   - **node handles are not reference counted on the way out.** `sciter-x-dom.h` says it plainly:
//     "node handles returned by functions below are not AddRef'ed". A handle is valid while the node
//     is in the document, and holding one past that needs `node_add_ref` / `node_release` - the same
//     arrangement as `use_element`, with a different spelling upstream.
//   - **a detached node is owned by you.** `make_text_node` and `make_comment_node` return a node that
//     is in no document. Insert it, or release it, or it leaks.
package sciter_app

import sciter ".."

// ---------------------------------------------------------------------------------------------------
// Lifetime

// Keeps the node alive while a handle to it is held. Pair with `node_release`.
node_add_ref :: proc(node: Node) -> Error {
	return dom_err(sciter.api().SciterNodeAddRef(sciter.Hnode(node)))
}

node_release :: proc(node: Node) -> Error {
	return dom_err(sciter.api().SciterNodeRelease(sciter.Hnode(node)))
}

// ---------------------------------------------------------------------------------------------------
// Crossing between the two views

// The node view of an element. Every element is a node; the reverse is not true.
node_from_element :: proc(element: Element) -> (node: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodeCastFromElement(sciter.Helement(element), &hn)) or_return
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// The element a node is, or `.Not_Found` when it is a text or comment node. Check `node_type` first if
// the distinction matters more than the failure.
node_to_element :: proc(node: Node) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterNodeCastToElement(sciter.Hnode(node), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

node_type :: proc(node: Node) -> (type: sciter.Node_Type, err: Error) {
	dom_err(sciter.api().SciterNodeType(sciter.Hnode(node), &type)) or_return
	return type, nil
}

// ---------------------------------------------------------------------------------------------------
// Nodes as Values
//
// The node half of `element_to_value` / `element_from_value`, and the only way to hand script a text
// or comment node. The rules are the same: the Value owns a reference, the handle that comes back is
// borrowed, and the wrapped Value is a `.RESOURCE` that renders as `""`.
//
// The two directions are not symmetric, because an element *is* a node and a text node is not an
// element: `node_from_value` accepts a Value made by either `node_to_value` or `element_to_value`,
// while `element_from_value` fails with `.OPERATION_FAILED` on a text node's Value.

node_to_value :: proc(node: Node) -> (v: Value, err: Error) {
	dom_err(sciter.Scdom_Result(sciter.api().SciterNodeWrap(&v, sciter.Hnode(node)))) or_return
	return v, nil
}

node_from_value :: proc(v: ^Value) -> (node: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.Scdom_Result(sciter.api().SciterNodeUnwrap(v, &hn))) or_return
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// ---------------------------------------------------------------------------------------------------
// Traversal
//
// Each returns `.Not_Found` at the end of the walk rather than a nil handle, so the error is the
// termination condition:
//
//	for child, err := node_first_child(root); err == nil; child, err = node_next_sibling(child) {
//		// ...
//	}

node_child_count :: proc(node: Node) -> (n: int, err: Error) {
	count: u32
	dom_err(sciter.api().SciterNodeChildrenCount(sciter.Hnode(node), &count)) or_return
	return int(count), nil
}

node_child :: proc(node: Node, n: int) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodeNthChild(sciter.Hnode(node), u32(n), &hn)) or_return
	return found_node(hn)
}

node_first_child :: proc(node: Node) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodeFirstChild(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_last_child :: proc(node: Node) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodeLastChild(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_next_sibling :: proc(node: Node) -> (sibling: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodeNextSibling(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_prev_sibling :: proc(node: Node) -> (sibling: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.api().SciterNodePrevSibling(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

// The parent, which is always an element - only an element can contain nodes.
node_parent :: proc(node: Node) -> (parent: Element, err: Error) {
	he: sciter.Helement
	dom_err(sciter.api().SciterNodeParent(sciter.Hnode(node), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// The engine reports "there is no such node" as OK plus a null handle. Every traversal above turns
// that into `.Not_Found`, so a walk terminates on the error rather than on a nil check.
@(private = "file")
found_node :: proc(hn: sciter.Hnode) -> (node: Node, err: Error) {
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// ---------------------------------------------------------------------------------------------------
// Text

// The text of a text or comment node, allocated in `allocator`. On an element node the engine reports
// nothing - use `text(element)` for that.
node_text :: proc(node: Node, allocator := context.allocator) -> (text: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(sciter.api().SciterNodeGetText(sciter.Hnode(node), wide_receiver, &sink)) or_return
	return sink.out, nil
}

node_set_text :: proc(node: Node, text: string) -> Error {
	w := utf16_from_string(text, context.temp_allocator)
	return dom_err(sciter.api().SciterNodeSetText(sciter.Hnode(node), raw_data(w), u32(len(w) - 1)))
}

// ---------------------------------------------------------------------------------------------------
// Creating and moving nodes

// A detached text node. It belongs to the caller until `node_insert` puts it in a document.
make_text_node :: proc(text: string) -> (node: Node, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	hn: sciter.Hnode
	dom_err(sciter.api().SciterCreateTextNode(raw_data(w), u32(len(w) - 1), &hn)) or_return
	return Node(hn), nil
}

// A detached comment node. Same ownership as `make_text_node`.
make_comment_node :: proc(text: string) -> (node: Node, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	hn: sciter.Hnode
	dom_err(sciter.api().SciterCreateCommentNode(raw_data(w), u32(len(w) - 1), &hn)) or_return
	return Node(hn), nil
}

// Puts `what` into the document, positioned relative to `node`: `.BEFORE`, `.AFTER`, `.APPEND` (as the
// last child of `node`) or `.PREPEND` (as the first). The document takes ownership from here.
node_insert :: proc(node: Node, where_: sciter.Node_Ins_Target, what: Node) -> Error {
	return dom_err(sciter.api().SciterNodeInsert(sciter.Hnode(node), u32(where_), sciter.Hnode(what)))
}

// Takes the node out of the document. `finalize = true` destroys it; `false` detaches it and hands
// ownership back to the caller, which is what a move between two places in the document wants.
node_remove :: proc(node: Node, finalize := true) -> Error {
	return dom_err(sciter.api().SciterNodeRemove(sciter.Hnode(node), b32(finalize)))
}
