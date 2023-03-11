@tool
extends RefCounted

## - Everything in this script should be static
## - There is one reason to have code in this script
##		1. To separate out code from the main plugin script to ease testing
##
## Common Abbreviations
## et = editor transform (viewport's canvas transform)

const TUP = preload("lib/tuple.gd")

#########
# VERTS #
#########
static func get_intersecting_control_point_in(
	s: SS2D_Shape_Base, et: Transform2D, mouse_pos: Vector2, grab_threshold: float
) -> Array[int]:
	return _get_intersecting_control_point(s, et, mouse_pos, grab_threshold, true)


static func get_intersecting_control_point_out(
	s: SS2D_Shape_Base, et: Transform2D, mouse_pos: Vector2, grab_threshold: float
) -> Array[int]:
	return _get_intersecting_control_point(s, et, mouse_pos, grab_threshold, false)


static func _get_intersecting_control_point(
	s: SS2D_Shape_Base, et: Transform2D, mouse_pos: Vector2, grab_threshold: float, _in: bool
) -> Array[int]:
	var points: Array[int] = []
	var xform: Transform2D = et * s.get_global_transform()
	for i in range(0, s.get_point_count(), 1):
		var key: int = s.get_point_key_at_index(i)
		var vec_pos: Vector2 = s.get_point_position(key)
		var c_pos := Vector2.ZERO
		if _in:
			c_pos = s.get_point_in(key)
		else:
			c_pos = s.get_point_out(key)
		if c_pos == Vector2.ZERO:
			continue
		var final_pos := vec_pos + c_pos
		final_pos = xform * final_pos
		if final_pos.distance_to(mouse_pos) <= grab_threshold:
			points.push_back(key)

	return points

###########
# ACTIONS #
###########
static func action_set_pivot(
	update_node: Node,
	update_method: String,
	undo: UndoRedo,
	s: SS2D_Shape_Base,
	et: Transform2D,
	pos: Vector2
) -> void:
	var old_pos: Vector2 = et * s.get_parent().get_global_transform() * s.position
	undo.create_action("Set Pivot")

	undo.add_do_method(Callable(update_node, update_method).bind(pos))
	undo.add_undo_method(Callable(update_node, update_method).bind(et.affine_inverse() * old_pos))

	undo.commit_action()


static func action_move_verticies(
	update_node: Node, update_method: String, undo: UndoRedo, s: SS2D_Shape_Base, action
) -> void:
	undo.create_action("Move Vertex")

	for i in range(0, action.keys.size(), 1):
		var key = action.keys[i]
		var from_position = action.starting_positions[i]
		var this_position = s.get_point_position(key)
		undo.add_do_method(s.set_point_position.bind(key, this_position))
		undo.add_undo_method(s.set_point_position.bind(key, from_position))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()

static func action_move_control_points(
	update_node: Node,
	update_method: String,
	undo: UndoRedo,
	s: SS2D_Shape_Base,
	action,
	_in: bool,
	_out: bool
) -> void:
	if not _in and not _out:
		return
	undo.create_action("Move Control Point")

	for i in range(0, action.keys.size(), 1):
		var key = action.keys[i]
		var from_position_in = action.starting_positions_control_in[i]
		var from_position_out = action.starting_positions_control_out[i]
		var to_position_in = s.get_point_in(key)
		var to_position_out = s.get_point_out(key)
		if _in:
			undo.add_do_method(s.set_point_in.bind(key, to_position_in))
			undo.add_undo_method(s.set_point_in.bind(key, from_position_in))
		if _out:
			undo.add_do_method(s.set_point_out.bind(key, to_position_out))
			undo.add_undo_method(s.set_point_out.bind(key, from_position_out))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))
	undo.commit_action()

static func action_delete_point_in(
	update_node: Node, update_method: String, undo: UndoRedo, s: SS2D_Shape_Base, key: int
) -> void:
	var from_position_in = s.get_point_in(key)
	undo.create_action("Delete Control Point In")

	undo.add_do_method(s.set_point_in.bind(key, Vector2.ZERO))
	undo.add_undo_method(s.set_point_in.bind(key, from_position_in))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()
	action_invert_orientation(update_node, update_method, undo, s)


