# open-tabletop
# Copyright (c) 2020-2021 Benjamin 'drwhut' Beddows
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

extends Spatial

signal setting_spawn_point(position)
signal spawning_piece_at(position)
signal table_flipped(table_reset)

onready var _camera_controller = $CameraController
onready var _hand_positions = $Table/HandPositions
onready var _hands = $Hands
onready var _hidden_areas = $HiddenAreas
onready var _hidden_area_preview = $HiddenAreaPreview
onready var _pieces = $Pieces
onready var _spot_light = $SpotLight
onready var _sun_light = $SunLight
onready var _table_body = $Table/Body
onready var _world_environment = $WorldEnvironment

var _srv_next_piece_name = 0
var _srv_retrieve_pieces_from_hell = true
var _table_preflip_state: Dictionary = {}

# Add a hand to the game for a given player.
# player: The ID of the player the hand should belong to.
# transform: The transform of the new hand.
remotesync func add_hand(player: int, transform: Transform) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var hand = preload("res://Scenes/Game/3D/Hand.tscn").instance()
	hand.name = str(player)
	hand.transform = transform
	
	hand.update_owner_display()
	_hands.add_child(hand)

# Called by the server to add a piece to the room.
# name: The name of the new piece.
# transform: The initial transform of the new piece.
# piece_entry: The piece's entry in the AssetDB.
# hover_player: If set to > 0, it will initially be in a hover state by the
# player with the given ID.
remotesync func add_piece(name: String, transform: Transform,
	piece_entry: Dictionary) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var piece = PieceBuilder.build_piece(piece_entry)
	
	piece.name = name
	piece.transform = transform
	
	if get_tree().is_network_server():
		piece.srv_retrieve_from_hell = _srv_retrieve_pieces_from_hell
	
	piece.connect("piece_exiting_tree", self, "_on_piece_exiting_tree")
	
	# If it is a stackable piece, make sure we attach the signal it emits when
	# it wants to create a stack.
	if piece is StackablePiece:
		piece.connect("stack_requested", self, "_on_stack_requested")
	
	# If it is a container, make sure we attach the signal it emits when it
	# wants to absorb or release a piece.
	if piece is PieceContainer:
		piece.connect("absorbing_piece", self, "_on_container_absorbing_piece")
		piece.connect("releasing_random_piece", self, "_on_container_releasing_random_piece")
	
	_pieces.add_child(piece)

