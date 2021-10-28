extends Node

var cur_resolution = null
var tree_data = null
var sample_data = null
var spline_mode setget set_spline_mode, get_spline_mode

enum AttributeType {
	Numerical,
	Text
}

enum FilterMode {
	ShowOnly,
	HideOnly,
	Show,
	Hide
}

enum SplineMode {
	Simple,
	Advanced
}

class AttributeInfo:
	var tree_attribute = false
	var attrib_type = null

var tree_attributes = {}
var dataset_attributes = {}
var tree_classes = []
var sample_filters = {}
var node_condition_expression = null
var _spline_update_needed = false
var _autogenerated_target_filters = false

var adv_leaf_color_mode : bool setget set_adv_leaf_color_mode, get_adv_leaf_color_mode

signal tree_data_changed
signal sample_data_changed(sample)
signal sample_data_added(sample)
signal sample_data_deleted(sample)
signal sample_visibility_changed(sample)
signal sample_color_changed(sample)
signal filter_added(filter)
signal filter_changed(filter)
signal filter_deleted(filter)
signal spline_mode_changed(new_mode)
signal spline_update_needed(node)
signal adv_leaf_color_mode_changed(is_enabled)

func _ready():
	var res_w = ProjectSettings.get_setting("display/window/size/width")
	var res_h = ProjectSettings.get_setting("display/window/size/height")
	cur_resolution = Vector2(res_w, res_h)
	
	node_condition_expression = Expression.new()
	spline_mode = SplineMode.Simple

func set_adv_leaf_color_mode(is_enabled : bool):
	if adv_leaf_color_mode != is_enabled:
		adv_leaf_color_mode = is_enabled
		emit_signal("adv_leaf_color_mode_changed", is_enabled)
		
func get_adv_leaf_color_mode():
	return adv_leaf_color_mode
	
func set_spline_mode(new_mode):
	if new_mode == spline_mode:
		return
	elif new_mode == SplineMode.Advanced and not is_advanced_mode_okay():
		return
	
	spline_mode = new_mode
	emit_signal("spline_mode_changed", new_mode)

func get_spline_mode():
	return spline_mode
	
func check_spline_update_needed():
	if _spline_update_needed == true:
		_spline_update_needed = false
		# Splines need to be recalculated when the range max or min changes for a node
		if spline_mode == SplineMode.Advanced:
			emit_signal("spline_update_needed")
	
func is_advanced_mode_okay():
	if sample_data == null or sample_data.size() <= 0:
		UiCanvas.show_message_box("Error Switching Mode","You must load a sample dataset before you can switch to advanced view.")
		return false
	
	return true
	
func tree_predict(sample, node_counter = null):
	if tree_data == null:
		return null
		
	var root_node = tree_data
	var predicted_class = tree_predict_node(root_node, sample, node_counter)
	sample["prediction"] = predicted_class
	return predicted_class
	
func tree_predict_node(node, sample, node_counter = null):
	if node == null:
		return null
		
	if node_counter != null and node_counter[0] == node:
		node_counter[1] += 1
		
	if "leaf_class" in node:
		return str(node.leaf_class)
		
	var node_attribute = node.attribute
	if not node_attribute in sample.attributes:
		return null
	
	var sample_value = sample.attributes[node_attribute]
	var range_min = node.range_min
	var range_max = node.range_max
	
	# Update Node range max and min
	if sample_value < range_min:
		node.range_min = sample_value
		_spline_update_needed = true
	if sample_value > range_max:
		node.range_max = sample_value
		_spline_update_needed = true
	
	var error = node_condition_expression.parse("value " + node.operator + " threshold", ["value", "threshold"])
	if error != OK:
		print("Warning: Error evaluting node condition operator '" + node.operator + "'. Defaulting to '<'.")
		if sample_value < node.threshold:
			return tree_predict_node(node.get("child_left", null), sample, node_counter)
		else:
			return tree_predict_node(node.get("child_right", null), sample, node_counter)
	else:
		var result = bool(node_condition_expression.execute([sample_value, node.threshold]))
		if result:
			return tree_predict_node(node.get("child_left", null), sample, node_counter)
		else:
			return tree_predict_node(node.get("child_right", null), sample, node_counter)
			