static func action_delete_point_out(
	update_node: Node, update_method: String, undo: UndoRedo, s: SS2D_Shape_Base, key: int
) -> void:
	var from_position_out = s.get_point_out(key)
	undo.create_action("Delete Control Point Out")

	undo.add_do_method(s.set_point_out.bind(key, Vector2.ZERO))
	undo.add_undo_method(s.set_point_out.bind(key, from_position_out))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()
	action_invert_orientation(update_node, update_method, undo, s)


static func get_constrained_points_to_delete(s: SS2D_Shape_Base, k: int, keys: Array[int] = []) -> Array[int]:
	keys.push_back(k)
	var constraints: Dictionary = s.get_point_constraints(k)
	for tuple in constraints:
		var constraint: SS2D_Point_Array.CONSTRAINT = constraints[tuple]
		if constraint == SS2D_Point_Array.CONSTRAINT.NONE:
			continue
		var k2: int = TUP.get_other_value_from_tuple(tuple, k)
		if constraint & SS2D_Point_Array.CONSTRAINT.ALL:
			if not keys.has(k2):
				get_constrained_points_to_delete(s, k2, keys)
	return keys


static func action_delete_point(
	update_node: Node, update_method: String, undo: UndoRedo, s: SS2D_Shape_Base, first_key: int
) -> void:
	var dupe: SS2D_Point_Array = s.get_point_array().duplicate(true)
	var keys: Array[int] = get_constrained_points_to_delete(s, first_key)
	undo.create_action("Delete Point")
	for key in keys:
		undo.add_do_method(s.remove_point.bind(key))
	undo.add_undo_method(s.set_point_array.bind(dupe))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()
	action_invert_orientation(update_node, update_method, undo, s)


## Will return key of added point.
static func action_add_point(
	update_node: Node,
	update_method: String,
	undo: UndoRedo,
	s: SS2D_Shape_Base,
	new_point: Vector2,
	idx: int = -1
) -> int:
	var new_key: int = s.get_next_key()
	undo.create_action("Add Point: %s" % new_point)

	undo.add_do_method(s.add_point.bind(new_point, idx, new_key))
	undo.add_undo_method(s.remove_point.bind(new_key))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()
	action_invert_orientation(update_node, update_method, undo, s)
	return new_key



static func action_split_curve(
	update_node: Node,
	update_method: String,
	undo: UndoRedo,
	s: SS2D_Shape_Base,
	idx: int,
	gpoint: Vector2,
	xform: Transform2D
) -> int:
	## Will split the shape at the given index.[br]
	## The key of the new point will be returned.[br]
	## If the orientation is changed, idx will be updated.[br]
	idx = s.adjust_add_point_index(idx)
	undo.create_action("Split Curve")

	undo.add_do_method(s.add_point.bind(xform.affine_inverse() * gpoint, idx))
	undo.add_undo_method(s.remove_point_at_index.bind(idx))

	undo.add_do_method(Callable(update_node, update_method))
	undo.add_undo_method(Callable(update_node, update_method))

	undo.commit_action()
	var key: int = s.get_point_key_at_index(idx)
	action_invert_orientation(update_node, update_method, undo, s)
	return key


static func should_invert_orientation(s: SS2D_Shape_Base) -> bool:
	if s == null:
		return false
	if s is SS2D_Shape_Open:
		return false
	return not s.are_points_clockwise() and s.get_point_count() >= 3


static func action_invert_orientation(
	update_node: Node, update_method: String, undo: UndoRedo, s: SS2D_Shape_Base
) -> bool:
	## Will reverse the orientation of the shape verticies
	## This does not create or commit an undo action on its own
	## It's meant to be included with another action
	## Therefore, the function should be called between a block like so:
	##     undo.create_action("xxx")
	##     action_invert_orientation()-
	##     undo.commit_action()
	if should_invert_orientation(s):
		undo.create_action("Invert Orientation")

		undo.add_do_method(s.invert_point_order)
		undo.add_undo_method(s.invert_point_order)

		undo.add_do_method(Callable(update_node, update_method))
		undo.add_undo_method(Callable(update_node, update_method))

		undo.commit_action()
		return true
	return false
