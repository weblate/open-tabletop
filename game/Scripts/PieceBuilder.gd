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

extends Node

# If a resource is loaded via the PieceBuilder (e.g. a texture or a 3D model),
# then it is very likely it will be loaded again in the future. So keep
# resources that we load into a dictionary, where the key is the path to the
# resource.
# Plus, this also makes building pieces in multiple threads safer, as we can
# control who gets control over the cache with a mutex.
var _res_cache = {}
var _res_cache_mutex = Mutex.new()

# Build a piece using an entry from the AssetDB.
# Returns: The piece corresponding to the given entry.
# piece_entry: The entry to create the piece with.
func build_piece(piece_entry: Dictionary) -> Piece:
	var piece = _load_res(piece_entry["scene_path"]).instance()
	
	# If the scene is not a piece (e.g. when importing a scene from the assets
	# folder), make it a piece so it can interact with other objects.
	if not piece is Piece:
		var scene_dir = piece_entry["scene_path"].get_base_dir()
		var build: Piece = null
		
		if scene_dir.ends_with("containers/custom"):
			build = PieceContainer.new()
			
			build.contact_monitor = true
			build.contacts_reported = 2
			
			var pieces_node = Spatial.new()
			pieces_node.name = "Pieces"
			build.add_child(pieces_node)
		elif scene_dir.ends_with("speakers/custom") or scene_dir.ends_with("timers/custom"):
			if scene_dir.ends_with("speakers/custom"):
				build = SpeakerPiece.new()
			else:
				build = TimerPiece.new()
			
			var audio_player_node = AudioStreamPlayer3D.new()
			audio_player_node.name = "AudioStreamPlayer3D"
			build.add_child(audio_player_node)
		else:
			build = Piece.new()
		
		_extract_and_shape_mesh_instances(build, piece, Transform.IDENTITY)
		
		if not piece.get_parent():
			piece.free()
		piece = build
	
	piece.mass = piece_entry["mass"]
	piece.piece_entry = piece_entry
	
	scale_piece(piece, piece_entry["scale"])
	
	# Now that the piece has been scaled, if the piece entry contains the
	# bounding box of the piece, we should take the time to adjust the centre
	# of mass of the object.
	# NOTE: The reason we offset all the collision shapes is because the
	# Bullet physics engine defines the centre of mass as the origin of the
	# rigidbody, and there is currently no way to manually define the
	# centre of mass of a rigidbody in Godot. See:
	# https://github.com/godotengine/godot-proposals/issues/945
	if piece_entry.has("bounding_box"):
		
		var bounding_box = piece_entry["bounding_box"]
		var centre_of_mass = 0.5 * (bounding_box[0] + bounding_box[1])
		
		for child in piece.get_children():
			child.transform.origin -= centre_of_mass
	
	if piece_entry.has("texture_path") and piece_entry["texture_path"] is String:
		var texture: Texture = _load_res(piece_entry["texture_path"])
		piece.apply_texture(texture)
		
		# Check if the entry has textures for more than one surface.
		var surface = 1
		while piece_entry.has("texture_path_" + str(surface)):
			texture = _load_res(piece_entry["texture_path_" + str(surface)])
			piece.apply_texture(texture, surface)
			surface += 1
	
	return piece

# Fill a stack with pieces using an entry from the AssetDB.
# stack: The stack to fill.
# stack_entry: The stack entry to use.
func fill_stack(stack: Stack, stack_entry: Dictionary) -> void:
	if stack_entry["masses"].size() != stack_entry["texture_paths"].size():
		push_error("Stack entry arrays do not match size!")
		return
	
	var single_piece = _load_res(stack_entry["scene_path"]).instance()
	if not single_piece is Piece:
		push_error("Scene path does not point to a piece!")
		return
	if single_piece.get_collision_shapes().size() != 1:
		push_error("Stackable pieces can only have one collision shape!")
		return
	if single_piece.get_mesh_instances().size() != 1:
		push_error("Stackable pieces can only have one mesh instance!")
		return
	
	scale_piece(single_piece, stack_entry["scale"])
	
	for i in range(stack_entry["texture_paths"].size()):
		var mesh = get_piece_meshes(single_piece)[0]
		var shape = single_piece.get_collision_shapes()[0]
		
		var mass = stack_entry.masses[i]
		var texture_path = stack_entry.texture_paths[i]
		
		# Create a new piece entry based on the stack entry.
		mesh.piece_entry = {
			"description": stack_entry.description,
			"mass": mass,
			"name": stack_entry.name,
			"scale": stack_entry.scale,
			"scene_path": stack_entry.scene_path,
			"texture_path": texture_path
		}
		
		# TODO: Make sure StackPieceInstances do the exact same thing as Pieces
		# when it comes to applying textures.
		var texture: Texture = _load_res(texture_path)
		var new_material = SpatialMaterial.new()
		new_material.albedo_texture = texture
		mesh.set_surface_material(0, new_material)
		
		# Cards are a special case, since they have two surfaces (one for each
		# face), so we need to make sure the second texture is accounted for.
		var type_dir = texture_path.get_base_dir()
		if type_dir.ends_with("cards"):
			var pack = type_dir.get_base_dir().get_file()
			var asset = texture_path.get_file().get_basename()
			
			var entry = AssetDB.search_type(pack, "cards", asset)
			if not entry.empty():
				var back_texture_path = entry["texture_path_1"]
				
				var back_texture: Texture = _load_res(back_texture_path)
				var back_material = SpatialMaterial.new()
				back_material.albedo_texture = back_texture
				mesh.set_surface_material(1, back_material)
				
				mesh.piece_entry["texture_path_1"] = back_texture_path
			else:
				push_error("Inferred %s/cards/%s from '%s', asset was not found in AssetDB!" % [
					pack, asset, texture_path])
		
		stack.add_piece(mesh, shape, Stack.STACK_BOTTOM, Stack.FLIP_NO)
	
	single_piece.free()