func load_tree_file(path):
	var file = File.new()
	var error = file.open(path, file.READ)
	if error != OK:
		UiCanvas.show_message_box("Error opening file.", "Unable to open file: " + path)
		return false
	
	var text = file.get_as_text()
	var json_result = JSON.parse(text)
	file.close()
	
	if json_result.error != OK:
		UiCanvas.show_message_box("Error parsing JSON file.", "Unable to parse JSON: " + json_result.error_string)
		return false
		
	var result = json_result.result
	if not result is Dictionary:
		UiCanvas.show_message_box("Error parsing JSON file.", "Root object in JSON file is not a Dictionary type.")
		return false
		
	if not result.has("tree_root"):
		UiCanvas.show_message_box("Error parsing JSON file.", "JSON file is missing required tree_root object.")
		return false
	
	result = result.tree_root
	tree_attributes = {}
	dataset_attributes = {}
	tree_classes = []
	sample_data = null
	sample_filters = {}
	_autogenerated_target_filters = false
	
	if not validate_tree_data(result):
		tree_data = null
		tree_attributes = {}
		tree_classes = []
		emit_signal("tree_data_changed")
		spline_mode = SplineMode.Simple
		return false
		
	tree_data = result
	tree_classes.sort()
	emit_signal("tree_data_changed")
	spline_mode = SplineMode.Simple
	
	# Create some basic prediction filters
	for a in tree_classes:
		var original_expr = "%prediction% == \"" + a + "\""
		var parsed_expr = parse_filter_expression(original_expr)
		var expression_instance = Expression.new()
		var expr_error = expression_instance.parse(parsed_expr, ["sample"])
		
		if expr_error != OK:
			continue
		else:
			create_sample_filter(a + " Prediction", original_expr, expression_instance)
	
	return true
	
func validate_tree_data(data):
	if not data is Dictionary:
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more child nodes is not a dictionary type as expected.")
		return false

	if data.has("leaf_class"):
		if data.has("child_left") or data.has("child_right"):
			UiCanvas.show_message_box("Error parsing JSON file.", "One or more nodes have a \"leaf_class\" with children. Leaf nodes should not have any children.")
			return false
		else:
			if data.leaf_class != null and not tree_classes.has(data.leaf_class):
				tree_classes.append(str(data.leaf_class))
			return true
	else:
		if not data.has("child_left") and not data.has("child_right"):
			UiCanvas.show_message_box("Error parsing JSON file.", "One or more leaf nodes are missing the \"leaf_class\" member.")
			return false

	if not data.has("attribute"):
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more non-leaf nodes is missing the \"attribute\" member.")
		return false
		
	if not data.has("threshold"):
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more non-leaf nodes is missing the \"threshold\" member.")
		return false
		
	if not data.has("operator"):
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more non-leaf nodes is missing the \"operator\" member.")
		return false
		
	var valid_operators = ["<", "<=", ">", ">=", "==", "!="]
		
	if not data.operator in valid_operators:
		UiCanvas.show_message_box("Error parsing JSON file.", "'" + data.operator + "' is not a valid node operator. Valid options are: <, <=, >, >=, ==, !=")
		return false
		
	if data.attribute == null:
		UiCanvas.show_message_box("Error parsing JSON file.", "attribute cannot be null.")
		return false
		
	if not data.has("child_left"):
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more non-leaf nodes is missing the \"child_left\" member.")
		return false
		
	if not data.has("child_right"):
		UiCanvas.show_message_box("Error parsing JSON file.", "One or more non-leaf nodes is missing the \"child_right\" member.")
		return false
		
	if data.child_left != null and not validate_tree_data(data.child_left):
		return false
		
	if data.child_right != null and not validate_tree_data(data.child_right):
		return false
		
	if data.attribute != null and not tree_attributes.has(data.attribute):
		var info = AttributeInfo.new()
		info.tree_attribute = true
		info.attrib_type = AttributeType.Numerical
		tree_attributes[data.attribute] = info

	data["range_min"] = data.threshold
	data["range_max"] = data.threshold
	return true