# Called by the server to add a piece to a container, a.k.a. having the piece
# be "absorbed" by the container.
# container_name: The name of the container that is absorbing the piece.
# piece_name: The name of the piece that the container is absorbing.
remotesync func add_piece_to_container(container_name: String, piece_name: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var container = _pieces.get_node(container_name)
	var piece     = _pieces.get_node(piece_name)
	
	if not container:
		push_error("Container " + container_name + " does not exist!")
		return
	
	if not piece:
		push_error("Piece " + piece_name + " does not exist!")
		return
	
	if not container is PieceContainer:
		push_error("Piece " + container_name + " is not a container!")
		return
	
	if not piece is Piece:
		push_error("Object " + piece_name + " is not a piece!")
		return
	
	_pieces.remove_child(piece)
	container.add_piece(piece)

# Called by the server to add a piece to a stack.
# piece_name: The name of the piece.
# stack_name: The name of the stack.
# on: Where to add the piece to in the stack.
# flip: Should the piece be flipped upon entering the stack?
remotesync func add_piece_to_stack(piece_name: String, stack_name: String,
	on: int = Stack.STACK_AUTO, flip: int = Stack.FLIP_AUTO) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var piece = _pieces.get_node(piece_name)
	var stack = _pieces.get_node(stack_name)
	
	if not piece:
		push_error("Piece " + stack_name + " does not exist!")
		return
	
	if not stack:
		push_error("Stack " + stack_name + " does not exist!")
		return
	
	if not piece is StackablePiece:
		push_error("Piece " + piece_name + " is not stackable!")
		return
	
	if not stack is Stack:
		push_error("Piece " + stack_name + " is not a stack!")
		return
	
	_pieces.remove_child(piece)
	
	var piece_meshes = PieceBuilder.get_piece_meshes(piece)
	if piece_meshes.size() != 1:
		push_error("Piece " + piece_name + " does not have one mesh instance!")
		return
	
	var piece_shapes = piece.get_collision_shapes()
	if piece_shapes.size() != 1:
		push_error("Piece " + piece_name + " does not have one collision shape!")
		return
	
	stack.add_piece(piece_meshes[0], piece_shapes[0], on, flip)
	
	piece.queue_free()

# Called by the server to add a stack to the room with 2 initial pieces.
# name: The name of the new stack.
# transform: The initial transform of the new stack.
# piece1_name: The name of the first piece to add to the stack.
# piece2_name: The name of the second piece to add to the stack.
remotesync func add_stack(name: String, transform: Transform,
	piece1_name: String, piece2_name: String) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var piece1 = _pieces.get_node(piece1_name)
	var piece2 = _pieces.get_node(piece2_name)
	
	if not piece1:
		push_error("Stackable piece " + piece1_name + " does not exist!")
		return
	
	if not piece2:
		push_error("Stackable piece " + piece2_name + " does not exist!")
		return
	
	if not piece1 is StackablePiece:
		push_error("Piece " + piece1_name + " is not stackable!")
		return
	
	if not piece2 is StackablePiece:
		push_error("Piece " + piece2_name + " is not stackable!")
		return
	
	_pieces.remove_child(piece1)
	_pieces.remove_child(piece2)
	
	var piece1_meshes = PieceBuilder.get_piece_meshes(piece1)
	if piece1_meshes.size() != 1:
		push_error("Piece " + piece1_name + " does not have one mesh instance!")
		return
	
	var piece2_meshes = PieceBuilder.get_piece_meshes(piece2)
	if piece2_meshes.size() != 1:
		push_error("Piece " + piece2_name + " does not have one mesh instance!")
		return
	
	var piece1_shapes = piece1.get_collision_shapes()
	if piece1_shapes.size() != 1:
		push_error("Piece " + piece1_name + " does not have one collision shape!")
		return
	
	var piece2_shapes = piece2.get_collision_shapes()
	if piece2_shapes.size() != 1:
		push_error("Piece " + piece2_name + " does not have one collision shape!")
		return
	
	var stack = add_stack_empty(name, transform)
	
	stack.add_piece(piece1_meshes[0], piece1_shapes[0])
	stack.add_piece(piece2_meshes[0], piece2_shapes[0])
	
	piece1.queue_free()
	piece2.queue_free()

# Called by the server to add an empty stack to the room.
# name: The name of the new stack.
# transform: The initial transform of the new stack.
puppet func add_stack_empty(name: String, transform: Transform) -> Stack:
	
	# Special case here, where we don't want the RPC to be sent to the server,
	# but the server needs the stack to be returned.
	if not (get_tree().is_network_server() or get_tree().get_rpc_sender_id() == 1):
		return null
	
	var stack: Stack = preload("res://Pieces/Stack.tscn").instance()
	
	stack.name = name
	stack.transform = transform
	
	if get_tree().is_network_server():
		stack.srv_retrieve_from_hell = _srv_retrieve_pieces_from_hell
	
	_pieces.add_child(stack)
	
	stack.connect("piece_exiting_tree", self, "_on_piece_exiting_tree")
	stack.connect("stack_requested", self, "_on_stack_requested")
	
	return stack

# Called by the server to add a pre-filled stack to the room.
# name: The name of the new stack.
# transform: The initial transform of the new stack.
# stack_entry: The stack's entry in the AssetDB.
# piece_names: The names of the pieces in the newly filled stack.
remotesync func add_stack_filled(name: String, transform: Transform,
	stack_entry: Dictionary, piece_names: Array) -> void:
	
	var stack = add_stack_empty(name, transform)
	PieceBuilder.fill_stack(stack, stack_entry)
	
	for i in range(stack.get_piece_count()):
		if i >= piece_names.size():
			break
		
		stack.get_pieces()[i].name = piece_names[i]

# Called by the server to merge the contents of one stack into another stack.
# stack1_name: The name of the stack to merge contents from.
# stack2_name: The name of the stack to merge contents to.
remotesync func add_stack_to_stack(stack1_name: String, stack2_name: String) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var stack1 = _pieces.get_node(stack1_name)
	var stack2 = _pieces.get_node(stack2_name)
	
	if not stack1:
		push_error("Stack " + stack1_name + " does not exist!")
		return
	
	if not stack2:
		push_error("Stack " + stack2_name + " does not exist!")
		return
	
	if not stack1 is Stack:
		push_error("Piece " + stack1_name + " is not a stack!")
		return
	
	if not stack2 is Stack:
		push_error("Piece " + stack2_name + " is not a stack!")
		return
	
	# If there are no children in the first stack, don't bother doing anything.
	if stack1.get_piece_count() == 0:
		return
	
	# We need to determine in which order to add the children of the first stack
	# to the second stack.
	# NOTE: In stacks, children are stored bottom-first.
	var reverse = false
	
	if stack1.transform.origin.y > stack2.transform.origin.y:
		reverse = stack1.transform.basis.y.y < 0
	else:
		reverse = stack1.transform.basis.y.y > 0
	
	# Remove the children of the first stack, determine their transform, then
	# add them to the second stack.
	var pieces = stack1.empty()
	if reverse:
		pieces.invert()
	
	for piece in pieces:
		var basis = piece.transform.basis
		var origin = piece.transform.origin
		
		basis = stack1.transform.basis * basis
		origin = stack1.transform.origin + origin
		
		piece.transform = Transform(basis, origin)
		
		stack2.add_piece(piece, null)
	
	# Finally, delete the first stack.
	_pieces.remove_child(stack1)
	stack1.queue_free()

# Apply options from the options menu.
# config: The options to apply.
func apply_options(config: ConfigFile) -> void:
	_camera_controller.apply_options(config)

# Flip the table.
# camera_basis: The basis matrix of the player flipping the table.
remotesync func flip_table(camera_basis: Basis) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	_table_preflip_state = get_state(false, false)
	
	_table_body.mode = RigidBody.MODE_RIGID
	
	var left = -camera_basis.x
	var diagonal = -camera_basis.z
	diagonal.y = 0.5
	diagonal = diagonal.normalized()
	_table_body.apply_central_impulse(_table_body.mass * 100 * diagonal)
	_table_body.apply_torque_impulse(_table_body.mass * 2000 * left)
	
	if get_tree().is_network_server():
		srv_set_retrieve_pieces_from_hell(false)
	
	emit_signal("table_flipped", false)

# Get the player camera's hover position.
# Returns: The current hover position.
func get_camera_hover_position() -> Vector3:
	return _camera_controller.get_hover_position()

# Get the camera controller's transform.
# Returns: The camera controller's transform.
func get_camera_transform() -> Transform:
	return _camera_controller.transform

# Get the color of the room lamp.
# Returns: The color of the lamp.
func get_lamp_color() -> Color:
	if _sun_light.visible:
		return _sun_light.light_color
	else:
		return _spot_light.light_color

# Get the intensity of the room lamp.
# Returns: The intensity of the lamp.
func get_lamp_intensity() -> float:
	if _sun_light.visible:
		return _sun_light.light_energy
	else:
		return _spot_light.light_energy

# Get the type of light the room lamp is emitting.
# Returns: True if the lamp is sunlight, false if it is a spotlight.
func get_lamp_type() -> bool:
	return _sun_light.visible

# Get a piece in the room with a given name.
# Returns: The piece with the given name.
# name: The name of the piece.
func get_piece_with_name(name: String) -> Piece:
	return _pieces.get_node(name)

# Get the list of pieces in the room.
# Returns: The list of pieces in the room.
func get_pieces() -> Array:
	return _pieces.get_children()

# Get the number of pieces in the room.
# Returns: The number of pieces in the room.
func get_piece_count() -> int:
	return _pieces.get_child_count()

# Get the current skybox's entry in the asset DB.
# Returns: The current skybox's entry, empty if it is using the default skybox.
func get_skybox() -> Dictionary:
	if _world_environment.has_meta("skybox_entry"):
		var skybox_entry = _world_environment.get_meta("skybox_entry")
		if skybox_entry.has("texture_path"):
			if not skybox_entry["texture_path"].empty():
				return skybox_entry
	
	return {}

# Get the current room state.
# Returns: The current room state.
# hands: Should the hand states be included?
# collisions: Should collision data be included?
func get_state(hands: bool = false, collisions: bool = false) -> Dictionary:
	var out = {}
	out["version"] = ProjectSettings.get_setting("application/config/version")
	
	out["lamp"] = {
		"color": get_lamp_color(),
		"intensity": get_lamp_intensity(),
		"sunlight": get_lamp_type()
	}
	out["skybox"] = get_skybox()
	out["table"] = {
		"is_rigid": _table_body.mode == RigidBody.MODE_RIGID,
		"preflip_state": _table_preflip_state,
		"transform": _table_body.transform
	}
	
	if hands:
		var hand_dict = {}
		for hand in _hands.get_children():
			var hand_meta = {
				"transform": hand.transform
			}
			
			hand_dict[hand.owner_id()] = hand_meta
		
		out["hands"] = hand_dict
	
	var hidden_area_dict = {}
	for hidden_area in _hidden_areas.get_children():
		if hidden_area is HiddenArea:
			# Convert the transform of the hidden area to corner points so the
			# set_state() function can re-use the function that creates the
			# hidden area.
			var area_origin = hidden_area.transform.origin
			var area_scale  = hidden_area.transform.basis.get_scale()
			var point1_v3 = area_origin - area_scale
			var point2_v3 = area_origin + area_scale
			var hidden_area_meta = {
				"player_id": hidden_area.player_id,
				"point1": Vector2(point1_v3.x, point1_v3.z),
				"point2": Vector2(point2_v3.x, point2_v3.z)
			}
			
			hidden_area_dict[hidden_area.name] = hidden_area_meta
	
	out["hidden_areas"] = hidden_area_dict
	
	_append_piece_states(out, _pieces, collisions)
	
	return out

# Called by the server to place a hidden area for a given player.
# area_name: The name of the new hidden area.
# player_id: The player the hidden area is registered to.
# point1: One corner of the hidden area.
# point2: The opposite corner of the hidden area.
remotesync func place_hidden_area(area_name: String, player_id: int,
	point1: Vector2, point2: Vector2) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var hidden_area: HiddenArea = preload("res://Scenes/Game/3D/HiddenArea.tscn").instance()
	hidden_area.name = area_name
	hidden_area.player_id = player_id
	_set_hidden_area_transform(hidden_area, point1, point2)
	
	_hidden_areas.add_child(hidden_area)
	hidden_area.update_player_color()

# Remove a player's hand from the room.
# player: The ID of the player whose hand to remove.
remotesync func remove_hand(player: int) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var hand = _hands.get_node(str(player))
	if hand:
		_hands.remove_child(hand)
		hand.queue_free()

# Called by the server to remove a hidden area from the table.
# area_name: The name of the hidden area to remove.
remotesync func remove_hidden_area(area_name: String) -> void:
	var hidden_area = _hidden_areas.get_node(area_name)
	
	if not hidden_area:
		push_error("Hidden area " + area_name + " does not exist!")
		return
	
	if not hidden_area is HiddenArea:
		push_error("Node " + area_name + " is not a hidden area!")
		return
	
	_hidden_areas.remove_child(hidden_area)
	hidden_area.queue_free()

# Called by the server to remove a piece from a container, a.k.a. having the
# piece be "released" by the container.
# container_name: The name of the container that is absorbing the piece.
# piece_name: The name of the piece that the container is releasing.
remotesync func remove_piece_from_container(container_name: String, piece_name: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var container = _pieces.get_node(container_name)
	
	if not container:
		push_error("Container " + container_name + " does not exist!")
		return
	
	if not container is PieceContainer:
		push_error("Piece " + container_name + " is not a container!")
		return
	
	if not container.has_piece(piece_name):
		push_error("Container " + container_name + " does not contain piece " + piece_name)
		return
	
	var piece = container.remove_piece(piece_name)
	_pieces.add_child(piece)

# Request the server to add cards to the given hand.
# card_names: The names of the cards to add to the hand. Note that the names
# of stacks are also allowed.
# hand_id: The player ID of the hand to add the cards to.
master func request_add_cards_to_hand(card_names: Array, hand_id: int) -> void:
	var hand_name = str(hand_id)
	if hand_id <= 0:
		push_error("Hand ID " + hand_name + " is invalid!")
		return
	
	var hand = _hands.get_node(str(hand_id))
	if not hand:
		push_error("Hand " + hand_name + " does not exist!")
		return
	
	var cards = []
	for card_name in card_names:
		var piece = _pieces.get_node(card_name)
		
		if not piece:
			push_error("Piece " + card_name + " does not exist!")
			continue
		
		if not piece is Piece:
			push_error("Object " + card_name + " is not a piece!")
			continue
		
		if piece is Card:
			cards.append(piece)
		elif piece is Stack:
			var is_card = piece.is_card_stack()
			
			if not is_card:
				push_error("Stack " + card_name + " does not contain cards!")
				continue
			
			var stack_names = []
			for inst in piece.get_pieces():
				stack_names.append(inst.name)
			
			for i in range(piece.get_piece_count() - 1):
				request_pop_stack(card_name, 1, false, i + 1.0)
			
			for name in stack_names:
				var card: Card = _pieces.get_node(name)
				cards.append(card)
		else:
			push_error("Piece " + card_name + " is not a card or a stack!")
			continue
	
	for card in cards:
		var success = hand.srv_add_card(card)
		if not success:
			push_error("Card " + card.name + " could not be hovered!")

# Request the server to add cards to the nearest hand. The hand is decided
# based on the card's hover offsets.
# card_names: The names of the cards to add to the hand. Note that the names
# of stacks of cards are also allowed.
master func request_add_cards_to_nearest_hand(card_names: Array) -> void:
	var hand_id = 0
	var min_dist = null
	
	for card_name in card_names:
		var piece = _pieces.get_node(card_name)
		
		if not piece:
			push_error("Piece " + card_name + " does not exist!")
			continue
		
		if not piece is Piece:
			push_error("Object " + card_name + " is not a piece!")
			continue
		
		if piece.get("over_hand") == null:
			push_error("Piece " + card_name + " does not have the over_hand property!")
			continue
		
		if piece.over_hand > 0:
			var piece_dist = piece.srv_get_hover_offset().length()
			if (min_dist == null) or (piece_dist < min_dist):
				hand_id = piece.over_hand
				min_dist = piece_dist
	
	if hand_id <= 0:
		push_error("None of the cards were over a hand!")
		return
	
	request_add_cards_to_hand(card_names, hand_id)

# Request the server to add a pre-filled stack.
# stack_transform: The transform the new stack should have.
# stack_entry: The stack's entry in the AssetDB.
master func request_add_stack_filled(stack_transform: Transform, stack_entry: Dictionary) -> void:
	# Before we can get everyone to add the stack, we need to come up with names
	# for the stack and it's items.
	var stack_name = srv_get_next_piece_name()
	var piece_names = []
	
	for texture_path in stack_entry["texture_paths"]:
		piece_names.push_back(srv_get_next_piece_name())
	
	rpc("add_stack_filled", stack_name, stack_transform, stack_entry, piece_names)

# Request the server to collect a set of pieces and, if possible, put them into
# stacks.
# piece_names: The names of the pieces to try and collect.
master func request_collect_pieces(piece_names: Array) -> void:
	var pieces = []
	for piece_name in piece_names:
		var piece = _pieces.get_node(piece_name)
		if piece and piece is StackablePiece:
			pieces.append(piece)
	
	if pieces.size() <= 1:
		return
	
	var add_to = pieces.pop_front()
	
	while add_to:
		for i in range(pieces.size() - 1, -1, -1):
			var add_from = pieces[i]
			
			if add_to.matches(add_from):
				if add_to is Stack:
					if add_from is Stack:
						rpc("add_stack_to_stack", add_from.name, add_to.name)
					else:
						rpc("add_piece_to_stack", add_from.name, add_to.name)
				else:
					if add_from is Stack:
						rpc("add_piece_to_stack", add_to.name, add_from.name)
						
						# add_to (Piece) has been added to add_from (Stack), so
						# in future, we need to add pieces to add_from.
						add_to = add_from
					else:
						var new_stack_name = srv_get_next_piece_name()
						rpc("add_stack", new_stack_name, add_to.transform,
							add_to.name, add_from.name)
						add_to = _pieces.get_node(new_stack_name)
				
				pieces.remove(i)
		
		add_to = pieces.pop_front()

# Called by the server when the request to release a piece from a container was
# accepted.
# piece_name: The name of the piece that was just released from a container.
remotesync func request_container_release_accepted(piece_name: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	# The server has allowed us to hover the piece that has just poped off the
	# stack!
	request_hover_piece_accepted(piece_name)

# Request the server to randomly release a set amount of pieces from a
# container.
# container_name: The name of the container to release pieces from.
# n: The number of pieces to release from the container.
# hover: Do we want to start hovering the piece afterwards?
master func request_container_release_random(container_name: String, n: int, hover: bool) -> void:
	if n < 1:
		return
	
	var container = _pieces.get_node(container_name)
	
	if not container:
		push_error("Container " + container_name + " does not exist!")
		return
	
	if not container is PieceContainer:
		push_error("Piece " + container_name + " is not a container!")
		return
	
	var names = container.get_piece_names()
	if names.size() == 0:
		return
	
	# We want the selection to be random!
	if n < names.size():
		randomize()
		names.shuffle()
		names = names.slice(0, n - 1)
	
	request_container_release_these(container_name, names, hover)

# Request the server to release a given set of pieces from a container.
# container_name: The name of the container to release the pieces from.
# release_names: The list of names of the pieces to be released from the
# container.
# hover: Do we want to start hovering the piece afterwards?
master func request_container_release_these(container_name: String,
	release_names: Array, hover: bool) -> void:
	
	if release_names.size() == 0:
		return
	
	var player_id = get_tree().get_rpc_sender_id()
	var container = _pieces.get_node(container_name)
	
	if not container:
		push_error("Container " + container_name + " does not exist!")
		return
	
	if not container is PieceContainer:
		push_error("Piece " + container_name + " is not a container!")
		return
	
	var hover_box_pos   = Vector3.ZERO
	var hover_box_size  = Vector3.ZERO
	var hover_direction = 0
	
	for piece_name in release_names:
		if container.has_piece(piece_name):
			rpc("remove_piece_from_container", container_name, piece_name)
			
			if hover:
				var piece = _pieces.get_node(piece_name)
				var piece_size = piece.get_size()
				var piece_offset = hover_box_pos
				
				if hover_direction == 0:
					piece_offset.x += (hover_box_size.x + piece_size.x) / 2
				elif hover_direction == 1:
					piece_offset.z += (hover_box_size.z + piece_size.z) / 2
				elif hover_direction == 2:
					piece_offset.x -= (hover_box_size.x + piece_size.x) / 2
				else:
					piece_offset.z -= (hover_box_size.z + piece_size.z) / 2
				
				hover_box_pos = 0.5 * (hover_box_pos + piece_offset)
				if hover_direction % 2 == 0:
					hover_box_size.x += piece_size.x
					hover_box_size.z = max(hover_box_size.z, piece_size.z)
				else:
					hover_box_size.x = max(hover_box_size.x, piece_size.x)
					hover_box_size.z += piece_size.z
				hover_direction = (hover_direction + 1) % 4
				
				if piece.srv_start_hovering(player_id, piece.transform.origin, piece_offset):
					rpc_id(player_id, "request_container_release_accepted", piece_name)

# Request the server to deal cards from a stack to all players.
# stack_name: The name of the stack of cards.
# n: The number of cards to deal to each player.
master func request_deal_cards(stack_name: String, n: int) -> void:
	if n < 1:
		return
	
	var stack = _pieces.get_node(stack_name)
	
	if not stack:
		push_error("Piece " + stack_name + " does not exist!")
		return
	
	if not stack is Stack:
		push_error("Piece " + stack_name + " is not a stack!")
		return
	
	var is_card_stack = stack.is_card_stack()
	
	if not is_card_stack:
		push_error("Stack " + stack_name + " does not contain cards!")
		return
	
	var card_names = []
	for card in stack.get_pieces():
		card_names.append(card.name)
	
	for _i in range(n):
		if card_names.size() < 1:
			break
		
		for hand in _hands.get_children():
			var card_name = ""
			
			if card_names.size() < 1:
				break
			elif card_names.size() == 1:
				card_name = card_names[0]
			else:
				card_name = request_pop_stack(stack_name, 1, false, 1.0)
			
			if card_name == "":
				break
			else:
				card_names.erase(card_name)
			
			request_add_cards_to_hand([card_name], hand.owner_id())

# Request the server to flip the table.
# camera_basis: The basis matrix of the player flipping the table.
master func request_flip_table(camera_basis: Basis) -> void:
	rpc("flip_table", camera_basis)

# Request the server to hover a piece.
# piece_name: The name of the piece to hover.
# init_pos: The initial hover position.
# offset_pos: The hover position offset.
master func request_hover_piece(piece_name: String, init_pos: Vector3,
	offset_pos: Vector3) -> void:
	
	var piece = _pieces.get_node(piece_name)
	
	if not piece:
		push_error("Piece " + piece_name + " does not exist!")
		return
	
	if not piece is Piece:
		push_error("Object " + piece_name + " is not a piece!")
		return
	
	var player_id = get_tree().get_rpc_sender_id()
	
	if piece.srv_start_hovering(player_id, init_pos, offset_pos):
		rpc_id(player_id, "request_hover_piece_accepted", piece_name)

# Called by the server if the request to hover a piece was accepted.
# piece_name: The name of the piece we are now hovering.
remotesync func request_hover_piece_accepted(piece_name: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var piece = _pieces.get_node(piece_name)
	
	if not piece:
		push_error("Piece " + piece_name + " does not exist!")
		return
	
	if not piece is Piece:
		push_error("Object " + piece_name + " is not a piece!")
		return
	
	_camera_controller.append_selected_pieces([piece])
	_camera_controller.set_is_hovering(true)

# Request the server to load a table state.
# state: The state to load.
master func request_load_table_state(state: Dictionary) -> void:
	rpc("set_state", state)

# Request the server to place a hidden area registered to you.
# point1: One corner of the new hidden area.
# point2: The opposite corner of the new hidden area.
master func request_place_hidden_area(point1: Vector2, point2: Vector2) -> void:
	var player_id = get_tree().get_rpc_sender_id()
	rpc("place_hidden_area", srv_get_next_piece_name(), player_id, point1, point2)

# Request the server to pop the piece at the top of a stack.
# Returns: The name of the new piece.
# stack_name: The name of the stack to pop.
# n: The number of pieces to pop from the stack.
# hover: Do we want to start hovering the piece afterwards?
# split_dist: How far away do we want the piece from the stack when it is poped?
master func request_pop_stack(stack_name: String, n: int, hover: bool,
	split_dist: float) -> String:
	
	var player_id = get_tree().get_rpc_sender_id()
	var stack = _pieces.get_node(stack_name)
	
	if not stack:
		push_error("Stack " + stack_name + " does not exist!")
		return ""
	
	if not stack is Stack:
		push_error("Object " + stack_name + " is not a stack!")
		return ""
	
	var new_piece: Piece = null
	
	if n < 1:
		return ""
	elif n < stack.get_piece_count():
		var unit_height = stack.get_unit_height()
		var total_height = stack.get_total_height()
		var removed_height = unit_height * n
		
		# NOTE: We normalise the basis here to reset the piece's scale, because
		# add_piece will use the piece entry to scale the piece again.
		var new_basis = stack.transform.basis.orthonormalized()
		var new_origin = stack.transform.origin
		new_origin.y += total_height / 2
		# Get the new piece away from the stack so it doesn't collide with it
		# again.
		new_origin.y += split_dist + removed_height / 2
		
		if n == 1:
			var piece_instance = stack.pop_piece()
			stack.rpc("remove_piece_by_name", piece_instance.name)
			
			new_basis = (stack.transform.basis * piece_instance.transform.basis).orthonormalized()
			rpc("add_piece", piece_instance.name, Transform(new_basis, new_origin),
				piece_instance.piece_entry)
			new_piece = _pieces.get_node(piece_instance.name)
			
			piece_instance.queue_free()
		else:
			var new_name = srv_get_next_piece_name()
			var new_transform = Transform(new_basis, new_origin)
			
			new_piece = add_stack_empty(new_name, new_transform)
			rpc("add_stack_empty", new_name, new_transform)
			
			rpc("transfer_stack_contents", stack_name, new_name, n)
		
		# Move the stack down to it's new location.
		var new_stack_translation = stack.translation
		var offset = stack.transform.basis.y.normalized()
		if offset.y > 0:
			offset = -offset
		new_stack_translation += offset * (removed_height / 2)
		stack.rpc("set_translation", new_stack_translation)
		
		# If there is only one piece left in the stack, turn it into a normal
		# piece.
		if stack.get_piece_count() == 1:
			var piece_instance = stack.empty()[0]
			new_basis = (stack.transform.basis * piece_instance.transform.basis).orthonormalized()
			stack.rpc("remove_self")
			
			rpc("add_piece", piece_instance.name,
				Transform(new_basis, new_stack_translation),
				piece_instance.piece_entry)
			
			piece_instance.queue_free()
	else:
		new_piece = stack
	
	if new_piece and hover:
		if new_piece.srv_start_hovering(player_id, new_piece.transform.origin, Vector3()):
			rpc_id(player_id, "request_pop_stack_accepted", new_piece.name)
	
	return new_piece.name

# Called by the server if the request to pop a stack was accepted, and we are
# now hovering the new piece.
# piece_name: The name of the piece that is now hovering.
remotesync func request_pop_stack_accepted(piece_name: String) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	# The server has allowed us to hover the piece that has just poped off the
	# stack!
	request_hover_piece_accepted(piece_name)

# Request the server to remove a hidden area.
# area_name: The name of the hidden area to remove.
master func request_remove_hidden_area(area_name: String) -> void:
	var hidden_area = _hidden_areas.get_node(area_name)
	
	if not hidden_area:
		push_error("Hidden area " + area_name + " does not exist!")
		return
	
	if not hidden_area is HiddenArea:
		push_error("Node " + area_name + " is not a hidden area!")
		return
	
	rpc("remove_hidden_area", area_name)

# Request the server to set the lamp color.
# color: The color to set the lamp to.
master func request_set_lamp_color(color: Color) -> void:
	rpc("set_lamp_color", color)

# Request the server to set the lamp intensity.
# intensity: The intensity to set the lamp to.
master func request_set_lamp_intensity(intensity: float) -> void:
	rpc("set_lamp_intensity", intensity)

# Request the server to set the lamp type.
# sunlight: True for sunlight, false for a spotlight.
master func request_set_lamp_type(sunlight: bool) -> void:
	rpc("set_lamp_type", sunlight)

# Request the server to set the room skybox.
# skybox_entry: The skybox's entry in the asset DB.
master func request_set_skybox(skybox_entry: Dictionary) -> void:
	rpc("set_skybox", skybox_entry)

# Request the server to get a stack to collect all of the pieces that it can
# stack.
# stack_name: The name of the collecting stack.
# collect_stacks: Do we want to collect other stacks? If false, it only collects
# individual pieces.
master func request_stack_collect_all(stack_name: String, collect_stacks: bool) -> void:
	var stack = _pieces.get_node(stack_name)
	
	if not stack:
		push_error("Stack " + stack_name + " does not exist!")
		return
	
	if not stack is Stack:
		push_error("Object " + stack_name + " is not a stack!")
		return
	
	for piece in get_pieces():
		if piece is StackablePiece and piece.name != stack_name:
			if stack.matches(piece):
				if piece is Stack:
					if collect_stacks:
						rpc("add_stack_to_stack", piece.name, stack_name)
					else:
						continue
				else:
					rpc("add_piece_to_stack", piece.name, stack_name, Stack.STACK_TOP)

# Request the server to unflip the table.
master func request_unflip_table() -> void:
	rpc("unflip_table")

# Set the color of the room lamp.
# color: The color of the lamp.
remotesync func set_lamp_color(color: Color) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	_spot_light.light_color = color
	_sun_light.light_color = color

# Set the intensity of the room lamp.
# intensity: The new intensity of the lamp.
remotesync func set_lamp_intensity(intensity: float) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	_spot_light.light_energy = intensity
	_sun_light.light_energy = intensity

# Set the type of light the room lamp is emitting.
# sunlight: True for sunlight, false for a spotlight.
remotesync func set_lamp_type(sunlight: bool) -> void:
	_spot_light.visible = not sunlight
	_sun_light.visible = sunlight

# Set the room's skybox.
# skybox_entry: The skybox's entry in the asset DB. If either the texture path
# or the entry are empty, the default skybox is used.
remotesync func set_skybox(skybox_entry: Dictionary) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var default_skybox = true
	if not skybox_entry.empty():
		if skybox_entry.has("texture_path"):
			var texture_path = skybox_entry["texture_path"]
			if not texture_path.empty():
				var texture: Texture = load(texture_path)
				var panorama = PanoramaSky.new()
				panorama.panorama = texture
				
				_world_environment.environment.background_sky = panorama
				
				default_skybox = false
	
	if default_skybox:
		_world_environment.environment.background_sky = ProceduralSky.new()
	
	_world_environment.set_meta("skybox_entry", skybox_entry)

# Set the room state.
# state: The new room state.
remotesync func set_state(state: Dictionary) -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	if state.has("lamp"):
		var lamp_meta = state["lamp"]
		set_lamp_color(lamp_meta["color"])
		set_lamp_intensity(lamp_meta["intensity"])
		set_lamp_type(lamp_meta["sunlight"])
	
	if state.has("skybox"):
		set_skybox(state["skybox"])
	
	if state.has("table"):
		var table_meta = state["table"]
		
		if table_meta["is_rigid"]:
			_table_body.mode = RigidBody.MODE_RIGID
		else:
			_table_body.mode = RigidBody.MODE_STATIC
		emit_signal("table_flipped", not table_meta["is_rigid"])
		
		if get_tree().is_network_server():
			srv_set_retrieve_pieces_from_hell(not table_meta["is_rigid"])
		
		_table_preflip_state = table_meta["preflip_state"]
		_table_body.transform = table_meta["transform"]
	
	if state.has("hands"):
		for hand in _hands.get_children():
			_hands.remove_child(hand)
			hand.queue_free()
		
		for hand_id in state["hands"]:
			var hand_name = str(hand_id)
			var hand_meta = state["hands"][hand_id]
			
			if not hand_meta.has("transform"):
				push_error("Hand " + hand_name + " in new state has no transform!")
				return
			
			if not hand_meta["transform"] is Transform:
				push_error("Hand " + hand_name + " transform is not a transform!")
				return
			
			add_hand(hand_id, hand_meta["transform"])
	
	if state.has("hidden_areas"):
		for hidden_area in _hidden_areas.get_children():
			_hidden_areas.remove_child(hidden_area)
			hidden_area.queue_free()
		
		for hidden_area_name in state["hidden_areas"]:
			# Make sure the server doesn't duplicate names! We need to do this
			# because hidden areas use the same naming system as pieces do.
			if get_tree().is_network_server():
				var name_int = int(hidden_area_name)
				if name_int >= _srv_next_piece_name:
					_srv_next_piece_name = name_int + 1
			
			var hidden_area_meta = state["hidden_areas"][hidden_area_name]
			
			if not hidden_area_meta.has("player_id"):
				push_error("Hidden area " + hidden_area_name + " in new state has no player ID!")
				return
			
			if not hidden_area_meta["player_id"] is int:
				push_error("Hidden area " + hidden_area_name + " player ID is not an integer!")
				return
			
			if not hidden_area_meta.has("point1"):
				push_error("Hidden area " + hidden_area_name + " in new state has no point 1!")
				return
			
			if not hidden_area_meta["point1"] is Vector2:
				push_error("Hidden area" + hidden_area_name + " point 1 is not a Vector2!")
				return
			
			if not hidden_area_meta.has("point2"):
				push_error("Hidden area " + hidden_area_name + " in new state has no point 2!")
				return
			
			if not hidden_area_meta["point2"] is Vector2:
				push_error("Hidden area" + hidden_area_name + " point 2 is not a Vector2!")
				return
			
			var player_id = hidden_area_meta["player_id"]
			var point1 = hidden_area_meta["point1"]
			var point2 = hidden_area_meta["point2"]
			place_hidden_area(hidden_area_name, player_id, point1, point2)
	
	for child in _pieces.get_children():
		_pieces.remove_child(child)
		child.queue_free()
	
	_extract_piece_states(state, _pieces)

# Get the next hand transform. Note that there may not be a next transform, in
# which case the function returns the identity transform.
# Returns: The next hand transform.
func srv_get_next_hand_transform() -> Transform:
	var potential = []
	
	for position in _hand_positions.get_children():
		potential.append(position.transform)
	
	for hand in _hands.get_children():
		if potential.has(hand.transform):
			potential.erase(hand.transform)
	
	if potential.empty():
		return Transform.IDENTITY
	else:
		return potential[0]

# Get the next piece name.
# Returns: The next piece name.
func srv_get_next_piece_name() -> String:
	var next_name = str(_srv_next_piece_name)
	_srv_next_piece_name += 1
	return next_name

# Set whether the server should retrieve pieces from hell.
# retrieve: If the server should retrieve pieces from hell.
func srv_set_retrieve_pieces_from_hell(retrieve: bool) -> void:
	_srv_retrieve_pieces_from_hell = retrieve
	
	for piece in _pieces.get_children():
		if piece is Piece:
			piece.srv_retrieve_from_hell = retrieve

# Stop a player from currently hovering any pieces.
# player: The player to stop from hovering.
func srv_stop_player_hovering(player: int) -> void:
	for piece in _pieces.get_children():
		if piece.srv_get_hover_player() == player:
			piece.rpc_id(1, "stop_hovering")

# Start sending the player's 3D cursor position to the server.
func start_sending_cursor_position() -> void:
	_camera_controller.send_cursor_position = true

# Transfer the contents at the top of one stack to the top of another.
# stack1_name: The name of the stack to transfer contents from.
# stack2_name: The name of the stack to transfer contents to.
# n: The number of contents to transfer.
remotesync func transfer_stack_contents(stack1_name: String, stack2_name: String,
	n: int) -> void:
	
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	var stack1 = _pieces.get_node(stack1_name)
	var stack2 = _pieces.get_node(stack2_name)
	
	if not stack1:
		push_error("Stack " + stack1_name + " does not exist!")
		return
	
	if not stack2:
		push_error("Stack " + stack2_name + " does not exist!")
		return
	
	if not stack1 is Stack:
		push_error("Piece " + stack1_name + " is not a stack!")
		return
	
	if not stack2 is Stack:
		push_error("Piece " + stack2_name + " is not a stack!")
		return
	
	n = int(min(n, stack1.get_piece_count()))
	if n < 1:
		return
	
	var contents = []
	for _i in range(n):
		contents.push_back(stack1.pop_piece())
	
	var test_piece = load(contents[0].piece_entry["scene_path"]).instance()
	PieceBuilder.scale_piece(test_piece, contents[0].piece_entry["scale"])
	
	var shapes = test_piece.get_collision_shapes()
	if shapes.size() != 1:
		push_error("Piece does not have one collision shape!")
		return
	var shape = shapes[0]
	
	while not contents.empty():
		var piece = contents.pop_back()
		stack2.add_piece(piece, shape, Stack.STACK_TOP)
	
	test_piece.queue_free()

# Unflip the table from it's flipped state.
remotesync func unflip_table() -> void:
	if get_tree().get_rpc_sender_id() != 1:
		return
	
	if not _table_preflip_state.empty():
		set_state(_table_preflip_state)
		_table_preflip_state = {}
	
	_table_body.mode = RigidBody.MODE_STATIC
	_table_body.transform = Transform.IDENTITY
	
	if get_tree().is_network_server():
		srv_set_retrieve_pieces_from_hell(true)
	
	emit_signal("table_flipped", true)

# Append the states of pieces to a given dictionary.
# state: The dictionary to add the states to.
# parent: The parent node to start scanning pieces from.
# collisions: Should collision data be included in the state?
func _append_piece_states(state: Dictionary, parent: Node, collisions: bool) -> void:
	state["containers"] = {}
	state["pieces"] = {}
	state["speakers"] = {}
	state["stacks"] = {}
	state["timers"] = {}
	
	for piece in parent.get_children():
		var piece_meta = {
			"is_locked": piece.is_locked(),
			"piece_entry": piece.piece_entry,
			"transform": piece.transform
		}
		
		if piece is PieceContainer:
			var child_pieces = {}
			_append_piece_states(child_pieces, piece.get_node("Pieces"), collisions)
			
			piece_meta["pieces"] = child_pieces
			state["containers"][piece.name] = piece_meta
		
		elif piece is Stack:
			# If the piece is a stack, we don't need to store the stack's piece
			# entry, as it will figure it out itself once the first piece is
			# added.
			piece_meta.erase("piece_entry")
			
			var child_pieces = []
			for child_piece in piece.get_pieces():
				var child_piece_meta = {
					"flip_y": child_piece.transform.basis.y.y < 0,
					"name": child_piece.name,
					"piece_entry": child_piece.piece_entry
				}
				
				child_pieces.push_back(child_piece_meta)
			
			piece_meta["pieces"] = child_pieces
			state["stacks"][piece.name] = piece_meta
		
		elif piece is SpeakerPiece or piece is TimerPiece:
			piece_meta["is_music_track"] = piece.is_music_track()
			piece_meta["is_playing"] = piece.is_playing_track()
			piece_meta["is_track_paused"] = piece.is_track_paused()
			piece_meta["playback_position"] = piece.get_playback_position()
			piece_meta["track_entry"] = piece.get_track()
			piece_meta["unit_size"] = piece.get_unit_size()
			
			if piece is TimerPiece:
				piece_meta["is_timer_paused"] = piece.is_timer_paused()
				piece_meta["mode"] = piece.get_mode()
				piece_meta["time"] = piece.get_time()
				
				state["timers"][piece.name] = piece_meta
			else:
				state["speakers"][piece.name] = piece_meta
		
		else:
			if collisions:
				if piece is Card:
					piece_meta["is_collisions_on"] = piece.is_collisions_on()
			
			state["pieces"][piece.name] = piece_meta

# Extract the pieces from a room state, and add them to the scene tree.
# state: The state to extract the pieces from.
# parent: The node to add the pieces to as children.
func _extract_piece_states(state: Dictionary, parent: Node) -> void:
	_extract_piece_states_type(state, parent, "containers")
	_extract_piece_states_type(state, parent, "pieces")
	_extract_piece_states_type(state, parent, "speakers")
	_extract_piece_states_type(state, parent, "stacks")
	_extract_piece_states_type(state, parent, "timers")

# A helper function when extracting piece states from a room state.
# state: The state to extract the pieces from.
# parent: The node to add the pieces to as children.
# type_key: The key to extract from the state.
func _extract_piece_states_type(state: Dictionary, parent: Node, type_key: String) -> void:
	if not state.has(type_key):
		return
	
	for piece_name in state[type_key]:
		var piece_meta = state[type_key][piece_name]
		
		# Make sure the server doesn't duplicate piece names!
		if get_tree().is_network_server():
			var name_int = int(piece_name)
			if name_int >= _srv_next_piece_name:
				_srv_next_piece_name = name_int + 1
		
		if not piece_meta.has("is_locked"):
			push_error("Piece " + type_key + "/" + piece_name + " in new state has no is locked value!")
			return
		
		if not piece_meta["is_locked"] is bool:
			push_error("Piece " + type_key + "/" + piece_name + " is locked value is not a boolean!")
			return
		
		if not piece_meta.has("transform"):
			push_error("Piece " + type_key + "/" + piece_name + " in new state has no transform!")
			return
		
		if not piece_meta["transform"] is Transform:
			push_error("Piece " + type_key + "/" + piece_name + " transform is not a transform!")
			return
		
		# Stacks don't include their piece entry, since they can figure it out
		# themselves once the first piece is added.
		if type_key != "stacks":
			if not piece_meta.has("piece_entry"):
				push_error("Piece " + type_key + "/" + piece_name + " in new state has no piece entry!")
				return
			
			if not piece_meta["piece_entry"] is Dictionary:
				push_error("Piece " + type_key + "/" + piece_name + " entry is not a dictionary!")
				return
		
		if type_key == "stacks":
			add_stack_empty(piece_name, piece_meta["transform"])
		else:
			add_piece(piece_name, piece_meta["transform"], piece_meta["piece_entry"])
		
		var piece: Piece = _pieces.get_node(piece_name)
		if piece_meta["is_locked"]:
			piece.lock_client(piece_meta["transform"])
		
		if type_key == "containers":
			if not piece_meta.has("pieces"):
				push_error("Container piece does not have a pieces entry!")
				return
			
			if not piece_meta["pieces"] is Dictionary:
				push_error("Container pieces entry is not a dictionary!")
				return
			
			_extract_piece_states(piece_meta["pieces"], piece.get_node("Pieces"))
			if piece is PieceContainer:
				piece.recalculate_mass()
		
		elif type_key == "piece":
			if piece is Card:
				# The state can choose not to have this data.
				if piece_meta.has("is_collisions_on"):
					if not piece_meta["is_collisions_on"] is bool:
						push_error("Card " + piece_name + " collisions on is not a boolean!")
						return
					
					piece.set_collisions_on(piece_meta["is_collisions_on"])
		
		elif type_key == "stacks":
			for stack_piece_meta in piece_meta["pieces"]:
				
				if not stack_piece_meta is Dictionary:
					push_error("Stack piece is not a dictionary!")
					return
				
				if not stack_piece_meta.has("name"):
					push_error("Stack piece does not have a name!")
					return
				
				if not stack_piece_meta["name"] is String:
					push_error("Stack piece name is not a string!")
					return
				
				var stack_piece_name = stack_piece_meta["name"]
				
				if not stack_piece_meta.has("flip_y"):
					push_error("Stack piece" + stack_piece_name + " does not have a flip value!")
					return
				
				if not stack_piece_meta["flip_y"] is bool:
					push_error("Stack piece" + stack_piece_name + " flip value is not a boolean!")
					return
				
				if not stack_piece_meta.has("piece_entry"):
					push_error("Stack piece" + stack_piece_name + " does not have a piece entry!")
					return
				
				if not stack_piece_meta["piece_entry"] is Dictionary:
					push_error("Stack piece" + stack_piece_name + " entry is not a dictionary!")
					return
				
				# Add the piece normally so we can extract the mesh instance and
				# shape.
				add_piece(stack_piece_name, Transform(), stack_piece_meta["piece_entry"])
				
				# Then add it to the stack at the top (since we're going through
				# the list in order from bottom to top).
				var flip = Stack.FLIP_NO
				if stack_piece_meta["flip_y"]:
					flip = Stack.FLIP_YES
				
				add_piece_to_stack(stack_piece_name, piece_name, Stack.STACK_TOP, flip)
		
		elif type_key == "speakers" or type_key == "timers":
			if not piece_meta.has("is_music_track"):
				push_error("Speaker " + piece_name + " does not have an is music track value!")
				return
			
			if not piece_meta["is_music_track"] is bool:
				push_error("Speaker " + piece_name + " is music track value is not a boolean!")
				return
				
			if not piece_meta.has("is_playing"):
				push_error("Speaker " + piece_name + " does not have an is playing value!")
				return
			
			if not piece_meta["is_playing"] is bool:
				push_error("Speaker " + piece_name + " is playing value is not a boolean!")
				return
				
			if not piece_meta.has("is_track_paused"):
				push_error("Speaker " + piece_name + " does not have an is track paused value!")
				return
			
			if not piece_meta["is_track_paused"] is bool:
				push_error("Speaker " + piece_name + " is track paused value is not a boolean!")
				return
				
			if not piece_meta.has("playback_position"):
				push_error("Speaker " + piece_name + " does not have a playback position value!")
				return
			
			if not piece_meta["playback_position"] is float:
				push_error("Speaker " + piece_name + " playback position value is not a float!")
				return
				
			if not piece_meta.has("track_entry"):
				push_error("Speaker " + piece_name + " does not have a track entry!")
				return
			
			if not piece_meta["track_entry"] is Dictionary:
				push_error("Speaker " + piece_name + " track entry is not a dictionary!")
				return
				
			if not piece_meta.has("unit_size"):
				push_error("Speaker " + piece_name + " does not have a unit size value!")
				return
			
			if not piece_meta["unit_size"] is float:
				push_error("Speaker " + piece_name + " unit size value is not a float!")
				return
			
			if piece is SpeakerPiece:
				piece.set_track(piece_meta["track_entry"], piece_meta["is_music_track"])
				piece.set_unit_size(piece_meta["unit_size"])
				
				if piece_meta["is_playing"]:
					piece.play_track(piece_meta["playback_position"])
				
				if piece_meta["is_track_paused"]:
					piece.pause_track(piece_meta["playback_position"])
			
			if type_key == "timers":
				if not piece_meta.has("is_timer_paused"):
					push_error("Timer " + piece_name + " does not have an is timer paused value!")
					return
				
				if not piece_meta["is_timer_paused"] is bool:
					push_error("Timer " + piece_name + " is timer paused value is not a boolean!")
					return
				
				if not piece_meta.has("mode"):
					push_error("Timer " + piece_name + " does not have a mode value!")
					return
				
				if not piece_meta["mode"] is int:
					push_error("Timer " + piece_name + " mode value is not an integer!")
					return
				
				if not piece_meta.has("time"):
					push_error("Timer " + piece_name + " does not have a time value!")
					return
				
				if not piece_meta["time"] is float:
					push_error("Timer " + piece_name + " time value is not a float!")
					return
				
				if piece is TimerPiece:
					piece.set_mode(piece_meta["mode"])
					if piece_meta["is_timer_paused"]:
						piece.pause_timer_at(piece_meta["time"])
					else:
						piece.set_time(piece_meta["time"])
		
		# Finally, we may need to move the piece in the scene tree so it has a
		# different parent.
		if parent != _pieces:
			_pieces.remove_child(piece)
			parent.add_child(piece)

# Set the transform of a hidden area based on two corner points.
# hidden_area: The hidden area to set the transform of.
# point1: One corner.
# point2: The opposite corner.
func _set_hidden_area_transform(hidden_area: HiddenArea, point1: Vector2, point2: Vector2) -> void:
	var min_point = Vector2(min(point1.x, point2.x), min(point1.y, point2.y))
	var max_point = Vector2(max(point1.x, point2.x), max(point1.y, point2.y))
	var avg_point = 0.5 * (min_point + max_point)
	var point_dif = max_point - min_point
	
	hidden_area.transform.origin.x = avg_point.x
	hidden_area.transform.origin.z = avg_point.y
	
	# We're assuming here that the hidden area is never rotated.
	hidden_area.transform.basis.x.x = point_dif.x / 2
	hidden_area.transform.basis.z.z = point_dif.y / 2

func _on_container_absorbing_piece(container: PieceContainer, piece: Piece) -> void:
	if get_tree().is_network_server():
		rpc("add_piece_to_container", container.name, piece.name)

func _on_container_releasing_random_piece(container: PieceContainer) -> void:
	if get_tree().is_network_server():
		rpc_id(1, "request_container_release_random", container.name, 1, false)

func _on_piece_exiting_tree(piece: Piece) -> void:
	_camera_controller.erase_selected_pieces(piece)

func _on_stack_requested(piece1: StackablePiece, piece2: StackablePiece) -> void:
	if get_tree().is_network_server():
		if piece1 is Stack and piece2 is Stack:
			rpc("add_stack_to_stack", piece1.name, piece2.name)
		elif piece1 is Stack:
			rpc("add_piece_to_stack", piece2.name, piece1.name)
		elif piece2 is Stack:
			rpc("add_piece_to_stack", piece1.name, piece2.name)
		else:
			rpc("add_stack", srv_get_next_piece_name(), piece1.transform, piece1.name,
				piece2.name)

func _on_CameraController_adding_cards_to_hand(cards: Array, id: int):
	var names = []
	for card in cards:
		if card.get("over_hand") != null:
			names.append(card.name)
	
	if id > 0:
		rpc_id(1, "request_add_cards_to_hand", names, id)
	else:
		rpc_id(1, "request_add_cards_to_nearest_hand", names)

func _on_CameraController_collect_pieces_requested(pieces: Array):
	var names = []
	for piece in pieces:
		if piece is StackablePiece:
			names.append(piece.name)
	rpc_id(1, "request_collect_pieces", names)

func _on_CameraController_container_release_random_requested(container: PieceContainer, n: int):
	rpc_id(1, "request_container_release_random", container.name, n, true)

func _on_CameraController_container_release_these_requested(container: PieceContainer, names: Array):
	var good_names = []
	for check_name in names:
		if check_name is String:
			if container.has_piece(check_name):
				good_names.append(check_name)
	rpc_id(1, "request_container_release_these", container.name, good_names, true)

func _on_CameraController_dealing_cards(stack: Stack, n: int):
	rpc_id(1, "request_deal_cards", stack.name, n)

func _on_CameraController_hover_piece_requested(piece: Piece, offset: Vector3):
	rpc_id(1, "request_hover_piece", piece.name,
		_camera_controller.get_hover_position(), offset)

func _on_CameraController_placing_hidden_area(point1: Vector2, point2: Vector2):
	rpc_id(1, "request_place_hidden_area", point1, point2)

func _on_CameraController_pop_stack_requested(stack: Stack, n: int):
	rpc_id(1, "request_pop_stack", stack.name, n, true, 1.0)

func _on_CameraController_removing_hidden_area(hidden_area: HiddenArea):
	if _hidden_areas.is_a_parent_of(hidden_area):
		rpc_id(1, "request_remove_hidden_area", hidden_area.name)

func _on_CameraController_selecting_all_pieces():
	var pieces = _pieces.get_children()
	_camera_controller.append_selected_pieces(pieces)

func _on_CameraController_setting_hidden_area_preview_points(point1: Vector2, point2: Vector2):
	_set_hidden_area_transform(_hidden_area_preview, point1, point2)

func _on_CameraController_setting_hidden_area_preview_visible(is_visible: bool):
	_hidden_area_preview.visible = is_visible
	_hidden_area_preview.collision_layer = 1 if is_visible else 2

func _on_CameraController_setting_spawn_point(position: Vector3):
	emit_signal("setting_spawn_point", position)

func _on_CameraController_spawning_piece_at(position: Vector3):
	emit_signal("spawning_piece_at", position)

func _on_CameraController_stack_collect_all_requested(stack: Stack, collect_stacks: bool):
	rpc_id(1, "request_stack_collect_all", stack.name, collect_stacks)

func _on_GameUI_clear_pieces():
	for piece in _pieces.get_children():
		if piece is Piece:
			piece.rpc_id(1, "request_remove_self")

func _on_GameUI_rotation_amount_updated(rotation_amount: float):
	_camera_controller.set_piece_rotation_amount(rotation_amount)