# Free the entire resource cache.
func free_cache() -> void:
	_res_cache_mutex.lock()
	_res_cache.clear()
	_res_cache_mutex.unlock()

# Create an array of StackPieceInstances from a piece, which act as mesh
# instances, but can also be inserted into stacks.
# Returns: An array of StackPieceInstances representing the piece's mesh
# instances.
# piece: The piece to get the mesh instances from.
func get_piece_meshes(piece: Piece) -> Array:
	var out = []
	for mesh_instance in piece.get_mesh_instances():
		var piece_mesh = StackPieceInstance.new()
		piece_mesh.name = piece.name
		piece_mesh.transform = piece.transform
		piece_mesh.piece_entry = piece.piece_entry
		
		# Get the scale from the mesh instance (since the rigid body itself
		# won't be scaled).
		piece_mesh.scale = mesh_instance.scale
		
		piece_mesh.mesh = mesh_instance.mesh
		for surface in range(mesh_instance.get_surface_material_count()):
			var material = mesh_instance.get_surface_material(surface)
			piece_mesh.set_surface_material(surface, material)
		
		out.append(piece_mesh)
	
	return out

# Scale a piece by changing the scale of its children collision shapes.
# piece: The piece to scale.
# scale: How much to scale the piece by.
func scale_piece(piece: Piece, scale: Vector3) -> void:
	for child in piece.get_collision_shapes():
		child.scale_object_local(scale)

# Extract mesh instances from a tree, define collision shapes for each mesh
# instance, and add them to a node.
# add_to: The node to add the collision shapes + mesh instances to.
# from: Where to start recursing from.
# transform: The transform up to that point in the recursion.
func _extract_and_shape_mesh_instances(add_to: Node, from: Node,
	transform: Transform) -> void:
	
	for child in from.get_children():
		var new_basis = transform.basis
		var new_origin = transform.origin
		
		if from is Spatial:
			new_basis = from.transform.basis * new_basis
			new_origin = from.transform.origin + new_origin
		
		var new_transform = Transform(new_basis, new_origin)
		_extract_and_shape_mesh_instances(add_to, child, new_transform)
	
	if from is MeshInstance:
		var parent = from.get_parent()
		if parent:
			parent.remove_child(from)
		
		# We also want to make sure that the mesh instance has it's own unique
		# material that isn't shared with the other instances, so when e.g. the
		# instance is being selected, not all of the instances look like they
		# are selected (see #20).
		var num_materials = from.get_surface_material_count()
		var num_surfaces  = from.mesh.get_surface_count()
		if num_materials < num_surfaces:
			push_warning("Mesh '%s' has %d surfaces, but only %d materials!" %
				[from.mesh.resource_path, num_surfaces, num_materials])
		for surface in range(num_surfaces):
			# NOTE: We always assume that imported meshes put their materials
			# into the mesh itself, not the mesh instance.
			var material = from.mesh.surface_get_material(surface)
			if material:
				material = material.duplicate()
				from.set_surface_material(surface, material)
		
		var collision_shape = CollisionShape.new()
		collision_shape.shape = from.mesh.create_convex_shape()
		
		# The collision shape's transform needs to match up with the mesh
		# instance's, but they can't both use the same transform, otherwise
		# the transform of the mesh instance will be wrong.
		var collision_transform = transform
		collision_transform.basis = from.transform.basis * collision_transform.basis
		collision_transform.origin = from.transform.origin + collision_transform.origin
		
		collision_shape.transform = collision_transform
		from.transform = Transform.IDENTITY
		
		collision_shape.add_child(from)
		add_to.add_child(collision_shape)

# Load the resource at the given path. If it is already in the cache, the cache
# version is returned. Otherwise, the resource is put into the cache before it
# is returned.
# Returns: The resource at the given path.
# path: The path of the resource to load.
func _load_res(path: String) -> Resource:
	var res: Resource
	
	_res_cache_mutex.lock()
	if _res_cache.has(path):
		res = _res_cache[path]
	else:
		res = load(path)
		_res_cache[path] = res
	_res_cache_mutex.unlock()
	
	return res