func add_new_sample(new_sample_data):
	if tree_data == null:
		return
		
	if sample_data == null:
		sample_data = {}
		
	var temp_name = new_sample_data.name
	var counter = 2
	
	while temp_name in sample_data:
		temp_name = new_sample_data.name + " (" + str(counter) + ")"
		counter += 1
		
	new_sample_data.name = temp_name
	new_sample_data.visible = false
	
	tree_predict(new_sample_data)
	
	sample_data[temp_name] = new_sample_data
	
	emit_signal("sample_data_added", new_sample_data)
	
func delete_sample(sample_name):
	if sample_data == null:
		return
		
	if not sample_name in sample_data:
		return
		
	var temp_sample = sample_data[sample_name]
	sample_data.erase(sample_name)
	emit_signal("sample_data_deleted", temp_sample)

func set_sample_visibility(sample_name, is_visible):
	if sample_data == null:
		return
		
	if not sample_name in sample_data:
		return
	
	var temp_sample = sample_data[sample_name]
	if temp_sample.visible == is_visible:
		return
		
	temp_sample.visible = is_visible
	emit_signal("sample_visibility_changed", temp_sample)

func get_sample_visibility(sample_name):
	if sample_data == null:
		return false
		
	if not sample_name in sample_data:
		return false
		
	var temp_sample = sample_data[sample_name]
	return temp_sample.visible

func set_sample_color(sample_name, new_color):
	if sample_data == null:
		return
		
	if not sample_name in sample_data:
		return
	
	var temp_sample = sample_data[sample_name]
	if temp_sample.spline_color == new_color:
		return

	temp_sample.spline_color = new_color
	emit_signal("sample_color_changed", temp_sample)

func edit_sample_attributes(sample_name, new_attrib):
	if sample_data == null:
		return
		
	if not sample_name in sample_data:
		return
	
	var temp_sample = sample_data[sample_name]
	temp_sample.attributes = new_attrib
	tree_predict(temp_sample)
	emit_signal("sample_data_changed", temp_sample)

func open_samples_csv(file_path, delim):
	var file = File.new()
	var error = file.open(file_path, file.READ)
	if error != OK:
		UiCanvas.show_message_box("Error opening file.", "Unable to open file: " + file_path)
		return null
		
	var column_labels = file.get_csv_line(delim)
	if len(column_labels) <= 0:
		file.close()
		UiCanvas.show_message_box("Error reading file.", "First line in CSV file appears to be empty, expected column labels.")
		return null
		
	for a in tree_attributes.keys():
		if not a in column_labels:
			file.close()
			UiCanvas.show_message_box("Error reading file.", "Column labels is missing tree attribute: " + a)
			return null

	var column_lookup_table = {}
	
	for i in range(len(column_labels)):
		if column_labels[i].strip_edges() != "":
			column_lookup_table[column_labels[i]] = i

	var seek_pos = file.get_position()
	file.seek_end(0)
	var file_size = file.get_position()
	file.seek(seek_pos)
	
	return [column_lookup_table, file, file_size]
	
func is_numerical_string(test_str : String):
	var c_index = 0
	var period_found = false
	
	var zero_ascii = "0".to_ascii()[0]
	var nine_ascii = "9".to_ascii()[0]
	
	while c_index < test_str.length():
		var c = test_str[c_index]
		var c_ascii = c.to_ascii()[0]
		
		if c == ".":
			if period_found:
				return false
			else:
				period_found = true
		elif c == "-":
			if c_index != 0:
				return false
		elif c_ascii < zero_ascii or c_ascii > nine_ascii:
			return false
			
		c_index += 1
			
	return true
	
func import_samples_from_csv(file_handle, delim, column_lookup_table, max_rows = 100, ignore_empty = true, name_col = null, name_prefix = ""):
	var num_samples = 0
	var row_count = 0
	var num_columns = column_lookup_table.size()
	
	if name_col != null and not name_col in column_lookup_table:
		name_col = null
	
	while num_samples < max_rows and not file_handle.eof_reached():
		row_count += 1
		
		var sample_split = file_handle.get_csv_line(delim)
		if len(sample_split) < num_columns:
			print("Skipping row " + str(row_count) + ", not enough columns.")
			continue
			
		var new_sample_data = {}
		if name_col == null:
			new_sample_data["name"] = name_prefix + str(num_samples + 1)
		else:
			new_sample_data["name"] = sample_split[column_lookup_table[name_col]].strip_edges()
			if new_sample_data["name"] == "":
				new_sample_data["name"] = name_prefix + str(num_samples + 1)
			
		new_sample_data["spline_color"] = Color.gray
		
		var abort = false
		var attributes = {}
		for a in column_lookup_table.keys():
			var attrib_str = sample_split[column_lookup_table[a]].strip_edges()
			var attrib_val = 0
			var is_numerical = is_numerical_string(attrib_str)
			
			if attrib_str == "":
				print("Warning: Row " + row_count + " in dataset has missing data in attribute " + a)
				if ignore_empty:
					abort = true
					break
				else:
					attrib_val = 0
			elif is_numerical:
				attrib_val = attrib_str.to_float()
			else:
				if a in tree_attributes:
					print("Warning: Row " + row_count + " in dataset has non-numerical attribute for " + a)
					if ignore_empty:
						abort = true
						break
				else:
					attrib_val = attrib_str
				
			attributes[a] = attrib_val
			
			if not a in tree_attributes:
				if not a in dataset_attributes:
					var info = AttributeInfo.new()
					info.tree_attribute = false
					
					if is_numerical:
						info.attrib_type = AttributeType.Numerical
					else:
						info.attrib_type = AttributeType.Text
						
					dataset_attributes[a] = info
				else:
					var info = dataset_attributes[a]
					if info.attrib_type == null:
						if is_numerical:
							info.attrib_type = AttributeType.Numerical
						else:
							info.attrib_type = AttributeType.Text
					else:
						var cur_type = AttributeType.Numerical if is_numerical else AttributeType.Text
						if info.attrib_type != cur_type:
							print("Warning: Row " + row_count + " in dataset has mis-matched datatype for attribute " + a + ". Defaulting to text type.")
							info.attrib_type = AttributeType.Text
		if abort:
			continue
			
		new_sample_data["attributes"] = attributes
		add_new_sample(new_sample_data)
		num_samples += 1
		
	check_spline_update_needed()
	generate_target_filters()
	
	return num_samples

func guess_target_attribute():
	if sample_data == null:
		return null
		
	if sample_data.size() <= 0:
		return null
	
	var target_guesss = null
	var first_sample = sample_data[sample_data.keys()[0]]
	
	for a in first_sample.attributes.keys():
		var value = first_sample.attributes[a]
		if value in tree_classes:
			target_guesss = a
			
	return target_guesss

func generate_target_filters():
	if _autogenerated_target_filters:
		return
	else:
		_autogenerated_target_filters = true

	var target_attribute_guess = guess_target_attribute()
	if target_attribute_guess == null:
		return

	for a in tree_classes:
		var original_expr = "%prediction% == \"" + a + "\" and $" + target_attribute_guess + "$ == \"" + a + "\""
		var parsed_expr = parse_filter_expression(original_expr)
		var expression_instance = Expression.new()
		var expr_error = expression_instance.parse(parsed_expr, ["sample"])
		
		if expr_error != OK:
			continue
		else:
			create_sample_filter("Correct " + a + " Prediction", original_expr, expression_instance)

	for a in tree_classes:
		var original_expr = "%prediction% == \"" + a + "\" and $" + target_attribute_guess + "$ != \"" + a + "\""
		var parsed_expr = parse_filter_expression(original_expr)
		var expression_instance = Expression.new()
		var expr_error = expression_instance.parse(parsed_expr, ["sample"])
		
		if expr_error != OK:
			continue
		else:
			create_sample_filter("Incorrect " + a + " Prediction", original_expr, expression_instance)
			
func create_sample_filter(filter_name, original_expr, expr_instance):
	if tree_data == null:
		return
		
	if sample_filters == null:
		sample_filters = {}
		
	var new_filter = {}
		
	var temp_name = filter_name
	var counter = 2
	
	while temp_name in sample_filters:
		temp_name = filter_name + " (" + str(counter) + ")"
		counter += 1
	
	filter_name = temp_name
	
	new_filter["name"] = filter_name
	new_filter["original_expr"] = original_expr
	new_filter["expr_instance"] = expr_instance
	
	sample_filters[filter_name] = new_filter
	emit_signal("filter_added", new_filter)
	
func change_sample_filter(filter_name, original_expr, expr_instance):
	if tree_data == null:
		return
		
	if sample_filters == null:
		sample_filters = {}
		
	if not filter_name in sample_filters:
		return
		
	var temp_filter = sample_filters[filter_name]
	temp_filter["original_expr"] = original_expr
	temp_filter["expr_instance"] = expr_instance
	
	emit_signal("filter_changed", temp_filter)
	
func delete_sample_filter(filter_name):
	if tree_data == null:
		return
		
	if not filter_name in sample_filters:
		return
		
	var temp_filter = sample_filters[filter_name]
	sample_filters.erase(filter_name)
	emit_signal("filter_deleted", temp_filter)
	
func parse_filter_expression(expr_str : String):
#	var char_index = 1
#	while char_index < expr_str.length():
#		if expr_str[char_index] == "=" and expr_str[char_index - 1] != "=":
#			expr_str = expr_str.insert(char_index, "=")
#			char_index += 1
#		char_index += 1
	
	if tree_attributes != null:
		for a in tree_attributes.keys():
			expr_str = expr_str.replacen("$" + a + "$", "sample.attributes.get(\"" + a + "\", 0)")
		for a in dataset_attributes.keys():
			var attrib_info = dataset_attributes[a]
			if attrib_info.attrib_type == AttributeType.Text:
				expr_str = expr_str.replacen("$" + a + "$", "str(sample.attributes.get(\"" + a + "\", ''))")
			else:
				expr_str = expr_str.replacen("$" + a + "$", "sample.attributes.get(\"" + a + "\", 0)")
			
	if tree_classes != null:
		expr_str = expr_str.replacen("%prediction%", "sample.get(\"prediction\", \"\")")
			
	return expr_str

func apply_filter(filter_name : String, mode):
	if tree_data == null:
		return
		
	if not filter_name in sample_filters:
		return
		
	if sample_data == null or sample_data.size() == 0:
		return
		
	var filter = sample_filters[filter_name]
	var filter_expr = filter.expr_instance
	
	var num_shown = 0
	var num_hidden = 0
	
	for s in sample_data.keys():
		var sample = sample_data[s]
		var expr_passed = filter_expr.execute([sample], self)
		if expr_passed == null:
			UiCanvas.show_message_box("Error executing filter expression", filter_expr.get_error_text())
			return
			
		expr_passed = bool(expr_passed)
		
		if mode == FilterMode.ShowOnly:
			set_sample_visibility(s, expr_passed)
		elif mode == FilterMode.HideOnly:
			set_sample_visibility(s, not expr_passed)
		elif mode == FilterMode.Show and expr_passed:
			set_sample_visibility(s, true)
		elif mode == FilterMode.Hide and expr_passed:
			set_sample_visibility(s, false)
			
		if sample.visible:
			num_shown += 1
		else:
			num_hidden += 1
			
	UiCanvas.show_message_box("Filter Applied.", "Samples Visible: " + str(num_shown) + "\nSamples Hidden: " + str(num_hidden))
	
